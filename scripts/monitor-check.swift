import Foundation

enum Paths {
    static let support = URL(fileURLWithPath: "/private/tmp/proxmacs-monitor-unit-tests")
    static func tartVMDir(_ name: String) -> URL { support.appending(path: "vms/\(name)") }
}
@main enum MonitorChecks {
    static func main() async {
        precondition(ExternalMonitor.state(serviceOutput: "\tstate = running\n", executable: "/bin/bash") == "stopped")
        precondition(ExternalMonitor.state(serviceOutput: "\tstate = running\n", executable: "/opt/virtual-machines/tart\n") == "running")
        precondition(ExternalMonitor.state(serviceOutput: "state = not running", executable: "") == "stopped")
        precondition(ExternalMonitor.state(serviceOutput: "state = running", executable: "") == "unknown")
        let missing = await ExternalMonitor.state(.init(service: "system/dev.proxmacs.nonexistent-monitor-test", ip: "192.0.2.1", diskGB: 200))
        precondition(missing == "unknown")
        print("PASS: running/stopped/waiting/unknown state; failed service query.")
    }
}
