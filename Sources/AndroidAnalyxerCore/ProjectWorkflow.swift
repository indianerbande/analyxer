import Foundation

public struct PackageLog: Sendable {
    public let pid: String
    public let text: String
}

extension EmulatorService {
    public func observeDevice(serial: String) async throws -> DeviceObservation {
        guard let device = try await devices().first(where: { $0.serial == serial && $0.isOnline }) else {
            throw AndroidAnalyxerError.failed("Das ausgewählte Gerät ist nicht online.")
        }
        var properties: [String: String] = [:]
        for key in ["ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi", "ro.product.model", "ro.build.fingerprint", "sys.boot_completed"] {
            properties[key] = try await adb(serial: serial, arguments: ["shell", "getprop", key]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard properties["sys.boot_completed"] == "1" else { throw AndroidAnalyxerError.failed("Android ist noch nicht vollständig gestartet.") }
        properties["boot_id"] = try await bootIdentity(serial: serial)
        let version = try await execute(tool: paths.adb, name: "adb", arguments: ["version"])
        return DeviceObservation(observedAt: Date(), serial: serial, avdName: device.avdName, properties: properties, adbVersion: version.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func bootIdentity(serial: String) async throws -> String {
        let result = try await adb(serial: serial, arguments: ["shell", "cat", "/proc/sys/kernel/random/boot_id"])
        let id = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { throw AndroidAnalyxerError.failed("Die Android-Bootidentität konnte nicht bestimmt werden.") }
        return id
    }
    public func logs(serial: String, package: String) async throws -> PackageLog {
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else { throw AndroidAnalyxerError.invalidInput("Ungültiges Paket.") }
        let pids = try await adb(serial: serial, arguments: ["shell", "pidof", package]).text.split(whereSeparator: \.isWhitespace)
        guard pids.count == 1, let pid = pids.first, pid.allSatisfy(\.isNumber) else {
            throw AndroidAnalyxerError.failed("Kein eindeutiger Hauptprozess für \(package). Bitte die Projekt-App starten.")
        }
        let result = try await adb(serial: serial, arguments: ["logcat", "-d", "-t", "1500", "--pid=\(pid)", "-v", "threadtime"])
        return PackageLog(pid: String(pid), text: result.text + (result.truncated ? "\n[Ausgabe auf 4 MiB begrenzt]" : ""))
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
        try await action(sessionID: sessionID, label: "APK installieren") { session, project in
            let apks = try await store.verifiedAPKs()
            let output = try await service.install(apks: apks, serial: session.device.serial)
            guard output.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" }) else {
                throw AndroidAnalyxerError.failed("Android bestätigt die Installation nicht: \(output.prefix(2000))")
            }
            try await store.record(kind: .installation, summary: "\(project.packageName) · SHA-256 \(project.analysis.apk.sha256)", data: Data(output.utf8), sessionID: sessionID)
        }
    }
    public func adoptInstalled(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Installierte App zuordnen") { session, project in
            _ = try await store.verifiedAPKs()
            let date = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
            guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else { throw AndroidAnalyxerError.failed("Android wurde während der Prüfung neu gestartet.") }
            let detail = "Bereits installierte App unverändert übernommen; keine Installation ausgeführt.\nPaket: \(project.packageName)\nGeprüft: \(date.ISO8601Format())\n" + project.apkFiles.map { "\($0.name): \($0.sha256)" }.joined(separator: "\n")
            try await store.record(kind: .installedApp, summary: "\(project.packageName) · \(project.apkFiles.count) APKs geprüft", data: Data(detail.utf8), sessionID: sessionID)
        }
    }
    public func launch(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Projekt-App starten") { session, project in
            guard project.evidence.contains(where: { $0.sessionID == sessionID && [.installation, .installedApp].contains($0.kind) }) else {
                throw AndroidAnalyxerError.failed("Bitte die Projekt-APK zuerst in dieser Sitzung installieren.")
            }
            if project.installedSource != nil {
                _ = try await store.verifiedAPKs()
                _ = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
            }
            guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else { throw AndroidAnalyxerError.failed("Android wurde während der Prüfung neu gestartet.") }
            let output = try await service.launchPackage(identifier: project.packageName, serial: session.device.serial)
            try await store.record(kind: .launch, summary: project.packageName, data: Data(output.utf8), sessionID: sessionID)
        }
    }
    public func captureLogs(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "App-Logcat aufnehmen") { session, project in
            if project.installedSource != nil {
                _ = try await store.verifiedAPKs()
                _ = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
                guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else { throw AndroidAnalyxerError.failed("Android wurde während der Prüfung neu gestartet.") }
            }
            let logs = try await service.logs(serial: session.device.serial, package: project.packageName)
            let prefix = "Paket: \(project.packageName)\nHauptprozess PID: \(logs.pid)\nGerät: \(session.device.serial)\nAufnahme: \(Date().ISO8601Format())\nUmfang: letzte 1.500 Einträge, gefiltert auf den aktuellen Hauptprozess; keine Nebenprozesse, kein vollständiger Mitschnitt. Ältere Einträge derselben PID können enthalten sein.\n\n"
            try await store.record(kind: .logcat, summary: "\(project.packageName) · PID \(logs.pid)", data: Data((prefix + logs.text).utf8), sessionID: sessionID)
        }
    }
    public func captureScreenshot(sessionID: UUID) async throws {
        try await action(sessionID: sessionID, label: "Screenshot aufnehmen") { session, _ in
            let bytes = try await service.screenshot(serial: session.device.serial)
            try await store.record(kind: .screenshot, summary: "Gerätebildschirm · \(session.device.serial)", data: bytes, sessionID: sessionID)
        }
    }
    public func navigate(sessionID: UUID, keyCode: Int) async throws {
        try await action(sessionID: sessionID, label: "Android-Navigation") { session, _ in
            try await service.keyevent(serial: session.device.serial, keyCode: keyCode)
            try await store.record(kind: .navigation, summary: "Keycode \(keyCode)", data: Data("adb input keyevent \(keyCode)\n".utf8), sessionID: sessionID)
        }
    }
    func action(sessionID: UUID, label: String, body: (AnalysisSession, AnalysisProject) async throws -> Void) async throws {
        let session = try await store.session(sessionID)
        do {
            guard try await service.bootIdentity(serial: session.device.serial) == session.device.properties["boot_id"] else {
                throw AndroidAnalyxerError.failed("Android wurde neu gestartet oder das Gerät ersetzt. Bitte eine neue Testsitzung beginnen.")
            }
            try await body(session, store.snapshot())
        } catch {
            let original = error.localizedDescription
            do { try await store.record(kind: .failure, summary: label, data: Data(original.utf8), sessionID: sessionID) }
            catch { throw AndroidAnalyxerError.failed("\(original)\nZusätzlich konnte der Fehler nicht im Projekt gespeichert werden: \(error.localizedDescription)") }
            throw error
        }
    }
}
