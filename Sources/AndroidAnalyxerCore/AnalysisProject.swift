import Foundation
import Darwin

public struct DeviceObservation: Codable, Sendable {
    public let observedAt: Date
    public let serial: String
    public let avdName: String?
    public let properties: [String: String]
    public let adbVersion: String
}

public struct AnalysisSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public let device: DeviceObservation
}

public enum EvidenceKind: String, Codable, Sendable {
    case staticReport, manifest, dex, installation, launch, logcat, screenshot, navigation, note, failure
    case rea, instrumentation, probeScript, networkCapture, networkReport, installedApp
    public var title: String {
        switch self {
        case .staticReport: "Statischer Bericht"
        case .manifest: "Manifest"
        case .dex: "DEX-Inventar"
        case .installation: "Installation"
        case .launch: "App-Start"
        case .logcat: "App-Logcat"
        case .screenshot: "Screenshot"
        case .navigation: "Navigation"
        case .note: "Notiz"
        case .failure: "Fehler"
        case .installedApp: "Installierte App geprüft"
        case .rea: "REA-Codeanalyse"
        case .instrumentation: "Prozessbeobachtung"
        case .probeScript: "Beobachtungsskript"
        case .networkCapture: "Netzwerkmitschnitt"
        case .networkReport: "Netzwerkbericht"
        }
    }
    var fileExtension: String {
        switch self {
        case .screenshot: "png"
        case .manifest: "xml"
        case .rea, .instrumentation: "json"
        case .probeScript: "js"
        case .networkCapture: "pcap"
        default: "txt"
        }
    }
}

public struct ProjectEvidence: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: EvidenceKind
    public let summary: String
    public let sessionID: UUID?
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int
}

public struct AnalysisProject: Codable, Identifiable, Sendable {
    public var schemaVersion: Int = 1
    public var revision: Int = 0
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let title: String
    public let originalAPKName: String
    public let apkPath: String
    public let analysis: StaticAnalysis
    public var sessions: [AnalysisSession] = []
    public var evidence: [ProjectEvidence] = []
    public var additionalAPKs: [ProjectAPK]?
    public var installedSource: InstalledAppSource?
    public var apkFiles: [ProjectAPK] { [ProjectAPK(relativePath: apkPath, name: originalAPKName, sha256: analysis.apk.sha256)] + (additionalAPKs ?? []) }
    public var packageName: String { analysis.manifest.packageName }
}

/// One folder is a portable project. project.json is the canonical index. All
/// evidence is immutable; writes use atomic replacement and an advisory writer lock.
public actor ProjectStore {
    public nonisolated let directory: URL
    private var project: AnalysisProject
    private init(directory: URL, project: AnalysisProject) { self.directory = directory; self.project = project }

    public static func create(at destination: URL, apk: URL, service: EmulatorService, installed: InstalledAppCapture? = nil) async throws -> ProjectStore {
        let fm = FileManager.default
        let target = destination.standardizedFileURL
        guard target.isFileURL, !fm.fileExists(atPath: target.path), apk.isFileURL, apk.pathExtension.lowercased() == "apk" else {
            throw AndroidAnalyxerError.invalidInput("Bitte eine APK und einen neuen, noch nicht vorhandenen Projektordner wählen.")
        }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".android-analyxer-creating-" + UUID().uuidString)
        try fm.createDirectory(at: staging.appendingPathComponent("input"), withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: staging) } }
        let copied = staging.appendingPathComponent("input/application.apk")
        try fm.copyItem(at: apk.resolvingSymlinksInPath(), to: copied)
        let analysis = try await service.staticAnalysis(apk: copied)
        var project = AnalysisProject(id: UUID(), createdAt: Date(), updatedAt: Date(), title: installed?.source.package ?? apk.deletingPathExtension().lastPathComponent,
                                      originalAPKName: installed?.files.first?.name ?? apk.lastPathComponent, apkPath: "input/application.apk", analysis: analysis)
        if let installed {
            guard analysis.manifest.packageName == installed.source.package, installed.files.first?.sha256 == analysis.apk.sha256 else { throw AndroidAnalyxerError.failed("Importierte Basis-APK stimmt nicht mit dem Paket überein.") }
            project.schemaVersion = 3
            project.installedSource = installed.source
            project.additionalAPKs = []
            for (index, file) in installed.files.dropFirst().enumerated() {
                let relative = "input/split-\(index + 1).apk"
                let source = try safeURL(file.relativePath, root: installed.directory)
                let target = staging.appendingPathComponent(relative)
                try fm.copyItem(at: source, to: target)
                guard try ArtifactHash.sha256(target) == file.sha256 else { throw AndroidAnalyxerError.failed("Split-APK während des Imports verändert.") }
                let report = try await service.inspectAPK(at: target)
                let identity = report.metadata.components(separatedBy: .newlines).first { $0.hasPrefix("package:") } ?? ""
                guard identity.contains("name='\(project.packageName)'"), identity.contains("versionCode='\(analysis.manifest.versionCode ?? "")'") else { throw AndroidAnalyxerError.failed("Split-APK gehört nicht zur gleichen Paketversion.") }
                project.additionalAPKs?.append(ProjectAPK(relativePath: relative, name: file.name, sha256: file.sha256))
            }
        }
        try fm.createDirectory(at: staging.appendingPathComponent("evidence"), withIntermediateDirectories: false)
        for (kind, text) in [(EvidenceKind.staticReport, analysis.reportText), (.manifest, analysis.manifestXML), (.dex, analysis.dexInventory)] {
            let entry = try writeEvidence(in: staging, kind: kind, summary: kind.title, sessionID: nil, data: Data(text.utf8))
            project.evidence.append(entry)
        }
        try encode(project).write(to: staging.appendingPathComponent("project.json"), options: .atomic)
        try fm.moveItem(at: staging, to: target)
        completed = true
        return ProjectStore(directory: target.resolvingSymlinksInPath(), project: project)
    }

    public static func open(at directory: URL) async throws -> ProjectStore {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let value = try read(root)
        try validate(value, root: root)
        let apk = try safeURL(value.apkPath, root: root)
        guard try ArtifactHash.sha256(apk) == value.analysis.apk.sha256 else {
            throw AndroidAnalyxerError.failed("Die Projekt-APK wurde verändert. Hash stimmt nicht mit der Analyse überein.")
        }
        for file in value.apkFiles {
            guard try ArtifactHash.sha256(safeURL(file.relativePath, root: root)) == file.sha256 else { throw AndroidAnalyxerError.failed("APK-Satz verändert: \(file.name)") }
        }
        return ProjectStore(directory: root, project: value)
    }

    public func snapshot() -> AnalysisProject { project }
    public func verifiedAPK() throws -> URL {
        let url = try Self.safeURL(project.apkPath, root: directory)
        guard try ArtifactHash.sha256(url) == project.analysis.apk.sha256 else { throw AndroidAnalyxerError.failed("Projekt-APK verändert; Aktion abgebrochen.") }
        return url
    }
    public func verifiedAPKs() throws -> [URL] {
        try project.apkFiles.map { try verifiedAPKComponent(path: $0.relativePath) }
    }
    public func verifiedAPKComponent(path: String) throws -> URL {
        guard let file = project.apkFiles.first(where: { $0.relativePath == path }) else { throw AndroidAnalyxerError.invalidInput("APK gehört nicht zum Projekt.") }
        let url = try Self.safeURL(path, root: directory)
        guard try ArtifactHash.sha256(url) == file.sha256 else { throw AndroidAnalyxerError.failed("APK-Satz verändert: \(file.name)") }
        return url
    }
    public func evidenceURL(id: UUID) throws -> URL {
        guard let entry = project.evidence.first(where: { $0.id == id }) else { throw AndroidAnalyxerError.invalidInput("Befund nicht gefunden.") }
        let url = try Self.safeURL(entry.relativePath, root: directory)
        guard try ArtifactHash.sha256(url) == entry.sha256 else { throw AndroidAnalyxerError.failed("Befunddatei verändert oder beschädigt.") }
        return url
    }
    public func session(_ id: UUID) throws -> AnalysisSession {
        guard let result = project.sessions.first(where: { $0.id == id }), result.endedAt == nil else { throw AndroidAnalyxerError.invalidInput("Testsitzung ist nicht aktiv.") }
        return result
    }
    public func evidenceData(id: UUID) throws -> Data {
        guard let entry = project.evidence.first(where: { $0.id == id }) else { throw AndroidAnalyxerError.invalidInput("Befund nicht gefunden.") }
        let url = try Self.safeURL(entry.relativePath, root: directory)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
        let data = try Data(contentsOf: url)
        guard ArtifactHash.sha256(data: data) == entry.sha256 else { throw AndroidAnalyxerError.failed("Befunddatei verändert oder beschädigt.") }
        return data
    }
    public func startSession(device: DeviceObservation) throws -> AnalysisSession {
        let newSession = AnalysisSession(id: UUID(), startedAt: Date(), device: device)
        try mutate { value in
            // A new explicit session closes any previous one; resumed projects never
            // silently attach to a reused emulator serial or an old PID.
            for index in value.sessions.indices where value.sessions[index].endedAt == nil { value.sessions[index].endedAt = Date() }
            value.sessions.append(newSession)
        }
        return newSession
    }
    public func endSession(_ id: UUID) throws {
        try mutate { value in
            guard let index = value.sessions.firstIndex(where: { $0.id == id }) else { throw AndroidAnalyxerError.invalidInput("Sitzung nicht gefunden.") }
            value.sessions[index].endedAt = Date()
        }
    }
    @discardableResult
    public func record(kind: EvidenceKind, summary: String, data: Data, sessionID: UUID? = nil) throws -> ProjectEvidence {
        if let sessionID { _ = try session(sessionID) }
        let entry = try Self.writeEvidence(in: directory, kind: kind, summary: summary, sessionID: sessionID, data: data)
        do { try mutate {
            $0.evidence.append(entry)
            if kind == .installedApp { $0.schemaVersion = 3 }
            if [.rea, .instrumentation, .probeScript, .networkCapture, .networkReport].contains(kind) { $0.schemaVersion = max($0.schemaVersion, 2) }
        } }
        catch {
            // Only our new UUID artifact is removed; canonical project data is untouched.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
            throw error
        }
        return entry
    }
    public func addNote(_ text: String, sessionID: UUID? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AndroidAnalyxerError.invalidInput("Notiz ist leer.") }
        try record(kind: .note, summary: String(text.prefix(120)), data: Data(text.utf8), sessionID: sessionID)
    }
    public func export(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AndroidAnalyxerError.invalidInput("Export benötigt einen neuen Ordner.") }
        _ = try verifiedAPKs()
        let sourceManifest = try Self.read(directory)
        guard sourceManifest.revision == project.revision else { throw AndroidAnalyxerError.failed("Projekt wurde anderweitig geändert. Bitte erneut öffnen.") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".android-analyxer-export-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: stage.appendingPathComponent("input"), withIntermediateDirectories: true)
        var done = false
        defer { if !done { try? fm.removeItem(at: stage) } }
        try fm.createDirectory(at: stage.appendingPathComponent("evidence"), withIntermediateDirectories: false)
        for file in project.apkFiles {
            let source = try verifiedAPKComponent(path: file.relativePath)
            let target = stage.appendingPathComponent(file.relativePath)
            try fm.copyItem(at: source, to: target)
            guard try ArtifactHash.sha256(target) == file.sha256 else { throw AndroidAnalyxerError.failed("APK-Satz während Export verändert.") }
        }
        for entry in project.evidence {
            let source = try evidenceURL(id: entry.id)
            let copy = stage.appendingPathComponent(entry.relativePath)
            try fm.copyItem(at: source, to: copy)
            guard try ArtifactHash.sha256(copy) == entry.sha256 else { throw AndroidAnalyxerError.failed("Befund während des Exports verändert.") }
        }
        try Self.encode(project).write(to: stage.appendingPathComponent("project.json"), options: .atomic)
        try combinedReport().write(to: stage.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        guard try ArtifactHash.sha256(stage.appendingPathComponent(project.apkPath)) == project.analysis.apk.sha256 else { throw AndroidAnalyxerError.failed("APK während des Exports verändert.") }
        try fm.moveItem(at: stage, to: destination)
        done = true
    }
    public func combinedReport() throws -> String {
        var report = project.analysis.reportText + "\nAPK-SATZ (statischer Hauptbericht: Basis-APK)\n"
        for file in project.apkFiles { report += "\(file.name) · \(file.relativePath) · SHA-256 \(file.sha256)\n" }
        if let source = project.installedSource { report += "Import: \(source.capturedAt.ISO8601Format()) · \(source.serial) · Boot \(source.bootID)\nInstaller laut Android: \(source.installer)\n" }
        report += "\nTESTSITZUNGEN\n"
        for session in project.sessions {
            report += "\nSitzung \(session.id) · \(session.startedAt.ISO8601Format())\nGerät: \(session.device.serial) · AVD: \(session.device.avdName ?? "unbekannt/physisch")\n"
            for key in session.device.properties.keys.sorted() { report += "\(key): \(session.device.properties[key]!)\n" }
            report += "ADB: \(session.device.adbVersion)\nEnde: \(session.endedAt?.ISO8601Format() ?? "nicht dokumentiert")\n"
        }
        report += "\nBEFUNDE UND AKTIONEN\n"
        for entry in project.evidence {
            report += "\n\(entry.timestamp.ISO8601Format()) · \(entry.kind.title) · \(entry.summary)\nSitzung: \(entry.sessionID?.uuidString ?? "statisch/projektweit")\nDatei: \(entry.relativePath)\nSHA-256: \(entry.sha256)\n"
            if [.note, .failure, .installation, .installedApp, .launch, .navigation].contains(entry.kind) {
                let text = String(decoding: try evidenceData(id: entry.id), as: UTF8.self)
                report += text + "\n"
            }
        }
        return report
    }

    private func mutate(_ operation: (inout AnalysisProject) throws -> Void) throws {
        // All cooperating writers lock the same file; revisions reject stale windows.
        let lockURL = directory.appendingPathComponent(".write-lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AndroidAnalyxerError.failed("Projekt kann nicht zum Schreiben gesperrt werden.") }
        defer { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AndroidAnalyxerError.failed("Projekt wird gerade von einer anderen Instanz gespeichert.") }
        let current = try Self.read(directory)
        guard current.id == project.id, current.revision == project.revision else { throw AndroidAnalyxerError.failed("Projekt wurde anderweitig geändert. Bitte erneut öffnen.") }
        var updated = project
        try operation(&updated)
        updated.revision += 1; updated.updatedAt = Date()
        try Self.encode(updated).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        project = updated
    }
    private static func writeEvidence(in root: URL, kind: EvidenceKind, summary: String, sessionID: UUID?, data: Data) throws -> ProjectEvidence {
        let id = UUID()
        let relative = "evidence/\(id.uuidString).\(kind.fileExtension)"
        let target = try safeURL(relative, root: root, requireFile: false)
        try data.write(to: target, options: .atomic)
        return ProjectEvidence(id: id, timestamp: Date(), kind: kind, summary: summary, sessionID: sessionID, relativePath: relative, sha256: ArtifactHash.sha256(data: data), byteCount: data.count)
    }
    private static func encode(_ project: AnalysisProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(project)
    }
    private static func read(_ root: URL) throws -> AnalysisProject {
        let url = try safeURL("project.json", root: root)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(AnalysisProject.self, from: Data(contentsOf: url))
        guard (1...3).contains(value.schemaVersion) else { throw AndroidAnalyxerError.invalidInput("Diese Projektversion wird noch nicht unterstützt.") }
        return value
    }
    private static func validate(_ value: AnalysisProject, root: URL) throws {
        guard value.apkPath == "input/application.apk", Set(value.sessions.map(\.id)).count == value.sessions.count,
              Set(value.evidence.map(\.id)).count == value.evidence.count else { throw AndroidAnalyxerError.invalidInput("Ungültiger Projektindex.") }
        for (index, file) in (value.additionalAPKs ?? []).enumerated() {
            guard value.schemaVersion >= 3, file.relativePath == "input/split-\(index + 1).apk",
                  file.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AndroidAnalyxerError.invalidInput("Ungültiger APK-Satz im Projekt.") }
            _ = try safeURL(file.relativePath, root: root)
        }
        for entry in value.evidence {
            guard entry.relativePath == "evidence/\(entry.id.uuidString).\(entry.kind.fileExtension)",
                  entry.sessionID == nil || value.sessions.contains(where: { $0.id == entry.sessionID }) else { throw AndroidAnalyxerError.invalidInput("Ungültiger Befundpfad oder Sitzungsbezug.") }
            _ = try safeURL(entry.relativePath, root: root)
        }
    }
    private static func safeURL(_ relative: String, root: URL, requireFile: Bool = true) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw AndroidAnalyxerError.invalidInput("Ungültiger Pfad im Projekt.")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = canonicalRoot.appendingPathComponent(relative)
        guard url.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot.path + "/") else { throw AndroidAnalyxerError.invalidInput("Projektpfad verweist nach außerhalb.") }
        // Reject symlinks even when they currently resolve within the project.
        var component = canonicalRoot
        for part in relative.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AndroidAnalyxerError.invalidInput("Symbolische Links im Projekt werden nicht unterstützt.") }
        }
        if requireFile, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { throw AndroidAnalyxerError.invalidInput("Projektdatei fehlt: \(relative)") }
        return url
    }
}
