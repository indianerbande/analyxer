import XCTest
@testable import AnalyxerCore

private struct FakeDownloader: FileDownloading {
    let files: [String: Data]
    func data(from url: URL) async throws -> Data {
        guard let data = files[url.absoluteString] else { throw AnalyxerError.failed("no fixture for \(url)") }
        return data
    }
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let data = try await self.data(from: url)
        progress(Int64(data.count), Int64(data.count))
        try data.write(to: destination)
    }
}

private actor VersionRunner: CommandRunning {
    let versions: [String: String]
    /// Keys are compared as real paths: temporary folders appear both as /var/… and /private/var/….
    init(_ versions: [String: String]) { self.versions = Dictionary(uniqueKeysWithValues: versions.map { (VersionRunner.real($0.key), $0.value) }) }
    static func real(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    func launch(_ command: Command) async throws {}
    func run(_ command: Command) async throws -> CommandResult {
        if command.arguments == ["--version"], let version = versions[VersionRunner.real(command.executable.path)] { return CommandResult(stdout: Data(version.utf8)) }
        return CommandResult(status: 1)
    }
}

final class ToolSetupTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String, _ text: String = "", executable: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func testVersionRangesFollowREAEngines() throws {
        let range = ToolRequirements.reaNodeRange
        for (version, ok) in [("v24.22.2", true), ("24.22.1", true), ("v24.15.0", false), ("v26.4.0", false), ("26.12.1", true), ("27.0.0", true),
                              ("22.23.4", true), ("22.22.0", false), ("23.5.0", false)] {
            XCTAssertEqual(try XCTUnwrap(SemanticVersion(version)).satisfies(range), ok, version)
        }
        XCTAssertTrue(try XCTUnwrap(SemanticVersion("1.5")).satisfies(">=1.2.0 <2.0.0"))
        XCTAssertFalse(try XCTUnwrap(SemanticVersion("2.0.0")).satisfies(">=1.2.0 <2.0.0"))
        XCTAssertEqual(SemanticVersion("25.0.5+8")?.description, "25.0.5")
        XCTAssertNil(SemanticVersion("latest"))
    }

    func testParsersReadTheOfficialFormats() throws {
        let jadx = """
        export const JADX_RELEASE = Object.freeze({
            version: "0.7.1",
            revision: "5844800a486d2248fa949b74c9896285f5b54de2",
            sha256: "6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75",
            url: "https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar",
        });
        """
        let release = try XCTUnwrap(ToolSetupService.jadxRelease(source: jadx))
        XCTAssertEqual(release.version, "0.7.1"); XCTAssertEqual(release.url.lastPathComponent, "jadx-headless-mcp-0.7.1-all.jar")
        XCTAssertNil(ToolSetupService.jadxRelease(source: jadx.replacingOccurrences(of: "https://", with: "http://")))
        XCTAssertNil(ToolSetupService.jadxRelease(source: jadx.replacingOccurrences(of: "6e5eacf5", with: "XYZ")))

        let sums = "abc  other.tar.gz\n" + String(repeating: "a", count: 64) + "  node-v24.22.2-darwin-arm64.tar.gz\n"
        XCTAssertEqual(ToolSetupService.shasum(sums, file: "node-v24.22.2-darwin-arm64.tar.gz"), String(repeating: "a", count: 64))
        XCTAssertNil(ToolSetupService.shasum(sums, file: "node-v24.22.2-darwin-x64.tar.gz"))

        let adoptium = #"[{"release_name":"jdk-25.0.5+8","binary":{"package":{"name":"OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5_8.tar.gz","link":"https://github.com/adoptium/x.tar.gz","checksum":"36dc"}}}]"#
        let asset = try XCTUnwrap(ToolSetupService.adoptiumAsset(json: Data(adoptium.utf8)))
        XCTAssertEqual(asset.release, "jdk-25.0.5+8"); XCTAssertEqual(asset.sha256, "36dc")

        let github = #"{"assets":[{"name":"frida-server-17.23.2-android-arm64.xz","browser_download_url":"https://github.com/f.xz","digest":"sha256:6ec5"},{"name":"other","browser_download_url":"https://x","digest":"sha256:00"}]}"#
        XCTAssertEqual(ToolSetupService.githubAsset(json: Data(github.utf8), name: "frida-server-17.23.2-android-arm64.xz")?.sha256, "6ec5")
        XCTAssertNil(ToolSetupService.githubAsset(json: Data(github.utf8), name: "missing.xz"))

        let xml = """
        <?xml version="1.0"?><sdk:repository xmlns:sdk="x">
        <remotePackage path="platform-tools"><revision><major>37</major></revision><archives><archive><complete><size>1</size><checksum>aa</checksum><url>pt.zip</url></complete><host-os>macosx</host-os></archive></archives></remotePackage>
        <remotePackage path="cmdline-tools;latest"><revision><major>23</major><minor>0</minor></revision><archives>
        <archive><complete><size>1</size><checksum>bb</checksum><url>commandlinetools-mac_x86_64-1_latest.zip</url></complete><host-os>macosx</host-os><host-arch>x64</host-arch></archive>
        <archive><complete><size>1</size><checksum>cc</checksum><url>commandlinetools-mac_arm64-1_latest.zip</url></complete><host-os>macosx</host-os><host-arch>aarch64</host-arch></archive>
        <archive><complete><size>1</size><checksum>dd</checksum><url>commandlinetools-linux-1_latest.zip</url></complete><host-os>linux</host-os></archive>
        </archives></remotePackage></sdk:repository>
        """
        let arm = try XCTUnwrap(ToolSetupService.commandLineTools(repositoryXML: Data(xml.utf8), arm: true))
        XCTAssertEqual(arm.url, "commandlinetools-mac_arm64-1_latest.zip"); XCTAssertEqual(arm.sha1, "cc"); XCTAssertEqual(arm.version, "23.0")
        XCTAssertEqual(ToolSetupService.commandLineTools(repositoryXML: Data(xml.utf8), arm: false)?.sha1, "bb")

        XCTAssertEqual(ToolSetupService.licenseText("[=====] 100%\nAll SDK package licenses accepted.\n"), "")
        let pending = ToolSetupService.licenseText("1 of 7 SDK package licenses not accepted.\nReview licenses that have not been accepted (y/N)? \nLicense android-sdk-license:\nTerms and Conditions\nAccept? (y/N): ")
        XCTAssertTrue(pending.contains("License android-sdk-license:")); XCTAssertFalse(pending.contains("Accept?"))

        XCTAssertEqual(ToolSetupService.javaVersion(release: "IMPLEMENTOR=\"Azul\"\nJAVA_VERSION=\"25.0.1\"\n"), "25.0.1")
    }

    func testCheckFindsAManagedToolsFolder() async throws {
        let tools = root.appendingPathComponent("tools")
        let node = try file("tools/node/node-v24.22.2-darwin-arm64/bin/node", executable: true)
        try file("tools/rea/node_modules/rea-agents/package.json", #"{"name":"rea-agents","version":"6.8.0","engines":{"node":"^24.22.1"}}"#)
        try file("tools/rea/node_modules/rea-agents/scripts/rea.mjs")
        try file("tools/rea/node_modules/frida/package.json", #"{"name":"frida","version":"17.23.2"}"#)
        try file("tools/rea/node_modules/frida/build/frida_binding.node")
        let jar = try file("tools/jadx/jadx-headless-mcp-0.7.1-all.jar", "jar bytes")
        try file("tools/rea/node_modules/rea-agents/dist/android/JadxRelease.js",
                 "version: \"0.7.1\", sha256: \"\(try ArtifactHash.sha256(jar))\", url: \"https://github.com/x/jadx-headless-mcp-0.7.1-all.jar\",")
        try file("tools/frida-bridge/java-bridge.bundle.js")
        try file("tools/frida-server/frida-server-17.23.2-android-arm64")
        try file("tools/jdk/jdk-25.0.5+8/Contents/Home/release", "JAVA_VERSION=\"25.0.5\"\n")
        try file("tools/jdk/jdk-25.0.5+8/Contents/Home/bin/java", executable: true)
        try file("tools/jdk/jdk-25.0.5+8/Contents/Home/bin/javac", executable: true)
        let setup = ToolSetupService(toolsFolder: tools, sdkRoot: root.appendingPathComponent("sdk"), runner: VersionRunner([node.path: "v24.22.2\n"]),
                                     downloader: FakeDownloader(files: [:]), arm: true)
        let statuses = await setup.check()
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        for tool in [ToolID.jdk, .node, .rea, .jadx, .fridaBridge, .fridaServer] { XCTAssertEqual(byID[tool]?.state, .ready, tool.rawValue) }
        XCTAssertEqual(byID[.jdk]?.version, "25.0.5"); XCTAssertEqual(byID[.rea]?.version, "6.8.0"); XCTAssertEqual(byID[.fridaServer]?.version, "17.23.2")
        XCTAssertEqual(byID[.androidSDK]?.state, .missing)
        let profile = setup.resolvedProfile(from: statuses)
        XCTAssertEqual(VersionRunner.real(profile.executable), VersionRunner.real(node.path))
        XCTAssertTrue(profile.cliScript.hasSuffix("rea-agents/scripts/rea.mjs")); XCTAssertEqual(VersionRunner.real(profile.jadxJAR), VersionRunner.real(jar.path))
        XCTAssertTrue(profile.javaHome.hasSuffix("Contents/Home")); XCTAssertTrue(profile.javaBridge.hasSuffix("java-bridge.bundle.js"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("tools/rea/node_modules/frida/build/frida_binding.node"))
        let withoutBinding = await setup.check().first { $0.id == .rea }
        XCTAssertEqual(withoutBinding?.state, .problem)
    }

    func testOldNodeAndMissingFolderAreReported() async throws {
        let node = try file("tools/node/node-v24.15.0-darwin-arm64/bin/node", executable: true)
        let setup = ToolSetupService(toolsFolder: root.appendingPathComponent("tools"), sdkRoot: root, runner: VersionRunner([node.path: "v24.15.0"]),
                                     downloader: FakeDownloader(files: [:]), arm: true)
        let status = await setup.checkNode()
        XCTAssertEqual(status.state, .outdated); XCTAssertEqual(status.version, "24.15.0")
        do { try await ToolSetupService(toolsFolder: nil, sdkRoot: root).install(.node); XCTFail("needs a tools folder") }
        catch AnalyxerError.invalidInput {}
    }

    func testJADXDownloadIsVerifiedAgainstREA() async throws {
        let tools = root.appendingPathComponent("tools")
        try file("tools/rea/node_modules/rea-agents/package.json", #"{"name":"rea-agents","version":"6.8.0"}"#)
        let good = Data("the real jar".utf8), url = "https://github.com/x/jadx-headless-mcp-0.7.1-all.jar"
        try file("tools/rea/node_modules/rea-agents/dist/android/JadxRelease.js",
                 "version: \"0.7.1\", sha256: \"\(ArtifactHash.sha256(data: good))\", url: \"\(url)\",")
        let ok = ToolSetupService(toolsFolder: tools, sdkRoot: root, downloader: FakeDownloader(files: [url: good]), arm: true)
        try await ok.install(.jadx)
        XCTAssertEqual(try Data(contentsOf: tools.appendingPathComponent("jadx/jadx-headless-mcp-0.7.1-all.jar")), good)
        XCTAssertEqual(ok.checkJADX().state, .ready)

        try FileManager.default.removeItem(at: tools.appendingPathComponent("jadx"))
        let tampered = ToolSetupService(toolsFolder: tools, sdkRoot: root, downloader: FakeDownloader(files: [url: Data("tampered".utf8)]), arm: true)
        do { try await tampered.install(.jadx); XCTFail("checksum mismatch must fail") } catch AnalyxerError.failed {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.appendingPathComponent("jadx/jadx-headless-mcp-0.7.1-all.jar").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.appendingPathComponent(".downloads/jadx-headless-mcp-0.7.1-all.jar").path))
    }

    func testRunnerPassesInputAndWorkingDirectory() async throws {
        let runner = ProcessCommandRunner()
        let echoed = try await runner.run(Command(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data("y\ny\n".utf8)))
        XCTAssertEqual(echoed.text, "y\ny\n")
        let directory = try await runner.run(Command(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], workingDirectory: root))
        XCTAssertEqual(VersionRunner.real(directory.text.trimmingCharacters(in: .whitespacesAndNewlines)), VersionRunner.real(root.path))
    }
}
