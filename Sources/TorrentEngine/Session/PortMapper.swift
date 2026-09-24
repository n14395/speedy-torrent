// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import SystemConfiguration

/// The state of the router port mapping, for display.
public enum PortMappingStatus: Sendable, Equatable {
    case disabled
    case mapping
    /// Incoming connections should reach us on `externalPort` via `method`.
    case mapped(externalPort: UInt16, method: String)
    case failed(String)

    public var summary: String {
        switch self {
        case .disabled: "Off"
        case .mapping: "Mapping…"
        case .mapped(let port, let method): "Mapped · port \(port) (\(method))"
        case .failed(let reason): "Unavailable — \(reason)"
        }
    }
}

/// NAT-PMP (RFC 6886) TCP port mapping so peers behind a home router can reach
/// the listening port. PCP-capable routers also honor NAT-PMP for backward
/// compatibility (RFC 6887 §1), so this one protocol covers the common cases;
/// UPnP-IGD and native PCP are possible future additions.
///
/// Everything here is best-effort: failure leaves outgoing connectivity intact
/// and is surfaced only as status.
actor PortMapper {
    private var current: PortMappingStatus = .disabled
    private var loop: Task<Void, Never>?
    private var internalPort: UInt16 = 0
    /// Requested mapping lifetime (RFC 6886 recommends 7200s).
    private let requestedLifetime: UInt32 = 7200

    func status() -> PortMappingStatus { current }

    func start(internalPort: UInt16) {
        guard internalPort != 0 else { return }
        self.internalPort = internalPort
        loop?.cancel()
        current = .mapping
        loop = Task { await self.run() }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
        // Politely release the mapping (lifetime 0) if we held one.
        if case .mapped = current, let gateway = Self.defaultGateway() {
            _ = try? await Self.natpmpMap(
                gateway: gateway, internalPort: internalPort, lifetime: 0
            )
        }
        current = .disabled
    }

    private func run() async {
        while !Task.isCancelled {
            let grantedLifetime = await attempt()
            // Renew at half the granted lifetime; retry sooner on failure.
            let delay = grantedLifetime > 0 ? max(60, Int(grantedLifetime) / 2) : 300
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    /// One mapping attempt; returns the granted lifetime (0 on failure).
    private func attempt() async -> UInt32 {
        guard let gateway = Self.defaultGateway() else {
            current = .failed("no router found")
            return 0
        }
        do {
            let result = try await Self.natpmpMap(
                gateway: gateway, internalPort: internalPort, lifetime: requestedLifetime
            )
            guard result.resultCode == 0 else {
                current = .failed("router refused (code \(result.resultCode))")
                return 0
            }
            current = .mapped(externalPort: result.externalPort, method: "NAT-PMP")
            return result.lifetime
        } catch {
            current = .failed("no response from router")
            return 0
        }
    }

    // MARK: - Gateway discovery

    /// The default IPv4 gateway from SystemConfiguration, if any.
    static func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "SpeedyTorrent" as CFString, nil, nil),
              let info = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/IPv4" as CFString
              ) as? [String: Any],
              let router = info["Router"] as? String
        else { return nil }
        return router
    }

    // MARK: - NAT-PMP protocol

    enum PortMapError: Error { case noResponse }

    static func natpmpMap(
        gateway: String, internalPort: UInt16, lifetime: UInt32
    ) async throws -> NATPMP.MapResult {
        let request = NATPMP.mapRequest(
            internalPort: internalPort, externalPort: internalPort, lifetime: lifetime
        )
        // RFC 6886 retransmission: 250ms, doubling. A few tries is plenty on a LAN.
        for timeoutMs in [250, 500, 1000] {
            if let data = await exchange(gateway: gateway, payload: request, timeoutMs: timeoutMs),
               let result = NATPMP.parseMapResponse(data) {
                return result
            }
        }
        throw PortMapError.noResponse
    }

    /// Sends one datagram to the gateway's NAT-PMP port and awaits one reply.
    private static func exchange(gateway: String, payload: Data, timeoutMs: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
                guard fd >= 0 else { continuation.resume(returning: nil); return }
                defer { Darwin.close(fd) }
                // This socket is connected, and on Darwin a `send` on a connected UDP
                // socket raises SIGPIPE once the gateway has answered with ICMP port
                // unreachable (no NAT-PMP there) — the default disposition then kills
                // the whole app seconds after launch. Fail the send with EPIPE instead.
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(5351).bigEndian
                guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else {
                    continuation.resume(returning: nil); return
                }
                let connected = withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connected == 0 else { continuation.resume(returning: nil); return }

                var tv = timeval(
                    tv_sec: timeoutMs / 1000,
                    tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000)
                )
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
                guard sent == payload.count else { continuation.resume(returning: nil); return }

                var buffer = [UInt8](repeating: 0, count: 64)
                let received = Darwin.recv(fd, &buffer, buffer.count, 0)
                guard received > 0 else { continuation.resume(returning: nil); return }
                continuation.resume(returning: Data(buffer[0..<received]))
            }
        }
    }
}

/// NAT-PMP (RFC 6886) request/response codecs — pure and unit-testable.
enum NATPMP {
    /// A port-mapping request (opcode 1 = UDP, 2 = TCP). Lifetime 0 deletes.
    static func mapRequest(
        internalPort: UInt16, externalPort: UInt16, lifetime: UInt32, tcp: Bool = true
    ) -> Data {
        var data = Data(capacity: 12)
        data.appendUInt8(0)            // version
        data.appendUInt8(tcp ? 2 : 1) // opcode
        data.appendUInt16(0)          // reserved
        data.appendUInt16(internalPort)
        data.appendUInt16(externalPort)
        data.appendUInt32(lifetime)
        return data
    }

    struct MapResult: Equatable, Sendable {
        let resultCode: UInt16
        let internalPort: UInt16
        let externalPort: UInt16
        let lifetime: UInt32
    }

    static func parseMapResponse(_ data: Data, tcp: Bool = true) -> MapResult? {
        guard data.count >= 16,
              data.readUInt8(at: 0) == 0,                    // version
              data.readUInt8(at: 1) == (tcp ? 130 : 129),    // opcode | 0x80
              let resultCode = data.readUInt16(at: 2),
              let internalPort = data.readUInt16(at: 8),
              let externalPort = data.readUInt16(at: 10),
              let lifetime = data.readUInt32(at: 12)
        else { return nil }
        return MapResult(
            resultCode: resultCode,
            internalPort: internalPort,
            externalPort: externalPort,
            lifetime: lifetime
        )
    }
}
