import Foundation

struct HostInterface: Hashable, Identifiable {
    var device: String
    var name: String
    var id: String { device }
}

enum NetworkInterfaces {
    /// Physical ports from `networksetup -listallhardwareports`, excluding bridges and Thunderbolt ports.
    static func list() async -> [HostInterface] {
        guard let out = try? await Shell.check("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return [] }
        var result: [HostInterface] = []
        var port: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") {
                port = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let name = port {
                let device = String(line.dropFirst("Device: ".count))
                if !device.hasPrefix("bridge"), !name.hasPrefix("Thunderbolt") {
                    result.append(HostInterface(device: device, name: name))
                }
                port = nil
            }
        }
        return result
    }

    /// Interface carrying the default route (the natural bridge target).
    static func defaultRoute() async -> String? {
        guard let out = try? await Shell.check("/sbin/route", ["-n", "get", "default"]) else { return nil }
        return out.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }
            .map { $0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces) }
    }
}
