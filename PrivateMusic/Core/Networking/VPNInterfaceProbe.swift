import Darwin
import Foundation

enum VPNDetectionPolicy {
    /// A tunnel is a hint, not proof of a VPN. Link-local system tunnels alone
    /// must not produce warnings, and VPNs on a router cannot be detected here.
    static func isTunnelHint(name: String, address: String, isUp: Bool) -> Bool {
        guard isUp, ["utun", "tun", "tap", "ppp", "ipsec"].contains(where: name.hasPrefix) else { return false }
        let value = address.lowercased().split(separator: "%").first.map(String.init) ?? ""
        guard !value.isEmpty, value != "::", value != "::1", value != "0.0.0.0",
              !value.hasPrefix("127."), !value.hasPrefix("169.254."),
              !value.hasPrefix("fe80:") else { return false }
        return true
    }
}

enum VPNInterfaceProbe {
    static func hasTunnelHint() -> Bool {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return false }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let entry = pointer.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, let name = entry.ifa_name,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if VPNDetectionPolicy.isTunnelHint(name: String(cString: name), address: String(cString: host),
                                               isUp: entry.ifa_flags & UInt32(IFF_UP) != 0) { return true }
        }
        return false
    }
}
