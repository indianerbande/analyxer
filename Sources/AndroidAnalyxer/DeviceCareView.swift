import SwiftUI
import AndroidAnalyxerCore

enum AppScope: String, CaseIterable, Identifiable {
    case all = "Alle", user = "Selbst installiert", system = "Vorinstalliert", disabled = "Deaktiviert", removed = "Entfernt"
    var id: String { rawValue }
}

enum AppSort: String, CaseIterable, Identifiable {
    case size = "Größe", name = "Name", lastUsed = "Zuletzt benutzt"
    var id: String { rawValue }
}

/// A change to one app that needs the user's confirmation before it runs on the device.
enum AppChange: Identifiable {
    case disable(InstalledApp), enable(InstalledApp), removeForUser(InstalledApp), restore(InstalledApp), uninstall(InstalledApp)
    var app: InstalledApp {
        switch self { case .disable(let app), .enable(let app), .removeForUser(let app), .restore(let app), .uninstall(let app): app }
    }
    var id: String { "\(title)/\(app.package)" }
    var title: String {
        switch self {
        case .disable: "Deaktivieren"
        case .enable: "Aktivieren"
        case .removeForUser: "Für Benutzer entfernen"
        case .restore: "Wiederherstellen"
        case .uninstall: "Deinstallieren"
        }
    }
    var explanation: String {
        switch self {
        case .disable: "Die App startet nicht mehr und verschwindet aus dem Launcher. Daten bleiben erhalten; Aktivieren macht das rückgängig."
        case .enable: "Die App wird wieder aktiviert."
        case .removeForUser: "Die vorinstallierte App wird für diesen Benutzer entfernt. Sie bleibt im System-Image und lässt sich unter Entfernt wiederherstellen."
        case .restore: "Die vorinstallierte App wird für diesen Benutzer wiederhergestellt."
        case .uninstall: "Die App wird mit allen ihren Daten endgültig vom Gerät gelöscht. Das lässt sich nicht rückgängig machen."
        }
    }
    var destructive: Bool { if case .uninstall = self { true } else { false } }
}

extension AnalyxerModel {
    var care: DeviceCareService { DeviceCareService(service: service) }

    var visibleApps: [InstalledApp] {
        apps.filter { app in
            let inScope: Bool
            switch appScope {
            case .all: inScope = !app.isRemovedForUser
            case .user: inScope = !app.isSystem && !app.isRemovedForUser
            case .system: inScope = app.isSystem && !app.isRemovedForUser
            case .disabled: inScope = app.isDisabled
            case .removed: inScope = app.isRemovedForUser
            }
            return inScope && (packageFilter.isEmpty || app.package.localizedCaseInsensitiveContains(packageFilter))
        }.sorted { lhs, rhs in
            switch appSort {
            case .size: return (lhs.totalBytes ?? -1, rhs.package) > (rhs.totalBytes ?? -1, lhs.package)
            case .name: return lhs.package < rhs.package
            case .lastUsed: return (lhs.lastUsed ?? .distantPast, rhs.package) > (rhs.lastUsed ?? .distantPast, lhs.package)
            }
        }
    }

    /// Reads apps, storage and leftovers of the selected device; nothing on the device is changed.
    func loadInventory() {
        guard connected else { return }
        let care = care, target = serial
        perform("Gerät wird analysiert …") {
            let (apps, storage) = try await care.inventory(serial: target)
            let leftovers = try await care.leftovers(serial: target, known: Set(apps.map(\.package)))
            guard self.serial == target else { return }
            self.apps = apps; self.storage = storage; self.leftovers = leftovers; self.inventoryDate = Date()
            self.message = "\(apps.filter { !$0.isRemovedForUser }.count) Apps und \(leftovers.count) App-Reste auf \(target) gelesen."
        }
    }

    func apply(_ change: AppChange) {
        guard connected else { return }
        let care = care, target = serial, package = change.app.package
        perform("\(change.title): \(package) …") {
            switch change {
            case .disable: try await care.setEnabled(false, package: package, serial: target)
            case .enable: try await care.setEnabled(true, package: package, serial: target)
            case .removeForUser: try await care.removeForUser(package: package, serial: target)
            case .restore: try await care.restoreForUser(package: package, serial: target)
            case .uninstall: try await care.uninstall(package: package, serial: target)
            }
            try await self.reloadInventory(target)
            self.message = "\(change.title): \(package) erledigt."
        }
    }

    func trimCaches() {
        guard connected else { return }
        let care = care, target = serial, before = storage?.appCache
        perform("App-Caches werden geleert …") {
            try await care.trimCaches(serial: target)
            try await self.reloadInventory(target)
            let freed = (before ?? 0) - (self.storage?.appCache ?? 0)
            self.message = freed > 0 ? "App-Caches geleert: \(Self.bytes(freed)) freigegeben." : "App-Caches geleert."
        }
    }

    func deleteLeftovers(_ selection: [AppLeftover]) {
        guard connected, !selection.isEmpty else { return }
        let care = care, target = serial
        perform("App-Reste werden entfernt …") {
            for leftover in selection { try await care.delete(leftover, serial: target) }
            try await self.reloadInventory(target)
            self.message = "\(selection.count) App-Rest\(selection.count == 1 ? "" : "e") entfernt (\(Self.bytes(selection.reduce(0) { $0 + $1.bytes })))."
        }
    }

    private func reloadInventory(_ target: String) async throws {
        let (apps, storage) = try await care.inventory(serial: target)
        let leftovers = try await care.leftovers(serial: target, known: Set(apps.map(\.package)))
        guard serial == target else { return }
        self.apps = apps; self.storage = storage; self.leftovers = leftovers; inventoryDate = Date()
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false; formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }
}

/// Installed apps of the selected device with sizes, origin and care actions.
struct AppInventoryView: View {
    @EnvironmentObject var model: AnalyxerModel
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Pakete filtern …", text: $model.packageFilter).textFieldStyle(.roundedBorder)
                Button(model.apps.isEmpty ? "Apps laden" : "Neu laden", systemImage: "arrow.clockwise") { model.loadInventory() }.disabled(!model.connected || model.busy)
            }
            if model.apps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 30)).foregroundStyle(accent)
                    Text("Apps laden").font(.title3.weight(.semibold))
                    Text("Wähle ein verbundenes Gerät und lade seine Apps mit Speicherbedarf, Herkunft und letzter Nutzung. Das Laden ändert nichts am Gerät und dauert einige Sekunden.").foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                HStack {
                    Picker("Anzeigen", selection: $model.appScope) { ForEach(AppScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    Picker("Sortieren", selection: $model.appSort) { ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 200)
                }
                let visible = model.visibleApps
                Text("\(visible.count) Apps · zusammen \(AnalyxerModel.bytes(visible.compactMap(\.totalBytes).reduce(0, +)))\(model.inventoryDate.map { " · gelesen \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { app in
                        row(app)
                        Divider().opacity(0.4)
                    }
                }.card()
            }
        }
        .confirmationDialog(model.appPendingChange.map { "\($0.app.package): \($0.title)?" } ?? "",
                            isPresented: Binding(get: { model.appPendingChange != nil }, set: { if !$0 { model.appPendingChange = nil } }),
                            presenting: model.appPendingChange) { change in
            Button(change.title, role: change.destructive ? .destructive : nil) { model.apply(change) }
            Button("Abbrechen", role: .cancel) {}
        } message: { change in Text(change.explanation) }
    }

    private func row(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app.isProtected ? "lock.fill" : app.isSystem ? "gearshape" : "app").frame(width: 18)
                .foregroundStyle(app.isProtected ? Color.secondary : accent)
                .help(app.isProtected ? "Geschützte Systemkomponente: wird nicht verändert" : app.isSystem ? "Vorinstallierte App" : "Selbst installierte App")
            VStack(alignment: .leading, spacing: 3) {
                Text(app.package).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                Text(details(app)).font(.caption).foregroundStyle(app.isDisabled || app.isRemovedForUser ? Color.orange : Color.secondary).lineLimit(1)
            }
            Spacer()
            Text(app.totalBytes.map(AnalyxerModel.bytes) ?? "–").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .help(["App", "Daten", "Cache"].enumerated().map { index, label in "\(label): \([app.appBytes, app.dataBytes, app.cacheBytes][index].map(AnalyxerModel.bytes) ?? "–")" }.joined(separator: " · "))
            if !app.isRemovedForUser {
                Button("Untersuchen …", systemImage: "magnifyingglass") { model.importInstalledApp(app.package) }.labelStyle(.iconOnly).help("In ein Analyseprojekt übernehmen")
                Button("Öffnen", systemImage: "play") { model.launch(app.package) }.labelStyle(.iconOnly).help("App auf dem Gerät öffnen").disabled(app.isDisabled)
            }
            if !app.isProtected { careButtons(app) }
        }
        .disabled(!model.connected || model.busy)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder private func careButtons(_ app: InstalledApp) -> some View {
        if app.isRemovedForUser {
            Button("Wiederherstellen …", systemImage: "arrow.uturn.backward.circle") { model.appPendingChange = .restore(app) }.labelStyle(.iconOnly).help("Für diesen Benutzer wiederherstellen")
        } else {
            if app.isDisabled {
                Button("Aktivieren …", systemImage: "play.circle") { model.appPendingChange = .enable(app) }.labelStyle(.iconOnly).help("Wieder aktivieren")
            } else {
                Button("Deaktivieren …", systemImage: "pause.circle") { model.appPendingChange = .disable(app) }.labelStyle(.iconOnly).help("Deaktivieren (rückgängig machbar)")
            }
            if app.isSystem {
                Button("Für Benutzer entfernen …", systemImage: "minus.circle") { model.appPendingChange = .removeForUser(app) }.labelStyle(.iconOnly).help("Für diesen Benutzer entfernen (rückgängig machbar)")
            } else {
                Button("Deinstallieren …", systemImage: "trash", role: .destructive) { model.appPendingChange = .uninstall(app) }.labelStyle(.iconOnly).help("Mit allen Daten deinstallieren")
            }
        }
    }

    private func details(_ app: InstalledApp) -> String {
        var parts = [app.source]
        if app.isRemovedForUser { parts.append("für Benutzer entfernt") } else if app.isDisabled { parts.append("deaktiviert") }
        if app.isProtected { parts.append("geschützt") }
        parts.append(app.lastUsed.map { "zuletzt " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "keine Nutzung erfasst")
        return parts.joined(separator: " · ")
    }
}

/// Storage overview and cleanup for the selected device.
struct DeviceCareView: View {
    @EnvironmentObject var model: AnalyxerModel
    @State private var confirmTrim = false
    @State private var leftoversToDelete: [AppLeftover] = []
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(model.inventoryDate.map { "Stand \($0.formatted(date: .omitted, time: .shortened))" } ?? "Noch nicht analysiert").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.inventoryDate == nil ? "Gerät analysieren" : "Neu analysieren", systemImage: "stethoscope") { model.loadInventory() }
                    .buttonStyle(.borderedProminent).disabled(!model.connected || model.busy)
            }
            if let storage = model.storage { storageCard(storage) }
            else if model.inventoryDate == nil {
                Text("Die Analyse liest Speicher, Apps und App-Reste des ausgewählten Geräts. Sie ändert nichts und dauert einige Sekunden.").foregroundStyle(.secondary)
            }
            if model.inventoryDate != nil {
                cacheCard
                leftoverCard
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vorinstallierte Apps").font(.headline)
                    Text("Vorinstallierte Apps lassen sich unter Installierte Apps deaktivieren oder für den Benutzer entfernen; beides ist rückgängig machbar. Systemkomponenten, Launcher, Tastatur und WebView sind gesperrt.").font(.callout).foregroundStyle(.secondary)
                    Button("Vorinstallierte Apps anzeigen", systemImage: "square.grid.2x2") { model.appScope = .system; model.appSort = .size; model.page = .packages }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
            }
        }
        .confirmationDialog("Alle App-Caches leeren?", isPresented: $confirmTrim) {
            Button("Caches leeren") { model.trimCaches() }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Android löscht zwischengespeicherte Daten aller Apps; Anmeldungen und App-Daten bleiben erhalten. Apps laden Benötigtes bei Bedarf neu.") }
        .confirmationDialog(leftoversToDelete.count == 1 ? "\(leftoversToDelete[0].package) entfernen?" : "\(leftoversToDelete.count) App-Reste entfernen?",
                            isPresented: Binding(get: { !leftoversToDelete.isEmpty }, set: { if !$0 { leftoversToDelete = [] } })) {
            let selection = leftoversToDelete
            Button("Endgültig löschen", role: .destructive) { model.deleteLeftovers(selection) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("\(AnalyxerModel.bytes(leftoversToDelete.reduce(0) { $0 + $1.bytes })) in Ordnern deinstallierter Apps werden vom Gerät gelöscht. Das lässt sich nicht rückgängig machen.")
        }
    }

    private func storageCard(_ storage: StorageOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speicher").font(.headline)
                Spacer()
                Text("\(AnalyxerModel.bytes(storage.used)) belegt · \(AnalyxerModel.bytes(storage.free)) frei von \(AnalyxerModel.bytes(storage.total))").font(.callout).monospacedDigit()
            }
            ProgressView(value: Double(storage.used), total: Double(max(storage.total, 1))).tint(accent)
            let categories: [(String, Int64?)] = [("Apps", storage.apps), ("App-Daten", storage.appData), ("Caches", storage.appCache), ("Bilder", storage.photos),
                                                  ("Videos", storage.videos), ("Audio", storage.audio), ("Downloads", storage.downloads), ("Sonstiges", storage.other)]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 10) {
                ForEach(categories.filter { $0.1 != nil }, id: \.0) { name, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Text(AnalyxerModel.bytes(value ?? 0)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                }
            }
            if let system = storage.system { Text("Android-System-Image: \(AnalyxerModel.bytes(system)), getrennt vom Datenspeicher.").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).card()
    }

    private var cacheCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("App-Caches").font(.headline)
                Text(model.storage?.appCache.map { "\(AnalyxerModel.bytes($0)) zwischengespeichert. Android behält, was laufende Apps gerade brauchen." } ?? "Größe unbekannt.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Alle Caches leeren …") { confirmTrim = true }.disabled(!model.connected || model.busy)
        }.padding(20).card()
    }

    private var leftoverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.badge.minus").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("App-Reste").font(.headline)
                    Text(model.leftovers.isEmpty ? "Keine Ordner deinstallierter Apps in Android/data, obb oder media gefunden."
                         : "\(model.leftovers.count) Ordner deinstallierter Apps · \(AnalyxerModel.bytes(model.leftovers.reduce(0) { $0 + $1.bytes }))").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.leftovers.count > 1 { Button("Alle entfernen …") { leftoversToDelete = model.leftovers }.disabled(!model.connected || model.busy) }
            }
            ForEach(model.leftovers) { leftover in
                HStack {
                    Text(leftover.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Text(AnalyxerModel.bytes(leftover.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Button("Entfernen …", systemImage: "trash", role: .destructive) { leftoversToDelete = [leftover] }.labelStyle(.iconOnly)
                        .help("Ordner endgültig löschen").disabled(!model.connected || model.busy)
                }
            }
        }.padding(20).card()
    }
}
