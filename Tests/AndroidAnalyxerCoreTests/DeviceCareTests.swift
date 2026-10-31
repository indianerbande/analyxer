import XCTest
@testable import AndroidAnalyxerCore

/// Fixtures are trimmed outputs of an Android 16 Google Play emulator image.
final class DeviceCareTests: XCTestCase {
    func testPackageListKeepsApkPathsWithEqualsSigns() {
        let text = """
        package:/data/app/~~X9IVPmXgugF7kbbQVOL89w==/com.example.game-CfneDxRieTsxSzYNFv1sqg==/base.apk=com.example.game  installer=com.android.vending uid:10224
        package:/product/app/YouTube/YouTube.apk=com.google.android.youtube  installer=null uid:10181
        package:/product/overlay/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk=com.android.internal.systemui.navbar.threebutton  installer=null uid:10050
        package:com.android.privatespace
        """
        let entries = DeviceCareService.parsePackageList(text)
        XCTAssertEqual(entries.map(\.package), ["com.example.game", "com.google.android.youtube", "com.android.internal.systemui.navbar.threebutton", "com.android.privatespace"])
        XCTAssertEqual(entries[0].path, "/data/app/~~X9IVPmXgugF7kbbQVOL89w==/com.example.game-CfneDxRieTsxSzYNFv1sqg==/base.apk")
        XCTAssertEqual(entries[0].installer, "com.android.vending")
        XCTAssertNil(entries[1].installer)
        XCTAssertNil(entries[3].path)
    }

    func testDiskStatsGivesStorageAndPerPackageSizes() throws {
        let text = """
        Latency: 0ms [512B Data Write]
        Data-Free: 6670388K / 10167132K total = 65% free
        System-Free: 0K / 519092K total = 0% free
        App Size: 2020073472
        App Data Size: 1093459845
        App Cache Size: 115286016
        Photos Size: 0
        Downloads Size: 4096
        System Size: 16000000000
        Package Names: ["com.example.game","com.google.android.youtube"]
        App Sizes: [1510031360,178454528]
        App Data Sizes: [176799744,90112]
        Cache Sizes: [1155072,32768]
        """
        let (storage, sizes) = DeviceCareService.parseDiskStats(text)
        let overview = try XCTUnwrap(storage)
        XCTAssertEqual(overview.total, 10_167_132 * 1024)
        XCTAssertEqual(overview.free, 6_670_388 * 1024)
        XCTAssertEqual(overview.used, (10_167_132 - 6_670_388) * 1024)
        XCTAssertEqual(overview.apps, 2_020_073_472)
        XCTAssertEqual(overview.downloads, 4096)
        XCTAssertNil(overview.videos)
        XCTAssertEqual(sizes["com.example.game"]?.app, 1_510_031_360)
        XCTAssertEqual(sizes["com.google.android.youtube"]?.cache, 32_768)

        let fresh = DeviceCareService.parseDiskStats("Data-Free: 1K / 2K total = 50% free\nPackage Names: [\"a.b\"]\nApp Sizes: [1,2]\n")
        XCTAssertEqual(fresh.sizes.count, 0, "mismatched arrays must not be paired")
    }

    func testDiskStatsJobIsFoundInJobScheduler() {
        let text = "  JOB #1000/1145656139: 82a1ef3 android/com.android.server.storage.DiskStatsLoggingService\n    1000 tag=*job*r/android/..."
        XCTAssertEqual(DeviceCareService.diskStatsJobID(text), "1145656139")
        XCTAssertNil(DeviceCareService.diskStatsJobID("JOB #1000/42: 1 android/com.example.Other"))
    }

    func testUsageKeepsLatestRealUsePerPackage() throws {
        let text = """
              package=com.example.game totalTimeUsed="01:27" lastTimeUsed="2026-10-22 16:10:56" totalTimeVisible="01:31"
              package=com.example.game totalTimeUsed="00:10" lastTimeUsed="2026-10-20 09:00:00" totalTimeVisible="00:10"
              package=com.google.android.youtube totalTimeUsed="00:00" lastTimeUsed="1970-01-01 01:00:00" totalTimeVisible="00:00"
          package=com.google.android.youtube u=0 bucket=10 reason=u-su used=<uninitialized>
        """
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        let usage = DeviceCareService.parseUsage(text, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        XCTAssertEqual(usage["com.example.game"], calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 16, minute: 10, second: 56)))
        XCTAssertNil(usage["com.google.android.youtube"])
    }

    func testProtectionCoversCoreOverlaysAndCurrentDefaults() {
        let dynamic = DeviceCareService.parseDynamicProtection(
            home: "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.google.android.apps.nexuslauncher/.NexusLauncherActivity\n",
            keyboard: "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME\n",
            webView: "  Current WebView package (name, version): (com.google.android.webview, 156.0.8078.47)\n")
        XCTAssertEqual(dynamic, ["com.google.android.apps.nexuslauncher", "com.google.android.inputmethod.latin", "com.google.android.webview"])
        let protected = { (package: String, path: String?) in DeviceCareService.isProtected(package, path: path, dynamic: dynamic) }
        XCTAssertTrue(protected("com.android.systemui", nil))
        XCTAssertTrue(protected("com.google.android.gms", "/data/app/x/base.apk"))
        XCTAssertTrue(protected("com.android.providers.media", nil))
        XCTAssertTrue(protected("com.google.android.apps.nexuslauncher", nil))
        XCTAssertTrue(protected("com.example.theme", "/product/overlay/Theme/Theme.apk"))
        XCTAssertTrue(protected("com.android.tethering", "/apex/com.android.tethering/priv-app/x.apk"))
        XCTAssertFalse(protected("com.google.android.youtube", "/product/app/YouTube/YouTube.apk"))
        XCTAssertFalse(protected("com.example.game", "/data/app/x/base.apk"))
    }

    func testLeftoversExcludeKnownPackagesAndOddPaths() {
        let text = """
        24\t/sdcard/Android/data/com.android.chrome/
        24\t/sdcard/Android/data/com.example.verwaist/
        3080\t/sdcard/Android/obb/com.example.altesspiel/
        8\t/sdcard/Android/media/.thumbnails/
        8\t/sdcard/Android/other/com.example.x/
        8\t/sdcard/Android/data/com.example.x/sub/
        """
        let leftovers = DeviceCareService.parseLeftovers(text, known: ["com.android.chrome"])
        XCTAssertEqual(leftovers.map(\.path), ["/sdcard/Android/obb/com.example.altesspiel", "/sdcard/Android/data/com.example.verwaist"])
        XCTAssertEqual(leftovers.first?.bytes, 3080 * 1024)
    }

    func testPackageValidationAndSuccessCheck() {
        XCTAssertNoThrow(try DeviceCareService.validate("com.google.android.youtube"))
        for bad in ["youtube", "com.example;reboot", "../com.x", "com.x y", "1com.x"] { XCTAssertThrowsError(try DeviceCareService.validate(bad), bad) }
        XCTAssertNoThrow(try DeviceCareService.requireSuccess("Success\n"))
        XCTAssertThrowsError(try DeviceCareService.requireSuccess("Failure [DELETE_FAILED_INTERNAL_ERROR]\n"))
    }

    func testAppSourceAndTotals() {
        func app(_ installer: String?, system: Bool, sizes: (Int64?, Int64?, Int64?)) -> InstalledApp {
            InstalledApp(package: "com.example.app", path: nil, installer: installer, isSystem: system, isDisabled: false, isRemovedForUser: false,
                         isProtected: false, appBytes: sizes.0, dataBytes: sizes.1, cacheBytes: sizes.2, lastUsed: nil)
        }
        XCTAssertEqual(app("com.android.vending", system: false, sizes: (1, 2, 3)).source, "Play Store")
        XCTAssertEqual(app(nil, system: true, sizes: (nil, nil, nil)).source, "Preinstalled")
        XCTAssertEqual(app(nil, system: false, sizes: (nil, nil, nil)).source, "Sideloaded")
        XCTAssertEqual(app("com.android.shell", system: false, sizes: (nil, nil, nil)).source, "ADB")
        XCTAssertEqual(app(nil, system: false, sizes: (1, 2, 3)).totalBytes, 6)
        XCTAssertNil(app(nil, system: false, sizes: (nil, nil, nil)).totalBytes)
    }
}
