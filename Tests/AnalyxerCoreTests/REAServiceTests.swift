import XCTest
@testable import AnalyxerCore

private actor REAFakeRunner: CommandRunning {
    var commands: [Command] = []
    var result: CommandResult
    init(_ result: CommandResult) { self.result = result }
    func run(_ command: Command) async throws -> CommandResult { commands.append(command); return result }
    func launch(_ command: Command) async throws { commands.append(command) }
    func recorded() -> [Command] { commands }
}

final class REAServiceTests: XCTestCase {
    private var root: URL!
    private var apk: URL { root.appendingPathComponent("fixture with spaces.apk") }
    private var configuration: REAConfiguration { REAConfiguration(executable: root.appendingPathComponent("node"), cliScript: root.appendingPathComponent("rea.mjs"), jadxJAR: root.appendingPathComponent("jadx.jar")) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["node", "rea.mjs", "jadx.jar", apk.lastPathComponent] {
            let file = root.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func evidence(operation: String, digest: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["evidence_id": "ev_example", "operation": operation,
            "subject": ["digest": ["sha256": digest ?? ArtifactHash.sha256(apk)]],
            "limitations": ["Static observations only"], "normalized_result": ["method": "raw source"]])
    }

    func testMethodUsesAdvertisedLiteralArgumentsAndRetainsEvidence() async throws {
        let data = try evidence(operation: "inspect_android_method")
        let runner = REAFakeRunner(CommandResult(stdout: data, stderr: Data("diagnostic".utf8)))
        let result = try await REAService(configuration: configuration, runner: runner)
            .inspectMethod(apk: apk, className: "a.Outer$Inner", methodName: "<init>", overloadIndex: 2)
        XCTAssertEqual(result.evidenceJSON, data)
        XCTAssertEqual(result.diagnostics, "diagnostic")
        let commands = await runner.recorded()
        XCTAssertEqual(commands[0].executable.path, "/usr/bin/env")
        XCTAssertEqual(commands[0].arguments, ["REA_JADX_HEAP_MIB=1024", "REA_JADX_MCP_JAR=\(root.path)/jadx.jar", "\(root.path)/node", "\(root.path)/rea.mjs",
            "inspect-android-method", apk.path, "a.Outer$Inner", "<init>", "--overload-index", "2", "--format", "json"])
    }

    func testStructuredProviderErrorWithZeroExitIsNotSuccess() async throws {
        let data = Data(#"{"code":"capability_unavailable","message":"JADX missing","details":{"provider_id":"jadx"}}"#.utf8)
        let runner = REAFakeRunner(CommandResult(stdout: data))
        do { _ = try await REAService(configuration: configuration, runner: runner).inspectPackage(apk: apk); XCTFail("Accepted error") }
        catch let error as REAExecutionError { XCTAssertEqual(error.responseJSON, data); XCTAssertTrue(error.message.contains("JADX missing")) }
    }

    func testRejectsTruncatedMalformedWrongDigestAndWrongOperation() async throws {
        let responses = [
            CommandResult(stdout: try evidence(operation: "inspect_android_package"), truncated: true),
            CommandResult(stdout: Data("not json".utf8)),
            CommandResult(stdout: try evidence(operation: "inspect_android_package", digest: String(repeating: "0", count: 64))),
            CommandResult(stdout: try evidence(operation: "inspect_android_class"))
        ]
        for response in responses {
            do { _ = try await REAService(configuration: configuration, runner: REAFakeRunner(response)).inspectPackage(apk: apk); XCTFail("Invalid evidence accepted") } catch {}
        }
    }

    func testRejectsOptionSelectorsAndNegativeOverloadBeforeExecution() async throws {
        let runner = REAFakeRunner(CommandResult())
        let service = REAService(configuration: configuration, runner: runner)
        do { _ = try await service.searchClasses(apk: apk, query: "--help"); XCTFail("Option accepted") } catch {}
        do { _ = try await service.inspectClass(apk: apk, className: ""); XCTFail("Empty class accepted") } catch {}
        do { _ = try await service.inspectMethod(apk: apk, className: "a.A", methodName: "x", overloadIndex: -1); XCTFail("Negative overload accepted") } catch {}
        let commands = await runner.recorded()
        XCTAssertTrue(commands.isEmpty)
    }

    func testEmptyClassQueryIsExplicitAndAPKMustExist() async throws {
        let runner = REAFakeRunner(CommandResult(stdout: try evidence(operation: "search_android_classes")))
        _ = try await REAService(configuration: configuration, runner: runner).searchClasses(apk: apk, query: "")
        let commands = await runner.recorded()
        XCTAssertTrue(commands[0].arguments.contains(""))
        try FileManager.default.removeItem(at: apk)
        do { _ = try await REAService(configuration: configuration, runner: runner).inspectPackage(apk: apk); XCTFail("Missing APK accepted") } catch {}
        let after = await runner.recorded()
        XCTAssertEqual(after.count, 1)
    }

    func testIncomingReferencesRequireMethodForOverload() async throws {
        let runner = REAFakeRunner(CommandResult(stdout: try evidence(operation: "trace_android_references")))
        let service = REAService(configuration: configuration, runner: runner)
        do { _ = try await service.traceReferences(apk: apk, className: "a.A", overloadIndex: 0); XCTFail("Overload without method accepted") } catch {}
        _ = try await service.traceReferences(apk: apk, className: "a.A", methodName: "request", overloadIndex: 1)
        let commands = await runner.recorded()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(Array(commands[0].arguments.suffix(9)), ["trace-android-references", apk.path, "a.A", "--method-name", "request", "--overload-index", "1", "--format", "json"])
    }
}
