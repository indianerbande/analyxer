import XCTest
@testable import AnalyxerCore

private actor DeepWorkflowRunner: CommandRunning {
    var wrongSubject = false
    var reaPaths: [String] = []
    func rejectSubject() { wrongSubject = true }
    func selectedPaths() -> [String] { reaPaths }
    func launch(_ command: Command) async throws { throw AnalyxerError.failed("Unexpected launch") }
    func run(_ command: Command) async throws -> CommandResult {
        let args = command.arguments
        if let index = args.firstIndex(of: "inspect-android-method") {
            let path = args[index + 1]
            reaPaths.append(path)
            let digest = wrongSubject ? String(repeating: "0", count: 64) : try ArtifactHash.sha256(URL(fileURLWithPath: path))
            let evidence: [String: Any] = [
                "evidence_id": "ev_workflow_fixture", "operation": "inspect_android_method",
                "subject": ["digest": ["sha256": digest]],
                "limitations": ["Static fixture observations only"],
                "normalized_result": ["source": ["text": "String request() {\n  return \"synthetic\";\n}"]]
            ]
            return CommandResult(stdout: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
        }
        let text: String
        switch Array(args.prefix(2)) {
        case ["dump", "badging"]: text = "package: name='lab.fixture' versionCode='1'"
        case ["dump", "permissions"]: text = "uses-permission: name='android.permission.INTERNET'"
        case ["manifest", "print"]: text = "<manifest package='lab.fixture'><application/></manifest>"
        case ["dex", "packages"]: text = "C d 1 1 23 lab.fixture.App"
        default:
            guard args == ["version"] else { throw AnalyxerError.failed("Unexpected fake command: \(args)") }
            text = "fixture tool 1"
        }
        return CommandResult(stdout: Data(text.utf8))
    }
}

final class DeepAnalysisWorkflowTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var runner: DeepWorkflowRunner!
    private var service: EmulatorService!
    private var rea: REAService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        for path in ["sdk/build-tools/37.0.0/aapt2", "sdk/cmdline-tools/latest/bin/apkanalyzer", "rea"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        source = root.appendingPathComponent("input.apk")
        try Data("synthetic original APK".utf8).write(to: source)
        runner = DeepWorkflowRunner()
        service = EmulatorService(paths: SDKPaths(root: root.appendingPathComponent("sdk")), runner: runner)
        rea = REAService(configuration: REAConfiguration(executable: root.appendingPathComponent("rea")), runner: runner)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func project() async throws -> ProjectStore {
        try await ProjectStore.create(at: root.appendingPathComponent("Test.androidlab"), apk: source, service: service)
    }

    func testREAUsesProjectCopyAndSchemaTwoEvidenceSurvivesPortableExport() async throws {
        let store = try await project()
        let initial = await store.snapshot()
        XCTAssertEqual(initial.schemaVersion, 1)
        try Data("source was later replaced".utf8).write(to: source)
        let entry = try await ProjectWorkflow(store: store, service: service).analyzeCode(using: rea,
            query: .method(className: "lab.fixture.App", methodName: "request", overload: 0))
        let bytes = try await store.evidenceData(id: entry.id)
        let paths = await runner.selectedPaths()
        XCTAssertEqual(paths, [store.directory.appendingPathComponent(initial.apkPath).path])
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let subject = try XCTUnwrap(record["subject"] as? [String: Any])
        XCTAssertEqual((subject["digest"] as? [String: String])?["sha256"], initial.analysis.apk.sha256)
        let export = root.appendingPathComponent("Export.androidlab")
        try await store.export(to: export)
        let reopened = try await ProjectStore.open(at: export)
        let value = await reopened.snapshot()
        let roundtrip = try await reopened.evidenceData(id: entry.id)
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertEqual(roundtrip, bytes)
        XCTAssertEqual(value.evidence.last?.kind, .rea)
        XCTAssertNil(value.evidence.last?.sessionID)
        XCTAssertTrue(value.evidence.last?.relativePath.hasSuffix(".json") == true)
    }

    func testMismatchedREASubjectIsRetainedAsFailureInsteadOfSuccessfulEvidence() async throws {
        let store = try await project()
        await runner.rejectSubject()
        do {
            _ = try await ProjectWorkflow(store: store, service: service).analyzeCode(using: rea,
                query: .method(className: "lab.fixture.App", methodName: "request", overload: nil))
            XCTFail("Mismatched subject accepted")
        } catch {}
        let value = await store.snapshot()
        XCTAssertFalse(value.evidence.contains { $0.kind == .rea })
        let failure = try XCTUnwrap(value.evidence.last)
        XCTAssertEqual(failure.kind, .failure)
        let data = try await store.evidenceData(id: failure.id)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ev_workflow_fixture"))
    }

    func testImportedPCAPRetainsUnverifiedProvenanceAndRejectsEndedSession() async throws {
        let store = try await project()
        let session = try await store.startSession(device: DeviceObservation(observedAt: Date(), serial: "emulator-5554",
            avdName: "Fixture", properties: ["boot_id": UUID().uuidString], adbVersion: "fixture"))
        let pcap = Data([0xd4,0xc3,0xb2,0xa1, 2,0,4,0, 0,0,0,0, 0,0,0,0, 0xff,0xff,0,0, 1,0,0,0])
        let input = root.appendingPathComponent("external.pcap")
        try pcap.write(to: input)
        let flow = ProjectWorkflow(store: store, service: service)
        try await flow.importTraffic(sessionID: session.id, file: input)
        let value = await store.snapshot()
        XCTAssertEqual(value.schemaVersion, 2)
        let capture = try XCTUnwrap(value.evidence.first { $0.kind == .networkCapture })
        let report = try XCTUnwrap(value.evidence.first { $0.kind == .networkReport })
        let captured = try await store.evidenceData(id: capture.id)
        let text = String(decoding: try await store.evidenceData(id: report.id), as: UTF8.self)
        XCTAssertEqual(captured, pcap)
        XCTAssertEqual(capture.sessionID, session.id)
        XCTAssertEqual(report.sessionID, session.id)
        XCTAssertTrue(text.contains("not verified"))
        XCTAssertTrue(text.contains("capture device, capture time and app attribution not verified"))
        XCTAssertTrue(text.contains(capture.sha256))
        try await store.endSession(session.id)
        do { try await flow.importTraffic(sessionID: session.id, file: input); XCTFail("Closed session accepted import") } catch {}
        let after = await store.snapshot()
        XCTAssertEqual(after.evidence.count, value.evidence.count)
    }

    func testPresentationUnwrapsRuntimeEvidencePreservesSourceAndCleanupFailure() throws {
        let source = "String request() {\n  return \"synthetic\";\n}"
        let data = try JSONSerialization.data(withJSONObject: [
            "cleanup_error": ["message": "detach incomplete"],
            "evidence": ["evidence_id": "ev_runtime", "operation": "instrument_with_frida",
                "limitations": ["Main process only"], "normalized_result": ["source": source],
                "raw_result": "RAW DUPLICATE MUST NOT APPEAR", "parameters": ["script": "LARGE BRIDGE MUST NOT APPEAR"]]
        ])
        let text = REAPresentation.text(data)
        XCTAssertTrue(text.contains("ev_runtime"))
        XCTAssertTrue(text.contains(source))
        XCTAssertTrue(text.contains("Main process only"))
        XCTAssertTrue(text.contains("detach incomplete"))
        XCTAssertFalse(text.contains("RAW DUPLICATE"))
        XCTAssertFalse(text.contains("LARGE BRIDGE"))
    }

    func testToolProfilesRejectOversizedFilesAndRelativeExecutablePaths() throws {
        let file = root.appendingPathComponent("tools.json")
        try Data(repeating: 32, count: 64 * 1024).write(to: file)
        XCTAssertThrowsError(try AnalysisTools.load(file))
        var profile = AnalysisTools()
        profile.executable = "relative/node"
        try JSONEncoder().encode(profile).write(to: file)
        let loaded = try AnalysisTools.load(file)
        XCTAssertThrowsError(try loaded.configuration())
        profile.executable = root.appendingPathComponent("rea").path
        try JSONEncoder().encode(profile).write(to: file)
        XCTAssertEqual(try AnalysisTools.load(file).configuration().executable.path, profile.executable)
    }
}
