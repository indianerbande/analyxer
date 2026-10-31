import Foundation

public struct InstalledAPKVerification: Codable, Sendable {
    public let packageIdentifier: String
    public let sha256: String
    public let installedPath: String
    public let verifiedAt: Date
}

extension EmulatorService {
    /// Verifies the installed standalone APK bytes, not merely package/version names.
    /// This is a point-in-time observation; callers must separately bind process and
    /// boot identity before attaching and avoid replacement during a capture.
    @discardableResult
    public func verifyInstalledAPK(serial: String, package: String, expectedSHA256: String) async throws -> InstalledAPKVerification {
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil,
              expectedSHA256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw AndroidAnalyxerError.invalidInput("Ungültige Paketkennung oder erwarteter APK-SHA-256.")
        }
        let installedPath = try await standaloneAPKPath(serial: serial, package: package)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("android-analyxer-apk-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let local = temporary.appendingPathComponent("installed.apk")
        // adb pull uses its sync protocol, never a remote `shell cat` command.
        let result = try await adb(serial: serial, arguments: ["pull", installedPath, local.path], timeout: 180, outputLimit: 64 * 1024)
        guard !result.truncated else { throw AndroidAnalyxerError.outputTooLarge }
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AndroidAnalyxerError.failed("Die installierte APK konnte nicht als reguläre Datei geprüft werden.")
        }
        let digest = try ArtifactHash.sha256(local)
        guard digest == expectedSHA256.lowercased() else {
            throw AndroidAnalyxerError.failed("Die installierte APK stimmt nicht mit der Projekt-APK überein. Bitte die Projekt-APK in dieser Testsitzung neu installieren.")
        }
        guard try await standaloneAPKPath(serial: serial, package: package) == installedPath else {
            throw AndroidAnalyxerError.failed("Der installierte APK-Pfad hat sich während der Prüfung geändert. Bitte die Testsitzung neu beginnen.")
        }
        return InstalledAPKVerification(packageIdentifier: package, sha256: digest, installedPath: installedPath, verifiedAt: Date())
    }

    private func standaloneAPKPath(serial: String, package: String) async throws -> String {
        let result = try await adb(serial: serial, arguments: ["shell", "pm", "path", package], outputLimit: 64 * 1024)
        guard !result.truncated else { throw AndroidAnalyxerError.outputTooLarge }
        let lines = result.text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("package:") }) else {
            throw AndroidAnalyxerError.failed("Für \(package) konnte kein eindeutiger installierter APK-Pfad ermittelt werden.")
        }
        guard lines.count == 1 else {
            throw AndroidAnalyxerError.failed("Diese Installation enthält Split-APKs. Der Abgleich unterstützt derzeit nur einzelne APKs; eine Basis-APK allein belegt die installierte App nicht.")
        }
        let path = String(lines[0].dropFirst("package:".count))
        guard path.range(of: #"^/[A-Za-z0-9_./~+=-]+\.apk$"#, options: .regularExpression) != nil,
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AndroidAnalyxerError.failed("Android lieferte einen ungültigen installierten APK-Pfad.")
        }
        return path
    }
}
