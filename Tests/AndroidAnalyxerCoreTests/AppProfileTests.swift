import XCTest
@testable import AndroidAnalyxerCore

final class AppProfileTests: XCTestCase {
    private func project(permissions: [String], components: [ManifestComponent], application: [String: String] = [:], dex: String = "") -> AnalysisProject {
        var manifest = ManifestSummary(packageName: "com.example.game", versionName: "2.1", versionCode: "21", minSDK: "24", targetSDK: "36.1")
        manifest.application = application; manifest.components = components; manifest.permissions = permissions
        let analysis = StaticAnalysis(observedAt: Date(), apk: APKReport(metadata: "", permissions: permissions, sha256: String(repeating: "a", count: 64)),
                                      manifest: manifest, manifestXML: "", dexInventory: dex, tools: [:], limitations: [])
        return AnalysisProject(id: UUID(), createdAt: Date(), updatedAt: Date(), title: "Spiel", originalAPKName: "base.apk", apkPath: "input/application.apk",
                               analysis: analysis, additionalAPKs: [ProjectAPK(relativePath: "input/split-1.apk", name: "split_config.arm64_v8a.apk", sha256: "b")])
    }

    func testPermissionsGetPlainLanguageGroupsAndLevels() {
        let describe = { (name: String) in PermissionCatalog.describe(name, ownPackage: "com.example.game") }
        XCTAssertEqual(describe("android.permission.CAMERA").label, "Camera")
        XCTAssertEqual(describe("android.permission.CAMERA").level, .dangerous)
        XCTAssertEqual(describe("android.permission.SYSTEM_ALERT_WINDOW").level, .special)
        XCTAssertEqual(describe("android.permission.MOUNT_UNMOUNT_FILESYSTEMS").level, .systemOnly)
        XCTAssertEqual(describe("com.google.android.gms.permission.AD_ID").group, "Advertising & Tracking")
        XCTAssertEqual(describe("android.permission.FOREGROUND_SERVICE_DATA_SYNC").label, "Background service: data sync")
        XCTAssertEqual(describe("com.example.game.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION").level, .appSpecific)
        XCTAssertEqual(describe("com.huawei.appmarket.service.commondata.permission.GET_COMMON_DATA").label, "Huawei: App store data")
        XCTAssertEqual(describe("com.sec.android.provider.badge.permission.READ").label, "Samsung: App icon badge")
        let unknown = describe("android.permission.BIND_APPHUB_SERVICE")
        XCTAssertEqual(unknown.group, "Other"); XCTAssertEqual(unknown.level, .unknown)
        XCTAssertEqual(describe("org.example.CUSTOM").level, .unknown)
    }

    func testLibrariesAreFoundInCodeNativeLibrariesAndMarkers() {
        let sdks = SDKCatalog.detect(
            classes: ["com.applovin.adview.AppLovinFullscreenActivity", "com.facebook.ads.AudienceNetworkActivity", "com.facebook.ads.internal.X",
                      "com.google.android.gms.ads.AdActivity", "com.unity3d.player.UnityPlayerActivity", "com.adjustable.Tool"],
            libraries: ["libapplovin-native-crash-reporter.so", "libcrashlytics.so", "libemulator_check.so", "libunity.so"],
            markers: ["firebase-analytics", "play-services-ads-identifier", "billing"])
        let byName = Dictionary(uniqueKeysWithValues: sdks.map { ($0.name, $0) })
        XCTAssertEqual(byName["AppLovin"]?.sources, ["Java code", "native library"])
        XCTAssertEqual(byName["Meta Audience Network"]?.category, "Advertising")
        XCTAssertNil(byName["Facebook SDK (Login, Sharing, App Events)"], "com.facebook.ads alone is not the Facebook SDK")
        XCTAssertNotNil(byName["Google AdMob"])
        XCTAssertNil(byName["Adjust"], "com.adjustable must not match com.adjust.sdk")
        XCTAssertEqual(byName["Firebase Crashlytics"]?.sources, ["native library"])
        XCTAssertNotNil(byName["Emulator Detection"])
        XCTAssertEqual(byName["Google Analytics for Firebase"]?.sources, ["library marker"])
        XCTAssertNotNil(byName["Google Play Billing"])
        XCTAssertNil(byName["Unity Ads"], "the Unity player is the engine, not Unity Ads")

        XCTAssertEqual(SDKCatalog.frameworks(libraries: ["libunity.so", "libil2cpp.so", "libmain.so"], markers: []), ["Unity (IL2CPP)"])
        XCTAssertEqual(SDKCatalog.frameworks(libraries: ["libflutter.so", "libapp.so"], markers: ["androidx.compose.ui_ui"]), ["Flutter", "Jetpack Compose"])
        XCTAssertEqual(SDKCatalog.frameworks(libraries: [], markers: []), [])
    }

    func testProfileCombinesManifestApkEntriesAndHighlights() {
        let components = [
            ManifestComponent(kind: "activity", name: "com.example.game.Main", exported: "true", permission: nil, enabled: nil,
                              actions: ["android.intent.action.MAIN", "android.intent.action.VIEW"], categories: ["android.intent.category.LAUNCHER", "android.intent.category.BROWSABLE"],
                              data: [["scheme": "https", "host": "play.example.com"], ["scheme": "examplegame", "host": "open"], ["scheme": "@ref/0x7f0e0070"]]),
            ManifestComponent(kind: "receiver", name: "com.example.game.Boot", exported: nil, permission: nil, enabled: nil, actions: ["android.intent.action.BOOT_COMPLETED"]),
            ManifestComponent(kind: "service", name: "com.example.game.Hidden", exported: "false", permission: nil, enabled: nil),
            ManifestComponent(kind: "provider", name: "com.example.game.Files", exported: nil, permission: nil, enabled: nil, actions: ["x"]),
            ManifestComponent(kind: "activity", name: "com.appsflyer.Tracking", exported: "true", permission: nil, enabled: "false"),
        ]
        let value = project(permissions: ["android.permission.INTERNET", "android.permission.CAMERA", "com.google.android.gms.permission.AD_ID",
                                          "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.RECEIVE_BOOT_COMPLETED"],
                            components: components, application: ["usesCleartextTraffic": "true", "allowBackup": "false"],
                            dex: "P d 1\t1\t10\t<TOTAL>\nC d 1\t1\t10\tcom.google.android.gms.ads.AdView\n")
        let profile = AppProfile.build(project: value, entries: [["classes.dex", "billing.properties", "META-INF/androidx.core_core.version", "assets/x.properties"],
                                                                  ["lib/arm64-v8a/libunity.so", "lib/arm64-v8a/libil2cpp.so", "lib/arm64-v8a/sub/x.so"]], sizes: [100, 50])
        XCTAssertEqual(profile.minAndroid, "7.0"); XCTAssertEqual(profile.targetAndroid, "16")
        XCTAssertEqual(profile.apkCount, 2); XCTAssertEqual(profile.totalBytes, 150)
        XCTAssertEqual(profile.frameworks, ["Unity (IL2CPP)"]); XCTAssertEqual(profile.abis, ["arm64-v8a"]); XCTAssertEqual(profile.nativeLibraryCount, 2)
        XCTAssertEqual(Set(profile.sdks.map(\.name)), ["Google AdMob", "Google Play Billing", "AppsFlyer"])
        XCTAssertEqual(profile.trackingSDKs.count, 2)
        XCTAssertEqual(profile.reachable, [ReachableEntry(kind: "screens", count: 1), ReachableEntry(kind: "receivers", count: 1)])
        XCTAssertEqual(profile.reachable.map(\.title), ["1 screen", "1 receiver"])
        XCTAssertEqual(profile.webLinkHosts, ["play.example.com"]); XCTAssertEqual(profile.linkSchemes, ["examplegame://"])
        XCTAssertTrue(profile.cleartextTraffic); XCTAssertFalse(profile.allowBackup); XCTAssertFalse(profile.debuggable)
        XCTAssertEqual(profile.permissionsByGroup.first?.group, "Camera & Microphone")
        let highlights = profile.highlights.map(\.text)
        XCTAssertEqual(highlights, ["2 advertising and tracking libraries", "Reads the advertising ID", "1 permission needing approval", "Display over other apps",
                                    "Starts at boot", "Allows unencrypted HTTP"])
    }
}
