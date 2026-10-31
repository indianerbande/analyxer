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
            throw AndroidAnalyxerError.invalidInput(String(localized: "Invalid package name or expected APK SHA-256."))
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
            throw AndroidAnalyxerError.failed(String(localized: "The installed APK could not be checked as a regular file."))
        }
        let digest = try ArtifactHash.sha256(local)
        guard digest == expectedSHA256.lowercased() else {
            throw AndroidAnalyxerError.failed(String(localized: "The installed APK does not match the project APK. Reinstall the project APK in this test session."))
        }
        guard try await standaloneAPKPath(serial: serial, package: package) == installedPath else {
            throw AndroidAnalyxerError.failed(String(localized: "The installed APK path changed during the check. Start the test session again."))
        }
        return InstalledAPKVerification(packageIdentifier: package, sha256: digest, installedPath: installedPath, verifiedAt: Date())
    }

    private func standaloneAPKPath(serial: String, package: String) async throws -> String {
        let result = try await adb(serial: serial, arguments: ["shell", "pm", "path", package], outputLimit: 64 * 1024)
        guard !result.truncated else { throw AndroidAnalyxerError.outputTooLarge }
        let lines = result.text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("package:") }) else {
            throw AndroidAnalyxerError.failed(String(localized: "No unique installed APK path could be determined for \(package)."))
        }
        guard lines.count == 1 else {
            throw AndroidAnalyxerError.failed(String(localized: "This installation contains split APKs. The comparison currently supports single APKs only; a base APK alone does not prove the installed app."))
        }
        let path = String(lines[0].dropFirst("package:".count))
        guard path.range(of: #"^/[A-Za-z0-9_./~+=-]+\.apk$"#, options: .regularExpression) != nil,
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AndroidAnalyxerError.failed(String(localized: "Android returned an invalid installed APK path."))
        }
        return path
    }
}
