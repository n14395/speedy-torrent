// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// A bound IPv4 UDP socket for DHT traffic (one socket, many peers), built on
/// BSD sockets + DispatchSource since Network.framework has no connectionless
/// server mode.
actor UDPSocket {
    typealias DatagramHandler = @Sendable (Data, PeerAddress) -> Void

    private var fd: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private(set) var port: UInt16 = 0

    enum SocketError: Error {
        case openFailed(String)
    }

    func open(port requestedPort: UInt16, handler: @escaping DatagramHandler) throws {
        guard fd < 0 else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError.openFailed("socket: \(errno)") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Darwin raises SIGPIPE on a datagram send too — after an ICMP unreachable
        // from one of the many DHT peers bootstrapped at launch, for instance — and
        // the default disposition kills the whole process. Make the send fail with
        // EPIPE instead; nothing here has a reason to stop the app over one peer.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketError.openFailed("bind: \(errno)")
        }

        // Learn the actual port when 0 was requested.
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.port = UInt16(bigEndian: bound.sin_port)
        self.fd = fd

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "dht-udp")
        )
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var sender = sockaddr_in()
                var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let received = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buffer, buffer.count, 0, sa, &senderLength)
                    }
                }
                guard received > 0 else { break }
                var addressBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var senderAddr = sender.sin_addr
                inet_ntop(AF_INET, &senderAddr, &addressBytes, socklen_t(INET_ADDRSTRLEN))
                let address = PeerAddress(
                    host: String(cString: addressBytes),
                    port: UInt16(bigEndian: sender.sin_port)
                )
                handler(Data(buffer[0..<received]), address)
            }
        }
        // Close through the cancel handler, which GCD runs only once the event
        // handler has returned. Closing alongside `cancel()` could pull the
        // descriptor out from under an in-flight `recvfrom` — and once the
        // number is recycled elsewhere in the process, read from whatever
        // reclaimed it.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    /// Fire-and-forget send; `address.host` must be an IPv4 dotted quad.
    func send(_ data: Data, to address: PeerAddress) {
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = address.port.bigEndian
        guard inet_pton(AF_INET, address.host, &addr.sin_addr) == 1 else { return }
        let sent = data.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, rawBuffer.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        _ = sent
    }

    func close() {
        source?.cancel() // the cancel handler closes the descriptor
        source = nil
        fd = -1          // stops `send` using it in the meantime
    }
}

enum DNSResolver {
    /// Blocking getaddrinfo dispatched off-actor; IPv4 only.
    static func resolveIPv4(_ host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var current: UnsafeMutablePointer<addrinfo>? = first
                while let node = current {
                    if node.pointee.ai_family == AF_INET, let sa = node.pointee.ai_addr {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var addr = sin.pointee.sin_addr
                            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                                addresses.append(String(cString: buffer))
                            }
                        }
                    }
                    current = node.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}
