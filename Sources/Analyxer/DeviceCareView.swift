import SwiftUI
import AnalyxerCore

enum AppScope: String, CaseIterable, Identifiable {
    case all, user, system, disabled, removed
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .user: "User-Installed"
        case .system: "Preinstalled"
        case .disabled: "Disabled"
        case .removed: "Removed"
        }
    }
}

enum AppSort: String, CaseIterable, Identifiable {
    case size, name, lastUsed
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .lastUsed: "Last Used"
        }
    }
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
        case .disable: String(localized: "Disable")
        case .enable: String(localized: "Enable")
        case .removeForUser: String(localized: "Remove for User")
        case .restore: String(localized: "Restore")
        case .uninstall: String(localized: "Uninstall")
        }
    }
    var explanation: String {
        switch self {
        case .disable: String(localized: "The app no longer starts and disappears from the launcher. Its data is kept; Enable undoes this.")
        case .enable: String(localized: "The app is enabled again.")
        case .removeForUser: String(localized: "The preinstalled app is removed for this user. It stays in the system image and can be restored under Removed.")
        case .restore: String(localized: "The preinstalled app is restored for this user.")
        case .uninstall: String(localized: "The app and all its data are permanently deleted from the device. This cannot be undone.")
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
        perform(String(localized: "Analysing the device …")) {
            let (apps, storage) = try await care.inventory(serial: target)
            let leftovers = try await care.leftovers(serial: target, known: Set(apps.map(\.package)))
            guard self.serial == target else { return }
            self.apps = apps; self.storage = storage; self.leftovers = leftovers; self.inventoryDate = Date()
            let appCount = apps.filter { !$0.isRemovedForUser }.count
            let appText = appCount == 1 ? String(localized: "1 app") : String(localized: "\(appCount) apps")
            let leftoverText = leftovers.count == 1 ? String(localized: "1 app leftover") : String(localized: "\(leftovers.count) app leftovers")
            self.message = String(localized: "Read \(appText) and \(leftoverText) from \(target).")
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
            self.message = String(localized: "\(change.title): \(package) done.")
        }
    }

    func trimCaches() {
        guard connected else { return }
        let care = care, target = serial, before = storage?.appCache
        perform(String(localized: "Clearing app caches …")) {
            try await care.trimCaches(serial: target)
            try await self.reloadInventory(target)
            let freed = (before ?? 0) - (self.storage?.appCache ?? 0)
            self.message = freed > 0 ? String(localized: "App caches cleared: \(Self.bytes(freed)) freed.") : String(localized: "App caches cleared.")
        }
    }

    func deleteLeftovers(_ selection: [AppLeftover]) {
        guard connected, !selection.isEmpty else { return }
        let care = care, target = serial
        perform(String(localized: "Removing app leftovers …")) {
            for leftover in selection { try await care.delete(leftover, serial: target) }
            try await self.reloadInventory(target)
            let freed = Self.bytes(selection.reduce(0) { $0 + $1.bytes })
            self.message = selection.count == 1 ? String(localized: "Removed 1 app leftover (\(freed)).") : String(localized: "Removed \(selection.count) app leftovers (\(freed)).")
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
                TextField("Filter packages …", text: $model.packageFilter).textFieldStyle(.roundedBorder)
                Button(model.apps.isEmpty ? "Load Apps" as LocalizedStringKey : "Reload", systemImage: "arrow.clockwise") { model.loadInventory() }.disabled(!model.connected || model.busy)
            }
            if model.apps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 30)).foregroundStyle(accent)
                    Text("Load Apps").font(.title3.weight(.semibold))
                    Text("Choose a connected device and load its apps with storage use, origin and last use. Loading changes nothing on the device and takes a few seconds.").foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                HStack {
                    Picker("Show", selection: $model.appScope) { ForEach(AppScope.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    Picker("Sort by", selection: $model.appSort) { ForEach(AppSort.allCases) { Text($0.title).tag($0) } }.frame(width: 200)
                }
                let visible = model.visibleApps
                let count = visible.count == 1 ? String(localized: "1 app") : String(localized: "\(visible.count) apps")
                let summary = String(localized: "\(count) · \(AnalyxerModel.bytes(visible.compactMap(\.totalBytes).reduce(0, +))) in total")
                Text([summary, model.inventoryDate.map { String(localized: "read at \($0.formatted(date: .omitted, time: .shortened))") }].compactMap { $0 }.joined(separator: " · "))
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
            Button("Cancel", role: .cancel) {}
        } message: { change in Text(change.explanation) }
    }

    private func row(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: app.isProtected ? "lock.fill" : app.isSystem ? "gearshape" : "app").frame(width: 18)
                .foregroundStyle(app.isProtected ? Color.secondary : accent)
                .help(app.isProtected ? "Protected system component: not changed" as LocalizedStringKey : app.isSystem ? "Preinstalled app" : "App you installed")
            VStack(alignment: .leading, spacing: 3) {
                Text(app.package).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                Text(details(app)).font(.caption).foregroundStyle(app.isDisabled || app.isRemovedForUser ? Color.orange : Color.secondary).lineLimit(1)
            }
            Spacer()
            Text(app.totalBytes.map(AnalyxerModel.bytes) ?? "–").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .help(["App", String(localized: "Data"), "Cache"].enumerated().map { index, label in "\(label): \([app.appBytes, app.dataBytes, app.cacheBytes][index].map(AnalyxerModel.bytes) ?? "–")" }.joined(separator: " · "))
            if !app.isRemovedForUser {
                Button("Investigate …", systemImage: "magnifyingglass") { model.importInstalledApp(app.package) }.labelStyle(.iconOnly).help("Add to an analysis project")
                Button("Open", systemImage: "play") { model.launch(app.package) }.labelStyle(.iconOnly).help("Open the app on the device").disabled(app.isDisabled)
            }
            if !app.isProtected { careButtons(app) }
        }
        .disabled(!model.connected || model.busy)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder private func careButtons(_ app: InstalledApp) -> some View {
        if app.isRemovedForUser {
            Button("Restore …", systemImage: "arrow.uturn.backward.circle") { model.appPendingChange = .restore(app) }.labelStyle(.iconOnly).help("Restore for this user")
        } else {
            if app.isDisabled {
                Button("Enable …", systemImage: "play.circle") { model.appPendingChange = .enable(app) }.labelStyle(.iconOnly).help("Enable again")
            } else {
                Button("Disable …", systemImage: "pause.circle") { model.appPendingChange = .disable(app) }.labelStyle(.iconOnly).help("Disable (can be undone)")
            }
            if app.isSystem {
                Button("Remove for User …", systemImage: "minus.circle") { model.appPendingChange = .removeForUser(app) }.labelStyle(.iconOnly).help("Remove for this user (can be undone)")
            } else {
                Button("Uninstall …", systemImage: "trash", role: .destructive) { model.appPendingChange = .uninstall(app) }.labelStyle(.iconOnly).help("Uninstall with all data")
            }
        }
    }

    private func details(_ app: InstalledApp) -> String {
        var parts = [app.source]
        if app.isRemovedForUser { parts.append(String(localized: "removed for user")) } else if app.isDisabled { parts.append(String(localized: "disabled")) }
        if app.isProtected { parts.append(String(localized: "protected")) }
        parts.append(app.lastUsed.map { String(localized: "last used \($0.formatted(date: .abbreviated, time: .shortened))") } ?? String(localized: "no usage recorded"))
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
                Text(model.inventoryDate.map { String(localized: "As of \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "Not analysed yet")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.inventoryDate == nil ? "Analyse Device" as LocalizedStringKey : "Analyse Again", systemImage: "stethoscope") { model.loadInventory() }
                    .buttonStyle(.borderedProminent).disabled(!model.connected || model.busy)
            }
            if let storage = model.storage { storageCard(storage) }
            else if model.inventoryDate == nil {
                Text("The analysis reads storage, apps and app leftovers of the selected device. It changes nothing and takes a few seconds.").foregroundStyle(.secondary)
            }
            if model.inventoryDate != nil {
                cacheCard
                leftoverCard
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preinstalled Apps").font(.headline)
                    Text("Under Installed Apps, preinstalled apps can be disabled or removed for the user; both can be undone. System components, launcher, keyboard and WebView are locked.").font(.callout).foregroundStyle(.secondary)
                    Button("Show Preinstalled Apps", systemImage: "square.grid.2x2") { model.appScope = .system; model.appSort = .size; model.page = .packages }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
            }
        }
        .confirmationDialog("Clear all app caches?", isPresented: $confirmTrim) {
            Button("Clear Caches") { model.trimCaches() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Android deletes the cached data of all apps; sign-ins and app data are kept. Apps reload what they need when they need it.") }
        .confirmationDialog(leftoversToDelete.count == 1 ? String(localized: "Remove \(leftoversToDelete[0].package)?") : String(localized: "Remove \(leftoversToDelete.count) app leftovers?"),
                            isPresented: Binding(get: { !leftoversToDelete.isEmpty }, set: { if !$0 { leftoversToDelete = [] } })) {
            let selection = leftoversToDelete
            Button("Delete Permanently", role: .destructive) { model.deleteLeftovers(selection) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(AnalyxerModel.bytes(leftoversToDelete.reduce(0) { $0 + $1.bytes })) in folders of uninstalled apps will be deleted from the device. This cannot be undone.")
        }
    }

    private func storageCard(_ storage: StorageOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.headline)
                Spacer()
                Text("\(AnalyxerModel.bytes(storage.used)) used · \(AnalyxerModel.bytes(storage.free)) free of \(AnalyxerModel.bytes(storage.total))").font(.callout).monospacedDigit()
            }
            ProgressView(value: Double(storage.used), total: Double(max(storage.total, 1))).tint(accent)
            let categories: [(String, Int64?)] = [(String(localized: "Apps"), storage.apps), (String(localized: "App Data"), storage.appData), (String(localized: "Caches"), storage.appCache),
                                                  (String(localized: "Images"), storage.photos), (String(localized: "Videos"), storage.videos), (String(localized: "Audio"), storage.audio),
                                                  (String(localized: "Downloads"), storage.downloads), (String(localized: "Other"), storage.other)]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 10) {
                ForEach(categories.filter { $0.1 != nil }, id: \.0) { name, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Text(AnalyxerModel.bytes(value ?? 0)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                }
            }
            if let system = storage.system { Text("Android system image: \(AnalyxerModel.bytes(system)), separate from data storage.").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).card()
    }

    private var cacheCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("App Caches").font(.headline)
                Text(model.storage?.appCache.map { String(localized: "\(AnalyxerModel.bytes($0)) cached. Android keeps what running apps need right now.") } ?? String(localized: "Size unknown.")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear All Caches …") { confirmTrim = true }.disabled(!model.connected || model.busy)
        }.padding(20).card()
    }

    private var leftoverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.badge.minus").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Leftovers").font(.headline)
                    let leftoverBytes = AnalyxerModel.bytes(model.leftovers.reduce(0) { $0 + $1.bytes })
                    Text(model.leftovers.isEmpty ? String(localized: "No folders of uninstalled apps found in Android/data, obb or media.")
                         : model.leftovers.count == 1 ? String(localized: "1 folder of an uninstalled app · \(leftoverBytes)")
                         : String(localized: "\(model.leftovers.count) folders of uninstalled apps · \(leftoverBytes)")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.leftovers.count > 1 { Button("Remove All …") { leftoversToDelete = model.leftovers }.disabled(!model.connected || model.busy) }
            }
            ForEach(model.leftovers) { leftover in
                HStack {
                    Text(leftover.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Text(AnalyxerModel.bytes(leftover.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Button("Remove …", systemImage: "trash", role: .destructive) { leftoversToDelete = [leftover] }.labelStyle(.iconOnly)
                        .help("Delete folder permanently").disabled(!model.connected || model.busy)
                }
            }
        }.padding(20).card()
    }
}
