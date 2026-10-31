import SwiftUI
import AndroidAnalyxerCore

extension AnalyxerModel {
    /// Reads the project's APK directories in the background; the profile only interprets data already in the project.
    func loadAppProfile() {
        guard let store = projectStore, let project else { appProfile = nil; return }
        let directory = store.directory
        appProfile = nil; profileLoading = true
        Task {
            let profile = try? await AppProfileService().profile(project: project, root: directory)
            guard self.projectDirectory == directory else { return }
            self.appProfile = profile; self.profileLoading = false
        }
    }
}

/// Plain-language overview of a project's APK at the top of the project page.
struct AppProfileView: View {
    @EnvironmentObject var model: AnalyxerModel
    let project: AnalysisProject
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let profile = model.appProfile {
                highlights(profile)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 430), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    permissions(profile)
                    VStack(alignment: .leading, spacing: 16) {
                        libraries(profile)
                        reachability(profile)
                    }
                }
            } else if model.profileLoading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Steckbrief wird erstellt …").foregroundStyle(.secondary) }.padding(.horizontal, 4)
            }
        }
    }

    private var header: some View {
        let profile = model.appProfile, manifest = project.analysis.manifest
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "shippingbox.fill").font(.largeTitle).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.title).font(.title2.weight(.semibold))
                    Text("\(project.packageName) · Version \(manifest.versionName ?? "unbekannt")").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Gespeichert", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                    Text(project.updatedAt, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                fact("Android", value: android(min: manifest.minSDK, target: manifest.targetSDK), icon: "iphone.gen3")
                fact("Umfang", value: profile.map { "\($0.apkCount) APK\($0.apkCount == 1 ? "" : "s") · \(AnalyxerModel.bytes($0.totalBytes))" } ?? "\(project.apkFiles.count) APKs", icon: "shippingbox")
                fact("Technik", value: profile.map { $0.frameworks.isEmpty ? "Java/Kotlin" : $0.frameworks.joined(separator: ", ") } ?? "…", icon: "cpu")
                fact("Architektur", value: profile.map { $0.abis.isEmpty ? "ohne nativen Code" : $0.abis.joined(separator: ", ") } ?? "…", icon: "memorychip")
                fact("Herkunft", value: project.installedSource.map { "vom Gerät \($0.serial)" } ?? "APK-Datei \(project.originalAPKName)", icon: "arrow.down.circle")
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func android(min: String?, target: String?) -> String {
        let minimum = AppProfile.android(min).map { "ab \($0)" } ?? min.map { "ab API \($0)" } ?? "unbekannt"
        let targeted = AppProfile.android(target).map { " · für \($0)" } ?? ""
        return minimum + targeted
    }

    private func fact(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Text(value).font(.callout).lineLimit(2)
            }
        }
    }

    private func highlights(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auf einen Blick").font(.headline)
            if profile.highlights.isEmpty { Text("Nichts Auffälliges in Berechtigungen, Bibliotheken und Manifest.").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Array(profile.highlights.enumerated()), id: \.offset) { _, item in
                    Label(item.text, systemImage: item.notable ? "exclamationmark.circle.fill" : "info.circle")
                        .font(.callout).foregroundStyle(item.notable ? Color.orange : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                        .background((item.notable ? Color.orange : Color.white).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func permissions(_ profile: AppProfile) -> some View {
        let dangerous = profile.permissions.filter { $0.level == .dangerous }.count, special = profile.permissions.filter { $0.level == .special }.count
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Berechtigungen").font(.headline)
                Text("\(profile.permissions.count) angefordert · \(dangerous) mit Freigabe · \(special) Sonderzugriff\(special == 1 ? "" : "e")").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(profile.permissionsByGroup, id: \.group) { group, items in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group, systemImage: Self.groupIcon[group] ?? "questionmark.circle").font(.subheadline.weight(.semibold))
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.label).font(.callout)
                            Spacer()
                            Text(item.level.title).font(.caption).foregroundStyle(Self.levelColor(item.level))
                        }.padding(.leading, 26).help(item.name)
                    }
                }
            }
            Text("Freigabe nötig: Android fragt den Nutzer. Sonderzugriff: muss in den Einstellungen eigens erlaubt werden. Ohne Rückfrage: wird bei der Installation gewährt. Rohname per Mauszeiger.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func libraries(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enthaltene Bibliotheken").font(.headline)
                Text("\(profile.sdks.count) erkannt · \(profile.trackingSDKs.count) für Werbung oder Tracking").font(.caption).foregroundStyle(.secondary)
            }
            if profile.sdks.isEmpty { Text("Keine bekannten Bibliotheken erkannt.").foregroundStyle(.secondary) }
            ForEach(profile.sdksByCategory, id: \.category) { category, items in
                VStack(alignment: .leading, spacing: 6) {
                    Text(category).font(.subheadline.weight(.semibold))
                        .foregroundStyle(SDKCatalog.trackingCategories.contains(category) ? Color.orange : Color.primary)
                    ForEach(items) { sdk in
                        HStack(alignment: .firstTextBaseline) {
                            Text(sdk.name).font(.callout)
                            Spacer()
                            Text(sdk.sources.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.leading, 12)
                    }
                }
            }
            if profile.frameworks.contains(where: { $0.hasPrefix("Unity (IL2CPP)") }) {
                Text("Die Spiellogik liegt als nativer Code vor (IL2CPP). Erkannt werden die eingebundenen Bibliotheken, nicht das Verhalten des Spiels selbst.").font(.caption).foregroundStyle(.secondary)
            }
            if profile.dexInventoryTruncated {
                Text("Das gespeicherte DEX-Inventar ist abgeschnitten; die Erkennung stützt sich vor allem auf Manifest, native Bibliotheken und Bibliothekskennungen.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func reachability(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Von außen erreichbar").font(.headline)
            Text(profile.reachable.isEmpty ? "Keine Komponente für andere Apps freigegeben." : profile.reachable.map(\.title).joined(separator: " · ")).font(.callout)
            if !profile.webLinkHosts.isEmpty {
                Label("Öffnet Weblinks: " + profile.webLinkHosts.joined(separator: ", "), systemImage: "link").font(.callout).textSelection(.enabled)
            }
            if !profile.linkSchemes.isEmpty {
                Label("Eigene Link-Schemata: " + profile.linkSchemes.joined(separator: ", "), systemImage: "arrow.up.right.square").font(.callout).textSelection(.enabled)
            }
            Text("Andere Apps oder Links können diese Komponenten starten. Die Einzelheiten stehen unter Details & Belege.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private static func levelColor(_ level: PermissionLevel) -> Color {
        switch level {
        case .special: .orange
        case .dangerous: .yellow
        default: .secondary
        }
    }

    private static let groupIcon = [
        "Standort": "location", "Kamera & Mikrofon": "camera", "Kontakte & Konten": "person.2", "Kalender": "calendar", "Telefon & Anrufe": "phone",
        "SMS & MMS": "message", "Fotos, Medien & Dateien": "photo.on.rectangle", "Körper & Aktivität": "figure.walk",
        "Geräte in der Nähe": "dot.radiowaves.left.and.right", "Werbung & Tracking": "eye", "Über anderen Apps & Systemzugriff": "rectangle.on.rectangle",
        "Hintergrund & Autostart": "clock.arrow.circlepath", "Benachrichtigungen": "bell", "Netzwerk & Internet": "network", "Käufe & Lizenzen": "creditcard",
        "Push-Nachrichten": "bell.badge", "Hardware & Sonstiges": "cpu", "Herstellerschnittstellen": "building.2", "App-intern": "lock.shield", "Sonstiges": "questionmark.circle",
    ]
}
