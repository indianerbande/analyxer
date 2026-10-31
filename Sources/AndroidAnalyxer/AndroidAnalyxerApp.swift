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
                Button("APK analysieren …") { model.chooseAPK() }.keyboardShortcut("o")
                Button("Geräte aktualisieren") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

enum Workspace: String, CaseIterable, Identifiable {
    case projects = "Analyseprojekte", devices = "Geräte", apk = "APK-Analyse", packages = "Installierte Apps", care = "Gerätepflege", logs = "Logcat", setup = "Einrichtung"
    var id: String { rawValue }
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
    var subtitle: String {
        switch self {
        case .projects: "APK, statische Befunde und Testsitzungen an einem Ort."
        case .devices: "Android starten. Apps ausprobieren. Verhalten untersuchen."
        case .apk: "Manifest-Metadaten und Berechtigungen direkt aus einer APK."
        case .packages: "Apps des ausgewählten Geräts mit Speicherbedarf, Herkunft und Pflege."
        case .care: "Speicher und Aufräumen auf dem ausgewählten Gerät."
        case .logs: "Die letzten 1.500 Log-Einträge des ausgewählten Geräts."
        case .setup: "Lokale Werkzeuge für deine Android-Arbeitsumgebung."
        }
    }
}

@MainActor
final class AnalyxerModel: ObservableObject {
    @Published var page: Workspace = .projects
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
    @Published var message = "Bereit."
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
                self.error = "Für \(expired.keys.sorted().joined(separator: ", ")) wurde nach zwei Minuten keine ADB-Verbindung erkannt. Bitte das Emulatorfenster prüfen."
            }
            if !devices.contains(where: { $0.serial == serial }) { serial = devices.first(where: \.isOnline)?.serial ?? "" }
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ label: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; message = label
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription; message = "Aktion fehlgeschlagen." }
        }
    }
    func start(_ avd: AVD) {
        guard !busy, startingAVDs[avd.name] == nil else { return }
        let current = service, persistent = persistentDevice
        startingAVDs[avd.name] = Date()
        perform("\(avd.name) wird gestartet …") {
            do { try await current.start(avd: avd, persistent: persistent) }
            catch { self.startingAVDs.removeValue(forKey: avd.name); throw error }
            self.message = "Start angefordert. Android öffnet sich in einem eigenen Fenster; der erste Start kann etwas dauern."
            await self.refresh()
        }
    }
    func isRunning(_ avd: AVD) -> Bool { startingAVDs[avd.name] != nil || devices.contains { $0.avdName == avd.name } }
    func delete(_ avd: AVD) {
        guard let home = avd.home, !isRunning(avd) else { return }
        let play = PlayDeviceService(service: service, home: home)
        perform("\(avd.name) wird in den Papierkorb gelegt …") {
            try await play.delete(name: avd.name)
            await self.refresh()
            self.message = "\(avd.name) liegt im Papierkorb. Bis zum Leeren lässt es sich von dort zurücklegen."
        }
    }
    func rename(_ avd: AVD, to newName: String) {
        guard let home = avd.home, !isRunning(avd) else { return }
        let play = PlayDeviceService(service: service, home: home), name = newName.trimmingCharacters(in: .whitespaces)
        perform("\(avd.name) wird umbenannt …") {
            let renamed = try await play.rename(avd.name, to: name)
            await self.refresh()
            self.message = "\(avd.name) heißt jetzt \(renamed.name). Apps, Anmeldung und Daten sind unverändert."
        }
    }
    func enableKeyboard() {
        guard connected else { return }
        let current = service, target = serial
        perform("Bildschirmtastatur wird eingerichtet …") {
            try await current.enableScreenKeyboard(serial: target)
            self.message = "Bildschirmtastatur aktiviert. Das Texteingabefeld erneut anklicken; einen bereits offenen Handschriftmodus über dessen Menü verlassen."
        }
    }
    func stop() {
        let current = service, target = serial
        perform("Gerät wird beendet …") {
            try await current.stop(serial: target)
            self.message = "Emulator beendet. Im dauerhaften Modus bleiben Apps und Einstellungen erhalten."
            await self.refresh()
        }
    }
    func chooseAPK() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "APK für die lokale Analyse auswählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createProject(from: url)
    }
    func analyze(_ url: URL) {
        guard !busy else { return }
        apk = url; report = nil; page = .apk
        let current = service
        perform("APK wird untersucht …") {
            self.report = try await current.inspectAPK(at: url)
            self.message = "APK lokal analysiert."
        }
    }
    func install() {
        guard let file = apk, connected else { return }
        let current = service, target = serial
        perform("APK wird auf \(target) installiert …") {
            let result = try await current.install(apk: file, serial: target)
            self.message = "Installation auf \(target): \(result.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
    func resetInventory() { apps = []; storage = nil; leftovers = []; inventoryDate = nil }
    func loadLogs() {
        guard connected else { return }
        let current = service, target = serial
        perform("Logcat wird gelesen …") {
            let result = try await current.logs(serial: target)
            if self.serial == target { self.logText = result }
            self.message = "Logcat-Momentaufnahme von \(target) geladen."
        }
    }
    func capture() {
        guard connected else { return }
        let current = service, target = serial
        perform("Screenshot wird aufgenommen …") {
            let data = try await current.screenshot(serial: target)
            guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            if self.serial == target { self.screenshot = image; self.screenshotData = data; self.screenshotDate = Date() }
            self.message = "Screenshot von \(target) aufgenommen."
        }
    }
    func navigate(_ key: Int) {
        guard connected else { return }
        let current = service, target = serial
        perform("Android-Navigation …") {
            try await current.keyevent(serial: target, keyCode: key)
            self.message = "Navigation auf \(target) ausgeführt."
        }
    }
    func launch(_ identifier: String) {
        guard connected else { return }
        let current = service, target = serial
        perform("\(identifier) wird gestartet …") {
            _ = try await current.launchPackage(identifier: identifier, serial: target)
            self.message = "Start von \(identifier) auf \(target) angefordert."
        }
    }
    func chooseSDK() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Android SDK-Ordner auswählen (enthält emulator und platform-tools)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sdkRoot = url.path; UserDefaults.standard.set(sdkRoot, forKey: "sdkRoot")
        ownAVDs = []; studioAVDs = []; devices = []; serial = ""
        Task { await refresh() }
    }
    func chooseAVDHome() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = avdHome
        panel.message = "Ordner für die eigenen Geräte (AVDs) auswählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customAVDHome = url.path; UserDefaults.standard.set(url.path, forKey: "avdHome")
        ownAVDs = []; studioAVDs = []
        Task { await refresh() }
    }
    func save(_ data: Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); message = "Gespeichert: \(url.lastPathComponent)" }
        catch { self.error = error.localizedDescription }
    }
    func exportReport() {
        guard let report, let apk else { return }
        let output = "Android Analyxer · APK-Analyse\nDatei: \(apk.lastPathComponent)\nSHA-256: \(report.sha256)\nZeit: \(Date().ISO8601Format())\n\nBerechtigungen\n\(report.permissions.joined(separator: "\n"))\n\nManifest-Metadaten\n\(report.metadata)\n"
        save(Data(output.utf8), name: "\(apk.deletingPathExtension().lastPathComponent)-analyse.txt")
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
                            Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                            Spacer()
                        }.padding(12).foregroundStyle(model.page == page ? accent : Color.primary.opacity(0.75))
                            .background(model.page == page ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("Analyse beginnt lokal", systemImage: "externaldrive").font(.caption.weight(.semibold))
                Text("APK prüfen, Android starten und Beobachtungen exportieren.").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                Text("v0.4 · macOS").font(.caption2).foregroundStyle(.tertiary)
            }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }.padding(18).frame(width: 218).background(Color(red: 0.055, green: 0.07, blue: 0.09))
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.page.rawValue).font(.system(size: 26, weight: .semibold))
                Text(model.page.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Geräte aktualisieren").disabled(model.busy || model.refreshing)
            Button("APK öffnen …", systemImage: "plus") { model.chooseAPK() }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }.padding(26)
    }
    private var devicePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                metric("VIRTUELLE GERÄTE", value: "\(model.avds.count)", icon: "ipad.landscape")
                metric("VERBUNDEN", value: "\(model.devices.filter(\.isOnline).count)", icon: "cable.connector")
                metric("LAUFZEIT", value: "Android SDK", icon: "cpu")
            }
            PlayDeviceSetupView()
            sectionTitle("Deine Emulatoren", note: "Eigenes Android-Fenster")
            Toggle("Änderungen dauerhaft speichern (Apps, Anmeldung und Einstellungen)", isOn: $model.persistentDevice).disabled(model.busy)
            if !model.persistentDevice { Text("Temporärer Modus: Änderungen werden beim Beenden verworfen.").font(.caption).foregroundStyle(.orange) }
            sectionTitle("Eigene Geräte", note: model.avdHome.path)
            if model.ownAVDs.isEmpty {
                empty("Noch kein eigenes Gerät", icon: "ipad.badge.play", detail: "Oben unter Google-Play-Gerät anlegen ein Gerät erstellen. Den Ordner dafür legst du unter Einrichtung → Eigene Geräte fest.")
            } else {
                avdGrid(model.ownAVDs, own: true)
            }
            sectionTitle("Android Studio", note: model.studioAVDHome.resolvingSymlinksInPath().path + " · steuerbar, Löschen nur in Android Studio")
            if !model.studioAVDs.isEmpty {
                avdGrid(model.studioAVDs, own: false)
            } else if model.playService.sharesCatalogue() {
                Text("Gleicher Ordner wie die eigenen Geräte; die Geräte stehen nur oben.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Keine Android-Studio-Geräte gefunden.").font(.caption).foregroundStyle(.secondary)
            }
            sectionTitle("Geräte-Werkzeuge", note: "Emulator oder per ADB verbundenes Gerät")
            devicePicker
            HStack(spacing: 10) {
                Button("Google Play öffnen", systemImage: "bag") { model.launch("com.android.vending") }
                Button("Screenshot", systemImage: "camera") { model.capture() }
                Button("Apps anzeigen", systemImage: "square.grid.2x2") { model.page = .packages; model.loadInventory() }
                Button("Logcat", systemImage: "terminal") { model.page = .logs; model.loadLogs() }
                Spacer()
                Button("Emulator beenden", systemImage: "stop.fill") { model.stop() }
                    .disabled(!model.serial.hasPrefix("emulator-"))
            }.disabled(!model.connected || model.busy)
            HStack(spacing: 12) {
                Button("Bildschirmtastatur aktivieren", systemImage: "keyboard") { model.enableKeyboard() }
                Button("Zurück", systemImage: "chevron.left") { model.navigate(4) }
                Button("Home", systemImage: "house") { model.navigate(3) }
                Button("Letzte Apps", systemImage: "square.on.square") { model.navigate(187) }
            }.disabled(!model.connected || model.busy)
            if let screenshot = model.screenshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Bildschirmaufnahme").font(.headline)
                        if let date = model.screenshotDate { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("PNG speichern …") { if let data = model.screenshotData { model.save(data, name: "android-screenshot.png") } }
                    }
                    Image(nsImage: screenshot).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 420)
                }.padding(20).card()
            }
        }
        .confirmationDialog(model.avdPendingDeletion.map { "\($0.name) löschen?" } ?? "",
                            isPresented: Binding(get: { model.avdPendingDeletion != nil }, set: { if !$0 { model.avdPendingDeletion = nil } }),
                            presenting: model.avdPendingDeletion) { avd in
            Button("In den Papierkorb legen", role: .destructive) { model.delete(avd) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Das Gerät mit allen installierten Apps, Anmeldungen und Daten wird in den Papierkorb gelegt. Bis zum Leeren des Papierkorbs lässt es sich wiederherstellen.")
        }
        .alert("Gerät umbenennen", isPresented: Binding(get: { model.avdPendingRename != nil }, set: { if !$0 { model.avdPendingRename = nil } }),
               presenting: model.avdPendingRename) { avd in
            TextField("Neuer Name", text: $model.renameText)
            Button("Umbenennen") { model.rename(avd, to: model.renameText) }
            Button("Abbrechen", role: .cancel) {}
        } message: { avd in
            Text("Neuer Name für \(avd.name): mit einem Buchstaben beginnen, dann Buchstaben, Zahlen, Unterstrich oder Bindestrich. Apps, Anmeldung und Daten bleiben erhalten.")
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
                    Button("Bericht exportieren …") { model.exportReport() }.disabled(model.report == nil)
                }.padding(22).card()
                if let report = model.report {
                    Text("SHA-256  \(report.sha256)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                    sectionTitle("Berechtigungen", note: "\(report.permissions.count) Deklarationen · keine Bewertung des Laufzeitverhaltens")
                    if report.permissions.isEmpty { Text("Keine Berechtigungen deklariert.").foregroundStyle(.secondary) }
                    ForEach(report.permissions, id: \.self) { permission in
                        Label(permission, systemImage: "key.horizontal").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    sectionTitle("Manifest-Metadaten", note: "Paket, Version, SDK-Anforderungen und unterstützte Architekturen")
                    codePanel(report.metadata)
                }
                Divider()
                devicePicker
                HStack {
                    Text("Installation und App-Start werden im Analyseprojekt protokolliert.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Zur Testsitzung", systemImage: "play.rectangle") { model.page = .projects }
                        .disabled(model.busy || model.project == nil)
                }
            } else {
                empty("APK untersuchen", icon: "shippingbox", detail: "Öffne eine APK-Datei. Die Analyse liest Manifest-Metadaten und Berechtigungen aus und berechnet den SHA-256-Hash. Die App wird dabei nicht ausgeführt.")
                Button("APK auswählen …") { model.chooseAPK() }.buttonStyle(.borderedProminent)
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
                TextField("Log-Einträge filtern …", text: $model.logFilter).textFieldStyle(.roundedBorder)
                Button("Momentaufnahme laden") { model.loadLogs() }.disabled(!model.connected || model.busy)
                Button("Exportieren …") { model.save(Data(model.filteredLogs.utf8), name: "android-logcat.txt") }.disabled(model.logText.isEmpty)
            }
            if model.logText.isEmpty { empty("Laufzeit beobachten", icon: "terminal", detail: "Starte die zu untersuchende App im Android-Fenster und lade anschließend die aktuellen Logs.") }
            else { codePanel(model.filteredLogs) }
        }
    }
    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Android SDK", note: "Die Werkzeuge werden aus deiner lokalen Installation verwendet.")
            HStack {
                Text(model.sdkRoot).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer(); Button("Ordner wählen …") { model.chooseSDK() }.disabled(model.busy || model.refreshing)
            }.padding(20).card()
            sectionTitle("Eigene Geräte", note: "Ordner für die in der App angelegten AVDs; sie lassen sich in der App löschen. Android-Studio-Geräte erscheinen getrennt und werden nur gesteuert.")
            HStack {
                Text(model.avdHome.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer(); Button("Ordner wählen …") { model.chooseAVDHome() }.disabled(model.busy || model.refreshing)
            }.padding(20).card()
            ForEach(model.paths.diagnostics, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            toolRow("Android Emulator", present: model.paths.emulator != nil)
            toolRow("Android Debug Bridge", present: model.paths.adb != nil)
            toolRow("AAPT2 · APK-Metadaten", present: model.paths.aapt2 != nil)
            toolRow("APK Analyzer · Manifest und DEX", present: model.paths.apkanalyzer != nil)
            Divider()
            Text("Neue Geräte").font(.headline)
            Text("Google-Play-Geräte unter Geräte → Google-Play-Gerät anlegen. Andere Geräte in Android Studio → Device Manager → Create Virtual Device anlegen (auf Apple Silicon mit ARM64-System-Image); sie erscheinen unter Geräte → Android Studio.").foregroundStyle(.secondary)
            Text("Temporäre Analysesitzungen").font(.headline)
            Text("Von Android Analyxer gestartete Emulatoren verwenden den Read-only-Modus ohne Snapshots. Installationen und Änderungen werden beim Beenden verworfen. Bereits laufende oder physische Geräte behalten ihre eigenen Einstellungen.").foregroundStyle(.secondary)
            Text("Ausbau zur App-Analyse").font(.headline)
            Text("Analyseprojekte speichern die APK, den statischen Bericht mit Manifest-Komponenten und DEX-Inventar sowie Testsitzungen mit App-Logs, Screenshots und Notizen. Java-/Kotlin-Dekompilierung über JADX, native REA-Analyse und Netzwerkmitschnitte sind weitere Ausbaustufen.").foregroundStyle(.secondary)
        }.lineSpacing(4)
    }
    private var devicePicker: some View {
        HStack(spacing: 14) {
            Circle().fill(model.connected ? accent : .gray).frame(width: 8, height: 8)
            Picker("Zielgerät", selection: $model.serial) {
                Text("Gerät auswählen").tag("")
                ForEach(model.devices) { device in
                    Text("\(device.avdName ?? device.model) · \(device.serial) · \(device.state)").tag(device.serial)
                }
            }.disabled(model.busy)
            if model.devices.isEmpty { Text("Kein Gerät verbunden").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).card()
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
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
                        Text(model.startingAVDs[avd.name] != nil ? "STARTET" : (model.devices.contains { $0.avdName == avd.name && $0.isOnline } ? "VERBUNDEN" : "VERFÜGBAR"))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(avd.name.replacingOccurrences(of: "_", with: " ")).font(.headline).lineLimit(2)
                        Text(model.avdSystems[avd.id]?.summary ?? "System unbekannt").font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text(own ? "Eigenes Gerät" : "Android Studio").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if own {
                            Button("Umbenennen …", systemImage: "pencil") { model.renameText = avd.name; model.avdPendingRename = avd }
                                .labelStyle(.iconOnly)
                                .disabled(model.busy || model.isRunning(avd))
                                .help(model.isRunning(avd) ? "Zum Umbenennen zuerst den Emulator beenden" : "Gerät umbenennen")
                            Button("Löschen …", systemImage: "trash", role: .destructive) { model.avdPendingDeletion = avd }
                                .labelStyle(.iconOnly)
                                .disabled(model.busy || model.isRunning(avd))
                                .help(model.isRunning(avd) ? "Zum Löschen zuerst den Emulator beenden" : "Gerät in den Papierkorb legen")
                        }
                        Button(model.startingAVDs[avd.name] != nil ? "Startet …" : "Starten", systemImage: "play.fill") { model.start(avd) }
                            .disabled(model.busy || model.isRunning(avd))
                    }
                }.padding(20).card()
            }
        }
    }
    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(note).font(.caption).foregroundStyle(.secondary) }
    }
    private func empty(_ title: String, icon: String, detail: String) -> some View {
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
    private func toolRow(_ title: String, present: Bool) -> some View {
        HStack { Image(systemName: present ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(present ? accent : .orange); Text(title); Spacer(); Text(present ? "Gefunden" : "Fehlt").font(.caption).foregroundStyle(.secondary) }
    }
}

extension View {
    func card() -> some View {
        background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.065), lineWidth: 1))
    }
}
