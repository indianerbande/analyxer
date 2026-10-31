import XCTest
@testable import AndroidAnalyxerCore

private actor InstalledAPKRunner: CommandRunning {
    var commands: [Command] = []
    var paths: [String]
    let bytes: Data
    init(paths: [String], bytes: Data = Data("installed apk".utf8)) { self.paths = paths; self.bytes = bytes }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        if command.arguments.contains("pull") {
            try bytes.write(to: URL(fileURLWithPath: command.arguments.last!))
            return CommandResult(stdout: Data("1 file pulled".utf8))
        }
        return CommandResult(stdout: Data(paths.removeFirst().utf8))
    }
    func launch(_ command: Command) async throws {}
    func recorded() -> [Command] { commands }
}

final class InstalledAPKVerificationTests: XCTestCase {
    var root: URL!
    let path = "/data/app/~~random=/app.random==/base.apk"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let adb = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testVerifiedInstalledCopyIsBoundToDeviceAndTempIsRemoved() async throws {
        let runner = InstalledAPKRunner(paths: ["package:\(path)\n", "package:\(path)\n"])
        let digest = ArtifactHash.sha256(data: Data("installed apk".utf8))
        let result = try await EmulatorService(paths: SDKPaths(root: root), runner: runner)
            .verifyInstalledAPK(serial: "emulator-5580", package: "lab.fixture", expectedSHA256: digest)
        XCTAssertEqual(result.sha256, digest)
        XCTAssertEqual(result.installedPath, path)
        let commands = await runner.recorded()
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands.allSatisfy { Array($0.arguments.prefix(2)) == ["-s", "emulator-5580"] })
        XCTAssertEqual(Array(commands[1].arguments.dropLast()), ["-s", "emulator-5580", "pull", path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: commands[1].arguments.last!))
    }

    func testRejectsSplitMissingAndUnsafePathsBeforePull() async throws {
        for output in ["", "package:/base.apk\npackage:/split.apk", "package:/data/../base.apk", "package:/data/a;id.apk", "Error: unavailable"] {
            let runner = InstalledAPKRunner(paths: [output])
            do {
                _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner)
                    .verifyInstalledAPK(serial: "emulator-5580", package: "lab.fixture", expectedSHA256: String(repeating: "0", count: 64))
                XCTFail("Invalid path accepted")
            } catch {}
            let commands = await runner.recorded()
            XCTAssertEqual(commands.count, 1)
        }
    }

    func testRejectsChangedBytesAndPathAndRemovesTemp() async throws {
        let digest = ArtifactHash.sha256(data: Data("installed apk".utf8))
        for (expected, paths) in [(String(repeating: "0", count: 64), ["package:\(path)"]), (digest, ["package:\(path)", "package:/data/app/new/base.apk"])] {
            let runner = InstalledAPKRunner(paths: paths)
            do {
                _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner)
                    .verifyInstalledAPK(serial: "emulator-5580", package: "lab.fixture", expectedSHA256: expected)
                XCTFail("Changed installed APK accepted")
            } catch {}
            let commands = await runner.recorded()
            XCTAssertFalse(FileManager.default.fileExists(atPath: commands[1].arguments.last!))
        }
    }

    func testRejectsInvalidPackageAndDigestBeforeADB() async throws {
        let runner = InstalledAPKRunner(paths: [])
        let service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
        do { _ = try await service.verifyInstalledAPK(serial: "emulator-5580", package: "lab.fixture;id", expectedSHA256: String(repeating: "0", count: 64)); XCTFail() } catch {}
        do { _ = try await service.verifyInstalledAPK(serial: "emulator-5580", package: "lab.fixture", expectedSHA256: "bad"); XCTFail() } catch {}
        let commands = await runner.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
}
