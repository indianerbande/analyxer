import Foundation

public struct PackageLog: Sendable {
    public let pid: String
    public let text: String
}

extension EmulatorService {
    public func observeDevice(serial: String) async throws -> DeviceObservation {
        guard let device = try await devices().first(where: { $0.serial == serial && $0.isOnline }) else {
            throw AnalyxerError.failed(String(localized: "The selected device is not online."))
        }
        var properties: [String: String] = [:]
        for key in ["ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi", "ro.product.model", "ro.build.fingerprint", "sys.boot_completed"] {
            properties[key] = try await adb(serial: serial, arguments: ["shell", "getprop", key]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard properties["sys.boot_completed"] == "1" else { throw AnalyxerError.failed(String(localized: "Android has not finished starting yet.")) }
        properties["boot_id"] = try await bootIdentity(serial: serial)
        let version = try await execute(tool: paths.adb, name: "adb", arguments: ["version"])
        return DeviceObservation(observedAt: Date(), serial: serial, avdName: device.avdName, properties: properties, adbVersion: version.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func bootIdentity(serial: String) async throws -> String {
        let result = try await adb(serial: serial, arguments: ["shell", "cat", "/proc/sys/kernel/random/boot_id"])
        let id = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { throw AnalyxerError.failed(String(localized: "Could not determine the Android boot identity.")) }
        return id
    }
    public func logs(serial: String, package: String) async throws -> PackageLog {
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else { throw AnalyxerError.invalidInput(String(localized: "Invalid package.")) }
        let pids = try await adb(serial: serial, arguments: ["shell", "pidof", package]).text.split(whereSeparator: \.isWhitespace)
        guard pids.count == 1, let pid = pids.first, pid.allSatisfy(\.isNumber) else {
            throw AnalyxerError.failed(String(localized: "No unique main process for \(package). Start the project app."))
        }
        let result = try await adb(serial: serial, arguments: ["logcat", "-d", "-t", "1500", "--pid=\(pid)", "-v", "threadtime"])
        return PackageLog(pid: String(pid), text: result.text + (result.truncated ? "\n[Output limited to 4 MiB]" : ""))
    }
}

/// The UI and CLI use the same persisted workflow. Each action is bound to one
/// explicit session, device serial and boot. Failures are retained as evidence.
public struct ProjectWorkflow: Sendable {
    public let store: ProjectStore
    public let service: EmulatorService
    public init(store: ProjectStore, service: EmulatorService) { self.store = store; self.service = service }

    public func begin(serial: String) async throws -> AnalysisSession {
        let device = try await service.observeDevice(serial: serial)
        return try await store.startSession(device: device)
    }
    public func install(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Install APK") { session, project in
            let apks = try await store.verifiedAPKs()
            let output = try await service.install(apks: apks, serial: session.device.serial)
            guard output.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" }) else {
                throw AnalyxerError.failed(String(localized: "Android did not confirm the installation: \(String(output.prefix(2000)))"))
            }
            try await store.record(kind: .installation, summary: "\(project.packageName) · SHA-256 \(project.analysis.apk.sha256)", data: Data(output.utf8), sessionID: sessionID)
        }
    }
    public func adoptInstalled(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Adopt Installed App") { session, project in
            _ = try await store.verifiedAPKs()
            let date = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
            guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else { throw AnalyxerError.failed(String(localized: "Android restarted during the verification.")) }
            let detail = "Adopted the already installed app unchanged; no installation performed.\nPackage: \(project.packageName)\nVerified: \(date.ISO8601Format())\n" + project.apkFiles.map { "\($0.name): \($0.sha256)" }.joined(separator: "\n")
            try await store.record(kind: .installedApp, summary: "\(project.packageName) · \(project.apkFiles.count == 1 ? "1 APK" : "\(project.apkFiles.count) APKs") verified", data: Data(detail.utf8), sessionID: sessionID)
        }
    }
    public func launch(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Launch Project App") { session, project in
            guard project.evidence.contains(where: { $0.sessionID == sessionID && [.installation, .installedApp].contains($0.kind) }) else {
                throw AnalyxerError.failed(String(localized: "Install the project APK in this session first."))
            }
            if project.installedSource != nil {
                _ = try await store.verifiedAPKs()
                _ = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
            }
            guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else { throw AnalyxerError.failed(String(localized: "Android restarted during the verification.")) }
            let output = try await service.launchPackage(identifier: project.packageName, serial: session.device.serial)
            try await store.record(kind: .launch, summary: project.packageName, data: Data(output.utf8), sessionID: sessionID)
        }
    }
    public func captureLogs(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Capture App Logcat") { session, project in
            if project.installedSource != nil {
                _ = try await store.verifiedAPKs()
                _ = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
                guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else { throw AnalyxerError.failed(String(localized: "Android restarted during the verification.")) }
            }
            let logs = try await service.logs(serial: session.device.serial, package: project.packageName)
            let prefix = "Package: \(project.packageName)\nMain process PID: \(logs.pid)\nDevice: \(session.device.serial)\nCaptured: \(Date().ISO8601Format())\nScope: last 1,500 entries, filtered to the current main process; no secondary processes, not a complete capture. Older entries from the same PID may be included.\n\n"
            try await store.record(kind: .logcat, summary: "\(project.packageName) · PID \(logs.pid)", data: Data((prefix + logs.text).utf8), sessionID: sessionID)
        }
    }
    public func captureScreenshot(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Capture Screenshot") { session, _ in
            let bytes = try await service.screenshot(serial: session.device.serial)
            try await store.record(kind: .screenshot, summary: "Device screen · \(session.device.serial)", data: bytes, sessionID: sessionID)
        }
    }
    public func navigate(sessionID: UUID, keyCode: Int) async throws {
        try await action(sessionID: sessionID, label: "Android-Navigation") { session, _ in
            try await service.keyevent(serial: session.device.serial, keyCode: keyCode)
            try await store.record(kind: .navigation, summary: "Key code \(keyCode)", data: Data("adb input keyevent \(keyCode)\n".utf8), sessionID: sessionID)
        }
    }
    func action(sessionID: UUID, label: String, body: (AnalysisSession, AnalysisProject) async throws -> Void) async throws {
        let session = try await store.session(sessionID)
        do {
            guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else {
                throw AnalyxerError.failed(String(localized: "Android restarted or the device was replaced. Start a new test session."))
            }
            try await body(session, store.snapshot())
        } catch {
            let original = error.localizedDescription
            do { try await store.record(kind: .failure, summary: label, data: Data(original.utf8), sessionID: sessionID) }
            catch { throw AnalyxerError.failed(String(localized: "\(original)\nIn addition, the error could not be saved in the project: \(error.localizedDescription)")) }
            throw error
        }
    }
}
