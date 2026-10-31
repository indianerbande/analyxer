import Foundation

public struct AVD: Identifiable, Hashable, Sendable {
    public let name: String
    public let home: URL?
    public var id: String { (home?.path ?? "default") + "/" + name }
    public init(name: String, home: URL? = nil) { self.name = name; self.home = home }
}

/// System an AVD runs, read from `<Name>.ini` (`target`) and the device's `config.ini` (tag, ABI).
public struct AVDSystemInfo: Hashable, Sendable {
    public let api: String
    public let variant: String?
    public let abi: String?
    public let pageSize16K: Bool

    static let androidVersions = ["21": "5.0", "22": "5.1", "23": "6", "24": "7.0", "25": "7.1", "26": "8.0", "27": "8.1", "28": "9", "29": "10",
                                  "30": "11", "31": "12", "32": "12L", "33": "13", "34": "14", "35": "15", "36": "16", "37": "17"]
    public var androidVersion: String? { Self.androidVersions[String(api.prefix { $0 != "." })] }
    public var summary: String {
        let architecture = abi.map { ["arm64-v8a": "ARM64", "x86_64": "x86_64", "armeabi-v7a": "ARMv7", "x86": "x86"][$0] ?? $0 }
        return [androidVersion.map { "Android " + $0 }, "API " + api, variant, pageSize16K ? "16-KB-Seiten" : nil, architecture].compactMap { $0 }.joined(separator: " · ")
    }

    public static func read(name: String, catalogue: URL) -> AVDSystemInfo? {
        guard let entry = values(at: catalogue.appendingPathComponent(name + ".ini")) else { return nil }
        let folder = entry["path"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? catalogue.appendingPathComponent(name + ".avd", isDirectory: true)
        let config = values(at: folder.appendingPathComponent("config.ini")) ?? [:]
        let sysdirTarget = config["image.sysdir.1"]?.split(separator: "/").first { $0.hasPrefix("android-") }.map(String.init)
        guard let target = [entry["target"], config["target"], sysdirTarget].compactMap({ $0 }).first(where: { $0.hasPrefix("android-") }) else { return nil }
        let tags = Set((config["tag.ids"] ?? config["tag.id"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let variant = tags.contains("google_apis_playstore") ? "Google Play" : tags.contains("google_apis") ? "Google APIs" : tags.contains("default") ? "AOSP" : config["tag.display"]
        return AVDSystemInfo(api: String(target.dropFirst("android-".count)), variant: variant, abi: config["abi.type"], pageSize16K: tags.contains("page_size_16kb"))
    }

    private static func values(at url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            result[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

public struct AndroidDevice: Identifiable, Hashable, Sendable {
    public let serial: String
    public let state: String
    public let model: String
    public let avdName: String?
    public var id: String { serial }
    public var isOnline: Bool { state == "device" }
    public var available: Bool { isOnline }
    public init(serial: String, state: String, model: String = "", avdName: String? = nil) {
        self.serial = serial; self.state = state; self.model = model; self.avdName = avdName
    }
}

public struct APKReport: Codable, Sendable {
    public let metadata: String
    public let permissions: [String]
    public let sha256: String
}

public enum AndroidAnalyxerError: LocalizedError {
    case missingTool(String), invalidInput(String), failed(String), timedOut, cancelled, outputTooLarge
    public var errorDescription: String? {
        switch self {
        case .missingTool(let name): return "Android-SDK-Werkzeug fehlt: \(name). Bitte SDK-Pfad und installierte Komponenten prüfen."
        case .invalidInput(let message), .failed(let message): return message
        case .timedOut: return "Das Android-SDK-Werkzeug hat das Zeitlimit überschritten."
        case .cancelled: return "Vorgang abgebrochen."
        case .outputTooLarge: return "Die Ausgabe überschreitet die erlaubte Größe."
        }
    }
}

public struct SDKPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) -> SDKPaths {
        let candidate = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }.first { !$0.isEmpty }
        return SDKPaths(root: candidate.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk"))
    }
    public var adb: URL? { executable("platform-tools/adb") }
    public var emulator: URL? { executable("emulator/emulator") }
    public var avdmanager: URL? { commandLineTool("avdmanager") }
    public var sdkmanager: URL? { commandLineTool("sdkmanager") }
    private func commandLineTool(_ name: String) -> URL? {
        if let latest = executable("cmdline-tools/latest/bin/" + name) { return latest }
        let versions = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cmdline-tools"), includingPropertiesForKeys: nil)) ?? []
        return versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/" + name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public var apkanalyzer: URL? {
        if let latest = executable("cmdline-tools/latest/bin/apkanalyzer") { return latest }
        let versions = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cmdline-tools"), includingPropertiesForKeys: nil)) ?? []
        return versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/apkanalyzer") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public var aapt2: URL? {
        let directory = root.appendingPathComponent("build-tools")
        let versions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("aapt2") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public var diagnostics: [String] {
        var result: [String] = []
        if adb == nil { result.append("Platform-Tools (adb) fehlen.") }
        if emulator == nil { result.append("Android Emulator fehlt.") }
        if aapt2 == nil { result.append("Build-Tools (aapt2) fehlen; APK-Metadaten können nicht gelesen werden.") }
        return result
    }
    private func executable(_ relative: String) -> URL? {
        let url = root.appendingPathComponent(relative)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
