import Foundation
import CryptoKit

// MARK: Tools and requirements

public enum ToolID: String, CaseIterable, Identifiable, Sendable {
    case jdk, node, rea, jadx, fridaBridge, fridaServer, androidSDK
    public var id: String { rawValue }
}

/// Versions the tool manager installs; detection also accepts other suitable versions.
public enum ToolRequirements {
    public static let nodeVersion = "24.22.2"
    public static let reaVersion = "6.8.0"
    public static let reaMinimum = "6.5.0"
    public static let jdkFeature = 25
    public static let jdkMinimum = 17
    public static let fridaJavaBridge = "7.0.13"
    /// REA's own `engines.node`, used until REA is installed and can be asked.
    public static let reaNodeRange = "^22.23.4 || ^24.22.1 || >=26.12.1"
    public static let androidPackages = ["platform-tools", "emulator", "build-tools;36.1.0", "platforms;android-36"]
    public static func playImage(arm: Bool) -> String { "system-images;android-36.1;google_apis_playstore;" + (arm ? "arm64-v8a" : "x86_64") }
}

public struct ToolStatus: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable { case ready, outdated, missing, problem }
    public let id: ToolID
    public let state: State
    public let version: String?
    public let location: URL?
    /// Plain-language detail, localised through the app's string tables.
    public let note: String?
    public init(id: ToolID, state: State, version: String? = nil, location: URL? = nil, note: String? = nil) {
        self.id = id; self.state = state; self.version = version; self.location = location; self.note = note
    }
}

// MARK: Versions

public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public init?(_ text: String) {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }.prefix { $0 != "-" && $0 != "+" }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.map { $0! } + Array(repeating: 0, count: max(0, 3 - numbers.count))
    }
    public var major: Int { parts[0] }
    public var description: String { parts.prefix(3).map(String.init).joined(separator: ".") }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts }

    /// Subset of npm ranges used by `engines`: `||` alternatives of space-separated `^x.y.z`, `>=x.y.z`, `>x.y.z`, `<x.y.z`, `<=x.y.z` or exact versions.
    public func satisfies(_ range: String) -> Bool {
        range.components(separatedBy: "||").contains { alternative in
            let conditions = alternative.split(separator: " ").map(String.init)
            return !conditions.isEmpty && conditions.allSatisfy { condition in
                for op in [">=", "<=", ">", "<", "^", "="] where condition.hasPrefix(op) {
                    guard let bound = SemanticVersion(String(condition.dropFirst(op.count))) else { return false }
                    switch op {
                    case ">=": return self >= bound
                    case "<=": return self <= bound
                    case ">": return self > bound
                    case "<": return self < bound
                    case "^": return major == bound.major && self >= bound
                    default: return self == bound
                    }
                }
                return SemanticVersion(condition).map { $0 == self } ?? false
            }
        }
    }
}

// MARK: Downloads

public protocol FileDownloading: Sendable {
    func data(from url: URL) async throws -> Data
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

/// HTTPS only; redirects (e.g. GitHub release storage) are followed by URLSession.
public struct URLSessionDownloader: FileDownloading {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        try Self.requireHTTPS(url)
        var request = URLRequest(url: url); request.setValue("android-analyxer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AndroidAnalyxerError.failed(String(localized: "Download failed (HTTP \(status)): \(url.absoluteString)")) }
        return data
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try Self.requireHTTPS(url)
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            var request = URLRequest(url: url); request.setValue("android-analyxer", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme == "https" else { throw AndroidAnalyxerError.invalidInput(String(localized: "Only HTTPS downloads are allowed.")) }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var failure: Error?
    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.destination = destination; self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { failure = AndroidAnalyxerError.failed(String(localized: "Download failed (HTTP \(status)).")); return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}

// MARK: Tool manager

/// Finds, checks and installs the external tools the analysis features call. Installed tools live in a user-chosen folder, never in the home folder by default.
public struct ToolSetupService: Sendable {
    public let toolsFolder: URL?
    public let sdkRoot: URL
    public let configured: AnalysisTools
    let runner: any CommandRunning
    let downloader: any FileDownloading
    let arm: Bool
    var fileManager: FileManager { .default }

    #if arch(arm64)
    public static let hostIsARM = true
    #else
    public static let hostIsARM = false
    #endif

    public init(toolsFolder: URL?, sdkRoot: URL, configured: AnalysisTools = AnalysisTools(), runner: any CommandRunning = ProcessCommandRunner(),
                downloader: any FileDownloading = URLSessionDownloader(), arm: Bool = ToolSetupService.hostIsARM) {
        self.toolsFolder = toolsFolder; self.sdkRoot = sdkRoot; self.configured = configured
        self.runner = runner; self.downloader = downloader; self.arm = arm
    }

    func folder(_ name: String) -> URL? { toolsFolder?.appendingPathComponent(name, isDirectory: true) }

    // MARK: Checking

    public func check() async -> [ToolStatus] {
        let jdk = await checkJDK(), node = await checkNode(), rea = checkREA()
        return [jdk, node, rea, checkJADX(), checkBridge(), checkFridaServer(), await checkAndroidSDK(javaHome: jdk.state == .ready ? jdk.location : nil)]
    }

    func checkJDK() async -> ToolStatus {
        var candidates = folder("jdk").map { children(of: $0).map { $0.appendingPathComponent("Contents/Home") } } ?? []
        if !configured.javaHome.isEmpty { candidates.append(URL(fileURLWithPath: configured.javaHome)) }
        if let result = try? await runner.run(Command(executable: URL(fileURLWithPath: "/usr/libexec/java_home"), arguments: [], timeout: 10)), result.status == 0 {
            let path = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { candidates.append(URL(fileURLWithPath: path)) }
        }
        var found: (URL, String)?
        for home in candidates where fileManager.isExecutableFile(atPath: home.appendingPathComponent("bin/java").path) {
            let version = Self.javaVersion(release: (try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8)) ?? "") ?? "?"
            guard fileManager.isExecutableFile(atPath: home.appendingPathComponent("bin/javac").path) else {
                found = found ?? (home, version); continue
            }
            if let parsed = SemanticVersion(version), parsed.major >= ToolRequirements.jdkMinimum { return ToolStatus(id: .jdk, state: .ready, version: version, location: home) }
            found = found ?? (home, version)
        }
        if let (home, version) = found {
            return ToolStatus(id: .jdk, state: .outdated, version: version, location: home,
                              note: String(localized: "A full JDK \(ToolRequirements.jdkMinimum) or newer with javac is needed."))
        }
        return ToolStatus(id: .jdk, state: .missing)
    }

    func checkNode() async -> ToolStatus {
        var candidates = folder("node").map { children(of: $0).map { $0.appendingPathComponent("bin/node") } } ?? []
        if !configured.executable.isEmpty, URL(fileURLWithPath: configured.executable).lastPathComponent == "node" { candidates.append(URL(fileURLWithPath: configured.executable)) }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map { URL(fileURLWithPath: $0) }
        let range = reaPackage().flatMap { Self.engines(packageJSON: $0.json) } ?? ToolRequirements.reaNodeRange
        var outdated: (URL, String)?
        for node in candidates where fileManager.isExecutableFile(atPath: node.path) {
            guard let result = try? await runner.run(Command(executable: node, arguments: ["--version"], timeout: 10)), result.status == 0,
                  let version = SemanticVersion(result.text) else { continue }
            if version.satisfies(range) { return ToolStatus(id: .node, state: .ready, version: version.description, location: node) }
            outdated = outdated ?? (node, version.description)
        }
        if let (node, version) = outdated {
            return ToolStatus(id: .node, state: .outdated, version: version, location: node, note: String(localized: "REA needs Node.js \(range)."))
        }
        return ToolStatus(id: .node, state: .missing)
    }

    /// The REA package in use: the managed one first, then the one from the existing tool profile.
    func reaPackage() -> (root: URL, json: [String: Any])? {
        var roots = folder("rea").map { [$0.appendingPathComponent("node_modules/rea-agents")] } ?? []
        if !configured.cliScript.isEmpty { roots.append(URL(fileURLWithPath: configured.cliScript).deletingLastPathComponent().deletingLastPathComponent()) }
        for root in roots {
            if let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["name"] as? String == "rea-agents" { return (root, json) }
        }
        return nil
    }

    func checkREA() -> ToolStatus {
        guard let (root, json) = reaPackage(), let version = json["version"] as? String else { return ToolStatus(id: .rea, state: .missing) }
        let script = root.appendingPathComponent("scripts/rea.mjs")
        if let parsed = SemanticVersion(version), let minimum = SemanticVersion(ToolRequirements.reaMinimum), parsed < minimum {
            return ToolStatus(id: .rea, state: .outdated, version: version, location: script, note: String(localized: "REA \(ToolRequirements.reaMinimum) or newer is needed."))
        }
        let binding = root.deletingLastPathComponent().appendingPathComponent("frida/build/frida_binding.node")
        guard fileManager.fileExists(atPath: binding.path) else {
            return ToolStatus(id: .rea, state: .problem, version: version, location: script, note: String(localized: "Frida's native component is missing; process observation will not work."))
        }
        return ToolStatus(id: .rea, state: .ready, version: version, location: script)
    }

    /// JADX release REA was audited with (version, URL, SHA-256), read from the installed REA.
    func expectedJADX() -> (version: String, url: URL, sha256: String)? {
        guard let (root, _) = reaPackage(), let text = try? String(contentsOf: root.appendingPathComponent("dist/android/JadxRelease.js"), encoding: .utf8) else { return nil }
        return Self.jadxRelease(source: text)
    }

    func checkJADX() -> ToolStatus {
        let expected = expectedJADX()
        var candidates = folder("jadx").map { children(of: $0).filter { $0.pathExtension == "jar" } } ?? []
        if !configured.jadxJAR.isEmpty { candidates.append(URL(fileURLWithPath: configured.jadxJAR)) }
        let existing = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        guard let expected else {
            return existing.first.map { ToolStatus(id: .jadx, state: .ready, location: $0, note: String(localized: "Version not verified; REA is not installed.")) }
                ?? ToolStatus(id: .jadx, state: .missing)
        }
        if let match = existing.first(where: { (try? ArtifactHash.sha256($0)) == expected.sha256 }) {
            return ToolStatus(id: .jadx, state: .ready, version: expected.version, location: match)
        }
        if let other = existing.first {
            return ToolStatus(id: .jadx, state: .outdated, location: other, note: String(localized: "Does not match the JADX \(expected.version) release REA expects."))
        }
        return ToolStatus(id: .jadx, state: .missing)
    }

    func checkBridge() -> ToolStatus {
        var candidates = folder("frida-bridge").map { [$0.appendingPathComponent("java-bridge.bundle.js")] } ?? []
        if !configured.javaBridge.isEmpty { candidates.append(URL(fileURLWithPath: configured.javaBridge)) }
        if let bridge = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) { return ToolStatus(id: .fridaBridge, state: .ready, location: bridge) }
        return ToolStatus(id: .fridaBridge, state: .missing)
    }

    /// Version of the Frida Node module REA uses; frida-server on the device must match it.
    func fridaVersion() -> String? {
        guard let (root, _) = reaPackage(), let data = try? Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("frida/package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    func fridaServerFile(version: String, abi: String) -> URL? { folder("frida-server")?.appendingPathComponent("frida-server-\(version)-android-\(abi)") }

    func checkFridaServer() -> ToolStatus {
        guard let version = fridaVersion() else { return ToolStatus(id: .fridaServer, state: .missing, note: String(localized: "Install REA first; frida-server must match its Frida version.")) }
        if let file = fridaServerFile(version: version, abi: arm ? "arm64" : "x86_64"), fileManager.fileExists(atPath: file.path) {
            return ToolStatus(id: .fridaServer, state: .ready, version: version, location: file)
        }
        return ToolStatus(id: .fridaServer, state: .missing, version: version)
    }

    func checkAndroidSDK(javaHome: URL?) async -> ToolStatus {
        let paths = SDKPaths(root: sdkRoot)
        let parts: [(String, URL?)] = [("adb", paths.adb), ("emulator", paths.emulator), ("aapt2", paths.aapt2), ("apkanalyzer", paths.apkanalyzer),
                                       ("avdmanager", paths.avdmanager), ("sdkmanager", paths.sdkmanager)]
        let missing = parts.filter { $0.1 == nil }.map(\.0)
        if missing.isEmpty { return ToolStatus(id: .androidSDK, state: .ready, location: sdkRoot) }
        if missing.count == parts.count { return ToolStatus(id: .androidSDK, state: .missing, location: sdkRoot) }
        return ToolStatus(id: .androidSDK, state: .problem, location: sdkRoot, note: String(localized: "Missing: \(missing.joined(separator: ", "))"))
    }

    /// Tool profile pointing at whatever is ready, keeping existing entries for anything not found.
    public func resolvedProfile(from statuses: [ToolStatus]) -> AnalysisTools {
        var profile = configured
        let ready = Dictionary(uniqueKeysWithValues: statuses.filter { $0.state == .ready || $0.id == .rea && $0.state == .problem }.compactMap { status in status.location.map { (status.id, $0.path) } })
        if let node = ready[.node] { profile.executable = node }
        if let rea = ready[.rea] { profile.cliScript = rea }
        if let jadx = ready[.jadx] { profile.jadxJAR = jadx }
        if let jdk = ready[.jdk] { profile.javaHome = jdk }
        if let bridge = ready[.fridaBridge] { profile.javaBridge = bridge }
        return profile
    }

    // MARK: Installing

    public typealias Progress = @Sendable (_ message: String, _ fraction: Double?) -> Void

    public func install(_ tool: ToolID, includePlayImage: Bool = false, progress: @escaping Progress = { _, _ in }) async throws {
        guard tool == .androidSDK || toolsFolder != nil else { throw AndroidAnalyxerError.invalidInput(String(localized: "Choose a tools folder first.")) }
        if let toolsFolder { try fileManager.createDirectory(at: toolsFolder, withIntermediateDirectories: true) }
        switch tool {
        case .jdk: try await installJDK(progress)
        case .node: try await installNode(progress)
        case .rea: try await installREA(progress)
        case .jadx: try await installJADX(progress)
        case .fridaBridge: try await installBridge(progress)
        case .fridaServer: try await installFridaServer(progress)
        case .androidSDK: try await installAndroidSDK(includePlayImage: includePlayImage, progress)
        }
    }

    /// Downloads into the tools folder's `.downloads`, verifies the checksum and returns the file; a mismatch deletes it.
    func fetch(_ url: URL, name: String, sha256: String? = nil, sha1: String? = nil, label: String, _ progress: @escaping Progress) async throws -> URL {
        let downloads = (toolsFolder ?? sdkRoot.deletingLastPathComponent()).appendingPathComponent(".downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent(name)
        progress(String(localized: "Downloading \(label) …"), 0)
        try await downloader.download(url, to: file) { written, total in progress(String(localized: "Downloading \(label) …"), total > 0 ? Double(written) / Double(total) : nil) }
        progress(String(localized: "Verifying \(label) …"), nil)
        let actual = sha256 != nil ? try ArtifactHash.sha256(file) : try Self.sha1(file)
        guard actual.lowercased() == (sha256 ?? sha1 ?? "").lowercased(), !actual.isEmpty else {
            try? fileManager.removeItem(at: file)
            throw AndroidAnalyxerError.failed(String(localized: "Checksum mismatch for \(label); the download was deleted."))
        }
        // URLSession leaves its temporary files at 0600.
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        return file
    }

    /// Extracts into a fresh sibling folder and only then replaces the target.
    func replace(_ target: URL, extracting archive: URL, zip: Bool = false) async throws {
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let command = zip ? Command(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, staging.path], timeout: 900)
                          : Command(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", staging.path], timeout: 900)
        let result = try await runner.run(command)
        guard result.status == 0 else {
            try? fileManager.removeItem(at: staging)
            throw AndroidAnalyxerError.failed(String(localized: "Could not extract \(archive.lastPathComponent).") + " " + String(decoding: result.stderr.prefix(500), as: UTF8.self))
        }
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: staging, to: target)
        try? fileManager.removeItem(at: archive)
    }

    func installJDK(_ progress: @escaping Progress) async throws {
        let api = URL(string: "https://api.adoptium.net/v3/assets/latest/\(ToolRequirements.jdkFeature)/hotspot?architecture=\(arm ? "aarch64" : "x64")&image_type=jdk&os=mac&vendor=eclipse")!
        guard let asset = Self.adoptiumAsset(json: try await downloader.data(from: api)) else { throw AndroidAnalyxerError.failed(String(localized: "Adoptium did not list a suitable JDK.")) }
        let archive = try await fetch(asset.url, name: asset.name, sha256: asset.sha256, label: "JDK \(asset.release)", progress)
        progress(String(localized: "Extracting \("JDK") …"), nil)
        try await replace(folder("jdk")!, extracting: archive)
    }

    func installNode(_ progress: @escaping Progress) async throws {
        let version = ToolRequirements.nodeVersion, name = "node-v\(version)-darwin-\(arm ? "arm64" : "x64").tar.gz"
        let base = URL(string: "https://nodejs.org/dist/v\(version)/")!
        guard let sha256 = Self.shasum(String(decoding: try await downloader.data(from: base.appendingPathComponent("SHASUMS256.txt")), as: UTF8.self), file: name) else {
            throw AndroidAnalyxerError.failed(String(localized: "nodejs.org lists no checksum for \(name)."))
        }
        let archive = try await fetch(base.appendingPathComponent(name), name: name, sha256: sha256, label: "Node.js \(version)", progress)
        progress(String(localized: "Extracting \("Node.js") …"), nil)
        try await replace(folder("node")!, extracting: archive)
    }

    /// npm runs through the selected Node binary with install scripts disabled and its cache inside the tools folder.
    func npm(_ arguments: [String], node: URL, in directory: URL, timeout: TimeInterval = 1800) async throws {
        let cli = node.deletingLastPathComponent().appendingPathComponent("npm").resolvingSymlinksInPath()
        guard cli.pathExtension == "js", fileManager.fileExists(atPath: cli.path) else { throw AndroidAnalyxerError.missingTool("npm") }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runner.run(Command(executable: node, arguments: [cli.path] + arguments, timeout: timeout, outputLimit: 16 * 1024 * 1024,
                                                  environment: nodeEnvironment(node), workingDirectory: directory))
        guard result.status == 0 else { throw AndroidAnalyxerError.failed("npm: " + String(decoding: (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(1500), as: UTF8.self)) }
    }

    func nodeEnvironment(_ node: URL) -> [String: String] {
        ["PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "npm_config_cache": (toolsFolder ?? sdkRoot).appendingPathComponent(".npm-cache").path,
         "npm_config_update_notifier": "false", "npm_config_fund": "false", "npm_config_audit": "false"]
    }

    func readyNode() async throws -> URL {
        let status = await checkNode()
        guard status.state == .ready, let node = status.location else { throw AndroidAnalyxerError.invalidInput(String(localized: "Install a suitable Node.js first.")) }
        return node
    }

    func installREA(_ progress: @escaping Progress) async throws {
        let node = try await readyNode(), target = folder("rea")!
        progress(String(localized: "Installing \("REA \(ToolRequirements.reaVersion)") with npm …"), nil)
        try await npm(["install", "--prefix", target.path, "--ignore-scripts", "--no-audit", "--no-fund", "rea-agents@\(ToolRequirements.reaVersion)"], node: node, in: target)
        // Only Frida's own installer runs: it fetches the native binding from Frida's GitHub releases.
        let frida = target.appendingPathComponent("node_modules/frida")
        if fileManager.fileExists(atPath: frida.appendingPathComponent("scripts/install.js").path) {
            progress(String(localized: "Fetching Frida's native component …"), nil)
            let result = try await runner.run(Command(executable: node, arguments: ["scripts/install.js"], timeout: 900, outputLimit: 8 * 1024 * 1024,
                                                      environment: nodeEnvironment(node), workingDirectory: frida))
            guard result.status == 0, fileManager.fileExists(atPath: frida.appendingPathComponent("build/frida_binding.node").path) else {
                throw AndroidAnalyxerError.failed(String(localized: "Frida's native component could not be installed.") + " " + String(decoding: result.stderr.suffix(800), as: UTF8.self))
            }
        }
    }

    func installJADX(_ progress: @escaping Progress) async throws {
        guard let expected = expectedJADX() else { throw AndroidAnalyxerError.invalidInput(String(localized: "Install REA first; it defines the JADX release.")) }
        let target = folder("jadx")!
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let file = try await fetch(expected.url, name: expected.url.lastPathComponent, sha256: expected.sha256, label: "JADX \(expected.version)", progress)
        let destination = target.appendingPathComponent(expected.url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: file, to: destination)
    }

    static let bridgeBuilder = """
    import fs from 'node:fs/promises';
    import path from 'node:path';
    import { pathToFileURL } from 'node:url';
    const [moduleFile, projectRoot] = process.argv.slice(2);
    const { default: frida } = await import(pathToFileURL(moduleFile).href);
    await fs.writeFile(path.join(projectRoot, 'java-bridge.js'), "import Java from 'frida-java-bridge';\\nglobalThis.Java = Java;\\n");
    const compiler = new frida.Compiler();
    const source = await compiler.build('java-bridge.js', { projectRoot, bundleFormat: 'iife', typeCheck: 'none', sourceMaps: frida.SourceMaps.Omitted });
    await fs.writeFile(path.join(projectRoot, 'java-bridge.bundle.js'), source);
    """

    func installBridge(_ progress: @escaping Progress) async throws {
        let node = try await readyNode()
        guard let (rea, _) = reaPackage() else { throw AndroidAnalyxerError.invalidInput(String(localized: "Install REA first; its Frida module builds the bridge.")) }
        let fridaModule = rea.deletingLastPathComponent().appendingPathComponent("frida/build/src/frida.js")
        guard fileManager.fileExists(atPath: fridaModule.path) else { throw AndroidAnalyxerError.missingTool("Frida (REA)") }
        let target = folder("frida-bridge")!
        progress(String(localized: "Installing \("frida-java-bridge \(ToolRequirements.fridaJavaBridge)") with npm …"), nil)
        try await npm(["install", "--prefix", target.path, "--ignore-scripts", "--no-audit", "--no-fund", "frida-java-bridge@\(ToolRequirements.fridaJavaBridge)"], node: node, in: target)
        progress(String(localized: "Building the Java bridge …"), nil)
        let builder = target.appendingPathComponent("build-java-bridge.mjs")
        try Self.bridgeBuilder.write(to: builder, atomically: true, encoding: .utf8)
        let result = try await runner.run(Command(executable: node, arguments: [builder.path, fridaModule.path, target.path], timeout: 600,
                                                  environment: nodeEnvironment(node), workingDirectory: target))
        guard result.status == 0, fileManager.fileExists(atPath: target.appendingPathComponent("java-bridge.bundle.js").path) else {
            throw AndroidAnalyxerError.failed(String(localized: "The Java bridge could not be built.") + " " + String(decoding: result.stderr.suffix(800), as: UTF8.self))
        }
    }

    func installFridaServer(_ progress: @escaping Progress) async throws {
        guard let version = fridaVersion() else { throw AndroidAnalyxerError.invalidInput(String(localized: "Install REA first; frida-server must match its Frida version.")) }
        let release = try await downloader.data(from: URL(string: "https://api.github.com/repos/frida/frida/releases/tags/\(version)")!)
        let target = folder("frida-server")!
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        for abi in arm ? ["arm64"] : ["x86_64", "arm64"] {
            let name = "frida-server-\(version)-android-\(abi).xz"
            guard let asset = Self.githubAsset(json: release, name: name) else { throw AndroidAnalyxerError.failed(String(localized: "Frida's release lists no \(name).")) }
            let file = try await fetch(asset.url, name: name, sha256: asset.sha256, label: "frida-server \(version) (\(abi))", progress)
            let data = try (Data(contentsOf: file) as NSData).decompressed(using: .lzma) as Data
            let output = fridaServerFile(version: version, abi: abi)!
            try data.write(to: output, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: Android SDK

    func sdkmanager(javaHome: URL) throws -> (URL, [String: String]) {
        guard let tool = SDKPaths(root: sdkRoot).sdkmanager else { throw AndroidAnalyxerError.missingTool("sdkmanager") }
        return (tool, ["JAVA_HOME": javaHome.path])
    }

    func readyJDK() async throws -> URL {
        let status = await checkJDK()
        guard status.state == .ready, let home = status.location else { throw AndroidAnalyxerError.invalidInput(String(localized: "Install a full JDK first; sdkmanager needs Java.")) }
        return home
    }

    func installCommandLineTools(_ progress: @escaping Progress) async throws {
        let xml = try await downloader.data(from: URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!)
        guard let archive = Self.commandLineTools(repositoryXML: xml, arm: arm) else { throw AndroidAnalyxerError.failed(String(localized: "Google's package list has no command-line tools for this Mac.")) }
        let zip = try await fetch(URL(string: "https://dl.google.com/android/repository/" + archive.url)!, name: archive.url, sha1: archive.sha1, label: "Android Command-line Tools \(archive.version)", progress)
        progress(String(localized: "Extracting \("Command-line Tools") …"), nil)
        let staging = sdkRoot.appendingPathComponent(".cmdline-tools-\(UUID().uuidString)", isDirectory: true)
        try await replace(staging, extracting: zip, zip: true)
        let latest = sdkRoot.appendingPathComponent("cmdline-tools/latest", isDirectory: true)
        try fileManager.createDirectory(at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: latest)
        try fileManager.moveItem(at: staging.appendingPathComponent("cmdline-tools"), to: latest)
        try? fileManager.removeItem(at: staging)
    }

    /// Licence texts sdkmanager would ask about; empty when all are accepted. Nothing is accepted here.
    public func androidLicenses(progress: @escaping Progress = { _, _ in }) async throws -> String {
        let javaHome = try await readyJDK()
        try fileManager.createDirectory(at: sdkRoot, withIntermediateDirectories: true)
        if SDKPaths(root: sdkRoot).sdkmanager == nil { try await installCommandLineTools(progress) }
        let (tool, environment) = try sdkmanager(javaHome: javaHome)
        let answers = Data(("y\n" + String(repeating: "n\n", count: 40)).utf8)
        let result = try await runner.run(Command(executable: tool, arguments: ["--sdk_root=\(sdkRoot.path)", "--licenses"], timeout: 300, outputLimit: 8 * 1024 * 1024,
                                                  environment: environment, input: answers))
        return Self.licenseText(result.text)
    }

    /// Accepts the Android SDK licences. Only call after the user has read and accepted them.
    public func acceptAndroidLicenses() async throws {
        let javaHome = try await readyJDK()
        let (tool, environment) = try sdkmanager(javaHome: javaHome)
        let result = try await runner.run(Command(executable: tool, arguments: ["--sdk_root=\(sdkRoot.path)", "--licenses"], timeout: 300,
                                                  environment: environment, input: Data(String(repeating: "y\n", count: 41).utf8)))
        guard result.text.contains("accepted") else { throw AndroidAnalyxerError.failed(String(localized: "sdkmanager did not confirm the licences.")) }
    }

    func installAndroidSDK(includePlayImage: Bool, _ progress: @escaping Progress) async throws {
        guard try await androidLicenses(progress: progress).isEmpty else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "Accept the Android SDK licences first."))
        }
        let javaHome = try await readyJDK()
        let (tool, environment) = try sdkmanager(javaHome: javaHome)
        let packages = ToolRequirements.androidPackages + (includePlayImage ? [ToolRequirements.playImage(arm: arm)] : [])
        progress(String(localized: "Installing Android SDK packages; this can take a while …"), nil)
        let result = try await runner.run(Command(executable: tool, arguments: ["--sdk_root=\(sdkRoot.path)", "--install"] + packages, timeout: 7200,
                                                  outputLimit: 16 * 1024 * 1024, environment: environment, input: Data()))
        guard result.status == 0 else { throw AndroidAnalyxerError.failed("sdkmanager: " + String(decoding: (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(1500), as: UTF8.self)) }
    }

    // MARK: Helpers and parsers

    func children(of directory: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
    }

    static func sha1(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func javaVersion(release: String) -> String? {
        release.split(whereSeparator: \.isNewline).first { $0.hasPrefix("JAVA_VERSION=") }
            .map { String($0.dropFirst("JAVA_VERSION=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    static func engines(packageJSON: [String: Any]) -> String? { (packageJSON["engines"] as? [String: Any])?["node"] as? String }

    static func jadxRelease(source: String) -> (version: String, url: URL, sha256: String)? {
        func value(_ key: String) -> String? {
            guard let range = source.range(of: key + #":\s*"([^"]+)""#, options: .regularExpression) else { return nil }
            return source[range].split(separator: "\"").dropFirst().first.map(String.init)
        }
        guard let version = value("version"), let link = value("url"), let url = URL(string: link), url.scheme == "https",
              let sha256 = value("sha256"), sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        return (version, url, sha256)
    }

    static func shasum(_ text: String, file: String) -> String? {
        text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return fields.count == 2 && fields[1] == file && fields[0].count == 64 ? String(fields[0]) : nil
        }.first
    }

    static func adoptiumAsset(json: Data) -> (release: String, name: String, url: URL, sha256: String)? {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]], let first = list.first,
              let package = (first["binary"] as? [String: Any])?["package"] as? [String: Any],
              let link = package["link"] as? String, let url = URL(string: link), url.scheme == "https",
              let name = package["name"] as? String, let checksum = package["checksum"] as? String else { return nil }
        return (first["release_name"] as? String ?? name, name, url, checksum)
    }

    static func githubAsset(json: Data, name: String) -> (url: URL, sha256: String)? {
        guard let release = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let assets = release["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == name }),
              let link = asset["browser_download_url"] as? String, let url = URL(string: link), url.scheme == "https",
              let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { return nil }
        return (url, String(digest.dropFirst(7)))
    }

    static func commandLineTools(repositoryXML: Data, arm: Bool) -> (version: String, url: String, sha1: String)? {
        let reader = RepositoryReader()
        let parser = XMLParser(data: repositoryXML)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.archives.first { $0.os == "macosx" && ($0.arch == nil || $0.arch == (arm ? "aarch64" : "x64")) }.map { ($0.version, $0.url, $0.sha1) }
    }

    static func licenseText(_ output: String) -> String {
        guard !output.contains("All SDK package licenses accepted") else { return "" }
        let lines = output.components(separatedBy: .newlines).filter { line in
            !line.contains("Accept? (y/N)") && !line.contains("Review licenses that have not been accepted") && !line.hasPrefix("[") && !line.contains("Loading")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads `cmdline-tools;latest` archives from Google's repository2 XML.
private final class RepositoryReader: NSObject, XMLParserDelegate {
    struct Archive { var version = "", os: String?, arch: String?, url = "", sha1 = "" }
    var archives: [Archive] = []
    private var inPackage = false, current: Archive?, revision: [String] = [], text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "remotePackage" { inPackage = attributes["path"] == "cmdline-tools;latest"; revision = [] }
        if inPackage, name == "archive" { current = Archive(version: revision.joined(separator: ".")) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inPackage else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "major", "minor", "micro": if current == nil { revision.append(value) }
        case "host-os": current?.os = value
        case "host-arch": current?.arch = value
        case "url": current?.url = value
        case "checksum": current?.sha1 = value
        case "archive": if let archive = current { archives.append(archive) }; current = nil
        case "remotePackage": inPackage = false
        default: break
        }
    }
}
