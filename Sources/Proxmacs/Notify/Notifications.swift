import Foundation

/// A webhook notifications are posted to (Proxmox: Datacenter → Notifications). The URL usually embeds
/// a token, so it is kept in secrets.json.
struct NotificationTarget: Codable, Hashable, Identifiable {
    /// Body shape: generic JSON, Discord or Slack incoming webhooks, or an ntfy topic URL (ntfy.sh or self-hosted).
    enum Format: String, Codable, CaseIterable { case json, discord, slack, ntfy }

    var id = UUID().uuidString.lowercased()
    var name: String
    var enabled = true
    var format: Format = .json
    /// Host of the webhook URL, for display (the URL is a secret).
    var host: String?

    var secretKey: String { "notify-\(id)" }
    var location: String { "\(format.rawValue) → \(host ?? "?")" }
}

enum NotificationStore {
    static let file = Paths.support.appending(path: "notifications.json")

    static func load() -> [NotificationTarget] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder.proxmacs.decode([NotificationTarget].self, from: data)) ?? []
    }

    static func save(_ targets: [NotificationTarget]) throws {
        try JSONEncoder.proxmacs.encode(targets).write(to: file, options: .atomic)
    }

    static func target(_ idOrName: String) -> NotificationTarget? {
        load().first { $0.id == idOrName || $0.name == idOrName }
    }

    /// `url`: the webhook URL; nil keeps the stored one.
    static func upsert(_ target: NotificationTarget, url: String?) throws {
        var target = target
        guard !target.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ProxmacsError("Name is required") }
        let stored = url ?? Secrets.get(target.secretKey)
        guard let stored, let parsed = URL(string: stored), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host(), !host.isEmpty else {
            throw ProxmacsError("Enter the webhook URL (https://…)")
        }
        target.host = host
        var targets = load()
        if targets.contains(where: { $0.name == target.name && $0.id != target.id }) {
            throw ProxmacsError("A notification target named \(target.name) already exists")
        }
        if let index = targets.firstIndex(where: { $0.id == target.id }) { targets[index] = target } else { targets.append(target) }
        try save(targets)
        if let url { try Secrets.set(target.secretKey, url) }
    }

    static func remove(_ id: String) throws {
        guard let target = target(id) else { return }
        try save(load().filter { $0.id != target.id })
        try Secrets.set(target.secretKey, nil)
    }
}

enum Notifier {
    /// Sends to every enabled target; returns one line per target that failed.
    static func broadcast(title: String, message: String, failed: Bool) async -> [String] {
        var errors: [String] = []
        for target in NotificationStore.load() where target.enabled {
            do {
                try await send(target, title: title, message: message, failed: failed)
            } catch {
                errors.append("\(target.name): \(error.localizedDescription)")
            }
        }
        return errors
    }

    static func send(_ target: NotificationTarget, title: String, message: String, failed: Bool) async throws {
        guard let secret = Secrets.get(target.secretKey), let url = URL(string: secret) else {
            throw ProxmacsError("No webhook URL stored")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        let host = ProcessInfo.processInfo.hostName
        switch target.format {
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "title": title, "message": message, "severity": failed ? "error" : "info", "host": host, "source": "proxmacs",
            ])
        case .discord:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["content": "**\(title)**\n\(message)"])
        case .slack:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": "*\(title)*\n\(message)"])
        case .ntfy:
            // Header values must be ASCII; ntfy decodes RFC 2047 encoded words.
            request.setValue(encodedWord(title), forHTTPHeaderField: "Title")
            request.setValue(failed ? "high" : "default", forHTTPHeaderField: "Priority")
            request.setValue(failed ? "warning" : "white_check_mark", forHTTPHeaderField: "Tags")
            request.httpBody = Data(message.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProxmacsError("HTTP \(status)\(data.isEmpty ? "" : ": " + String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    private static func encodedWord(_ text: String) -> String {
        text.allSatisfy(\.isASCII) ? text : "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }
}
