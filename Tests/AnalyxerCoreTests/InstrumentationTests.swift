import XCTest
@testable import AnalyxerCore

private let instrumentBoot = "4E7C57BA-76BE-41DB-8EE0-6B07EF677607"
private let instrumentProbe = JavaMethodProbe(className: "lab.analyxer.fixture.MainActivity", methodName: "buildRequest", argumentTypes: ["java.lang.String"])
private func instrumentEvidence(events: [[String: Any]], pid: Int = 42, truncated: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["evidence": ["operation": "instrument_with_frida", "normalized_result": [
        "pid": pid, "mode": "attach", "messages_truncated": truncated,
        "messages": events.map { ["type": "send", "payload": $0.merging(["schema": "analyxer.java-probe.v1"]) { _, new in new }] }
    ]]])
}
private actor InstrumentRunner: CommandRunning {
    var commands: [[String]] = []
    var failure = false
    var replacePID = false
    var statReads = 0
    func configure(failure: Bool = false, replacePID: Bool = false) { self.failure = failure; self.replacePID = replacePID }
    func recorded() -> [[String]] { commands }
    func launch(_ command: Command) async throws {}
    func run(_ command: Command) async throws -> CommandResult {
        let a = command.arguments
        commands.append(a)
        if a.contains("instrument-with-frida") {
            if failure { return CommandResult(stdout: Data("{\"code\":\"provider_missing\",\"message\":\"Frida unavailable\"}".utf8)) }
            return CommandResult(stdout: try instrumentEvidence(events: [["kind": "installed", "probe": 0], ["kind": "enter", "probe": 0, "callID": 1], ["kind": "return", "probe": 0, "callID": 1]]))
        }
        var text = ""
        if a.contains("/proc/sys/kernel/random/boot_id") { text = instrumentBoot }
        else if a.contains("pidof") { text = "42" }
        else if a.last == "/proc/42/cmdline" { text = "lab.analyxer.fixture\0" }
        else if a.last == "/proc/42/stat" {
            statReads += 1
            text = "42 (fixture) " + Array(repeating: "0", count: 19).joined(separator: " ") + " " + ((replacePID && statReads > 1) ? "1235" : "1234")
        } else if a.contains("forward") && !a.contains("--remove") { text = "34567" }
        return CommandResult(stdout: Data(text.utf8))
    }
}

final class InstrumentationTests: XCTestCase {
    func testRequestRejectsWildcardsDuplicateMethodsAndUnboundedCapture() throws {
        for request in [InstrumentationRequest(probes: []), InstrumentationRequest(probes: [instrumentProbe], durationMilliseconds: 60001),
                        InstrumentationRequest(probes: [instrumentProbe, instrumentProbe]),
                        InstrumentationRequest(probes: [JavaMethodProbe(className: "lab.*", methodName: "send", argumentTypes: [])]),
                        InstrumentationRequest(probes: [instrumentProbe], maxValueCharacters: 20000)] {
            XCTAssertThrowsError(try request.validate())
        }
        try InstrumentationRequest(probes: [instrumentProbe]).validate()
    }
    func testGeneratedProbePreservesOriginalCallAndDoesNotReadOpaqueObjects() throws {
        let script = try InstrumentationService.script(request: InstrumentationRequest(probes: [instrumentProbe]), bridge: "globalThis.Java = {};", package: "lab.analyxer.fixture", pid: 42)
        XCTAssertTrue(script.contains("overload(...probe.argumentTypes)"))
        XCTAssertTrue(script.contains("const result = method.apply(this,args)"))
        XCTAssertTrue(script.contains("throw error"))
        XCTAssertTrue(script.contains("kind:'opaque'"))
        XCTAssertTrue(script.contains("currentPackageName()"))
        XCTAssertTrue(script.contains("Process.id !== expectedPID"))
        XCTAssertFalse(script.contains(".toString()"))
    }
    func testEmptyObservationIsExplicitAndSetupErrorDoesNotLookSuccessful() throws {
        let request = InstrumentationRequest(probes: [instrumentProbe])
        let result = try InstrumentationService.parseEvidence(instrumentEvidence(events: [["kind":"installed", "probe":0]]), expectedPID: 42, request: request)
        XCTAssertEqual(result.invocations, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("no call observed") })
        XCTAssertThrowsError(try InstrumentationService.parseEvidence(instrumentEvidence(events: [["kind":"setup-error", "message":"class missing"]]), expectedPID: 42, request: request))
        XCTAssertThrowsError(try InstrumentationService.parseEvidence(instrumentEvidence(events: [["kind":"installed", "probe":0]], pid: 43), expectedPID: 42, request: request))
    }
    func testCaptureOwnsExactDeviceForwardAndReleasesItOnFailureOrPIDReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let bridge = root.appendingPathComponent("bridge.js")
        try Data("globalThis.Java = {};".utf8).write(to: bridge)
        for (failure, replaced) in [(false, false), (true, false), (false, true)] {
            let runner = InstrumentRunner()
            await runner.configure(failure: failure, replacePID: replaced)
            let service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
            let observer = InstrumentationService(rea: REAConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true")), bridgeURL: bridge, runner: runner)
            do {
                let result = try await observer.capture(service: service, serial: "emulator-5580", package: "lab.analyxer.fixture", expectedBootID: instrumentBoot, request: InstrumentationRequest(probes: [instrumentProbe]))
                XCTAssertFalse(failure || replaced)
                XCTAssertEqual(result.invocationCount, 1)
            } catch let error as InstrumentationError {
                XCTAssertTrue(failure || replaced)
                XCTAssertNotNil(error.evidenceJSON)
                XCTAssertNotNil(error.script)
            }
            let commands = await runner.recorded()
            XCTAssertTrue(commands.contains(["-s", "emulator-5580", "forward", "tcp:0", "tcp:27042"]))
            XCTAssertEqual(commands.filter { $0.contains("--remove") }.count, 1)
            let rea = try XCTUnwrap(commands.first { $0.contains("instrument-with-frida") })
            XCTAssertTrue(rea.contains("127.0.0.1:34567"))
            XCTAssertFalse(rea.contains("--device-id"))
        }
    }
}
