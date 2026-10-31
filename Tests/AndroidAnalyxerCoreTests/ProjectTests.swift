import XCTest
@testable import AndroidAnalyxerCore

private let testXML = """
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="lab.androidanalyxer.fixture" android:versionName="1.0">
<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="34"/>
<uses-permission android:name="android.permission.INTERNET"/>
<queries><intent><action android:name="not.a.component"/></intent></queries>
<application android:debuggable="true" android:permission="lab.GUARD">
<activity android:name=".MainActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity>
<service android:name="SyncService" android:exported="false"/>
<receiver android:name="lab.Receiver"/>
<provider android:name=".DataProvider" android:exported="false" android:permission="lab.DATA"/>
</application></manifest>
"""

private actor ProjectRunner: CommandRunning {
    var commands: [[String]] = []
    var boot = "8f043d56-c349-46e4-813d-22bb74ffbaf6"
    var installOutput = "Success\n"
    func changeBoot() { boot = UUID().uuidString }
    func recorded() -> [[String]] { commands }
    func setInstall(_ value: String) { installOutput = value }
    func launch(_ command: Command) async throws {}
    func run(_ command: Command) async throws -> CommandResult {
        let a = command.arguments
        commands.append(a)
        let output: String
        switch Array(a.prefix(2)) {
        case ["dump", "badging"]: output = "package: name='lab.androidanalyxer.fixture' versionCode='1'"
        case ["dump", "permissions"]: output = "uses-permission: name='android.permission.INTERNET'"
        case ["manifest", "print"]: output = testXML
        case ["dex", "packages"]: output = "C d 1 1 23 lab.androidanalyxer.fixture.MainActivity"
        case ["devices", "-l"]: output = "List of devices attached\nemulator-5554 device model:Test_Device\n"
        default:
            if a == ["version"] { return CommandResult(stderr: Data("test tool 1".utf8)) }
            else if a.suffix(3) == ["emu", "avd", "name"] { output = "Test_AVD\nOK\n" }
            else if a.contains("/proc/sys/kernel/random/boot_id") { output = boot }
            else if a.contains("getprop") { output = a.last == "sys.boot_completed" ? "1" : "test" }
            else if a.contains("install") { output = installOutput }
            else if a.contains("resolve-activity") { output = "lab.androidanalyxer.fixture/.MainActivity" }
            else if a.contains("am") { output = "Status: ok\nComplete" }
            else if a.contains("pidof") { output = "1234\n" }
            else if a.contains("logcat") { output = "AndroidAnalyxerFixture: onCreate" }
            else if a.contains("screencap") { return CommandResult(stdout: Data([137,80,78,71,13,10,26,10])) }
            else if a.contains("keyevent") { output = "" }
            else { throw AndroidAnalyxerError.failed("Unexpected: \(a)") }
        }
        return CommandResult(stdout: Data(output.utf8))
    }
}

final class ProjectTests: XCTestCase {
    var root: URL!
    var source: URL!
    private var runner: ProjectRunner!
    var service: EmulatorService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["sdk/platform-tools/adb", "sdk/emulator/emulator", "sdk/build-tools/37.0.0/aapt2", "sdk/cmdline-tools/latest/bin/apkanalyzer"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        source = root.appendingPathComponent("original with spaces.apk")
        try Data("abc".utf8).write(to: source)
        runner = ProjectRunner()
        service = EmulatorService(paths: SDKPaths(root: root.appendingPathComponent("sdk")), runner: runner)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func create(_ name: String = "Test.androidlab") async throws -> ProjectStore {
        try await ProjectStore.create(at: root.appendingPathComponent(name), apk: source, service: service)
    }
    func testManifestComponentsAndNamespaceAreParsedWithoutInferringExported() throws {
        let manifest = try ManifestSummary.parse(testXML.replacingOccurrences(of: "android:", with: "a:").replacingOccurrences(of: "xmlns:android", with: "xmlns:a"))
        XCTAssertEqual(manifest.components.count, 4)
        XCTAssertEqual(manifest.components[0].name, "lab.androidanalyxer.fixture.MainActivity")
        XCTAssertEqual(manifest.components[0].actions, ["android.intent.action.MAIN"])
        XCTAssertEqual(manifest.components[1].name, "lab.androidanalyxer.fixture.SyncService")
        XCTAssertEqual(manifest.components[1].exported, "false")
        XCTAssertNil(manifest.components[2].exported)
        XCTAssertEqual(manifest.components[0].permission, "lab.GUARD")
        XCTAssertEqual(manifest.components[3].permission, "lab.DATA")
    }
    func testMalformedAndEntityManifestsFailClosed() {
        for xml in ["<manifest>", "<other/>", "<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><manifest package='lab.example'/>"] {
            XCTAssertThrowsError(try ManifestSummary.parse(xml))
        }
    }
    func testProjectRetainsOwnAPKAndNotesAcrossOpenAndPortableExport() async throws {
        let store = try await create()
        try Data("changed source".utf8).write(to: source)
        try await store.addNote("Beobachtung: äöü und neue Zeile\nZweite Zeile")
        let destination = root.appendingPathComponent("export.androidlab")
        try await store.export(to: destination)
        let reopened = try await ProjectStore.open(at: destination)
        let saved = await reopened.snapshot()
        XCTAssertEqual(saved.analysis.manifest.components.count, 4)
        XCTAssertEqual(saved.analysis.tools["aapt2"], "test tool 1")
        XCTAssertEqual(saved.analysis.apk.sha256, ArtifactHash.sha256(data: Data("abc".utf8)))
        XCTAssertEqual(saved.evidence.count, 4)
        let note = try XCTUnwrap(saved.evidence.first { $0.kind == .note })
        let url = try await reopened.evidenceURL(id: note.id)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("äöü"))
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("report.txt"), encoding: .utf8).contains("Zweite Zeile"))
        let noteData = try await reopened.evidenceData(id: note.id)
        XCTAssertTrue(String(decoding: noteData, as: UTF8.self).contains("äöü"))
    }
    func testMutatedProjectAPKIsRejected() async throws {
        let store = try await create()
        let value = await store.snapshot()
        try Data("tampered".utf8).write(to: store.directory.appendingPathComponent(value.apkPath))
        do { _ = try await ProjectStore.open(at: store.directory); XCTFail("Modified APK accepted") } catch {}
    }
    func testTamperedEvidenceCannotBeExported() async throws {
        let store = try await create()
        let entry = await store.snapshot().evidence[0]
        try Data("modified report".utf8).write(to: store.directory.appendingPathComponent(entry.relativePath))
        do { _ = try await store.evidenceData(id: entry.id); XCTFail("Tampered preview accepted") } catch {}
        let destination = root.appendingPathComponent("export")
        do { try await store.export(to: destination); XCTFail("Tampered export accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testStaleWriterCannotOverwriteNewEvidence() async throws {
        let first = try await create()
        let stale = try await ProjectStore.open(at: first.directory)
        try await first.addNote("first writer")
        do { try await stale.addNote("stale writer"); XCTFail("Stale save accepted") } catch {}
        let reopened = try await ProjectStore.open(at: first.directory)
        let value = await reopened.snapshot()
        XCTAssertEqual(value.evidence.filter { $0.kind == .note }.map(\.summary), ["first writer"])
    }
    func testPathTraversalAndFutureSchemaAreRejected() async throws {
        let store = try await create()
        let url = store.directory.appendingPathComponent("project.json")
        let original = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["apkPath"] = "../original with spaces.apk"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        do { _ = try await ProjectStore.open(at: store.directory); XCTFail("Traversal accepted") } catch {}
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any]); json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        do { _ = try await ProjectStore.open(at: store.directory); XCTFail("Future schema accepted") } catch {}
    }
    func testSymlinkEvidenceIsRejected() async throws {
        let store = try await create()
        let entry = await store.snapshot().evidence[0]
        let file = store.directory.appendingPathComponent(entry.relativePath)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        do { _ = try await ProjectStore.open(at: store.directory); XCTFail("Symlink accepted") } catch {}
    }
    func testWorkflowRecordsActionsAndRejectsReusedSerialAfterReboot() async throws {
        let store = try await create()
        let flow = ProjectWorkflow(store: store, service: service)
        let session = try await flow.begin(serial: "emulator-5554")
        try await flow.install(sessionID: session.id)
        try await flow.launch(sessionID: session.id)
        try await flow.captureLogs(sessionID: session.id)
        try await flow.captureScreenshot(sessionID: session.id)
        let commands = await runner.recorded()
        XCTAssertTrue(commands.contains { $0.contains("--pid=1234") })
        await runner.changeBoot()
        do { try await flow.launch(sessionID: session.id); XCTFail("Reused serial accepted") } catch {}
        let project = await store.snapshot()
        XCTAssertEqual(project.evidence.last?.kind, .failure)
        let launches = await runner.recorded().filter { $0.contains("am") }
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(project.evidence.filter { $0.kind == .logcat || $0.kind == .screenshot }.allSatisfy { $0.sessionID == session.id })
    }
    func testFailedInstallDoesNotPermitLaunch() async throws {
        let store = try await create()
        let flow = ProjectWorkflow(store: store, service: service)
        let session = try await flow.begin(serial: "emulator-5554")
        await runner.setInstall("Failure [INSTALL_FAILED_INVALID_APK]")
        do { try await flow.install(sessionID: session.id); XCTFail("Install failure accepted") } catch {}
        do { try await flow.launch(sessionID: session.id); XCTFail("Launch without installation accepted") } catch {}
        let value = await store.snapshot()
        XCTAssertFalse(value.evidence.contains { $0.kind == .installation })
        XCTAssertEqual(value.evidence.filter { $0.kind == .failure }.count, 2)
    }
    func testCreationNeverOverwritesAnExistingFolder() async throws {
        let store = try await create()
        let before = try Data(contentsOf: store.directory.appendingPathComponent("project.json"))
        do { _ = try await create(); XCTFail("Existing project overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("project.json")), before)
    }
}
