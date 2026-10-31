import XCTest
@testable import AnalyxerCore

private actor CaptureRunner: CommandRunning {
    let avd: URL
    let payload: Data
    var rejectStart = false
    var changeBoot = false
    var loseStartAcknowledgment = false
    var bootCalls = 0
    var commands: [[String]] = []
    var output: URL?
    init(avd: URL, payload: Data) { self.avd = avd; self.payload = payload }
    func configure(reject: Bool = false, reboot: Bool = false, loseAcknowledgment: Bool = false) { rejectStart = reject; changeBoot = reboot; loseStartAcknowledgment = loseAcknowledgment }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command.arguments)
        let args = Array(command.arguments.dropFirst(2))
        var text = "OK\r\n"
        if args == ["shell", "cat", "/proc/sys/kernel/random/boot_id"] {
            bootCalls += 1
            text = changeBoot && bootCalls > 1 ? "22222222-2222-2222-2222-222222222222" : "11111111-1111-1111-1111-111111111111"
        } else if args == ["emu", "avd", "path"] {
            text = avd.path + "\r\nOK\r\n"
        } else if args.starts(with: ["emu", "network", "capture", "start"]) {
            if rejectStart { text = "KO: unsupported\r\n" }
            else {
                let file = avd.appendingPathComponent("console_out").appendingPathComponent(args.last!)
                output = file
                try payload.write(to: file)
                if loseStartAcknowledgment { throw AnalyxerError.timedOut }
            }
        } else if args != ["emu", "network", "capture", "stop"] {
            throw AnalyxerError.failed("Unexpected command \(args)")
        }
        return CommandResult(stdout: Data(text.utf8))
    }
    func launch(_ command: Command) async throws { throw AnalyxerError.failed("Unexpected launch") }
    func recorded() -> [[String]] { commands }
    func outputFile() -> URL? { output }
}

final class NetworkCaptureTests: XCTestCase {
    private var root: URL!
    private var header: Data {
        Data([0xd4,0xc3,0xb2,0xa1, 2,0,4,0, 0,0,0,0, 0,0,0,0, 0xff,0xff,0,0, 1,0,0,0])
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let adb = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testPCAPValidationCountsCompletePacketsAndRejectsTruncation() throws {
        XCTAssertEqual(try PCAPValidation.packetCount(header), 0)
        let packet = Data([0,0,0,0, 0,0,0,0, 3,0,0,0, 3,0,0,0, 1,2,3])
        XCTAssertEqual(try PCAPValidation.packetCount(header + packet), 1)
        XCTAssertThrowsError(try PCAPValidation.packetCount((header + packet).dropLast()))
        XCTAssertThrowsError(try PCAPValidation.packetCount(Data("not pcap".utf8)))
    }

    func testInspectorGroupsIPv4UDPWithoutIncludingPayload() throws {
        let ethernet = [UInt8](repeating: 0, count: 12) + [0x08, 0x00]
        let ip: [UInt8] = [0x45,0,0,34, 0,0,0,0, 64,17,0,0, 10,0,2,15, 10,0,2,2]
        let udp: [UInt8] = [0xc0,0, 0x48,0x0b, 0,14,0,0] + Array("secret".utf8)
        let packet = ethernet + ip + udp
        let record = Data([0,0,0,0, 0,0,0,0, UInt8(packet.count),0,0,0, UInt8(packet.count),0,0,0] + packet)
        let result = try PCAPInspector.inspect(header + record + record)
        XCTAssertEqual(result.packetCount, 2)
        XCTAssertEqual(result.decodedPackets, 2)
        XCTAssertEqual(result.endpoints.count, 1)
        XCTAssertEqual(result.endpoints.first?.source, "10.0.2.15:49152")
        XCTAssertEqual(result.endpoints.first?.destination, "10.0.2.2:18443")
        XCTAssertEqual(result.endpoints.first?.packets, 2)
        XCTAssertFalse(result.reportText.contains("secret"))
    }

    func testInspectorReadsBigEndianIPv6AndRejectsPCAPNG() throws {
        let global = Data([0xa1,0xb2,0xc3,0xd4, 0,2,0,4, 0,0,0,0, 0,0,0,0, 0,0,0xff,0xff, 0,0,0,101])
        let ip: [UInt8] = [0x60,0,0,0, 0,8,17,64] + [UInt8](repeating: 0, count: 15) + [1] + [UInt8](repeating: 0, count: 15) + [2] + [0,53,0,80,0,8,0,0]
        let record = Data([0,0,0,0, 0,0,0,0, 0,0,0,UInt8(ip.count), 0,0,0,UInt8(ip.count)] + ip)
        let result = try PCAPInspector.inspect(global + record)
        XCTAssertEqual(result.endpoints.first?.source, "[0:0:0:0:0:0:0:1]:53")
        XCTAssertEqual(result.endpoints.first?.destination, "[0:0:0:0:0:0:0:2]:80")
        XCTAssertThrowsError(try PCAPInspector.inspect(Data([0x0a,0x0d,0x0d,0x0a] + [UInt8](repeating: 0, count: 20))))
    }

    func testCaptureUsesExactDeviceAndCleansPrivateOutputWithExplicitCoverage() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("console_out"), withIntermediateDirectories: false)
        let runner = CaptureRunner(avd: root, payload: header)
        let result = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).captureNetwork(serial: "emulator-5590", duration: 1)
        XCTAssertEqual(result.pcap, header)
        XCTAssertEqual(result.metadata.packetCount, 0)
        XCTAssertTrue(result.metadata.reportText.contains("netsim Wi-Fi"))
        XCTAssertTrue(result.metadata.reportText.contains("not attributed to the project app"))
        let commands = await runner.recorded()
        XCTAssertTrue(commands.allSatisfy { Array($0.prefix(2)) == ["-s", "emulator-5590"] })
        XCTAssertEqual(commands.last, ["-s", "emulator-5590", "emu", "network", "capture", "stop"])
        let output = await runner.outputFile()!
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCaptureRejectsBadInputsBeforeCommands() async throws {
        let runner = CaptureRunner(avd: root, payload: header)
        let service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
        for (serial, duration) in [("USB123", 1.0), ("emulator-5590", 0.0), ("emulator-5590", 61.0), ("emulator-5590", Double.nan)] {
            do { _ = try await service.captureNetwork(serial: serial, duration: duration); XCTFail("Invalid capture accepted") } catch {}
        }
        let commands = await runner.recorded()
        XCTAssertTrue(commands.isEmpty)
    }

    func testConsoleKOIsFailureEvenWithProcessExitZero() async throws {
        let runner = CaptureRunner(avd: root, payload: header)
        await runner.configure(reject: true)
        do {
            _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).captureNetwork(serial: "emulator-5592", duration: 1)
            XCTFail("KO accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("KO:")) }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("console_out").path)
        XCTAssertTrue(files.isEmpty)
    }

    func testRebootDoesNotStopReplacementGuest() async throws {
        let runner = CaptureRunner(avd: root, payload: header)
        await runner.configure(reboot: true)
        do {
            _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).captureNetwork(serial: "emulator-5594", duration: 1)
            XCTFail("Reboot accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("restarted during the capture")) }
        let commands = await runner.recorded()
        XCTAssertFalse(commands.contains { $0.last == "stop" })
    }

    func testStartTimeoutAfterOpeningFileStillStopsCapture() async throws {
        let runner = CaptureRunner(avd: root, payload: header)
        await runner.configure(loseAcknowledgment: true)
        do {
            _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).captureNetwork(serial: "emulator-5598", duration: 1)
            XCTFail("Start timeout accepted")
        } catch {}
        let commands = await runner.recorded()
        XCTAssertTrue(commands.contains { $0.last == "stop" })
    }

    func testCancellationStillStopsSameGuestAndCleansOutput() async throws {
        let runner = CaptureRunner(avd: root, payload: header)
        let service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
        let task = Task { try await service.captureNetwork(serial: "emulator-5596", duration: 10) }
        for _ in 0..<100 {
            if await runner.outputFile() != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled capture succeeded") } catch {}
        let commands = await runner.recorded()
        XCTAssertTrue(commands.contains { $0.last == "stop" })
        let output = await runner.outputFile()!
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
