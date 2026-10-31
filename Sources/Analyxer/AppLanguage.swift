import SwiftUI
import AppKit

/// UI language: the system default, or an explicit choice stored as the app's own `AppleLanguages`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", german = "de"
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    /// Only the app's own domain counts; `UserDefaults.standard` would also return the system-wide list.
    static var stored: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let first = (domain?["AppleLanguages"] as? [String])?.first
        return AppLanguage.allCases.first { $0 != .system && first?.hasPrefix($0.rawValue) == true } ?? .system
    }

    func store() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
    }
}

extension AnalyxerModel {
    /// Relaunches the installed app so the language choice applies to every window and to Foundation formatting.
    func restartApp() {
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
