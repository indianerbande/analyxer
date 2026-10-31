import SwiftUI
import AnalyxerCore

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
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Creating app profile …").foregroundStyle(.secondary) }.padding(.horizontal, 4)
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
                    Text("\(project.packageName) · Version \(manifest.versionName ?? String(localized: "unknown"))").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                    Text(project.updatedAt, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                fact("Android", value: android(min: manifest.minSDK, target: manifest.targetSDK), icon: "iphone.gen3")
                fact(String(localized: "Contents"), value: profile.map { "\($0.apkCount) APK\($0.apkCount == 1 ? "" : "s") · \(AnalyxerModel.bytes($0.totalBytes))" } ?? "\(project.apkFiles.count) APKs", icon: "shippingbox")
                fact(String(localized: "Technology"), value: profile.map { $0.frameworks.isEmpty ? "Java/Kotlin" : $0.frameworks.joined(separator: ", ") } ?? "…", icon: "cpu")
                fact(String(localized: "Architecture"), value: profile.map { $0.abis.isEmpty ? String(localized: "no native code") : $0.abis.joined(separator: ", ") } ?? "…", icon: "memorychip")
                fact(String(localized: "Origin"), value: project.installedSource.map { String(localized: "from device \($0.serial)") } ?? String(localized: "APK file \(project.originalAPKName)"), icon: "arrow.down.circle")
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func android(min: String?, target: String?) -> String {
        let minimum = AppProfile.android(min).map { String(localized: "\($0) or later") } ?? min.map { String(localized: "API \($0) or later") } ?? String(localized: "unknown")
        let targeted = AppProfile.android(target).map { String(localized: "targets \($0)") }
        return [minimum, targeted].compactMap { $0 }.joined(separator: " · ")
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
            Text("At a Glance").font(.headline)
            if profile.highlights.isEmpty { Text("Nothing notable in permissions, libraries and manifest.").foregroundStyle(.secondary) }
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
                Text("Permissions").font(.headline)
                (special == 1 ? Text("\(profile.permissions.count) requested · \(dangerous) needing approval · 1 special access")
                     : Text("\(profile.permissions.count) requested · \(dangerous) needing approval · \(special) special access")).font(.caption).foregroundStyle(.secondary)
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
            Text("Needs approval: Android asks the user. Special access: must be allowed separately in Settings. No prompt: granted on installation. Hover for the raw name.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func libraries(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Included Libraries").font(.headline)
                Text("\(profile.sdks.count) detected · \(profile.trackingSDKs.count) for advertising or tracking").font(.caption).foregroundStyle(.secondary)
            }
            if profile.sdks.isEmpty { Text("No known libraries detected.").foregroundStyle(.secondary) }
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
                Text("The game logic is native code (IL2CPP). What is detected are the bundled libraries, not the behaviour of the game itself.").font(.caption).foregroundStyle(.secondary)
            }
            if profile.dexInventoryTruncated {
                Text("The stored DEX inventory is truncated; detection relies mainly on the manifest, native libraries and library markers.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func reachability(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reachable from Outside").font(.headline)
            Text(profile.reachable.isEmpty ? String(localized: "No component is exposed to other apps.") : profile.reachable.map(\.title).joined(separator: " · ")).font(.callout)
            if !profile.webLinkHosts.isEmpty {
                Label(String(localized: "Opens web links: \(profile.webLinkHosts.joined(separator: ", "))"), systemImage: "link").font(.callout).textSelection(.enabled)
            }
            if !profile.linkSchemes.isEmpty {
                Label(String(localized: "Custom link schemes: \(profile.linkSchemes.joined(separator: ", "))"), systemImage: "arrow.up.right.square").font(.callout).textSelection(.enabled)
            }
            Text("Other apps or links can start these components. The details are under Details & Evidence.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private static func levelColor(_ level: PermissionLevel) -> Color {
        switch level {
        case .special: .orange
        case .dangerous: .yellow
        default: .secondary
        }
    }

    /// Keyed by the localized group names that `PermissionInfo.group` carries.
    private static let groupIcon: [String: String] = Dictionary(uniqueKeysWithValues: [
        ("Location", "location"), ("Camera & Microphone", "camera"), ("Contacts & Accounts", "person.2"), ("Calendar", "calendar"), ("Phone & Calls", "phone"),
        ("SMS & MMS", "message"), ("Photos, Media & Files", "photo.on.rectangle"), ("Body & Activity", "figure.walk"),
        ("Nearby Devices", "dot.radiowaves.left.and.right"), ("Advertising & Tracking", "eye"), ("Overlays & System Access", "rectangle.on.rectangle"),
        ("Background & Autostart", "clock.arrow.circlepath"), ("Notifications", "bell"), ("Network & Internet", "network"), ("Purchases & Licences", "creditcard"),
        ("Push Messages", "bell.badge"), ("Hardware & Other", "cpu"), ("Vendor Interfaces", "building.2"), ("App-Internal", "lock.shield"), ("Other", "questionmark.circle"),
    ].map { (String(localized: String.LocalizationValue($0.0)), $0.1) })
}
