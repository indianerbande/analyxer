import Foundation

// MARK: Permissions

/// How Android grants a permission; ordered from most to least noteworthy.
public enum PermissionLevel: Int, Comparable, Sendable, CaseIterable {
    case special, dangerous, systemOnly, normal, vendor, appSpecific, unknown
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var title: String {
        switch self {
        case .special: "Sonderzugriff"
        case .dangerous: "Freigabe nötig"
        case .systemOnly: "nur Systemapps"
        case .normal: "ohne Rückfrage"
        case .vendor: "Hersteller"
        case .appSpecific: "App-intern"
        case .unknown: "unbekannt"
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
    /// Display order of the groups.
    public static let groups = ["Standort", "Kamera & Mikrofon", "Kontakte & Konten", "Kalender", "Telefon & Anrufe", "SMS & MMS",
                                "Fotos, Medien & Dateien", "Körper & Aktivität", "Geräte in der Nähe", "Werbung & Tracking",
                                "Über anderen Apps & Systemzugriff", "Hintergrund & Autostart", "Benachrichtigungen", "Netzwerk & Internet",
                                "Käufe & Lizenzen", "Push-Nachrichten", "Hardware & Sonstiges", "Herstellerschnittstellen", "App-intern", "Sonstiges"]

    private typealias Entry = (label: String, group: String, level: PermissionLevel)
    private static let android: [String: Entry] = [
        "ACCESS_FINE_LOCATION": ("Genauer Standort (GPS)", "Standort", .dangerous),
        "ACCESS_COARSE_LOCATION": ("Ungefährer Standort", "Standort", .dangerous),
        "ACCESS_BACKGROUND_LOCATION": ("Standort auch im Hintergrund", "Standort", .dangerous),
        "ACCESS_MEDIA_LOCATION": ("Aufnahmeorte in Fotos lesen", "Standort", .dangerous),
        "ACCESS_LOCATION_EXTRA_COMMANDS": ("Zusätzliche Standortbefehle", "Standort", .normal),
        "CAMERA": ("Kamera", "Kamera & Mikrofon", .dangerous),
        "RECORD_AUDIO": ("Mikrofon", "Kamera & Mikrofon", .dangerous),
        "MODIFY_AUDIO_SETTINGS": ("Audioeinstellungen ändern", "Kamera & Mikrofon", .normal),
        "READ_CONTACTS": ("Kontakte lesen", "Kontakte & Konten", .dangerous),
        "WRITE_CONTACTS": ("Kontakte ändern", "Kontakte & Konten", .dangerous),
        "GET_ACCOUNTS": ("Konten auf dem Gerät auflisten", "Kontakte & Konten", .dangerous),
        "READ_PROFILE": ("Eigenes Profil lesen (veraltet)", "Kontakte & Konten", .normal),
        "READ_CALENDAR": ("Kalender lesen", "Kalender", .dangerous),
        "WRITE_CALENDAR": ("Kalender ändern", "Kalender", .dangerous),
        "READ_PHONE_STATE": ("Telefonstatus und Gerätekennungen", "Telefon & Anrufe", .dangerous),
        "READ_PHONE_NUMBERS": ("Eigene Telefonnummer", "Telefon & Anrufe", .dangerous),
        "CALL_PHONE": ("Anrufe tätigen", "Telefon & Anrufe", .dangerous),
        "ANSWER_PHONE_CALLS": ("Anrufe annehmen", "Telefon & Anrufe", .dangerous),
        "READ_CALL_LOG": ("Anrufliste lesen", "Telefon & Anrufe", .dangerous),
        "WRITE_CALL_LOG": ("Anrufliste ändern", "Telefon & Anrufe", .dangerous),
        "PROCESS_OUTGOING_CALLS": ("Ausgehende Anrufe umleiten", "Telefon & Anrufe", .dangerous),
        "ADD_VOICEMAIL": ("Mailbox-Nachrichten hinzufügen", "Telefon & Anrufe", .dangerous),
        "USE_SIP": ("Internettelefonie (SIP)", "Telefon & Anrufe", .dangerous),
        "MANAGE_OWN_CALLS": ("Eigene Anrufe verwalten", "Telefon & Anrufe", .normal),
        "READ_PRIVILEGED_PHONE_STATE": ("Geschützte Telefonkennungen", "Telefon & Anrufe", .systemOnly),
        "SEND_SMS": ("SMS senden", "SMS & MMS", .dangerous),
        "RECEIVE_SMS": ("SMS empfangen", "SMS & MMS", .dangerous),
        "READ_SMS": ("SMS lesen", "SMS & MMS", .dangerous),
        "RECEIVE_MMS": ("MMS empfangen", "SMS & MMS", .dangerous),
        "RECEIVE_WAP_PUSH": ("WAP-Push empfangen", "SMS & MMS", .dangerous),
        "READ_EXTERNAL_STORAGE": ("Gemeinsamen Speicher lesen", "Fotos, Medien & Dateien", .dangerous),
        "WRITE_EXTERNAL_STORAGE": ("Gemeinsamen Speicher schreiben", "Fotos, Medien & Dateien", .dangerous),
        "READ_MEDIA_IMAGES": ("Fotos lesen", "Fotos, Medien & Dateien", .dangerous),
        "READ_MEDIA_VIDEO": ("Videos lesen", "Fotos, Medien & Dateien", .dangerous),
        "READ_MEDIA_AUDIO": ("Musik und Audio lesen", "Fotos, Medien & Dateien", .dangerous),
        "READ_MEDIA_VISUAL_USER_SELECTED": ("Vom Nutzer ausgewählte Fotos und Videos", "Fotos, Medien & Dateien", .dangerous),
        "MANAGE_EXTERNAL_STORAGE": ("Zugriff auf alle Dateien", "Fotos, Medien & Dateien", .special),
        "MANAGE_MEDIA": ("Medien ohne Rückfrage ändern", "Fotos, Medien & Dateien", .special),
        "MOUNT_UNMOUNT_FILESYSTEMS": ("Speicher ein- und aushängen", "Fotos, Medien & Dateien", .systemOnly),
        "BODY_SENSORS": ("Körpersensoren (z. B. Puls)", "Körper & Aktivität", .dangerous),
        "BODY_SENSORS_BACKGROUND": ("Körpersensoren im Hintergrund", "Körper & Aktivität", .dangerous),
        "ACTIVITY_RECOGNITION": ("Körperliche Aktivität erkennen", "Körper & Aktivität", .dangerous),
        "HIGH_SAMPLING_RATE_SENSORS": ("Bewegungssensoren mit hoher Rate", "Körper & Aktivität", .normal),
        "BLUETOOTH": ("Bluetooth", "Geräte in der Nähe", .normal),
        "BLUETOOTH_ADMIN": ("Bluetooth verwalten", "Geräte in der Nähe", .normal),
        "BLUETOOTH_SCAN": ("Bluetooth-Geräte suchen", "Geräte in der Nähe", .dangerous),
        "BLUETOOTH_CONNECT": ("Mit Bluetooth-Geräten verbinden", "Geräte in der Nähe", .dangerous),
        "BLUETOOTH_ADVERTISE": ("Für Bluetooth-Geräte sichtbar werden", "Geräte in der Nähe", .dangerous),
        "NEARBY_WIFI_DEVICES": ("WLAN-Geräte in der Nähe", "Geräte in der Nähe", .dangerous),
        "UWB_RANGING": ("Ultrabreitband-Ortung", "Geräte in der Nähe", .dangerous),
        "NFC": ("NFC", "Geräte in der Nähe", .normal),
        "CHANGE_WIFI_MULTICAST_STATE": ("WLAN-Multicast empfangen", "Geräte in der Nähe", .normal),
        "ACCESS_ADSERVICES_AD_ID": ("Werbe-ID (Privacy Sandbox)", "Werbung & Tracking", .normal),
        "ACCESS_ADSERVICES_ATTRIBUTION": ("Werbe-Attribution (Privacy Sandbox)", "Werbung & Tracking", .normal),
        "ACCESS_ADSERVICES_TOPICS": ("Interessen-Themen für Werbung", "Werbung & Tracking", .normal),
        "ACCESS_ADSERVICES_CUSTOM_AUDIENCE": ("Werbe-Zielgruppen (Protected Audience)", "Werbung & Tracking", .normal),
        "SYSTEM_ALERT_WINDOW": ("Über anderen Apps einblenden", "Über anderen Apps & Systemzugriff", .special),
        "WRITE_SETTINGS": ("Systemeinstellungen ändern", "Über anderen Apps & Systemzugriff", .special),
        "PACKAGE_USAGE_STATS": ("Nutzungsstatistik anderer Apps", "Über anderen Apps & Systemzugriff", .special),
        "REQUEST_INSTALL_PACKAGES": ("Andere Apps installieren", "Über anderen Apps & Systemzugriff", .special),
        "USE_FULL_SCREEN_INTENT": ("Vollbild-Benachrichtigungen", "Über anderen Apps & Systemzugriff", .special),
        "QUERY_ALL_PACKAGES": ("Alle installierten Apps sehen", "Über anderen Apps & Systemzugriff", .normal),
        "REQUEST_DELETE_PACKAGES": ("Deinstallation anderer Apps anfragen", "Über anderen Apps & Systemzugriff", .normal),
        "KILL_BACKGROUND_PROCESSES": ("Hintergrundprozesse anderer Apps beenden", "Über anderen Apps & Systemzugriff", .normal),
        "GET_TASKS": ("Laufende Apps abfragen (veraltet)", "Über anderen Apps & Systemzugriff", .normal),
        "REORDER_TASKS": ("Laufende Apps nach vorn holen", "Über anderen Apps & Systemzugriff", .normal),
        "DISABLE_KEYGUARD": ("Displaysperre aufheben", "Über anderen Apps & Systemzugriff", .normal),
        "EXPAND_STATUS_BAR": ("Statusleiste aufklappen", "Über anderen Apps & Systemzugriff", .normal),
        "READ_LOGS": ("Systemprotokolle lesen", "Über anderen Apps & Systemzugriff", .systemOnly),
        "WRITE_SECURE_SETTINGS": ("Geschützte Einstellungen ändern", "Über anderen Apps & Systemzugriff", .systemOnly),
        "INSTALL_PACKAGES": ("Apps ohne Rückfrage installieren", "Über anderen Apps & Systemzugriff", .systemOnly),
        "CHANGE_CONFIGURATION": ("Systemkonfiguration ändern", "Über anderen Apps & Systemzugriff", .systemOnly),
        "RECEIVE_BOOT_COMPLETED": ("Startet beim Hochfahren", "Hintergrund & Autostart", .normal),
        "WAKE_LOCK": ("Verhindert Standby", "Hintergrund & Autostart", .normal),
        "FOREGROUND_SERVICE": ("Dauerhafte Hintergrunddienste", "Hintergrund & Autostart", .normal),
        "SCHEDULE_EXACT_ALARM": ("Exakte Wecker und Zeitpläne", "Hintergrund & Autostart", .special),
        "USE_EXACT_ALARM": ("Exakte Wecker (Kalender-/Weckerapps)", "Hintergrund & Autostart", .normal),
        "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS": ("Akku-Optimierung umgehen (anfragen)", "Hintergrund & Autostart", .normal),
        "RUN_USER_INITIATED_JOBS": ("Vom Nutzer gestartete Hintergrundaufgaben", "Hintergrund & Autostart", .normal),
        "POST_NOTIFICATIONS": ("Benachrichtigungen anzeigen", "Benachrichtigungen", .dangerous),
        "VIBRATE": ("Vibration", "Benachrichtigungen", .normal),
        "ACCESS_NOTIFICATION_POLICY": ("Nicht-stören-Einstellungen", "Benachrichtigungen", .normal),
        "INTERNET": ("Internetzugriff", "Netzwerk & Internet", .normal),
        "ACCESS_NETWORK_STATE": ("Netzwerkstatus", "Netzwerk & Internet", .normal),
        "ACCESS_WIFI_STATE": ("WLAN-Status", "Netzwerk & Internet", .normal),
        "CHANGE_WIFI_STATE": ("WLAN ein- und ausschalten", "Netzwerk & Internet", .normal),
        "CHANGE_NETWORK_STATE": ("Netzwerkverbindung ändern", "Netzwerk & Internet", .normal),
        "USE_BIOMETRIC": ("Biometrische Anmeldung", "Hardware & Sonstiges", .normal),
        "USE_FINGERPRINT": ("Fingerabdruck (veraltet)", "Hardware & Sonstiges", .normal),
        "FLASHLIGHT": ("Taschenlampe", "Hardware & Sonstiges", .normal),
        "TRANSMIT_IR": ("Infrarot senden", "Hardware & Sonstiges", .normal),
        "SET_WALLPAPER": ("Hintergrundbild setzen", "Hardware & Sonstiges", .normal),
        "READ_SYNC_SETTINGS": ("Synchronisierungseinstellungen lesen", "Hardware & Sonstiges", .normal),
        "WRITE_SYNC_SETTINGS": ("Synchronisierung ein- und ausschalten", "Hardware & Sonstiges", .normal),
    ]
    private static let other: [String: Entry] = [
        "com.google.android.gms.permission.AD_ID": ("Werbe-ID lesen", "Werbung & Tracking", .normal),
        "com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE": ("Installationsquelle abfragen (Install Referrer)", "Werbung & Tracking", .normal),
        "com.google.android.gms.permission.ACTIVITY_RECOGNITION": ("Körperliche Aktivität erkennen (Play-Dienste)", "Körper & Aktivität", .dangerous),
        "com.android.vending.BILLING": ("In-App-Käufe (Google Play)", "Käufe & Lizenzen", .normal),
        "com.android.vending.CHECK_LICENSE": ("Lizenzprüfung (Google Play)", "Käufe & Lizenzen", .normal),
        "com.google.android.c2dm.permission.RECEIVE": ("Push-Nachrichten empfangen (Firebase)", "Push-Nachrichten", .normal),
        "com.android.launcher.permission.INSTALL_SHORTCUT": ("Verknüpfungen auf dem Startbildschirm anlegen", "Hardware & Sonstiges", .normal),
        "com.android.alarm.permission.SET_ALARM": ("Wecker stellen", "Hintergrund & Autostart", .normal),
    ]
    private static let vendors: [(prefix: String, name: String)] = [
        ("com.samsung.", "Samsung"), ("com.sec.", "Samsung"), ("com.huawei.", "Huawei"), ("com.hihonor.", "Honor"), ("com.hihonor.", "Honor"),
        ("com.oppo.", "Oppo"), ("com.coloros.", "Oppo"), ("com.heytap.", "Oppo"), ("com.vivo.", "Vivo"), ("com.xiaomi.", "Xiaomi"),
        ("com.miui.", "Xiaomi"), ("com.htc.", "HTC"), ("com.sonyericsson.", "Sony"), ("com.sonymobile.", "Sony"), ("com.majeur.", "Launcher"),
        ("com.anddoes.", "Launcher"), ("me.everything.", "Launcher"), ("com.amazon.", "Amazon"), ("com.lge.", "LG"), ("com.asus.", "Asus"),
    ]

    public static func describe(_ name: String, ownPackage: String) -> PermissionInfo {
        if name.hasPrefix("android.permission.") {
            let short = String(name.dropFirst("android.permission.".count))
            if let entry = android[short] { return PermissionInfo(name: name, label: entry.label, group: entry.group, level: entry.level) }
            if short.hasPrefix("FOREGROUND_SERVICE_") {
                let kind = short.dropFirst("FOREGROUND_SERVICE_".count).lowercased().replacingOccurrences(of: "_", with: " ")
                return PermissionInfo(name: name, label: "Hintergrunddienst: \(kind)", group: "Hintergrund & Autostart", level: .normal)
            }
            return PermissionInfo(name: name, label: short.lowercased().replacingOccurrences(of: "_", with: " ").capitalized, group: "Sonstiges", level: .unknown)
        }
        if let entry = other[name] { return PermissionInfo(name: name, label: entry.label, group: entry.group, level: entry.level) }
        if name.hasPrefix(ownPackage + ".") {
            let label = name.hasSuffix(".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION") ? "Interne Absicherung eigener Empfänger (automatisch)"
                : name.hasSuffix(".C2D_MESSAGE") ? "Push-Nachrichten (App-intern, veraltet)" : "App-eigene Berechtigung"
            return PermissionInfo(name: name, label: label, group: "App-intern", level: .appSpecific)
        }
        if let vendor = vendors.first(where: { name.hasPrefix($0.prefix) }) {
            let lower = name.lowercased()
            let topic = lower.contains("badge") ? "App-Symbol-Zähler" : (lower.contains("appmarket") || lower.contains("appgallery")) ? "App-Store-Daten"
                : lower.contains("launcher") || lower.contains("shortcut") ? "Startbildschirm" : "Schnittstelle"
            return PermissionInfo(name: name, label: "\(vendor.name): \(topic)", group: "Herstellerschnittstellen", level: .vendor)
        }
        return PermissionInfo(name: name, label: name.split(separator: ".").last.map(String.init) ?? name, group: "Sonstiges", level: .unknown)
    }
}

// MARK: Libraries

public struct DetectedSDK: Hashable, Sendable, Identifiable {
    public let name: String
    public let category: String
    /// Where it was found: Manifest, native Bibliothek, Bibliothekskennung, DEX.
    public let sources: [String]
    public var id: String { name }
}

public enum SDKCatalog {
    public static let categories = ["Werbung", "Analyse & Attribution", "Absturz- & Fehlerberichte", "Einwilligung & Datenschutz", "Login & Soziale Netzwerke",
                                    "Zahlungen", "Push & Kommunikation", "Kundenservice", "Publisher & Spieledienste", "Schutz & Erkennung", "Google-Dienste", "Sonstiges"]
    public static let trackingCategories: Set<String> = ["Werbung", "Analyse & Attribution"]

    struct Rule {
        let name: String, category: String
        var packages: [String] = [], excluding: [String] = [], libraries: [String] = [], markers: [String] = []
    }

    static let rules: [Rule] = [
        Rule(name: "Google AdMob", category: "Werbung", packages: ["com.google.android.gms.ads"], markers: ["play-services-ads"]),
        Rule(name: "AppLovin", category: "Werbung", packages: ["com.applovin"], libraries: ["applovin"]),
        Rule(name: "ironSource / LevelPlay", category: "Werbung", packages: ["com.ironsource", "com.unity3d.mediation"]),
        Rule(name: "Unity Ads", category: "Werbung", packages: ["com.unity3d.ads", "com.unity3d.services"]),
        Rule(name: "Meta Audience Network", category: "Werbung", packages: ["com.facebook.ads"]),
        Rule(name: "Pangle (ByteDance)", category: "Werbung", packages: ["com.bytedance.sdk", "com.bytedance.pangle"], libraries: ["pglarmor", "_pgl", "apminsight", "tt_ugen"]),
        Rule(name: "Mintegral", category: "Werbung", packages: ["com.mbridge", "com.mintegral"]),
        Rule(name: "Vungle / Liftoff", category: "Werbung", packages: ["com.vungle", "com.liftoff"]),
        Rule(name: "Chartboost", category: "Werbung", packages: ["com.chartboost"]),
        Rule(name: "InMobi", category: "Werbung", packages: ["com.inmobi"]),
        Rule(name: "Fyber / Digital Turbine", category: "Werbung", packages: ["com.fyber", "com.digitalturbine"]),
        Rule(name: "Moloco", category: "Werbung", packages: ["com.moloco"]),
        Rule(name: "Bigo Ads", category: "Werbung", packages: ["sg.bigo"]),
        Rule(name: "BidMachine", category: "Werbung", packages: ["io.bidmachine"]),
        Rule(name: "Verve / PubNative", category: "Werbung", packages: ["com.verve", "net.pubnative"]),
        Rule(name: "Ogury", category: "Werbung", packages: ["com.ogury"]),
        Rule(name: "Amazon Publisher Services", category: "Werbung", packages: ["com.amazon.device.ads", "com.amazon.aps"]),
        Rule(name: "Tapjoy", category: "Werbung", packages: ["com.tapjoy"], libraries: ["tapjoy"]),
        Rule(name: "AdColony", category: "Werbung", packages: ["com.adcolony"]),
        Rule(name: "Yandex Ads", category: "Werbung", packages: ["com.yandex.mobile.ads"]),
        Rule(name: "Smaato", category: "Werbung", packages: ["com.smaato"]),
        Rule(name: "FIVE (LINE)", category: "Werbung", packages: ["com.five_corp"]),
        Rule(name: "Start.io", category: "Werbung", packages: ["com.startapp"]),
        Rule(name: "AppsFlyer", category: "Analyse & Attribution", packages: ["com.appsflyer"]),
        Rule(name: "Adjust", category: "Analyse & Attribution", packages: ["com.adjust.sdk"]),
        Rule(name: "Kochava", category: "Analyse & Attribution", packages: ["com.kochava"]),
        Rule(name: "Branch", category: "Analyse & Attribution", packages: ["io.branch"]),
        Rule(name: "Singular", category: "Analyse & Attribution", packages: ["com.singular"]),
        Rule(name: "Google Analytics for Firebase", category: "Analyse & Attribution", packages: ["com.google.firebase.analytics", "com.google.android.gms.measurement"],
             libraries: ["FirebaseCppAnalytics"], markers: ["firebase-analytics", "play-services-measurement"]),
        Rule(name: "Amplitude", category: "Analyse & Attribution", packages: ["com.amplitude"]),
        Rule(name: "Mixpanel", category: "Analyse & Attribution", packages: ["com.mixpanel"]),
        Rule(name: "Flurry", category: "Analyse & Attribution", packages: ["com.flurry"]),
        Rule(name: "GameAnalytics", category: "Analyse & Attribution", packages: ["com.gameanalytics"]),
        Rule(name: "Tenjin", category: "Analyse & Attribution", packages: ["com.tenjin"]),
        Rule(name: "AppMetrica (Yandex)", category: "Analyse & Attribution", packages: ["com.yandex.metrica", "io.appmetrica"]),
        Rule(name: "Huawei Analytics", category: "Analyse & Attribution", packages: ["com.huawei.hms.analytics"]),
        Rule(name: "Firebase Crashlytics", category: "Absturz- & Fehlerberichte", packages: ["com.google.firebase.crashlytics"], libraries: ["crashlytics"], markers: ["firebase-crashlytics"]),
        Rule(name: "Sentry", category: "Absturz- & Fehlerberichte", packages: ["io.sentry"], libraries: ["sentry"]),
        Rule(name: "Bugsnag", category: "Absturz- & Fehlerberichte", packages: ["com.bugsnag"]),
        Rule(name: "Microsoft App Center", category: "Absturz- & Fehlerberichte", packages: ["com.microsoft.appcenter"]),
        Rule(name: "Instabug", category: "Absturz- & Fehlerberichte", packages: ["com.instabug"]),
        Rule(name: "Google UMP (Einwilligung)", category: "Einwilligung & Datenschutz", packages: ["com.google.android.ump"], markers: ["user-messaging-platform"]),
        Rule(name: "OneTrust", category: "Einwilligung & Datenschutz", packages: ["com.onetrust"]),
        Rule(name: "Usercentrics", category: "Einwilligung & Datenschutz", packages: ["com.usercentrics"]),
        Rule(name: "Didomi", category: "Einwilligung & Datenschutz", packages: ["io.didomi"]),
        Rule(name: "Google-Anmeldung", category: "Login & Soziale Netzwerke", packages: ["com.google.android.gms.auth"], markers: ["play-services-auth"]),
        Rule(name: "Facebook-SDK (Login, Teilen, App Events)", category: "Login & Soziale Netzwerke", packages: ["com.facebook"], excluding: ["com.facebook.ads", "com.facebook.react"]),
        Rule(name: "X / Twitter", category: "Login & Soziale Netzwerke", packages: ["com.twitter.sdk"]),
        Rule(name: "LINE", category: "Login & Soziale Netzwerke", packages: ["com.linecorp"]),
        Rule(name: "VK", category: "Login & Soziale Netzwerke", packages: ["com.vk.api", "com.vk.sdk"]),
        Rule(name: "WeChat", category: "Login & Soziale Netzwerke", packages: ["com.tencent.mm.opensdk"]),
        Rule(name: "Google Play Billing", category: "Zahlungen", packages: ["com.android.billingclient"], markers: ["billing"]),
        Rule(name: "Huawei In-App-Käufe", category: "Zahlungen", packages: ["com.huawei.hms.iap"]),
        Rule(name: "Stripe", category: "Zahlungen", packages: ["com.stripe"]),
        Rule(name: "PayPal", category: "Zahlungen", packages: ["com.paypal"]),
        Rule(name: "Xsolla", category: "Zahlungen", packages: ["com.xsolla"]),
        Rule(name: "Firebase Cloud Messaging", category: "Push & Kommunikation", packages: ["com.google.firebase.messaging"],
             libraries: ["FirebaseCppMessaging"], markers: ["firebase-messaging", "play-services-cloud-messaging"]),
        Rule(name: "OneSignal", category: "Push & Kommunikation", packages: ["com.onesignal"]),
        Rule(name: "Huawei Push", category: "Push & Kommunikation", packages: ["com.huawei.hms.push"]),
        Rule(name: "Airship", category: "Push & Kommunikation", packages: ["com.urbanairship"]),
        Rule(name: "Braze", category: "Push & Kommunikation", packages: ["com.braze", "com.appboy"]),
        Rule(name: "CleverTap", category: "Push & Kommunikation", packages: ["com.clevertap"]),
        Rule(name: "Helpshift", category: "Kundenservice", packages: ["com.helpshift"]),
        Rule(name: "Zendesk", category: "Kundenservice", packages: ["zendesk.", "com.zendesk"]),
        Rule(name: "Intercom", category: "Kundenservice", packages: ["io.intercom"]),
        Rule(name: "SayKit (SayGames)", category: "Publisher & Spieledienste", packages: ["saygames", "by.saygames"]),
        Rule(name: "YSO Corp", category: "Publisher & Spieledienste", packages: ["com.ysocorp"]),
        Rule(name: "Google Play Spiele", category: "Publisher & Spieledienste", packages: ["com.google.android.gms.games"], markers: ["play-services-games-v2", "play-services-games"]),
        Rule(name: "Play Integrity (Echtheitsprüfung)", category: "Schutz & Erkennung", packages: ["com.google.android.play.core.integrity"], markers: ["integrity"]),
        Rule(name: "Emulator-Erkennung", category: "Schutz & Erkennung", libraries: ["emulator_check"]),
        Rule(name: "Tencent ACE (Anti-Cheat)", category: "Schutz & Erkennung", libraries: ["anogs", "tersafe"]),
        Rule(name: "NetEase-Schutz", category: "Schutz & Erkennung", libraries: ["NetHTProtect"]),
        Rule(name: "Jiagu (Code-Verschleierung)", category: "Schutz & Erkennung", libraries: ["jiagu"]),
        Rule(name: "Bangcle (Code-Verschleierung)", category: "Schutz & Erkennung", libraries: ["DexHelper", "secexe"]),
        Rule(name: "Google-Standortdienste", category: "Google-Dienste", packages: ["com.google.android.gms.location"], markers: ["play-services-location"]),
        Rule(name: "Google Nearby", category: "Google-Dienste", packages: ["com.google.android.gms.nearby"], markers: ["play-services-nearby"]),
        Rule(name: "Play In-App-Updates", category: "Google-Dienste", markers: ["app-update"]),
        Rule(name: "Play In-App-Bewertung", category: "Google-Dienste", markers: ["review"]),
        Rule(name: "Google ML Kit (Übersetzung, Spracherkennung)", category: "Google-Dienste", libraries: ["translate_jni", "language_id"], markers: ["translate", "language-id"]),
        Rule(name: "TensorFlow Lite (maschinelles Lernen)", category: "Sonstiges", libraries: ["tensorflowlite"], markers: ["play-services-tflite-java"]),
        Rule(name: "Cronet (Chrome-Netzwerkstack)", category: "Sonstiges", libraries: ["cronet"], markers: ["play-services-cronet", "cronet-okhttp"]),
        Rule(name: "xLua (Lua-Skripting)", category: "Sonstiges", libraries: ["xlua"]),
        Rule(name: "AVPro Video", category: "Sonstiges", libraries: ["AVProVideo"]),
    ]

    /// `classes`: Java class or package names (manifest components, DEX inventory); `libraries`: native `.so` file names; `markers`: library marker files without extension.
    public static func detect(classes: Set<String>, libraries: Set<String>, markers: Set<String>) -> [DetectedSDK] {
        rules.compactMap { rule in
            var sources: [String] = []
            let packageHit = classes.contains { name in
                rule.packages.contains { prefix in name == prefix || name.hasPrefix(prefix.hasSuffix(".") ? prefix : prefix + ".") }
                    && !rule.excluding.contains { name == $0 || name.hasPrefix($0 + ".") }
            }
            if packageHit { sources.append("Java-Code") }
            if libraries.contains(where: { library in rule.libraries.contains { library.localizedCaseInsensitiveContains($0) } }) { sources.append("native Bibliothek") }
            if markers.contains(where: { rule.markers.contains($0) }) { sources.append("Bibliothekskennung") }
            return sources.isEmpty ? nil : DetectedSDK(name: rule.name, category: rule.category, sources: sources)
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
    public let kind: String
    public let count: Int
    /// "1 Bildschirm", "4 Bildschirme".
    public var title: String { "\(count) \(count == 1 ? ["Bildschirme": "Bildschirm", "Dienste": "Dienst"][kind] ?? kind : kind)" }
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
        if !trackingSDKs.isEmpty { result.append(("\(trackingSDKs.count) Werbe- und Tracking-Bibliothek\(trackingSDKs.count == 1 ? "" : "en")", true)) }
        if names.contains("com.google.android.gms.permission.AD_ID") || names.contains("android.permission.ACCESS_ADSERVICES_AD_ID") { result.append(("Liest die Werbe-ID", true)) }
        let dangerous = permissions.filter { $0.level == .dangerous }.count
        if dangerous > 0 { result.append(("\(dangerous) Berechtigung\(dangerous == 1 ? "" : "en") mit Freigabe", dangerous >= 5)) }
        for special in permissions where special.level == .special { result.append((special.label, true)) }
        if names.contains("android.permission.RECEIVE_BOOT_COMPLETED") { result.append(("Startet beim Hochfahren", false)) }
        if cleartextTraffic { result.append(("Erlaubt unverschlüsseltes HTTP", true)) }
        if debuggable { result.append(("Debug-Build", true)) }
        if allowBackup { result.append(("App-Daten in Android-Backups", false)) }
        if sdks.contains(where: { $0.name == "Emulator-Erkennung" }) { result.append(("Bibliothek zur Emulator-Erkennung", true)) }
        if sdks.contains(where: { $0.name.hasPrefix("xLua") }) { result.append(("Enthält Lua-Skripting (xLua)", true)) }
        let systemOnly = permissions.filter { $0.level == .systemOnly }.count
        if systemOnly > 0 { result.append(("\(systemOnly) Systemberechtigung\(systemOnly == 1 ? "" : "en") ohne Wirkung", false)) }
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
        let titles = [("activity", "Bildschirme"), ("activity-alias", "Bildschirme"), ("service", "Dienste"), ("receiver", "Empfänger"), ("provider", "Datenanbieter")]
        var counts: [String: Int] = [:]
        for component in components {
            let open = component.exported == "true" || (component.exported == nil && component.kind != "provider" && !component.actions.isEmpty)
            guard open, component.enabled != "false", let title = titles.first(where: { $0.0 == component.kind })?.1 else { continue }
            counts[title, default: 0] += 1
        }
        return ["Bildschirme", "Dienste", "Empfänger", "Datenanbieter"].compactMap { kind in counts[kind].map { ReachableEntry(kind: kind, count: $0) } }
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
