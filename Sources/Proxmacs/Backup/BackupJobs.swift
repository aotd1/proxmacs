import Foundation

enum NotifyWhen: String, Codable, CaseIterable {
    case never, failure, always
}

/// A scheduled backup of several VMs (Proxmox: Datacenter → Backup). Retention is per VM (BackupPolicy).
struct BackupJob: Codable, Hashable, Identifiable {
    enum Selection: String, Codable, CaseIterable {
        /// Every VM, including ones created later.
        case all
        /// Only the listed VMs.
        case include
        /// Every VM except the listed ones.
        case exclude
    }

    var id = UUID().uuidString.lowercased()
    var enabled = true
    var comment = ""
    /// ISO weekdays, 1 = Monday … 7 = Sunday; empty = every day.
    var days: [Int] = []
    var hour = 3
    var minute = 0
    var selection: Selection = .all
    var vms: [String] = []
    var notify: NotifyWhen = .failure
    /// Offsite target id the VMs are backed up to directly; nil = local backups.
    var target: String?
    /// Runs are due only after this (creation or last schedule change), so a new job doesn't run at once
    /// for a time already passed today.
    var since = Date()
    var lastRun: Date?
    var lastOK: Bool?
    var lastMessage: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 3
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        selection = try c.decodeIfPresent(Selection.self, forKey: .selection) ?? .all
        vms = try c.decodeIfPresent([String].self, forKey: .vms) ?? []
        notify = try c.decodeIfPresent(NotifyWhen.self, forKey: .notify) ?? .failure
        target = try c.decodeIfPresent(String.self, forKey: .target)
        since = try c.decodeIfPresent(Date.self, forKey: .since) ?? Date()
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastOK = try c.decodeIfPresent(Bool.self, forKey: .lastOK)
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
    }

    var title: String { comment.isEmpty ? "Backup job \(scheduleLabel)" : comment }

    func selects(_ vm: String) -> Bool {
        switch selection {
        case .all: true
        case .include: vms.contains(vm)
        case .exclude: !vms.contains(vm)
        }
    }

    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var scheduleLabel: String {
        let time = String(format: "%02d:%02d", hour, minute)
        let sorted = Set(days).sorted()
        if sorted.isEmpty || sorted.count == 7 { return "daily at \(time)" }
        if sorted == [1, 2, 3, 4, 5] { return "weekdays at \(time)" }
        if sorted == [6, 7] { return "weekends at \(time)" }
        return sorted.map { Self.dayNames[$0 - 1] }.joined(separator: ", ") + " at \(time)"
    }

    private static func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    private func runs(_ day: Date, _ calendar: Calendar) -> Bool {
        days.isEmpty || days.contains(Self.isoWeekday(day, calendar))
    }

    /// The latest scheduled time at or before `now`.
    func lastOccurrence(before now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today), runs(day, calendar),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), time <= now else { continue }
            return time
        }
        return nil
    }

    func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), runs(day, calendar),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), time > now else { continue }
            return time
        }
        return nil
    }

    /// A run missed while the Mac slept or Proxmacs wasn't running is caught up within 12 hours.
    func isDue(_ now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, let occurrence = lastOccurrence(before: now, calendar: calendar) else { return false }
        return occurrence > max(since, lastRun ?? .distantPast) && now.timeIntervalSince(occurrence) < 12 * 3600
    }

    func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw ProxmacsError("Invalid time") }
        guard days.allSatisfy((1...7).contains) else { throw ProxmacsError("Days are 1 (Monday) to 7 (Sunday)") }
        if selection == .include, vms.isEmpty { throw ProxmacsError("Select at least one VM") }
        guard comment.count <= 200 else { throw ProxmacsError("Comment is too long") }
        if let target, TargetStore.target(target) == nil { throw ProxmacsError("Unknown backup target \(target)") }
    }
}

/// Backup jobs live in jobs.json.
enum JobStore {
    static let file = Paths.support.appending(path: "jobs.json")

    static func load() -> [BackupJob] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder.proxmacs.decode([BackupJob].self, from: data)) ?? []
    }

    static func save(_ jobs: [BackupJob]) throws {
        try JSONEncoder.proxmacs.encode(jobs).write(to: file, options: .atomic)
    }

    static func job(_ id: String) -> BackupJob? { load().first { $0.id == id } }

    static func upsert(_ job: BackupJob) throws {
        try job.validate()
        var jobs = load()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
        try save(jobs)
    }

    static func update(_ id: String, _ change: (inout BackupJob) -> Void) {
        var jobs = load()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        try? save(jobs)
    }

    static func remove(_ id: String) throws {
        try save(load().filter { $0.id != id })
    }

    /// Older versions scheduled backups per VM (daily at an hour). The first start with jobs turns each
    /// such hour into a job for those VMs.
    static func migrate() {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        var byHour: [Int: [String]] = [:]
        for name in VMMeta.allNames() {
            guard var meta = VMMeta.load(name), meta.backup.daily else { continue }
            byHour[meta.backup.hour, default: []].append(name)
            meta.backup.daily = false
            try? meta.save()
        }
        let jobs = byHour.keys.sorted().map { hour -> BackupJob in
            var job = BackupJob()
            job.hour = hour
            job.selection = .include
            job.vms = byHour[hour]!.sorted()
            job.comment = "Daily backup"
            return job
        }
        try? save(jobs)
    }
}
