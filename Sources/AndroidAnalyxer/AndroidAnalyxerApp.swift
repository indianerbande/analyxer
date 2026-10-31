import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AndroidAnalyxerCore

@main
struct AndroidAnalyxerApp: App {
    @StateObject private var model = AnalyxerModel()
    var body: some Scene {
        WindowGroup("Android Analyxer") {
            AnalyxerView().environmentObject(model)
                .frame(minWidth: 1020, minHeight: 700)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Analyse APK …") { model.chooseAPK() }.keyboardShortcut("o")
                Button("Refresh Devices") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

enum Workspace: String, CaseIterable, Identifiable {
    case projects = "Analysis Projects", devices = "Devices", apk = "APK Analysis", packages = "Installed Apps", care = "Device Care", logs = "Logcat", setup = "Setup"
    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
    var icon: String {
        switch self {
        case .projects: "folder.badge.gearshape"
        case .devices: "ipad.and.iphone"
        case .apk: "shippingbox"
        case .packages: "square.grid.2x2"
        case .care: "wrench.and.screwdriver"
        case .logs: "terminal"
        case .setup: "slider.horizontal.3"
        }
    }
    var subtitle: LocalizedStringKey {
        switch self {
        case .projects: "APK, static findings and test sessions in one place."
        case .devices: "Start Android. Try apps. Investigate behaviour."
        case .apk: "Manifest metadata and permissions straight from an APK."
        case .packages: "Apps on the selected device with storage, origin and care actions."
        case .care: "Storage and cleanup on the selected device."
        case .logs: "The last 1,500 log entries of the selected device."
        case .setup: "Local tools for your Android workspace."
        }
    }
}

@MainActor
final class AnalyxerModel: ObservableObject {
    @Published var page: Workspace = .projects
    let launchLanguage = AppLanguage.stored
    @Published var appLanguage = AppLanguage.stored { didSet { appLanguage.store() } }
    @Published var project: AnalysisProject?
    @Published var projectDirectory: URL?
    @Published var appProfile: AppProfile?
    @Published var profileLoading = false
    @Published var activeSessionID: UUID?
    @Published var projectNote = ""
    @Published var analysisTools: AnalysisTools = {
        guard let data = UserDefaults.standard.data(forKey: "analysisTools"), let value = try? JSONDecoder().decode(AnalysisTools.self, from: data) else { return AnalysisTools() }
        return value
    }()
    @Published var evidencePreview: EvidencePreview?
    @Published var recentProjects = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
    var projectStore: ProjectStore?
    @Published var persistentDevice = true
    @Published var newPlayLayout: PlayDeviceLayout = .tablet
    @Published var newPlayName = "AndroidAnalyxer_Play"
    @Published var playImages: [PlaySystemImage] = []
    @Published var playImageID = ""
    @Published var analysisComponent = "input/application.apk"
    @Published var ownAVDs: [AVD] = []
    @Published var studioAVDs: [AVD] = []
    @Published var avdSystems: [String: AVDSystemInfo] = [:]
    @Published var avdPendingDeletion: AVD?
    @Published var avdPendingRename: AVD?
    @Published var renameText = ""
    @Published var devices: [AndroidDevice] = []
    @Published var serial = "" { didSet { if oldValue != serial { resetInventory(); logText = ""; screenshot = nil } } }
    @Published var busy = false
    @Published var refreshing = false
    @Published var startingAVDs: [String: Date] = [:]
    @Published var message = String(localized: "Ready.")
    @Published var error: String?
    @Published var apk: URL?
    @Published var report: APKReport?
    @Published var apps: [InstalledApp] = []
    @Published var storage: StorageOverview?
    @Published var leftovers: [AppLeftover] = []
    @Published var inventoryDate: Date?
    @Published var appScope: AppScope = .all
    @Published var appSort: AppSort = .size
    @Published var appPendingChange: AppChange?
    @Published var logText = ""
    @Published var screenshot: NSImage?
    @Published var screenshotData: Data?
    @Published var sdkRoot: String
    @Published var customAVDHome = UserDefaults.standard.string(forKey: "avdHome")
    @Published var toolsFolder = UserDefaults.standard.string(forKey: "toolsFolder")
    @Published var toolStatuses: [ToolStatus] = []
    @Published var toolInstalling: ToolID?
    @Published var toolMessage = ""
    @Published var toolFraction: Double?
    @Published var confirmInstallMissing = false
    @Published var showAndroidSetup = false
    @Published var androidLicenseText: String?
    @Published var includePlayImage = false
    @Published var packageFilter = ""
    @Published var logFilter = ""
    @Published var screenshotDate: Date?

    init() { sdkRoot = UserDefaults.standard.string(forKey: "sdkRoot") ?? SDKPaths.discover().root.path }
    var paths: SDKPaths { SDKPaths(root: URL(fileURLWithPath: sdkRoot)) }
    var service: EmulatorService { EmulatorService(paths: paths) }
    var avdHome: URL { customAVDHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PlayDeviceService.defaultHome(sdkRoot: paths.root) }
    var playService: PlayDeviceService { PlayDeviceService(service: service, home: avdHome) }
    var avds: [AVD] { ownAVDs + studioAVDs }
    var studioAVDHome: URL { EmulatorService.standardAVDHome() }
    var selected: AndroidDevice? { devices.first { $0.serial == serial } }
    var connected: Bool { selected?.isOnline == true }
    var filteredLogs: String {
        logFilter.isEmpty ? logText : logText.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(logFilter) }.joined(separator: "\n")
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let current = service, play = playService
        do {
            async let names = current.avds()
            async let attached = current.devices()
            let (newAVDs, newDevices) = try await (names, attached)
            ownAVDs = play.avds(); studioAVDs = play.foreignAVDs(newAVDs); devices = newDevices
            let studioHome = studioAVDHome
            avdSystems = Dictionary(uniqueKeysWithValues: avds.compactMap { avd in AVDSystemInfo.read(name: avd.name, catalogue: avd.home ?? studioHome).map { (avd.id, $0) } })
            playImages = play.installedImages()
            if !playImages.contains(where: { $0.id == playImageID }) { playImageID = playImages.first?.id ?? "" }
            let connectedNames = Set(newDevices.compactMap(\.avdName))
            let expired = startingAVDs.filter { !connectedNames.contains($0.key) && Date().timeIntervalSince($0.value) > 120 }
            startingAVDs = startingAVDs.filter { !connectedNames.contains($0.key) && Date().timeIntervalSince($0.value) <= 120 }
            if !expired.isEmpty {
                self.error = String(localized: "No ADB connection was detected for \(expired.keys.sorted().joined(separator: ", ")) after two minutes. Please check the emulator window.")
            }
            if !devices.contains(where: { $0.serial == serial }) { serial = devices.first(where: \.isOnline)?.serial ?? "" }
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ label: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; message = label
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription; message = String(localized: "Action failed.") }
        }
    }
    func start(_ avd: AVD) {
        guard !busy, startingAVDs[avd.name] == nil else { return }
        let current = service, persistent = persistentDevice
        startingAVDs[avd.name] = Date()
        perform(String(localized: "Starting \(avd.name) …")) {
            do { try await current.start(avd: avd, persistent: persistent) }
            catch { self.startingAVDs.removeValue(forKey: avd.name); throw error }
            self.message = String(localized: "Start requested. Android opens in its own window; the first start can take a while.")
            await self.refresh()
        }
    }
    func isRunning(_ avd: AVD) -> Bool { startingAVDs[avd.name] != nil || devices.contains { $0.avdName == avd.name } }
    func delete(_ avd: AVD) {
        guard let home = avd.home, !isRunning(avd) else { return }
        let play = PlayDeviceService(service: service, home: home)
        perform(String(localized: "Moving \(avd.name) to the Trash …")) {
            try await play.delete(name: avd.name)
            await self.refresh()
            self.message = String(localized: "\(avd.name) is in the Trash. You can put it back from there until the Trash is emptied.")
        }
    }
    func rename(_ avd: AVD, to newName: String) {
        guard let home = avd.home, !isRunning(avd) else { return }
        let play = PlayDeviceService(service: service, home: home), name = newName.trimmingCharacters(in: .whitespaces)
        perform(String(localized: "Renaming \(avd.name) …")) {
            let renamed = try await play.rename(avd.name, to: name)
            await self.refresh()
            self.message = String(localized: "\(avd.name) is now called \(renamed.name). Apps, sign-in and data are unchanged.")
        }
    }
    func enableKeyboard() {
        guard connected else { return }
        let current = service, target = serial
        perform(String(localized: "Setting up the on-screen keyboard …")) {
            try await current.enableScreenKeyboard(serial: target)
            self.message = String(localized: "On-screen keyboard enabled. Click the text field again; leave a handwriting mode that is already open through its menu.")
        }
    }
    func stop() {
        let current = service, target = serial
        perform(String(localized: "Stopping the device …")) {
            try await current.stop(serial: target)
            self.message = String(localized: "Emulator stopped. In persistent mode, apps and settings are kept.")
            await self.refresh()
        }
    }
    func chooseAPK() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an APK for local analysis")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createProject(from: url)
    }
    func analyze(_ url: URL) {
        guard !busy else { return }
        apk = url; report = nil; page = .apk
        let current = service
        perform(String(localized: "Inspecting the APK …")) {
            self.report = try await current.inspectAPK(at: url)
            self.message = String(localized: "APK analysed locally.")
        }
    }
    func install() {
        guard let file = apk, connected else { return }
        let current = service, target = serial
        perform(String(localized: "Installing the APK on \(target) …")) {
            let result = try await current.install(apk: file, serial: target)
            self.message = String(localized: "Installation on \(target): \(result.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
    func resetInventory() { apps = []; storage = nil; leftovers = []; inventoryDate = nil }
    func loadLogs() {
        guard connected else { return }
        let current = service, target = serial
        perform(String(localized: "Reading Logcat …")) {
            let result = try await current.logs(serial: target)
            if self.serial == target { self.logText = result }
            self.message = String(localized: "Logcat snapshot of \(target) loaded.")
        }
    }
    func capture() {
        guard connected else { return }
        let current = service, target = serial
        perform(String(localized: "Taking a screenshot …")) {
            let data = try await current.screenshot(serial: target)
            guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            if self.serial == target { self.screenshot = image; self.screenshotData = data; self.screenshotDate = Date() }
            self.message = String(localized: "Screenshot of \(target) taken.")
        }
    }
    func navigate(_ key: Int) {
        guard connected else { return }
        let current = service, target = serial
        perform(String(localized: "Android navigation …")) {
            try await current.keyevent(serial: target, keyCode: key)
            self.message = String(localized: "Navigation performed on \(target).")
        }
    }
    func launch(_ identifier: String) {
        guard connected else { return }
        let current = service, target = serial
        perform(String(localized: "Starting \(identifier) …")) {
            _ = try await current.launchPackage(identifier: identifier, serial: target)
            self.message = String(localized: "Start of \(identifier) on \(target) requested.")
        }
    }
    func chooseSDK() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = String(localized: "Choose the Android SDK folder (contains emulator and platform-tools)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sdkRoot = url.path; UserDefaults.standard.set(sdkRoot, forKey: "sdkRoot")
        ownAVDs = []; studioAVDs = []; devices = []; serial = ""
        Task { await refresh() }
    }
    func chooseAVDHome() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = avdHome
        panel.message = String(localized: "Choose the folder for My Devices (AVDs)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customAVDHome = url.path; UserDefaults.standard.set(url.path, forKey: "avdHome")
        ownAVDs = []; studioAVDs = []
        Task { await refresh() }
    }
    func save(_ data: Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); message = String(localized: "Saved: \(url.lastPathComponent)") }
        catch { self.error = error.localizedDescription }
    }
    func exportReport() {
        guard let report, let apk else { return }
        let output = "Android Analyxer · APK Analysis\nFile: \(apk.lastPathComponent)\nSHA-256: \(report.sha256)\nTime: \(Date().ISO8601Format())\n\nPermissions\n\(report.permissions.joined(separator: "\n"))\n\nManifest Metadata\n\(report.metadata)\n"
        save(Data(output.utf8), name: "\(apk.deletingPathExtension().lastPathComponent)-analysis.txt")
    }
}

struct AnalyxerView: View {
    @EnvironmentObject var model: AnalyxerModel
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(14).background(.orange.opacity(0.1))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch model.page {
                        case .projects: AnalysisProjectView()
                        case .devices: devicePage
                        case .apk: apkPage
                        case .packages: packagePage
                        case .care: carePage
                        case .logs: logPage
                        case .setup: setupPage
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 10) {
                    if model.busy || model.refreshing { ProgressView().controlSize(.small) }
                    else { Circle().fill(accent).frame(width: 6, height: 6) }
                    Text(model.message).font(.caption).lineLimit(2)
                    Spacer()
                    Text("LOCAL WORKSPACE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $model.evidencePreview) { preview in EvidencePreviewView(preview: preview) }
        .tint(accent)
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                if !model.busy && model.error == nil { await model.refresh() }
            }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 27)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Android Analyxer").font(.headline)
                    Text("APP ANALYSIS LAB").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(.secondary)
                }
            }.padding(.top, 16)
            VStack(spacing: 6) {
                ForEach(Workspace.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.icon).frame(width: 22)
                            Text(page.title).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                            Spacer()
                        }.padding(12).foregroundStyle(model.page == page ? accent : Color.primary.opacity(0.75))
                            .background(model.page == page ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("Analysis starts locally", systemImage: "externaldrive").font(.caption.weight(.semibold))
                Text("Check APKs, start Android and export observations.").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                Text("v0.4 · macOS").font(.caption2).foregroundStyle(.tertiary)
            }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }.padding(18).frame(width: 236).background(Color(red: 0.055, green: 0.07, blue: 0.09))
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.page.title).font(.system(size: 26, weight: .semibold))
                Text(model.page.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh Devices").disabled(model.busy || model.refreshing)
            Button("Open APK …", systemImage: "plus") { model.chooseAPK() }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }.padding(26)
    }
    private var devicePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                metric("VIRTUAL DEVICES", value: "\(model.avds.count)", icon: "ipad.landscape")
                metric("CONNECTED", value: "\(model.devices.filter(\.isOnline).count)", icon: "cable.connector")
                metric("RUNTIME", value: "Android SDK", icon: "cpu")
            }
            PlayDeviceSetupView()
            sectionTitle("Your Emulators", note: "Each in its own Android window")
            Toggle("Keep changes permanently (apps, sign-in and settings)", isOn: $model.persistentDevice).disabled(model.busy)
            if !model.persistentDevice { Text("Temporary mode: changes are discarded when the emulator stops.").font(.caption).foregroundStyle(.orange) }
            sectionTitle("My Devices", note: "\(model.avdHome.path)")
            if model.ownAVDs.isEmpty {
                empty("No device of your own yet", icon: "ipad.badge.play", detail: "Create one above under Create Google Play Device. You set its folder under Setup → My Devices.")
            } else {
                avdGrid(model.ownAVDs, own: true)
            }
            sectionTitle("Android Studio", note: "\(model.studioAVDHome.resolvingSymlinksInPath().path) · can be controlled; delete in Android Studio only")
            if !model.studioAVDs.isEmpty {
                avdGrid(model.studioAVDs, own: false)
            } else if model.playService.sharesCatalogue() {
                Text("Same folder as My Devices; the devices are listed above only.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No Android Studio devices found.").font(.caption).foregroundStyle(.secondary)
            }
            sectionTitle("Device Tools", note: "Emulator or device connected via ADB")
            devicePicker
            HStack(spacing: 10) {
                Button("Open Google Play", systemImage: "bag") { model.launch("com.android.vending") }
                Button("Screenshot", systemImage: "camera") { model.capture() }
                Button("Show Apps", systemImage: "square.grid.2x2") { model.page = .packages; model.loadInventory() }
                Button("Logcat", systemImage: "terminal") { model.page = .logs; model.loadLogs() }
                Spacer()
                Button("Stop Emulator", systemImage: "stop.fill") { model.stop() }
                    .disabled(!model.serial.hasPrefix("emulator-"))
            }.disabled(!model.connected || model.busy)
            HStack(spacing: 12) {
                Button("Enable On-Screen Keyboard", systemImage: "keyboard") { model.enableKeyboard() }
                Button("Back", systemImage: "chevron.left") { model.navigate(4) }
                Button("Home", systemImage: "house") { model.navigate(3) }
                Button("Recent Apps", systemImage: "square.on.square") { model.navigate(187) }
            }.disabled(!model.connected || model.busy)
            if let screenshot = model.screenshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Screen Capture").font(.headline)
                        if let date = model.screenshotDate { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Save PNG …") { if let data = model.screenshotData { model.save(data, name: "android-screenshot.png") } }
                    }
                    Image(nsImage: screenshot).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 420)
                }.padding(20).card()
            }
        }
        .confirmationDialog(model.avdPendingDeletion.map { String(localized: "Delete \($0.name)?") } ?? "",
                            isPresented: Binding(get: { model.avdPendingDeletion != nil }, set: { if !$0 { model.avdPendingDeletion = nil } }),
                            presenting: model.avdPendingDeletion) { avd in
            Button("Move to Trash", role: .destructive) { model.delete(avd) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The device and all its installed apps, sign-ins and data are moved to the Trash. You can restore it until the Trash is emptied.")
        }
        .alert("Rename Device", isPresented: Binding(get: { model.avdPendingRename != nil }, set: { if !$0 { model.avdPendingRename = nil } }),
               presenting: model.avdPendingRename) { avd in
            TextField("New name", text: $model.renameText)
            Button("Rename") { model.rename(avd, to: model.renameText) }
            Button("Cancel", role: .cancel) {}
        } message: { avd in
            Text("New name for \(avd.name): start with a letter, then letters, digits, underscores or hyphens. Apps, sign-in and data are kept.")
        }
    }
    private var apkPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let apk = model.apk {
                HStack(spacing: 16) {
                    Image(systemName: "shippingbox.fill").font(.largeTitle).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(apk.lastPathComponent).font(.title3.weight(.semibold))
                        Text(apk.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Export Report …") { model.exportReport() }.disabled(model.report == nil)
                }.padding(22).card()
                if let report = model.report {
                    Text("SHA-256  \(report.sha256)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                    sectionTitle("Permissions", note: report.permissions.count == 1 ? "1 declaration · no assessment of runtime behaviour" : "\(report.permissions.count) declarations · no assessment of runtime behaviour")
                    if report.permissions.isEmpty { Text("No permissions declared.").foregroundStyle(.secondary) }
                    ForEach(report.permissions, id: \.self) { permission in
                        Label(permission, systemImage: "key.horizontal").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    sectionTitle("Manifest Metadata", note: "Package, version, SDK requirements and supported architectures")
                    codePanel(report.metadata)
                }
                Divider()
                devicePicker
                HStack {
                    Text("Installation and app launch are logged in the analysis project.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Go to Test Session", systemImage: "play.rectangle") { model.page = .projects }
                        .disabled(model.busy || model.project == nil)
                }
            } else {
                empty("Inspect an APK", icon: "shippingbox", detail: "Open an APK file. The analysis reads manifest metadata and permissions and computes the SHA-256 hash. The app is not run.")
                Button("Choose APK …") { model.chooseAPK() }.buttonStyle(.borderedProminent)
            }
        }
    }
    private var packagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            devicePicker
            AppInventoryView()
        }
    }
    private var carePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            devicePicker
            DeviceCareView()
        }
    }
    private var logPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            devicePicker
            HStack {
                TextField("Filter log entries …", text: $model.logFilter).textFieldStyle(.roundedBorder)
                Button("Load Snapshot") { model.loadLogs() }.disabled(!model.connected || model.busy)
                Button("Export …") { model.save(Data(model.filteredLogs.utf8), name: "android-logcat.txt") }.disabled(model.logText.isEmpty)
            }
            if model.logText.isEmpty { empty("Observe the runtime", icon: "terminal", detail: "Start the app you want to examine in the Android window, then load the current logs.") }
            else { codePanel(model.filteredLogs) }
        }
    }
    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Language").font(.headline)
                Text("Follows the system language unless you choose one here.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Picker("Language", selection: $model.appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                if model.appLanguage != model.launchLanguage {
                    Text("Takes effect after a restart.").font(.caption).foregroundStyle(.orange)
                    Button("Restart Now") { model.restartApp() }
                }
                Spacer()
            }.padding(20).card()
            ToolSetupView()
            sectionTitle("Android SDK", note: "The tools are taken from your local installation.")
            HStack {
                Text(model.sdkRoot).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer(); Button("Choose Folder …") { model.chooseSDK() }.disabled(model.busy || model.refreshing)
            }.padding(20).card()
            sectionTitle("My Devices", note: "Folder for the AVDs created in the app; they can be deleted in the app. Android Studio devices appear separately and are only controlled.")
            HStack {
                Text(model.avdHome.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer(); Button("Choose Folder …") { model.chooseAVDHome() }.disabled(model.busy || model.refreshing)
            }.padding(20).card()
            ForEach(model.paths.diagnostics, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            toolRow("Android Emulator", present: model.paths.emulator != nil)
            toolRow("Android Debug Bridge", present: model.paths.adb != nil)
            toolRow("AAPT2 · APK metadata", present: model.paths.aapt2 != nil)
            toolRow("APK Analyzer · manifest and DEX", present: model.paths.apkanalyzer != nil)
            Divider()
            Text("New Devices").font(.headline)
            Text("Google Play devices under Devices → Create Google Play Device. Create other devices in Android Studio → Device Manager → Create Virtual Device (with an ARM64 system image on Apple Silicon); they appear under Devices → Android Studio.").foregroundStyle(.secondary)
            Text("Temporary Analysis Sessions").font(.headline)
            Text("Emulators started by Android Analyxer use read-only mode without snapshots. Installations and changes are discarded when the emulator stops. Devices that are already running and physical devices keep their own settings.").foregroundStyle(.secondary)
            Text("Expanding into App Analysis").font(.headline)
            Text("Analysis projects store the APK, the static report with manifest components and DEX inventory, and test sessions with app logs, screenshots and notes. Java/Kotlin decompilation via JADX, native REA analysis and network captures are further stages.").foregroundStyle(.secondary)
        }.lineSpacing(4)
    }
    private var devicePicker: some View {
        HStack(spacing: 14) {
            Circle().fill(model.connected ? accent : .gray).frame(width: 8, height: 8)
            Picker("Target device", selection: $model.serial) {
                Text("Select a device").tag("")
                ForEach(model.devices) { device in
                    Text("\(device.avdName ?? device.model) · \(device.serial) · \(device.state)").tag(device.serial)
                }
            }.disabled(model.busy)
            if model.devices.isEmpty { Text("No device connected").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).card()
    }
    private func metric(_ title: LocalizedStringKey, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(title).font(.system(size: 9, weight: .semibold)).tracking(1); Spacer(); Image(systemName: icon).foregroundStyle(accent) }
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .medium))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }
    private func avdGrid(_ list: [AVD], own: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
            ForEach(list) { avd in
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: "ipad.landscape").font(.system(size: 30)).foregroundStyle(accent)
                        Spacer()
                        Text(model.startingAVDs[avd.name] != nil ? "STARTING" : (model.devices.contains { $0.avdName == avd.name && $0.isOnline } ? "CONNECTED" : "AVAILABLE"))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(avd.name.replacingOccurrences(of: "_", with: " ")).font(.headline).lineLimit(2)
                        Text(model.avdSystems[avd.id]?.summary ?? String(localized: "System unknown")).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text(own ? "My device" : "Android Studio").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if own {
                            Button("Rename …", systemImage: "pencil") { model.renameText = avd.name; model.avdPendingRename = avd }
                                .labelStyle(.iconOnly)
                                .disabled(model.busy || model.isRunning(avd))
                                .help(model.isRunning(avd) ? "Stop the emulator before renaming it" : "Rename the device")
                            Button("Delete …", systemImage: "trash", role: .destructive) { model.avdPendingDeletion = avd }
                                .labelStyle(.iconOnly)
                                .disabled(model.busy || model.isRunning(avd))
                                .help(model.isRunning(avd) ? "Stop the emulator before deleting it" : "Move the device to the Trash")
                        }
                        Button(model.startingAVDs[avd.name] != nil ? "Starting …" : "Start", systemImage: "play.fill") { model.start(avd) }
                            .disabled(model.busy || model.isRunning(avd))
                    }
                }.padding(20).card()
            }
        }
    }
    private func sectionTitle(_ title: LocalizedStringKey, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(note).font(.caption).foregroundStyle(.secondary) }
    }
    private func empty(_ title: LocalizedStringKey, icon: String, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(accent)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).card()
    }
    private func codePanel(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }.background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
    }
    private func toolRow(_ title: LocalizedStringKey, present: Bool) -> some View {
        HStack { Image(systemName: present ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(present ? accent : .orange); Text(title); Spacer(); Text(present ? "Found" : "Missing").font(.caption).foregroundStyle(.secondary) }
    }
}

extension View {
    func card() -> some View {
        background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.065), lineWidth: 1))
    }
}
