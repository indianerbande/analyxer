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
    /// Shown in the UI; follows the app language.
    public var title: String {
        switch self {
        case .staticReport: String(localized: "Static Report")
        case .manifest: String(localized: "Manifest")
        case .dex: String(localized: "DEX Inventory")
        case .installation: String(localized: "Installation")
        case .launch: String(localized: "App Launch")
        case .logcat: String(localized: "App Logcat")
        case .screenshot: String(localized: "Screenshot")
        case .navigation: String(localized: "Navigation")
        case .note: String(localized: "Note")
        case .failure: String(localized: "Error")
        case .installedApp: String(localized: "Installed App Verified")
        case .rea: String(localized: "REA Code Analysis")
        case .instrumentation: String(localized: "Process Observation")
        case .probeScript: String(localized: "Observation Script")
        case .networkCapture: String(localized: "Network Capture")
        case .networkReport: String(localized: "Network Report")
        }
    }
    /// Written into project files and reports; independent of the UI language.
    var reportTitle: String {
        switch self {
        case .staticReport: "Static Report"
        case .manifest: "Manifest"
        case .dex: "DEX Inventory"
        case .installation: "Installation"
        case .launch: "App Launch"
        case .logcat: "App Logcat"
        case .screenshot: "Screenshot"
        case .navigation: "Navigation"
        case .note: "Note"
        case .failure: "Error"
        case .installedApp: "Installed App Verified"
        case .rea: "REA Code Analysis"
        case .instrumentation: "Process Observation"
        case .probeScript: "Observation Script"
        case .networkCapture: "Network Capture"
        case .networkReport: "Network Report"
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
            throw AnalyxerError.invalidInput(String(localized: "Choose an APK and a new project folder that does not exist yet."))
        }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".analyxer-creating-" + UUID().uuidString)
        try fm.createDirectory(at: staging.appendingPathComponent("input"), withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: staging) } }
        let copied = staging.appendingPathComponent("input/application.apk")
        try fm.copyItem(at: apk.resolvingSymlinksInPath(), to: copied)
        let analysis = try await service.staticAnalysis(apk: copied)
        var project = AnalysisProject(id: UUID(), createdAt: Date(), updatedAt: Date(), title: installed?.source.package ?? apk.deletingPathExtension().lastPathComponent,
                                      originalAPKName: installed?.files.first?.name ?? apk.lastPathComponent, apkPath: "input/application.apk", analysis: analysis)
        if let installed {
            guard analysis.manifest.packageName == installed.source.package, installed.files.first?.sha256 == analysis.apk.sha256 else { throw AnalyxerError.failed(String(localized: "The imported base APK does not match the package.")) }
            project.schemaVersion = 3
            project.installedSource = installed.source
            project.additionalAPKs = []
            for (index, file) in installed.files.dropFirst().enumerated() {
                let relative = "input/split-\(index + 1).apk"
                let source = try safeURL(file.relativePath, root: installed.directory)
                let target = staging.appendingPathComponent(relative)
                try fm.copyItem(at: source, to: target)
                guard try ArtifactHash.sha256(target) == file.sha256 else { throw AnalyxerError.failed(String(localized: "A split APK changed during the import.")) }
                let report = try await service.inspectAPK(at: target)
                let identity = report.metadata.components(separatedBy: .newlines).first { $0.hasPrefix("package:") } ?? ""
                guard identity.contains("name='\(project.packageName)'"), identity.contains("versionCode='\(analysis.manifest.versionCode ?? "")'") else { throw AnalyxerError.failed(String(localized: "A split APK does not belong to the same package version.")) }
                project.additionalAPKs?.append(ProjectAPK(relativePath: relative, name: file.name, sha256: file.sha256))
            }
        }
        try fm.createDirectory(at: staging.appendingPathComponent("evidence"), withIntermediateDirectories: false)
        for (kind, text) in [(EvidenceKind.staticReport, analysis.reportText), (.manifest, analysis.manifestXML), (.dex, analysis.dexInventory)] {
            let entry = try writeEvidence(in: staging, kind: kind, summary: kind.reportTitle, sessionID: nil, data: Data(text.utf8))
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
            throw AnalyxerError.failed(String(localized: "The project APK was changed. Its hash does not match the analysis."))
        }
        for file in value.apkFiles {
            guard try ArtifactHash.sha256(safeURL(file.relativePath, root: root)) == file.sha256 else { throw AnalyxerError.failed(String(localized: "APK set changed: \(file.name)")) }
        }
        return ProjectStore(directory: root, project: value)
    }

    public func snapshot() -> AnalysisProject { project }
    public func verifiedAPK() throws -> URL {
        let url = try Self.safeURL(project.apkPath, root: directory)
        guard try ArtifactHash.sha256(url) == project.analysis.apk.sha256 else { throw AnalyxerError.failed(String(localized: "Project APK changed; action cancelled.")) }
        return url
    }
    public func verifiedAPKs() throws -> [URL] {
        try project.apkFiles.map { try verifiedAPKComponent(path: $0.relativePath) }
    }
    public func verifiedAPKComponent(path: String) throws -> URL {
        guard let file = project.apkFiles.first(where: { $0.relativePath == path }) else { throw AnalyxerError.invalidInput(String(localized: "The APK does not belong to the project.")) }
        let url = try Self.safeURL(path, root: directory)
        guard try ArtifactHash.sha256(url) == file.sha256 else { throw AnalyxerError.failed(String(localized: "APK set changed: \(file.name)")) }
        return url
    }
    public func evidenceURL(id: UUID) throws -> URL {
        guard let entry = project.evidence.first(where: { $0.id == id }) else { throw AnalyxerError.invalidInput(String(localized: "Finding not found.")) }
        let url = try Self.safeURL(entry.relativePath, root: directory)
        guard try ArtifactHash.sha256(url) == entry.sha256 else { throw AnalyxerError.failed(String(localized: "Finding file changed or damaged.")) }
        return url
    }
    public func session(_ id: UUID) throws -> AnalysisSession {
        guard let result = project.sessions.first(where: { $0.id == id }), result.endedAt == nil else { throw AnalyxerError.invalidInput(String(localized: "The test session is not active.")) }
        return result
    }
    public func evidenceData(id: UUID) throws -> Data {
        guard let entry = project.evidence.first(where: { $0.id == id }) else { throw AnalyxerError.invalidInput(String(localized: "Finding not found.")) }
        let url = try Self.safeURL(entry.relativePath, root: directory)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw AnalyxerError.outputTooLarge }
        let data = try Data(contentsOf: url)
        guard ArtifactHash.sha256(data: data) == entry.sha256 else { throw AnalyxerError.failed(String(localized: "Finding file changed or damaged.")) }
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
            guard let index = value.sessions.firstIndex(where: { $0.id == id }) else { throw AnalyxerError.invalidInput(String(localized: "Session not found.")) }
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnalyxerError.invalidInput(String(localized: "The note is empty.")) }
        try record(kind: .note, summary: String(text.prefix(120)), data: Data(text.utf8), sessionID: sessionID)
    }
    public func export(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AnalyxerError.invalidInput(String(localized: "The export needs a new folder.")) }
        _ = try verifiedAPKs()
        let sourceManifest = try Self.read(directory)
        guard sourceManifest.revision == project.revision else { throw AnalyxerError.failed(String(localized: "The project was changed elsewhere. Please open it again.")) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".analyxer-export-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: stage.appendingPathComponent("input"), withIntermediateDirectories: true)
        var done = false
        defer { if !done { try? fm.removeItem(at: stage) } }
        try fm.createDirectory(at: stage.appendingPathComponent("evidence"), withIntermediateDirectories: false)
        for file in project.apkFiles {
            let source = try verifiedAPKComponent(path: file.relativePath)
            let target = stage.appendingPathComponent(file.relativePath)
            try fm.copyItem(at: source, to: target)
            guard try ArtifactHash.sha256(target) == file.sha256 else { throw AnalyxerError.failed(String(localized: "APK set changed during the export.")) }
        }
        for entry in project.evidence {
            let source = try evidenceURL(id: entry.id)
            let copy = stage.appendingPathComponent(entry.relativePath)
            try fm.copyItem(at: source, to: copy)
            guard try ArtifactHash.sha256(copy) == entry.sha256 else { throw AnalyxerError.failed(String(localized: "A finding changed during the export.")) }
        }
        try Self.encode(project).write(to: stage.appendingPathComponent("project.json"), options: .atomic)
        try combinedReport().write(to: stage.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        guard try ArtifactHash.sha256(stage.appendingPathComponent(project.apkPath)) == project.analysis.apk.sha256 else { throw AnalyxerError.failed(String(localized: "The APK changed during the export.")) }
        try fm.moveItem(at: stage, to: destination)
        done = true
    }
    public func combinedReport() throws -> String {
        var report = project.analysis.reportText + "\nAPK SET (main static report: base APK)\n"
        for file in project.apkFiles { report += "\(file.name) · \(file.relativePath) · SHA-256 \(file.sha256)\n" }
        if let source = project.installedSource { report += "Import: \(source.capturedAt.ISO8601Format()) · \(source.serial) · Boot \(source.bootID)\nInstaller reported by Android: \(source.installer)\n" }
        report += "\nTEST SESSIONS\n"
        for session in project.sessions {
            report += "\nSession \(session.id) · \(session.startedAt.ISO8601Format())\nDevice: \(session.device.serial) · AVD: \(session.device.avdName ?? "unknown/physical")\n"
            for key in session.device.properties.keys.sorted() { report += "\(key): \(session.device.properties[key]!)\n" }
            report += "ADB: \(session.device.adbVersion)\nEnd: \(session.endedAt?.ISO8601Format() ?? "not documented")\n"
        }
        report += "\nFINDINGS AND ACTIONS\n"
        for entry in project.evidence {
            report += "\n\(entry.timestamp.ISO8601Format()) · \(entry.kind.reportTitle) · \(entry.summary)\nSession: \(entry.sessionID?.uuidString ?? "static/project-wide")\nFile: \(entry.relativePath)\nSHA-256: \(entry.sha256)\n"
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
        guard fd >= 0 else { throw AnalyxerError.failed(String(localized: "The project cannot be locked for writing.")) }
        defer { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AnalyxerError.failed(String(localized: "Another instance is saving the project right now.")) }
        let current = try Self.read(directory)
        guard current.id == project.id, current.revision == project.revision else { throw AnalyxerError.failed(String(localized: "The project was changed elsewhere. Please open it again.")) }
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
        guard (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw AnalyxerError.outputTooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(AnalysisProject.self, from: Data(contentsOf: url))
        guard (1...3).contains(value.schemaVersion) else { throw AnalyxerError.invalidInput(String(localized: "This project version is not supported yet.")) }
        return value
    }
    private static func validate(_ value: AnalysisProject, root: URL) throws {
        guard value.apkPath == "input/application.apk", Set(value.sessions.map(\.id)).count == value.sessions.count,
              Set(value.evidence.map(\.id)).count == value.evidence.count else { throw AnalyxerError.invalidInput(String(localized: "Invalid project index.")) }
        for (index, file) in (value.additionalAPKs ?? []).enumerated() {
            guard value.schemaVersion >= 3, file.relativePath == "input/split-\(index + 1).apk",
                  file.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AnalyxerError.invalidInput(String(localized: "Invalid APK set in the project.")) }
            _ = try safeURL(file.relativePath, root: root)
        }
        for entry in value.evidence {
            guard entry.relativePath == "evidence/\(entry.id.uuidString).\(entry.kind.fileExtension)",
                  entry.sessionID == nil || value.sessions.contains(where: { $0.id == entry.sessionID }) else { throw AnalyxerError.invalidInput(String(localized: "Invalid finding path or session reference.")) }
            _ = try safeURL(entry.relativePath, root: root)
        }
    }
    private static func safeURL(_ relative: String, root: URL, requireFile: Bool = true) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw AnalyxerError.invalidInput(String(localized: "Invalid path in the project."))
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = canonicalRoot.appendingPathComponent(relative)
        guard url.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot.path + "/") else { throw AnalyxerError.invalidInput(String(localized: "A project path points outside the project.")) }
        // Reject symlinks even when they currently resolve within the project.
        var component = canonicalRoot
        for part in relative.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AnalyxerError.invalidInput(String(localized: "Symbolic links in the project are not supported.")) }
        }
        if requireFile, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { throw AnalyxerError.invalidInput(String(localized: "Project file missing: \(relative)")) }
        return url
    }
}
