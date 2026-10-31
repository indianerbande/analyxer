import Foundation

public enum PlayDeviceLayout: String, CaseIterable, Identifiable, Sendable {
    case tablet, phone
    public var id: String { rawValue }
    public var title: String { self == .tablet ? String(localized: "Tablet · Landscape") : String(localized: "Phone · Portrait") }
    var hardwareProfile: String { self == .tablet ? "pixel_tablet" : "pixel_6" }
    var displaySettings: [String: String] {
        switch self {
        case .tablet: return ["hw.lcd.width": "1920", "hw.lcd.height": "1200", "hw.lcd.density": "240", "hw.initialOrientation": "landscape", "skin.name": "1920x1200", "skin.path": "_no_skin", "skin.dynamic": "yes"]
        case .phone: return [:]
        }
    }
}

public struct PlaySystemImage: Identifiable, Hashable, Sendable {
    public let package: String
    public let api: String
    public let abi: String
    public var id: String { package }
    public var title: String { "Google Play · API \(api) · \(abi)" }
}

/// Own AVD catalogue; ordinary Android Studio AVDs are never overwritten.
public struct PlayDeviceService: Sendable {
    public let service: EmulatorService
    public let home: URL
    /// Without an explicit choice the own catalogue sits next to the SDK (`<SDK parent folder>/avd`), never in the user's Library.
    public static func defaultHome(sdkRoot: URL) -> URL {
        sdkRoot.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("avd", isDirectory: true)
    }
    public init(service: EmulatorService, home: URL? = nil) { self.service = service; self.home = home ?? Self.defaultHome(sdkRoot: service.paths.root) }

    public func installedImages() -> [PlaySystemImage] {
        #if arch(arm64)
        let abi = "arm64-v8a"
        #else
        let abi = "x86_64"
        #endif
        let base = service.paths.root.appendingPathComponent("system-images")
        let platforms = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return platforms.compactMap { platform in
            let directory = platform.appendingPathComponent("google_apis_playstore/" + abi)
            guard let properties = try? String(contentsOf: directory.appendingPathComponent("source.properties"), encoding: .utf8),
                  properties.contains("SystemImage.TagId=google_apis_playstore"),
                  !properties.contains("AndroidVersion.CodeName="),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.img").path),
                  platform.lastPathComponent.range(of: #"^android-[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
            return PlaySystemImage(package: "system-images;\(platform.lastPathComponent);google_apis_playstore;\(abi)", api: String(platform.lastPathComponent.dropFirst(8)), abi: abi)
        }.sorted { $0.api.compare($1.api, options: .numeric) == .orderedDescending }
    }

    public func sharesCatalogue(with standardHome: URL = EmulatorService.standardAVDHome()) -> Bool {
        home.resolvingSymlinksInPath().standardizedFileURL.path == standardHome.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Entries of Android's ordinary catalogue that are not already listed here; none when both are the same folder.
    public func foreignAVDs(_ listed: [AVD], standardHome: URL = EmulatorService.standardAVDHome()) -> [AVD] {
        sharesCatalogue(with: standardHome) ? [] : listed
    }

    public func avds() -> [AVD] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "ini" }.map { AVD(name: $0.deletingPathExtension().lastPathComponent, home: home) }.sorted { $0.name < $1.name }
    }

    public func create(name: String, image: PlaySystemImage, layout: PlayDeviceLayout = .phone) async throws -> AVD {
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "Device name: letters, digits, underscore or hyphen; at most 64 characters."))
        }
        guard installedImages().contains(image) else { throw AndroidAnalyxerError.invalidInput(String(localized: "Choose an installed Google Play system image for this Mac.")) }
        guard let tool = service.paths.avdmanager else { throw AndroidAnalyxerError.missingTool("avdmanager (Command-line Tools)") }
        let existing = try await service.avds()
        guard !existing.contains(where: { $0.name == name }), !FileManager.default.fileExists(atPath: home.appendingPathComponent(name + ".ini").path),
              !FileManager.default.fileExists(atPath: home.appendingPathComponent(name + ".avd").path) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "A device with this name already exists. Choose a new name."))
        }
        let java = try await service.runner.run(Command(executable: URL(fileURLWithPath: "/usr/libexec/java_home"), arguments: []))
        let javaHome = java.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard java.status == 0, javaHome.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: javaHome + "/bin/java") else { throw AndroidAnalyxerError.missingTool(String(localized: "Java JDK for avdmanager")) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = try await service.runner.run(Command(executable: tool,
            arguments: ["create", "avd", "--name", name, "--package", image.package, "--device", layout.hardwareProfile, "--path", home.appendingPathComponent(name + ".avd").path], timeout: 120,
            environment: ["JAVA_HOME": javaHome, "ANDROID_AVD_HOME": home.path, "ANDROID_USER_HOME": home.deletingLastPathComponent().appendingPathComponent("android").path]))
        guard result.status == 0, avds().contains(where: { $0.name == name }) else {
            throw AndroidAnalyxerError.failed(String(localized: "The device could not be created: \(String(String(decoding: result.stderr + result.stdout, as: UTF8.self).prefix(3000)))"))
        }
        let configURL = home.appendingPathComponent(name + ".avd/config.ini")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        let values = layout.displaySettings.merging(["PlayStore.enabled": "yes", "avd.ini.displayname": name, "AvdId": name, "hw.keyboard": "yes", "hw.keyboard.lid": "no"]) { _, value in value }
        for (key, value) in values {
            config = config.components(separatedBy: .newlines).filter { !$0.hasPrefix(key + "=") }.joined(separator: "\n")
            config += "\n\(key)=\(value)\n"
        }
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        return AVD(name: name, home: home)
    }

    static let namePattern = #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#

    private enum DeviceAction { case delete, rename }

    /// Files of an own, stopped device; Android Studio devices, foreign paths and running emulators are refused.
    private func ownStoppedDevice(_ name: String, action: DeviceAction) async throws -> (ini: URL, folder: URL) {
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "Invalid device name."))
        }
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        let ini = home.appendingPathComponent(name + ".ini"), folder = home.appendingPathComponent(name + ".avd", isDirectory: true)
        guard avds().contains(where: { $0.name == name }), FileManager.default.fileExists(atPath: ini.path) else {
            throw AndroidAnalyxerError.invalidInput(action == .delete
                ? String(localized: "\(name) is not one of this folder's own devices; Android Studio devices are not deleted.")
                : String(localized: "\(name) is not one of this folder's own devices; Android Studio devices are not renamed."))
        }
        let target = (try String(contentsOf: ini, encoding: .utf8)).components(separatedBy: .newlines)
            .first { $0.hasPrefix("path=") }.map { URL(fileURLWithPath: String($0.dropFirst(5)), isDirectory: true) }
        guard let target, target.resolvingSymlinksInPath().standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path,
              folder.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedHome + "/") else {
            throw AndroidAnalyxerError.invalidInput(action == .delete
                ? String(localized: "The configuration of \(name) does not point to \(folder.path). The device is not deleted.")
                : String(localized: "The configuration of \(name) does not point to \(folder.path). The device is not renamed."))
        }
        let processes = try await service.runner.run(Command(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "command="]))
        let running = processes.text.split(whereSeparator: \.isNewline).contains { line in
            let words = line.split(separator: " ").map(String.init)
            return words.indices.dropLast().contains { words[$0] == "-avd" && words[$0 + 1] == name }
        }
        guard !running else { throw AndroidAnalyxerError.invalidInput(String(localized: "\(name) is still running. Shut down the emulator first.")) }
        return (ini, folder)
    }

    /// Moves an own device to the Trash; Android Studio devices and running emulators are refused.
    public func delete(name: String, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async throws {
        let (ini, folder) = try await ownStoppedDevice(name, action: .delete)
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try trash(folder) }
            try trash(ini)
        } catch {
            throw AndroidAnalyxerError.failed(String(localized: "\(name) could not be moved to the Trash: \(error.localizedDescription)"))
        }
    }

    /// Renames an own, stopped device: folder, catalogue entry, `AvdId` and display name. User data stays untouched.
    public func rename(_ name: String, to newName: String) async throws -> AVD {
        guard newName.range(of: Self.namePattern, options: .regularExpression) != nil else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "New name: start with a letter, then letters, digits, underscore or hyphen; at most 64 characters."))
        }
        guard newName != name else { return AVD(name: name, home: home) }
        let (ini, folder) = try await ownStoppedDevice(name, action: .rename)
        let taken = Set(avds().map { $0.name.lowercased() } + (try await service.avds()).map { $0.name.lowercased() })
        let newINI = home.appendingPathComponent(newName + ".ini"), newFolder = home.appendingPathComponent(newName + ".avd", isDirectory: true)
        let caseOnly = newName.lowercased() == name.lowercased()
        guard caseOnly || (!taken.contains(newName.lowercased()) && !FileManager.default.fileExists(atPath: newINI.path) && !FileManager.default.fileExists(atPath: newFolder.path)) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "A device named \(newName) already exists, here or in Android Studio. Choose a different name."))
        }
        let fm = FileManager.default
        let entry = try String(contentsOf: ini, encoding: .utf8)
        let restoreConfig: (String) -> String = { line in
            if line.hasPrefix("AvdId=") { return "AvdId=" + name }
            if line.hasPrefix("avd.ini.displayname=") { return "avd.ini.displayname=" + name }
            return line
        }
        var moved = false
        do {
            try Self.move(folder, to: newFolder, in: home)
            moved = true
            let lines = entry.components(separatedBy: "\n").map { line -> String in
                if line.hasPrefix("path=") { return "path=" + newFolder.path }
                if line.hasPrefix("path.rel=") { return "path.rel=" + home.lastPathComponent + "/" + newName + ".avd" }
                return line
            }
            try fm.removeItem(at: ini)
            try lines.joined(separator: "\n").write(to: newINI, atomically: true, encoding: .utf8)
            try Self.rewrite(newFolder.appendingPathComponent("config.ini"), required: true) { line in
                if line.hasPrefix("AvdId=") { return "AvdId=" + newName }
                if line.hasPrefix("avd.ini.displayname=") { return "avd.ini.displayname=" + newName }
                return line
            }
            try Self.rewrite(newFolder.appendingPathComponent("hardware-qemu.ini"), required: false) { line in
                if line.hasPrefix("avd.name = ") { return "avd.name = " + newName }
                if line.hasPrefix("avd.id = ") { return "avd.id = " + newName }
                return line.replacingOccurrences(of: folder.path + "/", with: newFolder.path + "/")
            }
        } catch {
            if moved { try? Self.move(newFolder, to: folder, in: home) }
            if !caseOnly { try? fm.removeItem(at: newINI) }
            try? entry.write(to: ini, atomically: true, encoding: .utf8)
            try? Self.rewrite(folder.appendingPathComponent("config.ini"), required: false, restoreConfig)
            throw AndroidAnalyxerError.failed(String(localized: "\(name) could not be renamed: \(error.localizedDescription). The previous state was restored."))
        }
        return AVD(name: newName, home: home)
    }

    /// Two-step move via a hidden name, so case-only renames work on case-insensitive volumes.
    private static func move(_ source: URL, to destination: URL, in home: URL) throws {
        let stage = home.appendingPathComponent(".rename-\(UUID().uuidString).avd", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: stage)
        do { try FileManager.default.moveItem(at: stage, to: destination) }
        catch { try? FileManager.default.moveItem(at: stage, to: source); throw error }
    }

    private static func rewrite(_ url: URL, required: Bool, _ transform: (String) -> String) throws {
        guard required || FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.components(separatedBy: "\n").map(transform).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
