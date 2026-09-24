import Foundation
import Darwin

/// Local Service Discovery (BEP 14): a BT-SEARCH announcement, HTTP-ish text
/// sent to a well-known multicast group so peers on the same LAN find each
/// other without a tracker or the DHT.
enum LSDMessage {
    static let multicastHost = "239.192.152.143"
    static let multicastPort: UInt16 = 6771

    static func encode(port: UInt16, infoHashes: [InfoHash], cookie: String) -> Data {
        var lines = [
            "BT-SEARCH * HTTP/1.1",
            "Host: \(multicastHost):\(multicastPort)",
            "Port: \(port)",
        ]
        for hash in infoHashes { lines.append("Infohash: \(hash.hexString)") }
        lines.append("cookie: \(cookie)")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    struct Parsed {
        let port: UInt16
        let infoHashes: [InfoHash]
        let cookie: String?
    }

    static func parse(_ data: Data) -> Parsed? {
        guard let text = String(data: data, encoding: .utf8),
              text.uppercased().hasPrefix("BT-SEARCH")
        else { return nil }
        var port: UInt16?
        var hashes: [InfoHash] = []
        var cookie: String?
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "port": port = UInt16(value)
            case "infohash": if let hash = InfoHash(hex: value) { hashes.append(hash) }
            case "cookie": cookie = value
            default: break
            }
        }
        guard let port, !hashes.isEmpty else { return nil }
        return Parsed(port: port, infoHashes: hashes, cookie: cookie)
    }
}

/// Sends and receives LSD announcements on the LAN multicast group. Best-effort:
/// failures (no multicast route, sandboxing) leave everything else working.
actor LSDService {
    /// Called with a discovered peer and the info hashes it announced.
    typealias Handler = @Sendable (PeerAddress, [InfoHash]) -> Void

    private var fd: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// Random per-run token so we ignore our own multicast echoes.
    private let cookie = String(UInt32.random(in: .min ... .max), radix: 16)

    enum LSDError: Error { case setup(String) }

    func start(handler: @escaping Handler) throws {
        guard fd < 0 else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw LSDError.setup("socket") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        // A failed send must not raise SIGPIPE and take the process down (see PortMapper).
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = LSDMessage.multicastPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw LSDError.setup("bind") }

        // Join the multicast group on the default interface.
        var mreq = ip_mreq()
        inet_pton(AF_INET, LSDMessage.multicastHost, &mreq.imr_multiaddr)
        mreq.imr_interface.s_addr = INADDR_ANY
        guard setsockopt(
            fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)
        ) == 0 else {
            Darwin.close(fd)
            throw LSDError.setup("join")
        }
        var ttl: UInt8 = 1 // stay on the local segment
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let ourCookie = cookie
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "lsd-udp")
        )
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var sender = sockaddr_in()
                var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let received = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buffer, buffer.count, 0, sa, &senderLength)
                    }
                }
                guard received > 0 else { break }
                guard let message = LSDMessage.parse(Data(buffer[0..<received])),
                      message.cookie != ourCookie
                else { continue }
                var senderAddr = sender.sin_addr
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &senderAddr, &host, socklen_t(INET_ADDRSTRLEN))
                handler(
                    PeerAddress(host: String(cString: host), port: message.port),
                    message.infoHashes
                )
            }
        }
        // See UDPSocket: closing alongside `cancel()` races the event handler.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    /// Announces the given torrents' presence and our listening port.
    func announce(port: UInt16, infoHashes: [InfoHash]) {
        guard fd >= 0, port != 0, !infoHashes.isEmpty else { return }
        let data = LSDMessage.encode(port: port, infoHashes: infoHashes, cookie: cookie)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = LSDMessage.multicastPort.bigEndian
        inet_pton(AF_INET, LSDMessage.multicastHost, &addr.sin_addr)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func stop() {
        source?.cancel() // the cancel handler closes the descriptor
        source = nil
        fd = -1          // stops `announce` using it in the meantime
    }
}
