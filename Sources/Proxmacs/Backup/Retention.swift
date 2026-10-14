import Foundation

/// Which backups a retention policy keeps, with Proxmox Backup Server's prune semantics: keep-last first,
/// then for each period (day, ISO week, month, year) the newest backup of each of the N most recent periods
/// not already covered by a backup kept by an earlier option.
enum Retention {
    /// `dates` newest first; returns the indices to keep. A policy with every option at 0 keeps everything.
    static func kept(_ dates: [Date], policy: BackupPolicy, calendar: Calendar = .current) -> Set<Int> {
        let options = [policy.keep, policy.keepDaily, policy.keepWeekly, policy.keepMonthly, policy.keepYearly]
        guard options.contains(where: { $0 > 0 }) else { return Set(dates.indices) }

        var keep = Set(dates.indices.prefix(max(policy.keep, 0)))
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let periods: [(Int, (Date) -> String)] = [
            (policy.keepDaily, { d in let c = calendar.dateComponents([.year, .month, .day], from: d); return "\(c.year!)-\(c.month!)-\(c.day!)" }),
            (policy.keepWeekly, { d in let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d); return "\(c.yearForWeekOfYear!)-W\(c.weekOfYear!)" }),
            (policy.keepMonthly, { d in let c = calendar.dateComponents([.year, .month], from: d); return "\(c.year!)-\(c.month!)" }),
            (policy.keepYearly, { d in "\(calendar.component(.year, from: d))" }),
        ]
        for (count, period) in periods where count > 0 {
            let covered = Set(keep.map { period(dates[$0]) })
            var included = Set<String>()
            for index in dates.indices where !keep.contains(index) {
                let id = period(dates[index])
                if covered.contains(id) || included.contains(id) { continue }
                if included.count >= count { break }
                included.insert(id)
                keep.insert(index)
            }
        }
        return keep
    }
}
