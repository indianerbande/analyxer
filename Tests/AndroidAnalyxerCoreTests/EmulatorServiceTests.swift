import XCTest
@testable import AndroidAnalyxerCore

private actor FakeRunner: CommandRunning {
    var commands: [Command] = []
    var responses: [[String]: CommandResult] = [:]
    func set(_ args: [String], text: String) { responses[args] = CommandResult(stdout: Data(text.utf8)) }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        guard let result = responses[command.arguments] else { throw AndroidAnalyxerError.failed("Unexpected fake command: \(command.arguments)") }
        return result
    }
    func launch(_ command: Command) async throws { commands.append(command) }
    func recorded() -> [Command] { commands }
}

final class EmulatorServiceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["platform-tools/adb", "emulator/emulator", "build-tools/9.0.0/aapt2", "build-tools/35.0.0/aapt2"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSDKUsesNumericBuildToolVersion() {
        let paths = SDKPaths(root: root)
        XCTAssertEqual(paths.aapt2?.deletingLastPathComponent().lastPathComponent, "35.0.0")
        XCTAssertTrue(paths.diagnostics.isEmpty)
        XCTAssertEqual(SDKPaths.discover(environment: ["ANDROID_HOME": root.path]).root, root.standardizedFileURL)
    }

    func testDeviceParsingMapsOnlyOnlineEmulators() async throws {
        let runner = FakeRunner()
        await runner.set(["devices", "-l"], text: "List of devices attached\nemulator-5554 device product:sdk model:Pixel_Tablet transport_id:1\nemulator-5556 offline transport_id:2\nUSB123 unauthorized usb:1-1\n")
        await runner.set(["-s", "emulator-5554", "emu", "avd", "name"], text: "Analysis_Tablet\nOK\n")
        let devices = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).devices()
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].avdName, "Analysis_Tablet")
        XCTAssertEqual(devices[0].model, "Pixel Tablet")
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertFalse(devices[1].isOnline)
        XCTAssertEqual(devices[2].state, "unauthorized")
        let commands = await runner.recorded()
        XCTAssertEqual(commands.count, 2)
    }

    func testLaunchUsesTemporaryOverlayAndLiteralArgument() async throws {
        let runner = FakeRunner()
        let name = "Tablet with spaces;$(echo injected)"
        try await EmulatorService(paths: SDKPaths(root: root), runner: runner).start(avd: AVD(name: name))
        let command = await runner.recorded().first!
        XCTAssertEqual(command.arguments, ["-avd", name, "-read-only", "-no-snapshot", "-no-metrics"])
    }

    func testScreenKeyboardEnablesKeysAndVerifiesAndroidSettings() async throws {
        let runner = FakeRunner()
        for (key, value) in [("show_ime_with_hard_keyboard", "1"), ("stylus_handwriting_enabled", "0")] {
            await runner.set(["-s", "emulator-5554", "shell", "settings", "put", "secure", key, value], text: "")
            await runner.set(["-s", "emulator-5554", "shell", "settings", "get", "secure", key], text: value + "\n")
        }
        let service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
        try await service.enableScreenKeyboard(serial: "emulator-5554")
        let recorded = await runner.recorded()
        XCTAssertEqual(recorded.count, 4)
        do { try await service.enableScreenKeyboard(serial: "USB123"); XCTFail("Physical device modified") } catch {}
        let after = await runner.recorded()
        XCTAssertEqual(after.count, 4)
        await runner.set(["-s", "emulator-5554", "shell", "settings", "get", "secure", "show_ime_with_hard_keyboard"], text: "0")
        do { try await service.enableScreenKeyboard(serial: "emulator-5554"); XCTFail("Unapplied setting accepted") } catch {}
    }

    func testRejectsPhysicalDeviceStopAndShellPayloads() async {
        let runner = FakeRunner()
        let service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
        do { try await service.stop(serial: "USB123"); XCTFail("Physical stop accepted") } catch {}
        do { _ = try await service.launchPackage(identifier: "com.example.app;reboot", serial: "emulator-5554"); XCTFail("Payload accepted") } catch {}
        do { try await service.keyevent(serial: "emulator-5554", keyCode: 26); XCTFail("Unapproved key accepted") } catch {}
        do { _ = try await service.logs(serial: "x;reboot"); XCTFail("Invalid serial accepted") } catch {}
        let commands = await runner.recorded()
        XCTAssertTrue(commands.isEmpty)
    }

    func testPackagesAreParsedAndEveryCommandTargetsSelectedDevice() async throws {
        let runner = FakeRunner()
        await runner.set(["-s", "emulator-5558", "shell", "pm", "list", "packages"], text: "package:org.zeta\npackage:com.alpha\nnoise\n")
        let packages = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).packages(serial: "emulator-5558")
        XCTAssertEqual(packages, ["com.alpha", "org.zeta"])
    }

    func testAPKInspectionExtractsPermissionsAndHashesBytes() async throws {
        let apk = root.appendingPathComponent("test with spaces.apk")
        try Data("abc".utf8).write(to: apk)
        let runner = FakeRunner()
        await runner.set(["dump", "badging", apk.path], text: "package: name='org.example' versionCode='1'")
        await runner.set(["dump", "permissions", apk.path], text: "package: org.example\nuses-permission: name='android.permission.INTERNET'\nuses-permission: name='android.permission.INTERNET'\npermission: name='org.example.CUSTOM'\n")
        let report = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).inspectAPK(at: apk)
        XCTAssertEqual(report.permissions, ["android.permission.INTERNET"])
        XCTAssertEqual(report.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(report.metadata.contains("org.example"))
    }

    private var resolveArguments: [String] {
        ["-s", "emulator-5554", "shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "lab.androidanalyxer.fixture"]
    }

    func testLaunchResolvesActivityAndPreservesInnerClassName() async throws {
        let runner = FakeRunner()
        let component = "lab.androidanalyxer.fixture/.Fixture$Launcher"
        await runner.set(resolveArguments, text: "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false\n\(component)\n")
        let launchArguments = ["-s", "emulator-5554", "shell", "am", "start", "-W", "-n", "'\(component)'"]
        await runner.set(launchArguments, text: "Starting: Intent { cmp=\(component) }\nStatus: ok\nComplete\n")
        let result = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).launchPackage(identifier: "lab.androidanalyxer.fixture", serial: "emulator-5554")
        XCTAssertTrue(result.contains("Status: ok"))
        let commands = await runner.recorded()
        XCTAssertEqual(commands.map(\.arguments), [resolveArguments, launchArguments])
    }

    func testLaunchWithoutLauncherDoesNotStartAnything() async {
        let runner = FakeRunner()
        await runner.set(resolveArguments, text: "No activity found\n")
        do {
            _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).launchPackage(identifier: "lab.androidanalyxer.fixture", serial: "emulator-5554")
            XCTFail("Missing launcher was accepted")
        } catch {}
        let commands = await runner.recorded()
        XCTAssertEqual(commands.count, 1)
    }

    func testLaunchRejectsMalformedOrOtherPackageComponent() async {
        for component in ["lab.androidanalyxer.fixture/.Main;reboot", "org.other/.Main", "lab.androidanalyxer.fixture/.Main'$(reboot)"] {
            let runner = FakeRunner()
            await runner.set(resolveArguments, text: component + "\n")
            do {
                _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).launchPackage(identifier: "lab.androidanalyxer.fixture", serial: "emulator-5554")
                XCTFail("Invalid component accepted: \(component)")
            } catch {}
            let commands = await runner.recorded()
            XCTAssertEqual(commands.count, 1)
        }
    }

    func testLaunchDetectsAndroidErrorDespiteSuccessfulProcessExit() async {
        let runner = FakeRunner()
        await runner.set(resolveArguments, text: "lab.androidanalyxer.fixture/.Main\n")
        await runner.set(["-s", "emulator-5554", "shell", "am", "start", "-W", "-n", "'lab.androidanalyxer.fixture/.Main'"], text: "Starting: Intent {}\nError: Activity not started, unable to resolve Intent\n")
        do {
            _ = try await EmulatorService(paths: SDKPaths(root: root), runner: runner).launchPackage(identifier: "lab.androidanalyxer.fixture", serial: "emulator-5554")
            XCTFail("Android error was accepted")
        } catch {}
    }
}
