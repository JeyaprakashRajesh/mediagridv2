import Foundation
import Darwin

/// Wake-on-LAN magic packet (6 x FF, then the PC's MAC 16 times) over UDP port 9, sent to the PC's subnet broadcast address,
/// the global broadcast address and the PC's last known IP.
/// Caveat: iOS only allows broadcast for apps with Apple's multicast entitlement, so a sideloaded build may be refused.
enum WakeOnLAN {
    static func send(mac: String, host: String) -> Bool {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for target in targets(host) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            let n = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if n == packet.count { sent = true }
        }
        return sent
    }

    private static func targets(_ host: String) -> [String] {
        let ip = host.split(separator: ":").first.map(String.init) ?? ""
        let p = ip.split(separator: ".")
        var t = ["255.255.255.255"]
        if p.count == 4 { t.insert("\(p[0]).\(p[1]).\(p[2]).255", at: 0); t.append(ip) }   // assumes a /24 home network
        return t
    }
}
