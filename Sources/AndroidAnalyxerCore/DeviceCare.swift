import Foundation

/// One package on the selected device, as `pm`, `dumpsys diskstats` and `dumpsys usagestats` report it for user 0.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let package: String
    public let path: String?
    public let installer: String?
    public let isSystem: Bool
    public let isDisabled: Bool
    /// Removed for user 0 with `pm uninstall --user 0`; `cmd package install-existing` restores it.
    public let isRemovedForUser: Bool
    /// Core components, launcher, keyboard and WebView are never disabled or removed.
    public let isProtected: Bool
    public let appBytes: Int64?
    public let dataBytes: Int64?
    public let cacheBytes: Int64?
    public let lastUsed: Date?
    public var id: String { package }
    public var totalBytes: Int64? {
        let parts = [appBytes, dataBytes, cacheBytes].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
    public var source: String {
        switch installer {
        case "com.android.vending": return "Play Store"
        case nil: return isSystem ? String(localized: "Preinstalled") : String(localized: "Sideloaded")
        case let other?: return other == "com.android.shell" || other == "adb" ? "ADB" : other
        }
    }
}

public struct StorageOverview: Hashable, Sendable {
    public let total: Int64
    public let free: Int64
    /// Categories from the disk stats job, `nil` when the device has not produced them.
    public let apps: Int64?, appData: Int64?, appCache: Int64?, photos: Int64?, videos: Int64?, audio: Int64?, downloads: Int64?, system: Int64?, other: Int64?
    public var used: Int64 { max(0, total - free) }
}

/// A folder under `/sdcard/Android/{data,obb,media}` whose package is no longer installed.
public struct AppLeftover: Identifiable, Hashable, Sendable {
    public let area: String
    public let package: String
    public let bytes: Int64
    public var path: String { "/sdcard/Android/\(area)/\(package)" }
    public var id: String { path }
}

public struct DeviceCareService: Sendable {
    public let service: EmulatorService
    public init(service: EmulatorService) { self.service = service }

    static let packagePattern = #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#
    static let leftoverAreas = ["data", "obb", "media"]
    static let protectedPackages: Set<String> = [
        "android", "com.android.systemui", "com.android.settings", "com.android.phone", "com.android.shell", "com.android.vending",
        "com.google.android.gms", "com.google.android.gsf", "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller", "com.android.externalstorage",
        "com.android.documentsui", "com.google.android.documentsui", "com.android.server.telecom", "com.android.bluetooth",
        "com.google.android.bluetooth", "com.android.se", "com.android.keychain", "com.android.location.fused", "com.android.ext.services",
        "com.google.android.ext.services", "com.android.webview", "com.google.android.webview", "com.android.inputdevices",
        "com.android.localtransport", "com.android.wallpaperbackup", "com.android.certinstaller", "com.android.emergency",
        "com.google.android.modulemetadata", "com.android.modulemetadata", "com.android.devicelockcontroller", "com.android.nfc", "com.google.android.nfc"
    ]
    static let protectedPrefixes = ["com.android.providers.", "com.google.android.providers.", "com.android.internal.", "com.android.networkstack",
                                    "com.google.android.networkstack", "com.android.wifi", "com.google.android.wifi", "com.android.cellbroadcast",
                                    "com.google.android.cellbroadcast", "com.android.adservices", "com.google.android.adservices"]

    // MARK: Reading

    /// Packages of user 0 with sizes and last use. Triggers Android's disk stats job first so sizes are current.
    public func inventory(serial: String) async throws -> (apps: [InstalledApp], storage: StorageOverview?) {
        let listed = Self.parsePackageList(try await shell(serial, ["pm", "list", "packages", "-f", "-i", "-U", "-u"]).text)
        let installed = Self.parseNames(try await shell(serial, ["pm", "list", "packages"]).text)
        let system = Self.parseNames(try await shell(serial, ["pm", "list", "packages", "-s"]).text)
        let disabled = Self.parseNames(try await shell(serial, ["pm", "list", "packages", "-d"]).text)
        let guarded = try await dynamicallyProtected(serial: serial)
        let disk = try await freshDiskStats(serial: serial)
        let zone = TimeZone(identifier: (try? await shell(serial, ["getprop", "persist.sys.timezone"]).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") ?? .current
        let usage = Self.parseUsage((try? await service.adb(serial: serial, arguments: ["shell", "dumpsys", "usagestats"], timeout: 60, outputLimit: 32 * 1024 * 1024).text) ?? "", timeZone: zone)
        let apps = listed.map { entry -> InstalledApp in
            let sizes = disk.sizes[entry.package]
            return InstalledApp(package: entry.package, path: entry.path, installer: entry.installer, isSystem: system.contains(entry.package),
                                isDisabled: disabled.contains(entry.package), isRemovedForUser: !installed.contains(entry.package),
                                isProtected: Self.isProtected(entry.package, path: entry.path, dynamic: guarded),
                                appBytes: sizes?.app, dataBytes: sizes?.data, cacheBytes: sizes?.cache, lastUsed: usage[entry.package])
        }.sorted { ($0.totalBytes ?? -1, $1.package) > ($1.totalBytes ?? -1, $0.package) }
        return (apps, disk.storage)
    }

    /// Folders in `Android/data`, `obb` and `media` without a matching package, including packages only removed for the user.
    public func leftovers(serial: String, known: Set<String>) async throws -> [AppLeftover] {
        let script = Self.leftoverAreas.map { "for d in /sdcard/Android/\($0)/*/; do [ -d \"$d\" ] && du -sk \"$d\"; done" }.joined(separator: "; ") + "; true"
        return Self.parseLeftovers(try await shell(serial, [script]).text, known: known)
    }

    // MARK: Changing

    public func setEnabled(_ enabled: Bool, package: String, serial: String) async throws {
        try await requireChangeable(package, serial: serial)
        let output = try await shell(serial, enabled ? ["pm", "enable", "--user", "0", package] : ["pm", "disable-user", "--user", "0", package]).text
        guard output.contains("new state: " + (enabled ? "enabled" : "disabled-user")) else { throw AndroidAnalyxerError.failed(String(localized: "Android reports: \(String(output.prefix(500)))")) }
    }

    /// System apps only; data stays on the device so `restoreForUser` brings the app back unchanged.
    public func removeForUser(package: String, serial: String) async throws {
        let app = try await requireChangeable(package, serial: serial)
        guard app.isSystem else { throw AndroidAnalyxerError.invalidInput(String(localized: "\(package) is not a preinstalled app. Apps you installed are uninstalled, not removed for the user.")) }
        try Self.requireSuccess(try await shell(serial, ["pm", "uninstall", "-k", "--user", "0", package]).text)
    }

    public func restoreForUser(package: String, serial: String) async throws {
        try Self.validate(package)
        let output = try await shell(serial, ["cmd", "package", "install-existing", "--user", "0", package]).text
        guard output.contains("installed for user") else { throw AndroidAnalyxerError.failed(String(localized: "Android reports: \(String(output.prefix(500)))")) }
    }

    /// Removes an app the user installed, including its data. Not for preinstalled apps.
    public func uninstall(package: String, serial: String) async throws {
        let app = try await requireChangeable(package, serial: serial)
        guard !app.isSystem else { throw AndroidAnalyxerError.invalidInput(String(localized: "\(package) is preinstalled and can only be disabled or removed for the user.")) }
        try Self.requireSuccess(try await shell(serial, ["pm", "uninstall", package]).text)
    }

    /// Asks Android to free all app caches; Android keeps what running apps still need.
    public func trimCaches(serial: String) async throws {
        _ = try await service.adb(serial: serial, arguments: ["shell", "pm", "trim-caches", "999G"], timeout: 120)
    }

    /// Deletes one leftover folder after re-checking that its package is still unknown on the device.
    public func delete(_ leftover: AppLeftover, serial: String) async throws {
        try Self.validate(leftover.package)
        guard Self.leftoverAreas.contains(leftover.area) else { throw AndroidAnalyxerError.invalidInput(String(localized: "Unknown area \(leftover.area).")) }
        guard !Self.parseNames(try await shell(serial, ["pm", "list", "packages", "-u"]).text).contains(leftover.package) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "\(leftover.package) has been installed again in the meantime; the folder is kept."))
        }
        _ = try await shell(serial, ["rm", "-rf", "--", leftover.path])
    }

    // MARK: Internals

    private func shell(_ serial: String, _ arguments: [String]) async throws -> CommandResult {
        try await service.adb(serial: serial, arguments: ["shell"] + arguments, timeout: 60)
    }

    @discardableResult
    private func requireChangeable(_ package: String, serial: String) async throws -> InstalledApp {
        try Self.validate(package)
        let entry = Self.parsePackageList(try await shell(serial, ["pm", "list", "packages", "-f", "-i", "-U", "-u"]).text).first { $0.package == package }
        guard let entry else { throw AndroidAnalyxerError.invalidInput(String(localized: "\(package) is not on the device.")) }
        guard !Self.isProtected(package, path: entry.path, dynamic: try await dynamicallyProtected(serial: serial)) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "\(package) is a protected system component and is not changed."))
        }
        let system = Self.parseNames(try await shell(serial, ["pm", "list", "packages", "-s"]).text).contains(package)
        return InstalledApp(package: package, path: entry.path, installer: entry.installer, isSystem: system, isDisabled: false, isRemovedForUser: false,
                            isProtected: false, appBytes: nil, dataBytes: nil, cacheBytes: nil, lastUsed: nil)
    }

    /// Current launcher, keyboard and WebView provider.
    private func dynamicallyProtected(serial: String) async throws -> Set<String> {
        let home = try? await shell(serial, ["cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME"])
        let keyboard = try? await shell(serial, ["settings", "get", "secure", "default_input_method"])
        let webView = try? await shell(serial, ["dumpsys", "webviewupdate"])
        return Self.parseDynamicProtection(home: home?.text ?? "", keyboard: keyboard?.text ?? "", webView: webView?.text ?? "")
    }

    private func freshDiskStats(serial: String) async throws -> (storage: StorageOverview?, sizes: [String: (app: Int64, data: Int64, cache: Int64)]) {
        let before = try await shell(serial, ["dumpsys", "diskstats"]).text
        let jobs = try await service.adb(serial: serial, arguments: ["shell", "dumpsys", "jobscheduler"], timeout: 60, outputLimit: 32 * 1024 * 1024).text
        if let job = Self.diskStatsJobID(jobs) {
            _ = try? await shell(serial, ["cmd", "jobscheduler", "run", "-f", "android", job])
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let current = try await shell(serial, ["dumpsys", "diskstats"]).text
                if current != before && current.contains("Package Names:") { return Self.parseDiskStats(current) }
            }
        }
        return Self.parseDiskStats(try await shell(serial, ["dumpsys", "diskstats"]).text)
    }

    // MARK: Parsing

    static func validate(_ package: String) throws {
        guard package.range(of: packagePattern, options: .regularExpression) != nil else { throw AndroidAnalyxerError.invalidInput(String(localized: "Invalid package name.")) }
    }

    static func requireSuccess(_ output: String) throws {
        guard output.contains("Success") else { throw AndroidAnalyxerError.failed(String(localized: "Android reports: \(String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))")) }
    }

    static func isProtected(_ package: String, path: String?, dynamic: Set<String>) -> Bool {
        protectedPackages.contains(package) || dynamic.contains(package) || protectedPrefixes.contains { package.hasPrefix($0) }
            || (path.map { $0.hasPrefix("/apex/") || $0.contains("/overlay/") } ?? false)
    }

    static func parseNames(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
        })
    }

    /// Lines of `pm list packages -f -i -U`: `package:<apk path>=<name>  installer=<installer> uid:<uid>`. APK paths may contain `=`.
    static func parsePackageList(_ text: String) -> [(package: String, path: String?, installer: String?)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            guard raw.hasPrefix("package:") else { return nil }
            var line = String(raw.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            var installer: String?
            if let range = line.range(of: "  installer=") ?? line.range(of: " installer=") {
                installer = line[range.upperBound...].split(separator: " ").first.map(String.init).flatMap { $0 == "null" ? nil : $0 }
                line = String(line[..<range.lowerBound])
            } else if let range = line.range(of: " uid:") {
                line = String(line[..<range.lowerBound])
            }
            guard let equals = line.lastIndex(of: "=") else { return line.isEmpty ? nil : (line, nil, installer) }
            return (String(line[line.index(after: equals)...]), String(line[..<equals]), installer)
        }
    }

    static func diskStatsJobID(_ text: String) -> String? {
        guard let range = text.range(of: #"JOB #\d+/(\d+): \S+ android/com\.android\.server\.storage\.DiskStatsLoggingService"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "/")[1].split(separator: ":")[0].description
    }

    static func parseDiskStats(_ text: String) -> (storage: StorageOverview?, sizes: [String: (app: Int64, data: Int64, cache: Int64)]) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            values[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let number = { (key: String) in values[key].flatMap { Int64($0) } }
        var storage: StorageOverview?
        if let free = values["Data-Free"], let match = free.range(of: #"^(\d+)K / (\d+)K"#, options: .regularExpression) {
            let parts = free[match].split(separator: " ").compactMap { Int64($0.dropLast()) }
            if parts.count == 2 {
                storage = StorageOverview(total: parts[1] * 1024, free: parts[0] * 1024, apps: number("App Size"), appData: number("App Data Size"),
                                          appCache: number("App Cache Size"), photos: number("Photos Size"), videos: number("Videos Size"),
                                          audio: number("Audio Size"), downloads: number("Downloads Size"), system: number("System Size"), other: number("Other Size"))
            }
        }
        let array = { (key: String) -> [Any] in
            guard let raw = values[key], let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        }
        let names = array("Package Names").compactMap { $0 as? String }
        let bytes = { (key: String) in array(key).map { ($0 as? NSNumber)?.int64Value ?? 0 } }
        let app = bytes("App Sizes"), data = bytes("App Data Sizes"), cache = bytes("Cache Sizes")
        var sizes: [String: (app: Int64, data: Int64, cache: Int64)] = [:]
        if app.count == names.count, data.count == names.count, cache.count == names.count {
            for (index, name) in names.enumerated() { sizes[name] = (app[index], data[index], cache[index]) }
        }
        return (storage, sizes)
    }

    /// Latest `lastTimeUsed` per package from `dumpsys usagestats`; the device prints its local time.
    static func parseUsage(_ text: String, timeZone: TimeZone) -> [String: Date] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let pattern = try! NSRegularExpression(pattern: #"package=(\S+) totalTimeUsed="[^"]*" lastTimeUsed="(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)""#)
        var result: [String: Date] = [:]
        let whole = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: whole) {
            guard let nameRange = Range(match.range(at: 1), in: text), let dateRange = Range(match.range(at: 2), in: text),
                  let date = formatter.date(from: String(text[dateRange])), date.timeIntervalSince1970 > 86_400 * 365 else { continue }
            let name = String(text[nameRange])
            if result[name].map({ date > $0 }) ?? true { result[name] = date }
        }
        return result
    }

    static func parseDynamicProtection(home: String, keyboard: String, webView: String) -> Set<String> {
        var result: Set<String> = []
        if let line = home.split(whereSeparator: \.isNewline).last(where: { $0.contains("/") }) { result.insert(String(line.split(separator: "/")[0]).trimmingCharacters(in: .whitespaces)) }
        if let package = keyboard.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").first, !package.isEmpty, package != "null" { result.insert(String(package)) }
        if let range = webView.range(of: #"Current WebView package \(name, version\): \(([^,]+),"#, options: .regularExpression) {
            let inner = webView[range].dropFirst("Current WebView package (name, version): (".count)
            result.insert(String(inner.prefix { $0 != "," }))
        }
        return result
    }

    static func parseLeftovers(_ text: String, known: Set<String>) -> [AppLeftover] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let kilobytes = Int64(fields[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let parts = fields[1].trimmingCharacters(in: .whitespaces).split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "sdcard", parts[1] == "Android", leftoverAreas.contains(parts[2]),
                  parts[3].range(of: packagePattern, options: .regularExpression) != nil, !known.contains(parts[3]) else { return nil }
            return AppLeftover(area: parts[2], package: parts[3], bytes: kilobytes * 1024)
        }.sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
    }
}
