import XCTest
@testable import AnalyxerCore

private actor StoreRunner: CommandRunning {
    var commands: [Command] = []
    var remote = ["/data/app/code/base.apk", "/data/app/code/split_config.en.apk"]
    var changed = false
    var changedBoot = false
    var pathReads = 0
    var bootReads = 0
    var wrongSplit = false
    func changePaths() { changed = true }
    func changeBoot() { changedBoot = true }
    func wrongPackage() { wrongSplit = true }
    func records() -> [Command] { commands }
    func launch(_ command: Command) async throws { commands.append(command) }
    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        let a = command.arguments
        var output = ""
        if a.contains("/proc/sys/kernel/random/boot_id") {
            bootReads += 1
            output = changedBoot && bootReads > 1 ? "00000000-0000-0000-0000-000000000002" : "00000000-0000-0000-0000-000000000001"
        } else if a.contains("path") {
            pathReads += 1
            output = remote.map { "package:" + (changed && pathReads > 1 ? $0.replacingOccurrences(of: "code", with: "new") : $0) }.reversed().joined(separator: "\n")
        } else if a.contains("pull") {
            let path = a[a.count - 2]
            try Data((path.hasSuffix("base.apk") ? "base" : "split").utf8).write(to: URL(fileURLWithPath: a.last!))
        } else if a.contains("-i") { output = "package:lab.fixture installer=com.android.vending\npackage:lab.fixture.other installer=unrelated" }
        else if a.starts(with: ["dump", "badging"]) { output = "package: name='\(wrongSplit && a.last!.contains("split-") ? "lab.other" : "lab.fixture")' versionCode='1'" }
        else if a.starts(with: ["manifest", "print"]) { output = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"lab.fixture\" android:versionCode=\"1\"><application/></manifest>" }
        else if a.starts(with: ["dump", "permissions"]) || a.starts(with: ["dex", "packages"]) || a == ["version"] || a == ["--version"] { output = "" }
        else if a.contains("install-multiple") { output = "Success" }
        else { throw AnalyxerError.failed("Unexpected test command \(a)") }
        return CommandResult(stdout: Data(output.utf8))
    }
}

private actor ProcessListRunner: CommandRunning {
    let processes: String, catalogue: String
    init(_ processes: String, catalogue: String = "") { self.processes = processes; self.catalogue = catalogue }
    func launch(_ command: Command) async throws {}
    func run(_ command: Command) async throws -> CommandResult {
        if command.executable.path == "/bin/ps" { return CommandResult(stdout: Data(processes.utf8)) }
        if command.executable.lastPathComponent == "emulator", command.arguments == ["-list-avds"] { return CommandResult(stdout: Data(catalogue.utf8)) }
        throw AnalyxerError.failed("Unexpected test command \(command.arguments)")
    }
}

final class PlayWorkflowTests: XCTestCase {
    var root: URL!
    private var runner: StoreRunner!
    var service: EmulatorService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["platform-tools/adb", "emulator/emulator", "build-tools/37/aapt2", "cmdline-tools/latest/bin/apkanalyzer"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        runner = StoreRunner(); service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func capture() async throws -> InstalledAppCapture {
        try await service.captureInstalledApp(serial: "emulator-5582", package: "lab.fixture", to: root.appendingPathComponent("capture"))
    }
    func testDurableLaunchScopesManagedHomeWithoutOverlayOrWipe() async throws {
        try await service.start(avd: AVD(name: "Play", home: root), persistent: true)
        let records = await runner.records()
        let command = try XCTUnwrap(records.first)
        XCTAssertEqual(command.environment["ANDROID_AVD_HOME"], root.path)
        XCTAssertFalse(command.arguments.contains("-read-only"))
        XCTAssertFalse(command.arguments.contains("-wipe-data"))
        XCTAssertTrue(command.arguments.contains("-no-snapshot"))
    }
    func testSplitCapturePreservesAllBytesOriginAndBaseOrdering() async throws {
        let capture = try await capture()
        XCTAssertEqual(capture.files.map(\.name), ["base.apk", "split_config.en.apk"])
        XCTAssertEqual(capture.source.installer, "package:lab.fixture installer=com.android.vending")
        XCTAssertEqual(try Data(contentsOf: capture.baseAPK), Data("base".utf8))
        let date = try await service.verifyInstalledSet(serial: "emulator-5582", package: "lab.fixture", expected: capture.files.map(\.sha256))
        XCTAssertLessThan(abs(date.timeIntervalSinceNow), 10)
    }
    func testImportRejectsUpdateOrRebootAndRemovesPartialFiles() async throws {
        await runner.changePaths()
        do { _ = try await capture(); XCTFail("Update accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture").path))
        runner = StoreRunner(); service = EmulatorService(paths: SDKPaths(root: root), runner: runner)
        await runner.changeBoot()
        do { _ = try await capture(); XCTFail("Reboot accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture").path))
    }
    func testBaseAloneCannotVerifySplitInstallation() async throws {
        do { _ = try await service.verifyInstalledSet(serial: "emulator-5582", package: "lab.fixture", expected: [ArtifactHash.sha256(data: Data("base".utf8))]); XCTFail() } catch {}
    }
    func testSplitProjectRoundTripExportAndTamperDetection() async throws {
        let capture = try await capture()
        let store = try await ProjectStore.create(at: root.appendingPathComponent("project"), apk: capture.baseAPK, service: service, installed: capture)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.schemaVersion, 3)
        XCTAssertEqual(saved.apkFiles.count, 2)
        try await store.record(kind: .rea, summary: "test", data: Data("{}".utf8))
        let updated = await store.snapshot()
        XCTAssertEqual(updated.schemaVersion, 3)
        try await store.export(to: root.appendingPathComponent("export"))
        let copy = try await ProjectStore.open(at: root.appendingPathComponent("export"))
        let copiedFiles = try await copy.verifiedAPKs()
        XCTAssertEqual(copiedFiles.count, 2)
        let split = try await copy.verifiedAPKComponent(path: "input/split-1.apk")
        try Data("tampered".utf8).write(to: split)
        do { _ = try await ProjectStore.open(at: copy.directory); XCTFail() } catch {}
        do { try await copy.export(to: root.appendingPathComponent("bad-export")); XCTFail() } catch {}
    }
    func testMismatchedSplitPackageNeverPublishesProject() async throws {
        let capture = try await capture()
        await runner.wrongPackage()
        let target = root.appendingPathComponent("bad")
        do { _ = try await ProjectStore.create(at: target, apk: capture.baseAPK, service: service, installed: capture); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testInstallSetUsesAtomicInstallMultipleOnExplicitSerial() async throws {
        let capture = try await capture()
        let result = try await service.install(apks: capture.files.map { capture.directory.appendingPathComponent($0.relativePath) }, serial: "emulator-5582")
        XCTAssertEqual(result, "Success")
        let records = await runner.records()
        let command = try XCTUnwrap(records.last)
        XCTAssertEqual(Array(command.arguments.prefix(4)), ["-s", "emulator-5582", "install-multiple", "-r"])
    }
    func testInstalledImagesExcludePreviewNonPlayAndWrongABI() throws {
        #if arch(arm64)
        let abi = "arm64-v8a"
        #else
        let abi = "x86_64"
        #endif
        for (platform, tag, extra) in [("android-34", "google_apis_playstore", ""), ("android-36.1", "google_apis_playstore", ""), ("android-37", "google_apis_playstore", "\nAndroidVersion.CodeName=Preview"), ("android-35", "google_apis", "")] {
            let dir = root.appendingPathComponent("system-images/\(platform)/\(tag)/\(abi)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("SystemImage.TagId=\(tag)\(extra)".utf8).write(to: dir.appendingPathComponent("source.properties"))
            try Data().write(to: dir.appendingPathComponent("system.img"))
        }
        let images = PlayDeviceService(service: service, home: root.appendingPathComponent("avd")).installedImages()
        XCTAssertEqual(images.map(\.api), ["36.1", "34"])
    }

    func testDefaultCatalogueSitsNextToSDKAndExplicitHomeWins() {
        let sdk = URL(fileURLWithPath: "/opt/android/sdk/", isDirectory: true)
        XCTAssertEqual(PlayDeviceService.defaultHome(sdkRoot: sdk).path, "/opt/android/avd")
        let explicit = root.appendingPathComponent("own-avd")
        XCTAssertEqual(PlayDeviceService(service: service, home: explicit).home, explicit)
        XCTAssertFalse(PlayDeviceService(service: service).home.path.contains("/Library/"))
    }

    func testStandardCatalogueFollowsEmulatorPrecedence() {
        let user = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(EmulatorService.standardAVDHome(environment: [:], userHome: user).path, "/Users/test/.android/avd")
        XCTAssertEqual(EmulatorService.standardAVDHome(environment: ["ANDROID_EMULATOR_HOME": "/e"], userHome: user).path, "/e/avd")
        XCTAssertEqual(EmulatorService.standardAVDHome(environment: ["ANDROID_EMULATOR_HOME": "/e", "ANDROID_USER_HOME": "/u"], userHome: user).path, "/u/avd")
        XCTAssertEqual(EmulatorService.standardAVDHome(environment: ["ANDROID_USER_HOME": "/u", "ANDROID_AVD_HOME": "/a"], userHome: user).path, "/a")
    }

    func testStudioDevicesAreHiddenOnlyWhenBothCataloguesAreTheSameFolder() throws {
        let own = root.appendingPathComponent("own-avd"), studio = root.appendingPathComponent("studio-avd"), link = root.appendingPathComponent("link-avd")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        let play = PlayDeviceService(service: service, home: own), listed = [AVD(name: "Pixel_Tablet")]
        XCTAssertEqual(play.foreignAVDs(listed, standardHome: studio), listed)
        XCTAssertEqual(play.foreignAVDs(listed, standardHome: link), [])
        XCTAssertTrue(play.sharesCatalogue(with: link))
    }

    private func makeOwnDevice(_ name: String, in home: URL, pathLine: String? = nil, config: Bool = true) throws {
        let folder = home.appendingPathComponent(name + ".avd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: folder.appendingPathComponent("userdata-qemu.img"))
        if config { try Data("PlayStore.enabled=yes\navd.ini.displayname=\(name)\nAvdId=\(name)\n".utf8).write(to: folder.appendingPathComponent("config.ini")) }
        try Data("disk.dataPartition.path = \(folder.path)/userdata-qemu.img\navd.name = \(name)\navd.id = \(name)\n".utf8).write(to: folder.appendingPathComponent("hardware-qemu.ini"))
        try Data("avd.ini.encoding=UTF-8\n\(pathLine ?? "path=" + home.appendingPathComponent(name + ".avd").path)\ntarget=android-36.1\n".utf8)
            .write(to: home.appendingPathComponent(name + ".ini"))
    }

    func testDeleteTrashesOnlyOwnStoppedDevices() async throws {
        let home = root.appendingPathComponent("own-avd")
        try makeOwnDevice("Play", in: home)
        try makeOwnDevice("Busy", in: home)
        try makeOwnDevice("Elsewhere", in: home, pathLine: "path=" + root.appendingPathComponent("studio-avd/Elsewhere.avd").path)
        let processes = "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -netdelay none -avd Busy -no-snapshot\n/bin/zsh -l\n"
        let play = PlayDeviceService(service: EmulatorService(paths: SDKPaths(root: root), runner: ProcessListRunner(processes)), home: home)
        var trashed: [String] = []
        let trash: (URL) throws -> Void = { trashed.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }

        try await play.delete(name: "Play", trash: trash)
        XCTAssertEqual(trashed, ["Play.avd", "Play.ini"])
        XCTAssertFalse(play.avds().contains { $0.name == "Play" })

        for name in ["Busy", "Elsewhere", "Pixel_Tablet", "../Play"] {
            do { try await play.delete(name: name, trash: trash); XCTFail("\(name) must not be deleted") }
            catch AnalyxerError.invalidInput {}
        }
        XCTAssertEqual(trashed, ["Play.avd", "Play.ini"])
        XCTAssertEqual(Set(play.avds().map(\.name)), ["Busy", "Elsewhere"])
    }

    func testRenameMovesOwnStoppedDeviceAndKeepsUserData() async throws {
        let home = root.appendingPathComponent("own-avd")
        try makeOwnDevice("Play", in: home)
        try makeOwnDevice("Busy", in: home)
        try makeOwnDevice("Elsewhere", in: home, pathLine: "path=" + root.appendingPathComponent("studio-avd/Elsewhere.avd").path)
        let processes = "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Busy -no-snapshot\n"
        let play = PlayDeviceService(service: EmulatorService(paths: SDKPaths(root: root), runner: ProcessListRunner(processes, catalogue: "Pixel_Tablet\n")), home: home)

        let renamed = try await play.rename("Play", to: "Spiel")
        XCTAssertEqual(renamed, AVD(name: "Spiel", home: home))
        let folder = home.appendingPathComponent("Spiel.avd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Play.avd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Play.ini").path))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("Spiel.ini"), encoding: .utf8).contains("path=" + folder.path + "\n"))
        let config = try String(contentsOf: folder.appendingPathComponent("config.ini"), encoding: .utf8)
        XCTAssertTrue(config.contains("AvdId=Spiel\n") && config.contains("avd.ini.displayname=Spiel\n") && config.contains("PlayStore.enabled=yes"))
        let hardware = try String(contentsOf: folder.appendingPathComponent("hardware-qemu.ini"), encoding: .utf8)
        XCTAssertEqual(hardware, "disk.dataPartition.path = \(folder.path)/userdata-qemu.img\navd.name = Spiel\navd.id = Spiel\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("userdata-qemu.img"), encoding: .utf8), "data")

        _ = try await play.rename("Spiel", to: "SPIEL")
        XCTAssertTrue(play.avds().contains { $0.name == "SPIEL" })
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("SPIEL.avd/config.ini"), encoding: .utf8).contains("AvdId=SPIEL"))

        for (source, target) in [("Busy", "Frei"), ("Elsewhere", "Frei"), ("Pixel_Tablet", "Frei"), ("SPIEL", "busy"), ("SPIEL", "Pixel_Tablet"), ("SPIEL", "1Play"), ("SPIEL", "../Play")] {
            do { _ = try await play.rename(source, to: target); XCTFail("\(source) → \(target) must be refused") }
            catch AnalyxerError.invalidInput {}
        }
        XCTAssertEqual(Set(play.avds().map(\.name)), ["Busy", "Elsewhere", "SPIEL"])
    }

    func testFailedRenameRestoresPreviousState() async throws {
        let home = root.appendingPathComponent("own-avd")
        try makeOwnDevice("Play", in: home, config: false)
        let play = PlayDeviceService(service: EmulatorService(paths: SDKPaths(root: root), runner: ProcessListRunner("")), home: home)
        do { _ = try await play.rename("Play", to: "Spiel"); XCTFail("missing config.ini must fail") }
        catch AnalyxerError.failed {}
        XCTAssertEqual(play.avds().map(\.name), ["Play"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Play.avd/userdata-qemu.img").path))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("Play.ini"), encoding: .utf8).contains("path=" + home.appendingPathComponent("Play.avd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Spiel.avd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Spiel.ini").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".rename-") }
        XCTAssertEqual(leftovers, [])
    }

    func testSystemInfoComesFromCatalogueEntryAndConfig() throws {
        let catalogue = root.appendingPathComponent("catalogue")
        func device(_ name: String, target: String?, config: String?) throws {
            let folder = catalogue.appendingPathComponent(name + ".avd")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("avd.ini.encoding=UTF-8\npath=\(folder.path)\n\(target.map { "target=" + $0 + "\n" } ?? "")".utf8).write(to: catalogue.appendingPathComponent(name + ".ini"))
            if let config { try Data(config.utf8).write(to: folder.appendingPathComponent("config.ini")) }
        }
        try device("Play", target: "android-36.1", config: "abi.type=arm64-v8a\ntag.id=google_apis_playstore\ntag.ids=google_apis_playstore\n")
        try device("Preview", target: "android-37.2", config: "abi.type=arm64-v8a\ntag.id=google_apis_playstore\ntag.ids=google_apis_playstore,page_size_16kb\n")
        try device("Apis", target: nil, config: "abi.type=x86_64\nimage.sysdir.1=system-images/android-34/google_apis/x86_64/\ntag.id=google_apis\n")
        try device("Bare", target: "android-99", config: nil)
        let summary = { (name: String) in AVDSystemInfo.read(name: name, catalogue: catalogue)?.summary }
        XCTAssertEqual(summary("Play"), "Android 16 · API 36.1 · Google Play · ARM64")
        XCTAssertEqual(summary("Preview"), "Android 17 · API 37.2 · Google Play · 16 KB pages · ARM64")
        XCTAssertEqual(summary("Apis"), "Android 14 · API 34 · Google APIs · x86_64")
        XCTAssertEqual(summary("Bare"), "API 99")
        XCTAssertNil(summary("Missing"))
    }
}
