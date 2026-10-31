import Foundation

/// Looks up a catalogue text (permission labels, groups, library names and categories) in the app's localization.
private func profileText(_ english: String) -> String { String(localized: String.LocalizationValue(english)) }

// MARK: Permissions

/// How Android grants a permission; ordered from most to least noteworthy.
public enum PermissionLevel: Int, Comparable, Sendable, CaseIterable {
    case special, dangerous, systemOnly, normal, vendor, appSpecific, unknown
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var title: String {
        switch self {
        case .special: String(localized: "Special access")
        case .dangerous: String(localized: "Needs approval")
        case .systemOnly: String(localized: "System apps only")
        case .normal: String(localized: "No prompt")
        case .vendor: String(localized: "Vendor")
        case .appSpecific: String(localized: "App-internal")
        case .unknown: String(localized: "Unknown")
        }
    }
}

public struct PermissionInfo: Hashable, Sendable, Identifiable {
    public let name: String
    public let label: String
    public let group: String
    public let level: PermissionLevel
    public var id: String { name }
}

public enum PermissionCatalog {
    /// Display order of the groups (localized, like `PermissionInfo.group`).
    public static let groups = ["Location", "Camera & Microphone", "Contacts & Accounts", "Calendar", "Phone & Calls", "SMS & MMS",
                                "Photos, Media & Files", "Body & Activity", "Nearby Devices", "Advertising & Tracking",
                                "Overlays & System Access", "Background & Autostart", "Notifications", "Network & Internet",
                                "Purchases & Licences", "Push Messages", "Hardware & Other", "Vendor Interfaces", "App-Internal", "Other"].map(profileText)

    private typealias Entry = (label: String, group: String, level: PermissionLevel)
    private static let android: [String: Entry] = [
        "ACCESS_FINE_LOCATION": ("Precise location (GPS)", "Location", .dangerous),
        "ACCESS_COARSE_LOCATION": ("Approximate location", "Location", .dangerous),
        "ACCESS_BACKGROUND_LOCATION": ("Location, also in the background", "Location", .dangerous),
        "ACCESS_MEDIA_LOCATION": ("Read locations in photos", "Location", .dangerous),
        "ACCESS_LOCATION_EXTRA_COMMANDS": ("Extra location commands", "Location", .normal),
        "CAMERA": ("Camera", "Camera & Microphone", .dangerous),
        "RECORD_AUDIO": ("Microphone", "Camera & Microphone", .dangerous),
        "MODIFY_AUDIO_SETTINGS": ("Change audio settings", "Camera & Microphone", .normal),
        "READ_CONTACTS": ("Read contacts", "Contacts & Accounts", .dangerous),
        "WRITE_CONTACTS": ("Change contacts", "Contacts & Accounts", .dangerous),
        "GET_ACCOUNTS": ("List accounts on the device", "Contacts & Accounts", .dangerous),
        "READ_PROFILE": ("Read own profile (deprecated)", "Contacts & Accounts", .normal),
        "READ_CALENDAR": ("Read calendar", "Calendar", .dangerous),
        "WRITE_CALENDAR": ("Change calendar", "Calendar", .dangerous),
        "READ_PHONE_STATE": ("Phone status and device identifiers", "Phone & Calls", .dangerous),
        "READ_PHONE_NUMBERS": ("Own phone number", "Phone & Calls", .dangerous),
        "CALL_PHONE": ("Make calls", "Phone & Calls", .dangerous),
        "ANSWER_PHONE_CALLS": ("Answer calls", "Phone & Calls", .dangerous),
        "READ_CALL_LOG": ("Read call log", "Phone & Calls", .dangerous),
        "WRITE_CALL_LOG": ("Change call log", "Phone & Calls", .dangerous),
        "PROCESS_OUTGOING_CALLS": ("Redirect outgoing calls", "Phone & Calls", .dangerous),
        "ADD_VOICEMAIL": ("Add voicemail messages", "Phone & Calls", .dangerous),
        "USE_SIP": ("Internet calling (SIP)", "Phone & Calls", .dangerous),
        "MANAGE_OWN_CALLS": ("Manage own calls", "Phone & Calls", .normal),
        "READ_PRIVILEGED_PHONE_STATE": ("Protected phone identifiers", "Phone & Calls", .systemOnly),
        "SEND_SMS": ("Send SMS", "SMS & MMS", .dangerous),
        "RECEIVE_SMS": ("Receive SMS", "SMS & MMS", .dangerous),
        "READ_SMS": ("Read SMS", "SMS & MMS", .dangerous),
        "RECEIVE_MMS": ("Receive MMS", "SMS & MMS", .dangerous),
        "RECEIVE_WAP_PUSH": ("Receive WAP push", "SMS & MMS", .dangerous),
        "READ_EXTERNAL_STORAGE": ("Read shared storage", "Photos, Media & Files", .dangerous),
        "WRITE_EXTERNAL_STORAGE": ("Write shared storage", "Photos, Media & Files", .dangerous),
        "READ_MEDIA_IMAGES": ("Read photos", "Photos, Media & Files", .dangerous),
        "READ_MEDIA_VIDEO": ("Read videos", "Photos, Media & Files", .dangerous),
        "READ_MEDIA_AUDIO": ("Read music and audio", "Photos, Media & Files", .dangerous),
        "READ_MEDIA_VISUAL_USER_SELECTED": ("Photos and videos chosen by the user", "Photos, Media & Files", .dangerous),
        "MANAGE_EXTERNAL_STORAGE": ("Access to all files", "Photos, Media & Files", .special),
        "MANAGE_MEDIA": ("Change media without asking", "Photos, Media & Files", .special),
        "MOUNT_UNMOUNT_FILESYSTEMS": ("Mount and unmount storage", "Photos, Media & Files", .systemOnly),
        "BODY_SENSORS": ("Body sensors (e.g. heart rate)", "Body & Activity", .dangerous),
        "BODY_SENSORS_BACKGROUND": ("Body sensors in the background", "Body & Activity", .dangerous),
        "ACTIVITY_RECOGNITION": ("Recognise physical activity", "Body & Activity", .dangerous),
        "HIGH_SAMPLING_RATE_SENSORS": ("High-rate motion sensors", "Body & Activity", .normal),
        "BLUETOOTH": ("Bluetooth", "Nearby Devices", .normal),
        "BLUETOOTH_ADMIN": ("Manage Bluetooth", "Nearby Devices", .normal),
        "BLUETOOTH_SCAN": ("Scan for Bluetooth devices", "Nearby Devices", .dangerous),
        "BLUETOOTH_CONNECT": ("Connect to Bluetooth devices", "Nearby Devices", .dangerous),
        "BLUETOOTH_ADVERTISE": ("Become visible to Bluetooth devices", "Nearby Devices", .dangerous),
        "NEARBY_WIFI_DEVICES": ("Nearby Wi-Fi devices", "Nearby Devices", .dangerous),
        "UWB_RANGING": ("Ultra-wideband ranging", "Nearby Devices", .dangerous),
        "NFC": ("NFC", "Nearby Devices", .normal),
        "CHANGE_WIFI_MULTICAST_STATE": ("Receive Wi-Fi multicast", "Nearby Devices", .normal),
        "ACCESS_ADSERVICES_AD_ID": ("Advertising ID (Privacy Sandbox)", "Advertising & Tracking", .normal),
        "ACCESS_ADSERVICES_ATTRIBUTION": ("Ad attribution (Privacy Sandbox)", "Advertising & Tracking", .normal),
        "ACCESS_ADSERVICES_TOPICS": ("Interest topics for advertising", "Advertising & Tracking", .normal),
        "ACCESS_ADSERVICES_CUSTOM_AUDIENCE": ("Ad audiences (Protected Audience)", "Advertising & Tracking", .normal),
        "SYSTEM_ALERT_WINDOW": ("Display over other apps", "Overlays & System Access", .special),
        "WRITE_SETTINGS": ("Change system settings", "Overlays & System Access", .special),
        "PACKAGE_USAGE_STATS": ("Usage statistics of other apps", "Overlays & System Access", .special),
        "REQUEST_INSTALL_PACKAGES": ("Install other apps", "Overlays & System Access", .special),
        "USE_FULL_SCREEN_INTENT": ("Full-screen notifications", "Overlays & System Access", .special),
        "QUERY_ALL_PACKAGES": ("See all installed apps", "Overlays & System Access", .normal),
        "REQUEST_DELETE_PACKAGES": ("Request uninstalling other apps", "Overlays & System Access", .normal),
        "KILL_BACKGROUND_PROCESSES": ("End background processes of other apps", "Overlays & System Access", .normal),
        "GET_TASKS": ("Query running apps (deprecated)", "Overlays & System Access", .normal),
        "REORDER_TASKS": ("Bring running apps to the front", "Overlays & System Access", .normal),
        "DISABLE_KEYGUARD": ("Dismiss the screen lock", "Overlays & System Access", .normal),
        "EXPAND_STATUS_BAR": ("Expand the status bar", "Overlays & System Access", .normal),
        "READ_LOGS": ("Read system logs", "Overlays & System Access", .systemOnly),
        "WRITE_SECURE_SETTINGS": ("Change protected settings", "Overlays & System Access", .systemOnly),
        "INSTALL_PACKAGES": ("Install apps without asking", "Overlays & System Access", .systemOnly),
        "CHANGE_CONFIGURATION": ("Change system configuration", "Overlays & System Access", .systemOnly),
        "RECEIVE_BOOT_COMPLETED": ("Starts at boot", "Background & Autostart", .normal),
        "WAKE_LOCK": ("Prevents standby", "Background & Autostart", .normal),
        "FOREGROUND_SERVICE": ("Persistent background services", "Background & Autostart", .normal),
        "SCHEDULE_EXACT_ALARM": ("Exact alarms and schedules", "Background & Autostart", .special),
        "USE_EXACT_ALARM": ("Exact alarms (calendar and alarm apps)", "Background & Autostart", .normal),
        "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS": ("Bypass battery optimisation (request)", "Background & Autostart", .normal),
        "RUN_USER_INITIATED_JOBS": ("Background tasks started by the user", "Background & Autostart", .normal),
        "POST_NOTIFICATIONS": ("Show notifications", "Notifications", .dangerous),
        "VIBRATE": ("Vibration", "Notifications", .normal),
        "ACCESS_NOTIFICATION_POLICY": ("Do Not Disturb settings", "Notifications", .normal),
        "INTERNET": ("Internet access", "Network & Internet", .normal),
        "ACCESS_NETWORK_STATE": ("Network status", "Network & Internet", .normal),
        "ACCESS_WIFI_STATE": ("Wi-Fi status", "Network & Internet", .normal),
        "CHANGE_WIFI_STATE": ("Turn Wi-Fi on and off", "Network & Internet", .normal),
        "CHANGE_NETWORK_STATE": ("Change network connection", "Network & Internet", .normal),
        "USE_BIOMETRIC": ("Biometric sign-in", "Hardware & Other", .normal),
        "USE_FINGERPRINT": ("Fingerprint (deprecated)", "Hardware & Other", .normal),
        "FLASHLIGHT": ("Flashlight", "Hardware & Other", .normal),
        "TRANSMIT_IR": ("Send infrared", "Hardware & Other", .normal),
        "SET_WALLPAPER": ("Set wallpaper", "Hardware & Other", .normal),
        "READ_SYNC_SETTINGS": ("Read sync settings", "Hardware & Other", .normal),
        "WRITE_SYNC_SETTINGS": ("Turn sync on and off", "Hardware & Other", .normal),
    ]
    private static let other: [String: Entry] = [
        "com.google.android.gms.permission.AD_ID": ("Read the advertising ID", "Advertising & Tracking", .normal),
        "com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE": ("Query the install source (Install Referrer)", "Advertising & Tracking", .normal),
        "com.google.android.gms.permission.ACTIVITY_RECOGNITION": ("Recognise physical activity (Play services)", "Body & Activity", .dangerous),
        "com.android.vending.BILLING": ("In-app purchases (Google Play)", "Purchases & Licences", .normal),
        "com.android.vending.CHECK_LICENSE": ("Licence check (Google Play)", "Purchases & Licences", .normal),
        "com.google.android.c2dm.permission.RECEIVE": ("Receive push messages (Firebase)", "Push Messages", .normal),
        "com.android.launcher.permission.INSTALL_SHORTCUT": ("Create home screen shortcuts", "Hardware & Other", .normal),
        "com.android.alarm.permission.SET_ALARM": ("Set alarms", "Background & Autostart", .normal),
    ]
    private static let vendors: [(prefix: String, name: String)] = [
        ("com.samsung.", "Samsung"), ("com.sec.", "Samsung"), ("com.huawei.", "Huawei"), ("com.hihonor.", "Honor"), ("com.hihonor.", "Honor"),
        ("com.oppo.", "Oppo"), ("com.coloros.", "Oppo"), ("com.heytap.", "Oppo"), ("com.vivo.", "Vivo"), ("com.xiaomi.", "Xiaomi"),
        ("com.miui.", "Xiaomi"), ("com.htc.", "HTC"), ("com.sonyericsson.", "Sony"), ("com.sonymobile.", "Sony"), ("com.majeur.", "Launcher"),
        ("com.anddoes.", "Launcher"), ("me.everything.", "Launcher"), ("com.amazon.", "Amazon"), ("com.lge.", "LG"), ("com.asus.", "Asus"),
    ]

    public static func describe(_ name: String, ownPackage: String) -> PermissionInfo {
        let known = { (entry: Entry) in PermissionInfo(name: name, label: profileText(entry.label), group: profileText(entry.group), level: entry.level) }
        if name.hasPrefix("android.permission.") {
            let short = String(name.dropFirst("android.permission.".count))
            if let entry = android[short] { return known(entry) }
            if short.hasPrefix("FOREGROUND_SERVICE_") {
                let kind = short.dropFirst("FOREGROUND_SERVICE_".count).lowercased().replacingOccurrences(of: "_", with: " ")
                return PermissionInfo(name: name, label: String(localized: "Background service: \(kind)"), group: profileText("Background & Autostart"), level: .normal)
            }
            return PermissionInfo(name: name, label: short.lowercased().replacingOccurrences(of: "_", with: " ").capitalized, group: profileText("Other"), level: .unknown)
        }
        if let entry = other[name] { return known(entry) }
        if name.hasPrefix(ownPackage + ".") {
            let label = name.hasSuffix(".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION") ? String(localized: "Internal protection of own receivers (automatic)")
                : name.hasSuffix(".C2D_MESSAGE") ? String(localized: "Push messages (app-internal, deprecated)") : String(localized: "App-defined permission")
            return PermissionInfo(name: name, label: label, group: profileText("App-Internal"), level: .appSpecific)
        }
        if let vendor = vendors.first(where: { name.hasPrefix($0.prefix) }) {
            let lower = name.lowercased()
            let topic = lower.contains("badge") ? String(localized: "App icon badge") : (lower.contains("appmarket") || lower.contains("appgallery")) ? String(localized: "App store data")
                : lower.contains("launcher") || lower.contains("shortcut") ? String(localized: "Home screen") : String(localized: "Interface")
            return PermissionInfo(name: name, label: "\(vendor.name): \(topic)", group: profileText("Vendor Interfaces"), level: .vendor)
        }
        return PermissionInfo(name: name, label: name.split(separator: ".").last.map(String.init) ?? name, group: profileText("Other"), level: .unknown)
    }
}

// MARK: Libraries

public struct DetectedSDK: Hashable, Sendable, Identifiable {
    public let name: String
    public let category: String
    /// Where it was found (localized): Java code, native library, library marker.
    public let sources: [String]
    public var id: String { name }
}

public enum SDKCatalog {
    public static let categories = ["Advertising", "Analytics & Attribution", "Crash & Error Reports", "Consent & Privacy", "Login & Social Networks",
                                    "Payments", "Push & Messaging", "Customer Support", "Publisher & Game Services", "Protection & Detection", "Google Services", "Other"].map(profileText)
    public static let trackingCategories: Set<String> = Set(["Advertising", "Analytics & Attribution"].map(profileText))

    struct Rule {
        let name: String, category: String
        var packages: [String] = [], excluding: [String] = [], libraries: [String] = [], markers: [String] = []
    }

    static let rules: [Rule] = [
        Rule(name: "Google AdMob", category: "Advertising", packages: ["com.google.android.gms.ads"], markers: ["play-services-ads"]),
        Rule(name: "AppLovin", category: "Advertising", packages: ["com.applovin"], libraries: ["applovin"]),
        Rule(name: "ironSource / LevelPlay", category: "Advertising", packages: ["com.ironsource", "com.unity3d.mediation"]),
        Rule(name: "Unity Ads", category: "Advertising", packages: ["com.unity3d.ads", "com.unity3d.services"]),
        Rule(name: "Meta Audience Network", category: "Advertising", packages: ["com.facebook.ads"]),
        Rule(name: "Pangle (ByteDance)", category: "Advertising", packages: ["com.bytedance.sdk", "com.bytedance.pangle"], libraries: ["pglarmor", "_pgl", "apminsight", "tt_ugen"]),
        Rule(name: "Mintegral", category: "Advertising", packages: ["com.mbridge", "com.mintegral"]),
        Rule(name: "Vungle / Liftoff", category: "Advertising", packages: ["com.vungle", "com.liftoff"]),
        Rule(name: "Chartboost", category: "Advertising", packages: ["com.chartboost"]),
        Rule(name: "InMobi", category: "Advertising", packages: ["com.inmobi"]),
        Rule(name: "Fyber / Digital Turbine", category: "Advertising", packages: ["com.fyber", "com.digitalturbine"]),
        Rule(name: "Moloco", category: "Advertising", packages: ["com.moloco"]),
        Rule(name: "Bigo Ads", category: "Advertising", packages: ["sg.bigo"]),
        Rule(name: "BidMachine", category: "Advertising", packages: ["io.bidmachine"]),
        Rule(name: "Verve / PubNative", category: "Advertising", packages: ["com.verve", "net.pubnative"]),
        Rule(name: "Ogury", category: "Advertising", packages: ["com.ogury"]),
        Rule(name: "Amazon Publisher Services", category: "Advertising", packages: ["com.amazon.device.ads", "com.amazon.aps"]),
        Rule(name: "Tapjoy", category: "Advertising", packages: ["com.tapjoy"], libraries: ["tapjoy"]),
        Rule(name: "AdColony", category: "Advertising", packages: ["com.adcolony"]),
        Rule(name: "Yandex Ads", category: "Advertising", packages: ["com.yandex.mobile.ads"]),
        Rule(name: "Smaato", category: "Advertising", packages: ["com.smaato"]),
        Rule(name: "FIVE (LINE)", category: "Advertising", packages: ["com.five_corp"]),
        Rule(name: "Start.io", category: "Advertising", packages: ["com.startapp"]),
        Rule(name: "AppsFlyer", category: "Analytics & Attribution", packages: ["com.appsflyer"]),
        Rule(name: "Adjust", category: "Analytics & Attribution", packages: ["com.adjust.sdk"]),
        Rule(name: "Kochava", category: "Analytics & Attribution", packages: ["com.kochava"]),
        Rule(name: "Branch", category: "Analytics & Attribution", packages: ["io.branch"]),
        Rule(name: "Singular", category: "Analytics & Attribution", packages: ["com.singular"]),
        Rule(name: "Google Analytics for Firebase", category: "Analytics & Attribution", packages: ["com.google.firebase.analytics", "com.google.android.gms.measurement"],
             libraries: ["FirebaseCppAnalytics"], markers: ["firebase-analytics", "play-services-measurement"]),
        Rule(name: "Amplitude", category: "Analytics & Attribution", packages: ["com.amplitude"]),
        Rule(name: "Mixpanel", category: "Analytics & Attribution", packages: ["com.mixpanel"]),
        Rule(name: "Flurry", category: "Analytics & Attribution", packages: ["com.flurry"]),
        Rule(name: "GameAnalytics", category: "Analytics & Attribution", packages: ["com.gameanalytics"]),
        Rule(name: "Tenjin", category: "Analytics & Attribution", packages: ["com.tenjin"]),
        Rule(name: "AppMetrica (Yandex)", category: "Analytics & Attribution", packages: ["com.yandex.metrica", "io.appmetrica"]),
        Rule(name: "Huawei Analytics", category: "Analytics & Attribution", packages: ["com.huawei.hms.analytics"]),
        Rule(name: "Firebase Crashlytics", category: "Crash & Error Reports", packages: ["com.google.firebase.crashlytics"], libraries: ["crashlytics"], markers: ["firebase-crashlytics"]),
        Rule(name: "Sentry", category: "Crash & Error Reports", packages: ["io.sentry"], libraries: ["sentry"]),
        Rule(name: "Bugsnag", category: "Crash & Error Reports", packages: ["com.bugsnag"]),
        Rule(name: "Microsoft App Center", category: "Crash & Error Reports", packages: ["com.microsoft.appcenter"]),
        Rule(name: "Instabug", category: "Crash & Error Reports", packages: ["com.instabug"]),
        Rule(name: "Google UMP (Consent)", category: "Consent & Privacy", packages: ["com.google.android.ump"], markers: ["user-messaging-platform"]),
        Rule(name: "OneTrust", category: "Consent & Privacy", packages: ["com.onetrust"]),
        Rule(name: "Usercentrics", category: "Consent & Privacy", packages: ["com.usercentrics"]),
        Rule(name: "Didomi", category: "Consent & Privacy", packages: ["io.didomi"]),
        Rule(name: "Google Sign-In", category: "Login & Social Networks", packages: ["com.google.android.gms.auth"], markers: ["play-services-auth"]),
        Rule(name: "Facebook SDK (Login, Sharing, App Events)", category: "Login & Social Networks", packages: ["com.facebook"], excluding: ["com.facebook.ads", "com.facebook.react"]),
        Rule(name: "X / Twitter", category: "Login & Social Networks", packages: ["com.twitter.sdk"]),
        Rule(name: "LINE", category: "Login & Social Networks", packages: ["com.linecorp"]),
        Rule(name: "VK", category: "Login & Social Networks", packages: ["com.vk.api", "com.vk.sdk"]),
        Rule(name: "WeChat", category: "Login & Social Networks", packages: ["com.tencent.mm.opensdk"]),
        Rule(name: "Google Play Billing", category: "Payments", packages: ["com.android.billingclient"], markers: ["billing"]),
        Rule(name: "Huawei In-App Purchases", category: "Payments", packages: ["com.huawei.hms.iap"]),
        Rule(name: "Stripe", category: "Payments", packages: ["com.stripe"]),
        Rule(name: "PayPal", category: "Payments", packages: ["com.paypal"]),
        Rule(name: "Xsolla", category: "Payments", packages: ["com.xsolla"]),
        Rule(name: "Firebase Cloud Messaging", category: "Push & Messaging", packages: ["com.google.firebase.messaging"],
             libraries: ["FirebaseCppMessaging"], markers: ["firebase-messaging", "play-services-cloud-messaging"]),
        Rule(name: "OneSignal", category: "Push & Messaging", packages: ["com.onesignal"]),
        Rule(name: "Huawei Push", category: "Push & Messaging", packages: ["com.huawei.hms.push"]),
        Rule(name: "Airship", category: "Push & Messaging", packages: ["com.urbanairship"]),
        Rule(name: "Braze", category: "Push & Messaging", packages: ["com.braze", "com.appboy"]),
        Rule(name: "CleverTap", category: "Push & Messaging", packages: ["com.clevertap"]),
        Rule(name: "Helpshift", category: "Customer Support", packages: ["com.helpshift"]),
        Rule(name: "Zendesk", category: "Customer Support", packages: ["zendesk.", "com.zendesk"]),
        Rule(name: "Intercom", category: "Customer Support", packages: ["io.intercom"]),
        Rule(name: "SayKit (SayGames)", category: "Publisher & Game Services", packages: ["saygames", "by.saygames"]),
        Rule(name: "YSO Corp", category: "Publisher & Game Services", packages: ["com.ysocorp"]),
        Rule(name: "Google Play Games", category: "Publisher & Game Services", packages: ["com.google.android.gms.games"], markers: ["play-services-games-v2", "play-services-games"]),
        Rule(name: "Play Integrity (Authenticity Check)", category: "Protection & Detection", packages: ["com.google.android.play.core.integrity"], markers: ["integrity"]),
        Rule(name: "Emulator Detection", category: "Protection & Detection", libraries: ["emulator_check"]),
        Rule(name: "Tencent ACE (Anti-Cheat)", category: "Protection & Detection", libraries: ["anogs", "tersafe"]),
        Rule(name: "NetEase Protection", category: "Protection & Detection", libraries: ["NetHTProtect"]),
        Rule(name: "Jiagu (Code Obfuscation)", category: "Protection & Detection", libraries: ["jiagu"]),
        Rule(name: "Bangcle (Code Obfuscation)", category: "Protection & Detection", libraries: ["DexHelper", "secexe"]),
        Rule(name: "Google Location Services", category: "Google Services", packages: ["com.google.android.gms.location"], markers: ["play-services-location"]),
        Rule(name: "Google Nearby", category: "Google Services", packages: ["com.google.android.gms.nearby"], markers: ["play-services-nearby"]),
        Rule(name: "Play In-App Updates", category: "Google Services", markers: ["app-update"]),
        Rule(name: "Play In-App Review", category: "Google Services", markers: ["review"]),
        Rule(name: "Google ML Kit (Translation, Language ID)", category: "Google Services", libraries: ["translate_jni", "language_id"], markers: ["translate", "language-id"]),
        Rule(name: "TensorFlow Lite (Machine Learning)", category: "Other", libraries: ["tensorflowlite"], markers: ["play-services-tflite-java"]),
        Rule(name: "Cronet (Chrome Network Stack)", category: "Other", libraries: ["cronet"], markers: ["play-services-cronet", "cronet-okhttp"]),
        Rule(name: "xLua (Lua Scripting)", category: "Other", libraries: ["xlua"]),
        Rule(name: "AVPro Video", category: "Other", libraries: ["AVProVideo"]),
    ]

    /// `classes`: Java class or package names (manifest components, DEX inventory); `libraries`: native `.so` file names; `markers`: library marker files without extension.
    public static func detect(classes: Set<String>, libraries: Set<String>, markers: Set<String>) -> [DetectedSDK] {
        rules.compactMap { rule in
            var sources: [String] = []
            let packageHit = classes.contains { name in
                rule.packages.contains { prefix in name == prefix || name.hasPrefix(prefix.hasSuffix(".") ? prefix : prefix + ".") }
                    && !rule.excluding.contains { name == $0 || name.hasPrefix($0 + ".") }
            }
            if packageHit { sources.append(String(localized: "Java code")) }
            if libraries.contains(where: { library in rule.libraries.contains { library.localizedCaseInsensitiveContains($0) } }) { sources.append(String(localized: "native library")) }
            if markers.contains(where: { rule.markers.contains($0) }) { sources.append(String(localized: "library marker")) }
            return sources.isEmpty ? nil : DetectedSDK(name: profileText(rule.name), category: profileText(rule.category), sources: sources)
        }
    }

    /// App frameworks recognised from native library names.
    public static func frameworks(libraries: Set<String>, markers: Set<String>) -> [String] {
        let has = { (name: String) in libraries.contains(name) }
        var result: [String] = []
        if has("libunity.so") { result.append(has("libil2cpp.so") ? "Unity (IL2CPP)" : libraries.contains { $0.hasPrefix("libmono") } ? "Unity (Mono)" : "Unity") }
        if has("libflutter.so") { result.append("Flutter") }
        if has("libreactnativejni.so") || has("libhermes.so") || has("libjsc.so") { result.append("React Native") }
        if has("libUE4.so") || has("libUnreal.so") { result.append("Unreal Engine") }
        if libraries.contains(where: { $0.hasPrefix("libcocos") }) { result.append("Cocos2d-x") }
        if has("libgodot_android.so") { result.append("Godot") }
        if has("libmonodroid.so") || has("libxamarin-app.so") { result.append("Xamarin / .NET") }
        if markers.contains(where: { $0.hasPrefix("androidx.compose.ui_ui") }) { result.append("Jetpack Compose") }
        return result
    }
}

// MARK: Profile

public struct ReachableEntry: Hashable, Sendable {
    /// "screens", "services", "receivers" or "providers".
    public let kind: String
    public let count: Int
    /// "1 screen", "4 screens".
    public var title: String {
        switch (kind, count == 1) {
        case ("screens", true): String(localized: "1 screen")
        case ("screens", false): String(localized: "\(count) screens")
        case ("services", true): String(localized: "1 service")
        case ("services", false): String(localized: "\(count) services")
        case ("receivers", true): String(localized: "1 receiver")
        case ("receivers", false): String(localized: "\(count) receivers")
        case ("providers", true): String(localized: "1 data provider")
        case ("providers", false): String(localized: "\(count) data providers")
        default: "\(count) \(kind)"
        }
    }
}

public struct AppProfile: Sendable {
    public let title: String
    public let packageName: String
    public let versionName: String?
    public let versionCode: String?
    public let minSDK: String?
    public let targetSDK: String?
    public let apkCount: Int
    public let totalBytes: Int64
    public let permissions: [PermissionInfo]
    public let sdks: [DetectedSDK]
    public let frameworks: [String]
    public let abis: [String]
    public let nativeLibraryCount: Int
    public let reachable: [ReachableEntry]
    public let webLinkHosts: [String]
    public let linkSchemes: [String]
    public let cleartextTraffic: Bool
    public let debuggable: Bool
    public let allowBackup: Bool
    /// The stored DEX inventory was cut off, so detection relied on the manifest, native libraries and marker files.
    public let dexInventoryTruncated: Bool

    public static func android(_ sdk: String?) -> String? { sdk.flatMap { AVDSystemInfo.androidVersions[String($0.prefix { $0 != "." })] } }
    public var minAndroid: String? { Self.android(minSDK) }
    public var targetAndroid: String? { Self.android(targetSDK) }
    public var trackingSDKs: [DetectedSDK] { sdks.filter { SDKCatalog.trackingCategories.contains($0.category) } }

    public var permissionsByGroup: [(group: String, items: [PermissionInfo])] {
        PermissionCatalog.groups.compactMap { group in
            let items = permissions.filter { $0.group == group }.sorted { ($0.level, $0.label) < ($1.level, $1.label) }
            return items.isEmpty ? nil : (group, items)
        }
    }

    public var sdksByCategory: [(category: String, items: [DetectedSDK])] {
        SDKCatalog.categories.compactMap { category in
            let items = sdks.filter { $0.category == category }.sorted { $0.name < $1.name }
            return items.isEmpty ? nil : (category, items)
        }
    }

    /// Short, plain-language findings for the top of the profile; `true` marks points worth a closer look.
    public var highlights: [(text: String, notable: Bool)] {
        var result: [(String, Bool)] = []
        let names = Set(permissions.map(\.name))
        let tracking = trackingSDKs.count
        if tracking > 0 { result.append((tracking == 1 ? String(localized: "1 advertising or tracking library") : String(localized: "\(tracking) advertising and tracking libraries"), true)) }
        if names.contains("com.google.android.gms.permission.AD_ID") || names.contains("android.permission.ACCESS_ADSERVICES_AD_ID") { result.append((String(localized: "Reads the advertising ID"), true)) }
        let dangerous = permissions.filter { $0.level == .dangerous }.count
        if dangerous > 0 { result.append((dangerous == 1 ? String(localized: "1 permission needing approval") : String(localized: "\(dangerous) permissions needing approval"), dangerous >= 5)) }
        for special in permissions where special.level == .special { result.append((special.label, true)) }
        if names.contains("android.permission.RECEIVE_BOOT_COMPLETED") { result.append((String(localized: "Starts at boot"), false)) }
        if cleartextTraffic { result.append((String(localized: "Allows unencrypted HTTP"), true)) }
        if debuggable { result.append((String(localized: "Debug build"), true)) }
        if allowBackup { result.append((String(localized: "App data in Android backups"), false)) }
        if sdks.contains(where: { $0.name == profileText("Emulator Detection") }) { result.append((String(localized: "Emulator detection library"), true)) }
        if sdks.contains(where: { $0.name.hasPrefix("xLua") }) { result.append((String(localized: "Contains Lua scripting (xLua)"), true)) }
        let systemOnly = permissions.filter { $0.level == .systemOnly }.count
        if systemOnly > 0 { result.append((systemOnly == 1 ? String(localized: "1 system permission without effect") : String(localized: "\(systemOnly) system permissions without effect"), false)) }
        return result
    }

    /// `entries`: ZIP entry names per APK (base first); `sizes`: byte size per APK.
    public static func build(project: AnalysisProject, entries: [[String]], sizes: [Int64]) -> AppProfile {
        let manifest = project.analysis.manifest
        let paths = entries.flatMap { $0 }
        var libraries: Set<String> = [], abis: Set<String> = []
        for path in paths {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "lib", parts[2].hasSuffix(".so") else { continue }
            abis.insert(String(parts[1])); libraries.insert(String(parts[2]))
        }
        let markers = Set(paths.compactMap { path -> String? in
            if !path.contains("/"), path.hasSuffix(".properties") { return String(path.dropLast(".properties".count)) }
            if path.hasPrefix("META-INF/"), path.hasSuffix(".version"), path.split(separator: "/").count == 2 { return String(path.dropFirst(9).dropLast(8)) }
            return nil
        })
        var classes = Set(manifest.components.map(\.name))
        let inventory = project.analysis.dexInventory.split(whereSeparator: \.isNewline)
        for line in inventory {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 3, fields[0] == "P" || fields[0] == "C", fields[1] == "d", let name = fields.last, name != "<TOTAL>" { classes.insert(String(name)) }
        }
        let packageLines = inventory.filter { $0.hasPrefix("P d") }.count
        let reachable = Self.reachable(manifest.components)
        var hosts: Set<String> = [], schemes: Set<String> = []
        for component in manifest.components where component.actions.contains("android.intent.action.VIEW") && component.categories.contains("android.intent.category.BROWSABLE") {
            for data in component.data {
                guard let scheme = data["scheme"], !scheme.hasPrefix("@") else { continue }
                if scheme == "http" || scheme == "https" { if let host = data["host"], !host.hasPrefix("@") { hosts.insert(host) } } else { schemes.insert(scheme + "://") }
            }
        }
        let application = manifest.application
        return AppProfile(title: project.title, packageName: manifest.packageName, versionName: manifest.versionName, versionCode: manifest.versionCode,
                          minSDK: manifest.minSDK, targetSDK: manifest.targetSDK, apkCount: project.apkFiles.count, totalBytes: sizes.reduce(0, +),
                          permissions: project.analysis.apk.permissions.map { PermissionCatalog.describe($0, ownPackage: manifest.packageName) },
                          sdks: SDKCatalog.detect(classes: classes, libraries: libraries, markers: markers),
                          frameworks: SDKCatalog.frameworks(libraries: libraries, markers: markers), abis: abis.sorted(), nativeLibraryCount: libraries.count,
                          reachable: reachable, webLinkHosts: hosts.sorted(), linkSchemes: schemes.sorted(),
                          cleartextTraffic: application["usesCleartextTraffic"] == "true", debuggable: application["debuggable"] == "true",
                          allowBackup: application["allowBackup"] != "false",
                          dexInventoryTruncated: inventory.count > 1000 && packageLines < 20)
    }

    /// Components other apps can start: explicitly exported, or older manifests with an intent filter and no `exported` value. Providers default to private.
    static func reachable(_ components: [ManifestComponent]) -> [ReachableEntry] {
        let titles = [("activity", "screens"), ("activity-alias", "screens"), ("service", "services"), ("receiver", "receivers"), ("provider", "providers")]
        var counts: [String: Int] = [:]
        for component in components {
            let open = component.exported == "true" || (component.exported == nil && component.kind != "provider" && !component.actions.isEmpty)
            guard open, component.enabled != "false", let title = titles.first(where: { $0.0 == component.kind })?.1 else { continue }
            counts[title, default: 0] += 1
        }
        return ["screens", "services", "receivers", "providers"].compactMap { kind in counts[kind].map { ReachableEntry(kind: kind, count: $0) } }
    }
}

/// Reads the ZIP directories of a project's APKs; nothing is extracted or executed.
public struct AppProfileService: Sendable {
    let runner: any CommandRunning
    public init(runner: any CommandRunning = ProcessCommandRunner()) { self.runner = runner }

    public func profile(project: AnalysisProject, root: URL) async throws -> AppProfile {
        var entries: [[String]] = [], sizes: [Int64] = []
        for apk in project.apkFiles {
            let url = root.appendingPathComponent(apk.relativePath)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            sizes.append(size)
            let result = try await runner.run(Command(executable: URL(fileURLWithPath: "/usr/bin/zipinfo"), arguments: ["-1", url.path], timeout: 60, outputLimit: 64 * 1024 * 1024))
            entries.append(result.status == 0 ? result.text.split(whereSeparator: \.isNewline).map(String.init) : [])
        }
        return AppProfile.build(project: project, entries: entries, sizes: sizes)
    }
}
