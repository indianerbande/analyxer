import Foundation
import CryptoKit

public struct EmulatorService: Sendable {
    public let paths: SDKPaths
    let runner: any CommandRunning
    public init(paths: SDKPaths, runner: any CommandRunning = ProcessCommandRunner()) {
        self.paths = paths; self.runner = runner
    }

    /// Folder of Android's ordinary catalogue (Android Studio), resolved in the same order as `emulator -list-avds`.
    public static func standardAVDHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let avdHome = environment["ANDROID_AVD_HOME"], !avdHome.isEmpty { return URL(fileURLWithPath: avdHome, isDirectory: true) }
        for key in ["ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME"] {
            if let base = environment[key], !base.isEmpty { return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("avd", isDirectory: true) }
        }
        return userHome.appendingPathComponent(".android/avd", isDirectory: true)
    }

    public func avds() async throws -> [AVD] {
        let result = try await execute(tool: paths.emulator, name: "emulator", arguments: ["-list-avds"])
        return Array(Set(result.text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }))
            .filter { !$0.isEmpty }.sorted().map { AVD(name: $0) }
    }

    public func devices() async throws -> [AndroidDevice] {
        let result = try await execute(tool: paths.adb, name: "adb", arguments: ["devices", "-l"])
        var devices: [AndroidDevice] = []
        for line in result.text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"), !line.hasPrefix("adb:") else { continue }
            let serial = fields[0], state = fields[1]
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? ""
            var avdName: String?
            if state == "device", isEmulator(serial) {
                if let nameResult = try? await execute(tool: paths.adb, name: "adb", arguments: ["-s", serial, "emu", "avd", "name"], timeout: 5) {
                    avdName = nameResult.text.split(whereSeparator: \.isNewline).map(String.init)
                        .first { !$0.isEmpty && $0 != "OK" && !$0.hasPrefix("KO:") }
                }
            }
            devices.append(AndroidDevice(serial: serial, state: state, model: model, avdName: avdName))
        }
        return devices
    }

    /// A temporary writable overlay permits testing without persisting guest changes
    /// to the existing AVD. Snapshots and emulator metrics are disabled.
    public func start(avd: AVD, persistent: Bool = false) async throws {
        guard !avd.name.isEmpty, !avd.name.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw AnalyxerError.invalidInput(String(localized: "Invalid AVD name."))
        }
        guard let emulator = paths.emulator else { throw AnalyxerError.missingTool("emulator") }
        try await runner.launch(Command(executable: emulator, arguments: ["-avd", avd.name] + (persistent ? [] : ["-read-only"]) + ["-no-snapshot", "-no-metrics"], environment: avd.home.map { ["ANDROID_AVD_HOME": $0.path] } ?? [:]))
    }

    /// Keep Android's key-based IME available alongside the Mac keyboard.
    public func enableScreenKeyboard(serial: String) async throws {
        guard isEmulator(serial) else { throw AnalyxerError.invalidInput(String(localized: "Keyboard setup is only intended for an emulator.")) }
        for (key, value) in [("show_ime_with_hard_keyboard", "1"), ("stylus_handwriting_enabled", "0")] {
            _ = try await adb(serial: serial, arguments: ["shell", "settings", "put", "secure", key, value])
            let result = try await adb(serial: serial, arguments: ["shell", "settings", "get", "secure", key])
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines) == value else { throw AnalyxerError.failed(String(localized: "Android could not apply the keyboard setting: \(key)")) }
        }
    }

    public func stop(serial: String) async throws {
        guard isEmulator(serial) else { throw AnalyxerError.invalidInput(String(localized: "Only a selected Android emulator can be shut down.")) }
        _ = try await adb(serial: serial, arguments: ["emu", "kill"])
    }

    public func install(apk: URL, serial: String) async throws -> String {
        try validateAPK(apk)
        return try await adb(serial: serial, arguments: ["install", "-r", apk.standardizedFileURL.path], timeout: 180).text
    }

    public func packages(serial: String) async throws -> [String] {
        let result = try await adb(serial: serial, arguments: ["shell", "pm", "list", "packages"])
        return result.text.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }.sorted()
    }

    public func logs(serial: String) async throws -> String {
        let result = try await adb(serial: serial, arguments: ["logcat", "-d", "-t", "1500", "-v", "threadtime"])
        return result.text + (result.truncated ? "\n" + String(localized: "[Output limited to 4 MiB]") : "")
    }

    public func screenshot(serial: String) async throws -> Data {
        let result = try await adb(serial: serial, arguments: ["exec-out", "screencap", "-p"], outputLimit: 32 * 1024 * 1024)
        guard !result.truncated else { throw AnalyxerError.outputTooLarge }
        guard result.stdout.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw AnalyxerError.failed(String(localized: "The emulator did not deliver a valid PNG image."))
        }
        return result.stdout
    }

    public func keyevent(serial: String, keyCode: Int) async throws {
        guard [3, 4, 187].contains(keyCode) else { throw AnalyxerError.invalidInput(String(localized: "This navigation key is not supported.")) }
        _ = try await adb(serial: serial, arguments: ["shell", "input", "keyevent", String(keyCode)])
    }

    public func launchPackage(identifier: String, serial: String) async throws -> String {
        guard identifier.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else {
            throw AnalyxerError.invalidInput(String(localized: "Invalid Android package name."))
        }
        let resolution = try await adb(serial: serial, arguments: ["shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", identifier])
        try checkAndroidCommandResult(resolution)
        guard !resolution.truncated,
              let component = resolution.text.split(whereSeparator: \.isNewline).last.map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
              component.hasPrefix(identifier + "/"),
              component.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*/\.?[A-Za-z_$][A-Za-z0-9_.$]*$"#, options: .regularExpression) != nil else {
            throw AnalyxerError.failed(String(localized: "No valid launchable activity was found for \(identifier)."))
        }
        // adb shell joins its arguments into a remote shell command. Quote the
        // validated component so legal Java inner-class names containing $ stay literal.
        let launch = try await adb(serial: serial, arguments: ["shell", "am", "start", "-W", "-n", "'\(component)'"])
        try checkAndroidCommandResult(launch)
        return launch.text
    }

    private func checkAndroidCommandResult(_ result: CommandResult) throws {
        let output = result.text + "\n" + String(decoding: result.stderr, as: UTF8.self)
        let failed = output.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasPrefix("Error:") || text.hasPrefix("Error type ") || text.hasPrefix("Exception:")
                || text.hasPrefix("java.lang.") || text.hasPrefix("Security exception:")
                || (text.hasPrefix("Status:") && text != "Status: ok")
        }
        if failed { throw AnalyxerError.failed(String(localized: "Android could not launch the app: \(String(output.prefix(4000)))")) }
    }

    public func inspectAPK(at apk: URL) async throws -> APKReport {
        try validateAPK(apk)
        let path = apk.standardizedFileURL.path
        async let metadata = execute(tool: paths.aapt2, name: "aapt2 (build-tools)", arguments: ["dump", "badging", path])
        async let permissions = execute(tool: paths.aapt2, name: "aapt2 (build-tools)", arguments: ["dump", "permissions", path])
        let (metadataResult, permissionsResult) = try await (metadata, permissions)
        guard !metadataResult.truncated, !permissionsResult.truncated else { throw AnalyxerError.outputTooLarge }
        let permissionNames = permissionsResult.text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("uses-permission"), let start = line.firstIndex(of: "'"), let end = line[line.index(after: start)...].firstIndex(of: "'") else { return nil }
            return String(line[line.index(after: start)..<end])
        }
        // Hash incrementally, avoiding a second in-memory copy of large APKs.
        let hash = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: apk)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        return APKReport(metadata: metadataResult.text, permissions: Array(Set(permissionNames)).sorted(), sha256: hash)
    }

    func adb(serial: String, arguments: [String], timeout: TimeInterval = 30, outputLimit: Int = 4 * 1024 * 1024) async throws -> CommandResult {
        guard !serial.isEmpty, serial.range(of: #"^[A-Za-z0-9_.:\[\]-]+$"#, options: .regularExpression) != nil else {
            throw AnalyxerError.invalidInput(String(localized: "Invalid device serial."))
        }
        return try await execute(tool: paths.adb, name: "adb", arguments: ["-s", serial] + arguments, timeout: timeout, outputLimit: outputLimit)
    }

    func execute(tool: URL?, name: String, arguments: [String], timeout: TimeInterval = 30, outputLimit: Int = 4 * 1024 * 1024) async throws -> CommandResult {
        guard let tool else { throw AnalyxerError.missingTool(name) }
        let result = try await runner.run(Command(executable: tool, arguments: arguments, timeout: timeout, outputLimit: outputLimit))
        guard result.status == 0 else {
            let detail = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            throw AnalyxerError.failed(String(localized: "\(name) failed (status \(Int(result.status))): \(String(detail.prefix(4000)))"))
        }
        return result
    }

    private func isEmulator(_ serial: String) -> Bool {
        serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil
    }
    private func validateAPK(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "apk",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw AnalyxerError.invalidInput(String(localized: "Choose an existing APK file."))
        }
    }
}
