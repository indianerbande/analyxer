import Foundation

public struct ProjectAPK: Codable, Identifiable, Sendable {
    public let relativePath: String
    public let name: String
    public let sha256: String
    public var id: String { relativePath }
}
public struct InstalledAppSource: Codable, Sendable {
    public let package: String
    public let serial: String
    public let bootID: String
    public let capturedAt: Date
    public let installer: String
    public let installedPaths: [String]
}
public struct InstalledAppCapture: Sendable {
    public let directory: URL
    public let source: InstalledAppSource
    public let files: [ProjectAPK]
    public var baseAPK: URL { directory.appendingPathComponent(files[0].relativePath) }
}

extension EmulatorService {
    /// Capture code artifacts only. App-private data and account tokens are not copied.
    /// Caller owns the new destination and removes it after project creation.
    public func captureInstalledApp(serial: String, package: String, to directory: URL) async throws -> InstalledAppCapture {
        let boot = try await bootIdentity(serial: serial)
        let paths = try await installedAPKPaths(serial: serial, package: package)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw AndroidAnalyxerError.invalidInput("APK-Import benötigt einen neuen Zielordner.") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? fm.removeItem(at: directory) } }
        var files: [ProjectAPK] = []
        for (index, path) in paths.enumerated() {
            let name = index == 0 ? "base.apk" : "split-\(index).apk"
            let target = directory.appendingPathComponent(name)
            _ = try await adb(serial: serial, arguments: ["pull", path, target.path], timeout: 180)
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AndroidAnalyxerError.failed("APK konnte nicht gelesen werden.") }
            files.append(ProjectAPK(relativePath: name, name: URL(fileURLWithPath: path).lastPathComponent, sha256: try ArtifactHash.sha256(target)))
        }
        let installer = try await adb(serial: serial, arguments: ["shell", "pm", "list", "packages", "-i", package])
        guard try await installedAPKPaths(serial: serial, package: package) == paths,
              try await bootIdentity(serial: serial) == boot else { throw AndroidAnalyxerError.failed("Installation oder Android-Gerät während des Imports geändert. Bitte erneut importieren.") }
        complete = true
        return InstalledAppCapture(directory: directory, source: InstalledAppSource(package: package, serial: serial, bootID: boot,
            capturedAt: Date(), installer: installer.text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("package:" + package + " ") }.joined(separator: "\n"), installedPaths: paths), files: files)
    }

    public func verifyInstalledSet(serial: String, package: String, expected: [String]) async throws -> Date {
        guard !expected.isEmpty, expected.allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else { throw AndroidAnalyxerError.invalidInput("Ungültige APK-Prüfsummen.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("android-analyxer-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = try await captureInstalledApp(serial: serial, package: package, to: folder)
        guard capture.files.map(\.sha256).sorted() == expected.sorted() else {
            throw AndroidAnalyxerError.failed("Die installierte App stimmt nicht mit dem vollständigen APK-Satz des Projekts überein. Nach einem Store-Update bitte neu importieren.")
        }
        return capture.source.capturedAt
    }

    public func install(apks: [URL], serial: String) async throws -> String {
        guard !apks.isEmpty else { throw AndroidAnalyxerError.invalidInput("APK-Satz ist leer.") }
        if apks.count == 1 { return try await install(apk: apks[0], serial: serial) }
        for file in apks {
            guard file.isFileURL, file.pathExtension == "apk", (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw AndroidAnalyxerError.invalidInput("APK-Datei fehlt.") }
        }
        return try await adb(serial: serial, arguments: ["install-multiple", "-r"] + apks.map(\.path), timeout: 300).text
    }

    func installedAPKPaths(serial: String, package: String) async throws -> [String] {
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else { throw AndroidAnalyxerError.invalidInput("Ungültige Paketkennung.") }
        let result = try await adb(serial: serial, arguments: ["shell", "pm", "path", package], outputLimit: 128 * 1024)
        guard !result.truncated else { throw AndroidAnalyxerError.outputTooLarge }
        let lines = result.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !lines.isEmpty, lines.count <= 256, lines.allSatisfy({ $0.hasPrefix("package:") }) else { throw AndroidAnalyxerError.failed("Keine gültige APK-Liste für \(package).") }
        let paths = lines.map { String($0.dropFirst(8)) }
        guard Set(paths).count == paths.count, paths.allSatisfy({ path in
            path.range(of: #"^/[A-Za-z0-9_./~+=-]+\.apk$"#, options: .regularExpression) != nil && !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        }) else { throw AndroidAnalyxerError.failed("Ungültige installierte APK-Pfade.") }
        if paths.count == 1 { return paths }
        guard paths.filter({ $0.hasSuffix("/base.apk") }).count == 1 else { throw AndroidAnalyxerError.failed("Basis-APK im Split-Satz nicht eindeutig.") }
        return paths.sorted { left, right in
            if left.hasSuffix("/base.apk") { return true }
            if right.hasSuffix("/base.apk") { return false }
            return left < right
        }
    }
}
