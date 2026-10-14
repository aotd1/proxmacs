import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// JSON API used by the browser UI (React app in web/, types in web/src/types.ts).
struct WebAPI: Sendable {
    let state: AppState
    /// The settings the server runs with (web.json may have changed since).
    var settings = WebSettings()
    var secureCookies: Bool { settings.tls }

    func register(on router: Router<WebContext>) {
        registerAuth(router)
        registerHost(router)
        registerVMs(router)
        registerBackups(router)
        registerTargets(router)
        registerConsole(router)
    }

    // MARK: Auth

    private func registerAuth(_ router: Router<WebContext>) {
        let secure = secureCookies
        router.get("/api/session") { request, _ in
            let valid = await SessionStore.shared.isValid(request.cookies[SessionStore.cookieName]?.value)
            return API.json(["authenticated": valid, "passwordSet": WebAuth.hasPassword])
        }
        router.post("/api/login") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                guard WebAuth.verify(body["password"] as? String ?? "") else {
                    try await Task.sleep(for: .seconds(1))  // slow down guessing
                    return API.error(WebAuth.hasPassword ? "Wrong password" : "No admin password set (Proxmacs menu → Web UI)", status: .unauthorized)
                }
                let token = await SessionStore.shared.create()
                var response = API.noContent()
                response.setCookie(Cookie(name: SessionStore.cookieName, value: token, maxAge: Int(SessionStore.lifetime),
                                          path: "/", secure: secure, httpOnly: true, sameSite: .strict))
                return response
            }
        }
        router.post("/api/logout") { request, _ in
            await SessionStore.shared.remove(request.cookies[SessionStore.cookieName]?.value)
            var response = API.noContent()
            response.setCookie(Cookie(name: SessionStore.cookieName, value: "", maxAge: 0, path: "/", secure: secure, httpOnly: true, sameSite: .strict))
            return response
        }
    }

    // MARK: Host

    /// Where the web UI can be reached: one URL per address it listens on, the default route's interface
    /// first and loopback last.
    private static func listeningURLs(_ settings: WebSettings) async -> [[String: Any]] {
        let ports = Dictionary(await NetworkInterfaces.list().map { ($0.device, $0.name) }, uniquingKeysWith: { a, _ in a })
        let primary = await NetworkInterfaces.defaultRoute()
        func rank(_ a: HostAddress) -> Int {
            if a.device == primary { return 0 }
            if ports[a.device] != nil { return 1 }
            return a.device.hasPrefix("lo") ? 3 : 2
        }
        return NetworkInterfaces.listening(on: settings.bind)
            .enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .map { address in
                let host = address.ipv6 ? "[\(address.address)]" : address.address
                let name = ports[address.device] ?? (address.device.hasPrefix("lo") ? "Loopback" : nil)
                return [
                    "url": "\(settings.scheme)://\(host):\(settings.port)",
                    "address": address.address,
                    "device": address.device,
                    "name": name as Any? ?? NSNull(),
                ]
            }
    }

    private func registerHost(_ router: Router<WebContext>) {
        let state = self.state
        let settings = self.settings
        router.get("/api/host") { _, _ in
            let values = try? Paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let tartVersion = await state.tartVersion
            let listening = await Self.listeningURLs(settings)
            return API.json([
                "hostname": ProcessInfo.processInfo.hostName,
                "tartVersion": tartVersion as Any? ?? NSNull(),
                "cpus": ProcessInfo.processInfo.activeProcessorCount,
                "memoryBytes": ProcessInfo.processInfo.physicalMemory,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "diskFreeBytes": values?.volumeAvailableCapacityForImportantUsage ?? 0,
                "diskTotalBytes": values?.volumeTotalCapacity ?? 0,
                "web": ["bind": settings.bind, "port": settings.port, "urls": listening],
            ])
        }
        router.get("/api/host/stats") { _, _ in
            let running = await MainActor.run { state.vms.filter(\.isRunning).map { $0.memoryMB ?? 0 } }
            var json: [String: Any] = [
                "time": Date().ISO8601Format(),
                "loadAverage": HostStats.loadAverage(),
                "runningVMs": running.count,
                "vmMemoryBytes": running.reduce(0) { $0 + UInt64($1) * 1024 * 1024 },
            ]
            if let memory = HostStats.memory() {
                json["memory"] = [
                    "total": memory.total, "used": memory.used, "app": memory.app, "wired": memory.wired,
                    "compressed": memory.compressed, "cached": memory.cached, "free": memory.free,
                    "swapUsed": memory.swapUsed, "swapTotal": memory.swapTotal, "pressure": memory.pressureLabel,
                ]
            }
            return API.json(json)
        }
        router.get("/api/host/storage") { _, _ in
            let busy = await state.storageBusy
            return API.json([
                "vms": Self.storageJSON(Storage.info(.vms)),
                "backups": Self.storageJSON(Storage.info(.backups)),
                "busy": busy?.rawValue as Any? ?? NSNull(),
                "vmsFixed": Storage.tartHomeOverridden,
                "volumes": Storage.externalVolumes().map(Self.volumeJSON),
            ])
        }
        router.put("/api/host/storage") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                guard let kind = (body["kind"] as? String).flatMap(StorageKind.init) else { throw APIError(message: "kind must be vms or backups") }
                let path = (body["path"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                let plan = try await state.planStorageChange(kind, to: path)
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.changeStorage(plan, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.get("/api/host/sshkeys") { _, _ in
            API.json(CloudInitSeed.sshPublicKeys())
        }
        router.get("/api/interfaces") { _, _ in
            let interfaces = await NetworkInterfaces.list()
            let preferred = await NetworkInterfaces.defaultRoute()
            return API.json(interfaces.map { ["device": $0.device, "name": $0.name, "default": $0.device == preferred] })
        }
        router.get("/api/images") { _, _ in
            let progress = ImageDownloads.shared.progress()
            return API.json(ImageStore.entries().map { image -> [String: Any] in
                let download = progress[image.id]
                return [
                    "id": image.id, "name": image.name, "distro": image.catalog?.distro as Any? ?? NSNull(),
                    "user": image.catalog?.user as Any? ?? NSNull(), "url": image.catalog?.page.absoluteString as Any? ?? NSNull(),
                    "imported": image.catalog == nil, "cached": image.cached,
                    "sizeBytes": image.virtualBytes as Any? ?? NSNull(), "diskBytes": image.diskBytes as Any? ?? NSNull(),
                    "downloading": download.map { ["message": $0.message, "progress": $0.fraction as Any? ?? NSNull()] } as Any? ?? NSNull(),
                ]
            })
        }
        router.post("/api/images/:id/download") { _, context in
            await API.guarded {
                guard let image = context.parameters.get("id").flatMap(ImageCatalog.find) else { throw APIError.notFound("Image") }
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.downloadImage(image, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.delete("/api/images/:id") { _, context in
            await API.guarded {
                try await state.deleteImage(context.parameters.get("id") ?? "")
                return API.noContent()
            }
        }
        router.get("/api/tasks") { _, _ in
            let tasks = await state.tasks
            return API.json(tasks.map { task -> [String: Any] in
                [
                    "id": task.id, "vm": task.vm as Any? ?? NSNull(), "title": task.title, "status": task.status.rawValue,
                    "message": task.message as Any? ?? NSNull(), "progress": task.progress as Any? ?? NSNull(),
                    "started": task.started.ISO8601Format(), "finished": task.finished?.ISO8601Format() as Any? ?? NSNull(),
                ]
            })
        }
    }

    // MARK: VMs

    @MainActor
    static func vmJSON(_ item: VMItem, activity: String?) -> [String: Any] {
        var network: [String: Any] = ["mode": "nat", "interface": NSNull()]
        if case .bridged(let iface) = item.meta.network { network = ["mode": "bridged", "interface": iface] }
        let config = item.meta.effectiveCloudInit
        let password = !config.managePassword && config.passwordHash == nil ? "unknown" : (config.passwordHash == nil ? "none" : "set")
        let cloudInit: [String: Any] = [
            "user": config.user, "password": password, "sshKeys": config.sshKeys, "legacy": item.meta.cloudInit == nil,
            "network": ["dhcp": config.network.dhcp, "address": config.network.address as Any? ?? NSNull(),
                        "gateway": config.network.gateway as Any? ?? NSNull(), "dns": config.network.dns],
        ]
        return [
            "cloudInit": cloudInit, "seedPending": item.meta.seedPending, "image": item.meta.image as Any? ?? NSNull(),
            "hasSeed": FileManager.default.fileExists(atPath: Paths.seedISO(item.name).path),
            "name": item.name, "state": item.state, "ip": item.ip as Any? ?? NSNull(), "network": network,
            "cpus": item.cpus as Any? ?? NSNull(), "memoryMB": item.memoryMB as Any? ?? NSNull(), "diskGB": item.diskGB as Any? ?? NSNull(),
            "autostart": item.meta.autostart, "activity": activity as Any? ?? NSNull(),
            "backup": ["daily": item.meta.backup.daily, "hour": item.meta.backup.hour, "keep": item.meta.backup.keep],
            "offsite": ["targets": item.meta.offsite.targets, "auto": item.meta.offsite.auto],
        ]
    }

    private func registerVMs(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/vms") { _, _ in
            let list = await MainActor.run { state.vms.map { Self.vmJSON($0, activity: state.activity[$0.name]) } }
            return API.json(list)
        }

        router.post("/api/vms") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                guard let name = body["name"] as? String else { throw APIError(message: "name is required") }
                let mode = await Self.networkMode(body["network"] as? [String: Any]) ?? .nat
                let imageID = body["image"] as? String ?? ImageCatalog.defaultID
                guard let image = ImageSource.named(imageID) else { throw APIError(message: "No image \(imageID)") }
                let vmRequest = NewVMRequest(
                    name: name, cpus: body["cpus"] as? Int ?? 2, memoryMB: body["memoryMB"] as? Int ?? 2048,
                    diskGB: body["diskGB"] as? Int ?? 20, network: mode, image: image,
                    password: body["password"] as? String ?? "", autostart: body["autostart"] as? Bool ?? false,
                    startNow: body["startNow"] as? Bool ?? true,
                    user: body["user"] as? String ?? "debian",
                    sshKeys: (body["sshKeys"] as? [Any]).map(Self.keys),
                    guestNetwork: Self.guestNetwork(body["ipv4"] as? [String: Any])
                )
                try await state.validateNewVM(name)
                try vmRequest.cloudInit.validate()
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.create(vmRequest, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }

        for action in ["start", "stop", "backup"] {
            router.post("/api/vms/:name/\(action)") { _, context in
                await API.guarded {
                    let name = try await Self.requireVM(state, context)
                    let task = Self.newTaskID()
                    Task { @MainActor in
                        switch action {
                        case "start": await state.start(name, taskID: task)
                        case "stop": await state.stop(name, taskID: task)
                        default: await state.backup(name, taskID: task)
                        }
                    }
                    return API.json(["task": task], status: .accepted)
                }
            }
        }

        router.delete("/api/vms/:name") { _, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let task = Self.newTaskID()
                Task { @MainActor in await state.delete(name, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }

        router.put("/api/vms/:name/hardware") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                let change = HardwareChange(cpus: body["cpus"] as? Int, memoryMB: body["memoryMB"] as? Int, diskGB: body["diskGB"] as? Int,
                                            network: await Self.networkMode(body["network"] as? [String: Any]))
                try await state.editHardware(name, change)
                return try await Self.currentVM(state, name)
            }
        }

        router.put("/api/vms/:name/cloudinit") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                let password: PasswordChange = if let plain = body["password"] as? String, !plain.isEmpty {
                    .set(plain)
                } else if body["removePassword"] as? Bool == true {
                    .remove
                } else {
                    .keep
                }
                guard let user = body["user"] as? String else { throw APIError(message: "user is required") }
                try await state.editCloudInit(name, user: user, password: password, sshKeys: Self.keys(body["sshKeys"] as? [Any] ?? []),
                                              network: Self.guestNetwork(body["ipv4"] as? [String: Any]))
                return try await Self.currentVM(state, name)
            }
        }

        router.patch("/api/vms/:name") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                let targetIDs = Set(TargetStore.load().map(\.id))
                return try await MainActor.run {
                    try state.updateMeta(name) { meta in
                        if let autostart = body["autostart"] as? Bool { meta.autostart = autostart }
                        if let backup = body["backup"] as? [String: Any] {
                            if let daily = backup["daily"] as? Bool { meta.backup.daily = daily }
                            if let hour = backup["hour"] as? Int { meta.backup.hour = min(max(hour, 0), 23) }
                            if let keep = backup["keep"] as? Int { meta.backup.keep = max(keep, 1) }
                        }
                        if let offsite = body["offsite"] as? [String: Any] {
                            if let targets = offsite["targets"] as? [String] { meta.offsite.targets = targets.filter(targetIDs.contains) }
                            if let auto = offsite["auto"] as? Bool { meta.offsite.auto = auto }
                        }
                    }
                    guard let item = state.vms.first(where: { $0.name == name }) else { throw APIError.notFound("VM \(name)") }
                    return API.json(Self.vmJSON(item, activity: state.activity[name]))
                }
            }
        }
    }

    // MARK: Local backups

    private func registerBackups(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/vms/:name/backups") { _, context in
            await API.guarded {
                let name = try Self.param(context, "name")
                try Storage.require(.backups)
                return API.json(BackupManager.list(name).map { backup -> [String: Any] in
                    ["id": backup.name, "date": backup.record.date.ISO8601Format(), "consistent": backup.record.consistent,
                     "source": backup.record.source as Any? ?? NSNull()]
                })
            }
        }
        router.post("/api/vms/:name/backups/:id/restore") { _, context in
            await API.guarded {
                let (name, backup) = try Self.backup(context)
                let task = Self.newTaskID()
                Task { @MainActor in await state.restore(name, backup, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.post("/api/vms/:name/backups/:id/push") { request, context in
            await API.guarded {
                let (name, backup) = try Self.backup(context)
                let body = try await API.body(request)
                guard let target = (body["target"] as? String).flatMap(TargetStore.target) else { throw APIError.notFound("target") }
                let task = Self.newTaskID()
                Task { @MainActor in await state.push(name, backup: backup, targetID: target.id, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.delete("/api/vms/:name/backups/:id") { _, context in
            await API.guarded {
                let (_, backup) = try Self.backup(context)
                try BackupManager.delete(backup)
                return API.noContent()
            }
        }
    }

    // MARK: Offsite targets

    static func targetJSON(_ target: OffsiteTarget) -> [String: Any] {
        var json: [String: Any] = ["id": target.id, "name": target.name, "kind": target.kind.rawValue,
                                   "location": target.location, "keep": target.keep, "smb": NSNull(), "pbs": NSNull()]
        if let smb = target.smb { json["smb"] = ["url": smb.url] }
        if let pbs = target.pbs {
            json["pbs"] = ["host": pbs.host, "port": pbs.port, "datastore": pbs.datastore, "namespace": pbs.namespace as Any? ?? NSNull(),
                           "authId": pbs.authId, "fingerprint": pbs.fingerprint as Any? ?? NSNull()]
        }
        return json
    }

    private func registerTargets(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/targets") { _, _ in
            API.json(TargetStore.load().map(Self.targetJSON))
        }
        router.post("/api/targets") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                let (target, secret) = try Self.parseTarget(body)
                try await MainActor.run { try state.addTarget(target, secret: secret) }
                return API.json(Self.targetJSON(target), status: .created)
            }
        }
        router.delete("/api/targets/:id") { _, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                try await MainActor.run { try state.removeTarget(id) }
                return API.noContent()
            }
        }
        router.post("/api/targets/:id/test") { _, context in
            await API.guarded {
                let result = await state.testTarget(try Self.param(context, "id"))
                return API.json(["ok": result.ok, "message": result.message])
            }
        }
        router.get("/api/targets/:id/snapshots") { request, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                guard let vm = request.uri.queryParameters.get("vm"), !vm.isEmpty else { throw APIError(message: "vm is required") }
                let snapshots = try await state.remoteSnapshots(targetID: id, vm: vm)
                return API.json(snapshots.map { ["vm": $0.vm, "time": $0.time.ISO8601Format(), "id": $0.id] })
            }
        }
        router.post("/api/targets/:id/pull") { request, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                let body = try await API.body(request)
                guard let vm = body["vm"] as? String, let snapshot = body["id"] as? String else { throw APIError(message: "vm and id are required") }
                let exists = VMMeta.load(vm) != nil
                let task = Self.newTaskID()
                Task { @MainActor in await state.pull(vm, snapshotID: snapshot, targetID: id, taskID: task) }
                return API.json(["task": task,
                                 "message": exists ? "Pulling into local backups of \(vm)" : "Pulling and recreating \(vm)"],
                                status: .accepted)
            }
        }
    }

    static func parseTarget(_ body: [String: Any]) throws -> (OffsiteTarget, String?) {
        guard let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw APIError(message: "name is required")
        }
        let keep = max(body["keep"] as? Int ?? 7, 1)
        switch body["kind"] as? String {
        case "smb":
            guard let smb = body["smb"] as? [String: Any], let url = smb["url"] as? String else { throw APIError(message: "smb.url is required") }
            _ = try SMBLocation(parsing: url)
            return (OffsiteTarget(name: name, kind: .smb, keep: keep, smb: SMBSettings(url: url)), smb["password"] as? String)
        case "pbs":
            guard let pbs = body["pbs"] as? [String: Any], let host = pbs["host"] as? String, let datastore = pbs["datastore"] as? String,
                  let authId = pbs["authId"] as? String else { throw APIError(message: "pbs.host, pbs.datastore and pbs.authId are required") }
            guard authId.contains("!") else { throw APIError(message: "authId must be an API token id like user@pbs!tokenname") }
            let namespace = (pbs["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let fingerprint = (pbs["fingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let settings = PBSSettings(host: host, port: pbs["port"] as? Int ?? 8007, datastore: datastore,
                                       namespace: namespace, authId: authId, fingerprint: fingerprint)
            return (OffsiteTarget(name: name, kind: .pbs, keep: keep, pbs: settings), pbs["secret"] as? String)
        default:
            throw APIError(message: "kind must be smb or pbs")
        }
    }

    // MARK: Console

    private func registerConsole(_ router: Router<WebContext>) {
        router.ws("/api/vms/:name/console") { _, context in
            guard let name = context.parameters.get("name"),
                  FileManager.default.fileExists(atPath: VMRunner.socketPath(name).path) else { return .dontUpgrade }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let name = context.requestContext.parameters.get("name") else { return }
            try await ConsoleBridge.run(vm: name, inbound: inbound, outbound: outbound)
        }
    }

    // MARK: Helpers

    static func newTaskID() -> String { UUID().uuidString.lowercased() }

    static func storageJSON(_ info: StorageInfo) -> [String: Any] {
        ["path": info.path, "default": info.isDefault, "available": info.available,
         "volume": info.volume.map(volumeJSON) as Any? ?? NSNull()]
    }

    static func volumeJSON(_ volume: VolumeInfo) -> [String: Any] {
        ["path": volume.path, "name": volume.name, "fileSystem": volume.fileSystem, "internal": volume.isInternal,
         "ejectable": volume.ejectable, "freeBytes": volume.freeBytes, "totalBytes": volume.totalBytes]
    }

    static func param(_ context: WebContext, _ name: String) throws -> String {
        guard let value = context.parameters.get(name), !value.isEmpty else { throw APIError(message: "missing \(name)") }
        return value
    }

    static func currentVM(_ state: AppState, _ name: String) async throws -> Response {
        try await MainActor.run {
            guard let item = state.vms.first(where: { $0.name == name }) else { throw APIError.notFound("VM \(name)") }
            return API.json(vmJSON(item, activity: state.activity[name]))
        }
    }

    static func networkMode(_ json: [String: Any]?) async -> NetworkMode? {
        switch json?["mode"] as? String {
        case "nat": return .nat
        case "bridged":
            let iface = (json?["interface"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let iface { return .bridged(interface: iface) }
            return .bridged(interface: await NetworkInterfaces.defaultRoute() ?? "en0")
        default: return nil
        }
    }

    static func guestNetwork(_ json: [String: Any]?) -> GuestNetwork {
        guard let json, json["dhcp"] as? Bool == false else { return GuestNetwork() }
        let trimmed = { (value: Any?) -> String? in
            (value as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return GuestNetwork(dhcp: false, address: trimmed(json["address"]), gateway: trimmed(json["gateway"]),
                            dns: ((json["dns"] as? [Any]) ?? []).compactMap(trimmed))
    }

    static func keys(_ list: [Any]) -> [String] {
        list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func requireVM(_ state: AppState, _ context: WebContext) async throws -> String {
        let name = try param(context, "name")
        guard VMMeta.load(name) != nil else { throw APIError.notFound("VM \(name)") }
        return name
    }

    static func backup(_ context: WebContext) throws -> (String, BackupInfo) {
        let name = try param(context, "name")
        let id = try param(context, "id")
        guard let backup = BackupManager.list(name).first(where: { $0.name == id }) else { throw APIError.notFound("backup \(id)") }
        return (name, backup)
    }
}

/// Bridges a VM console socket (served by VMRunner) to a WebSocket.
enum ConsoleBridge {
    static func run(vm: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async throws {
        guard let fd = ConsoleClient.connect(vm) else {
            try await outbound.close(.unexpectedServerError, reason: "console not available")
            return
        }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let scrollback = ConsoleClient.scrollback(vm)
        if !scrollback.isEmpty { try await outbound.write(.binary(ByteBuffer(bytes: scrollback))) }

        let output = AsyncStream<Data> { continuation in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 {
                        continuation.yield(Data(buffer[0..<n]))
                    } else {
                        if n == 0 || (errno != EAGAIN && errno != EINTR) { continuation.finish() }
                        break
                    }
                }
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in output {
                    try await outbound.write(.binary(ByteBuffer(bytes: data)))
                }
            }
            group.addTask {
                for try await message in inbound.messages(maxSize: 1 << 16) {
                    let bytes: [UInt8] = switch message {
                    case .text(let text): Array(text.utf8)
                    case .binary(let buffer): Array(buffer.readableBytesView)
                    }
                    writeAll(fd, bytes)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { return }
        }
    }
}
