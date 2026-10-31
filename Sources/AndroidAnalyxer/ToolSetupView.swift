import SwiftUI
import AppKit
import AndroidAnalyxerCore

extension ToolID {
    var title: LocalizedStringKey {
        switch self {
        case .jdk: "Java Development Kit"
        case .node: "Node.js"
        case .rea: "REA"
        case .jadx: "JADX headless MCP"
        case .fridaBridge: "Frida Java bridge"
        case .fridaServer: "frida-server"
        case .androidSDK: "Android SDK"
        }
    }
    var purpose: LocalizedStringKey {
        switch self {
        case .jdk: "Runs JADX and the Android command-line tools."
        case .node: "Runs REA and builds the Frida bridge."
        case .rea: "Code analysis and process observation."
        case .jadx: "Decompiles Java and Kotlin code for REA."
        case .fridaBridge: "Lets REA watch Java methods inside the app process."
        case .fridaServer: "Runs on the analysis device; must match REA's Frida version."
        case .androidSDK: "Emulator, adb, aapt2, apkanalyzer, avdmanager and sdkmanager."
        }
    }
    /// Shown before a download starts.
    var source: LocalizedStringKey {
        switch self {
        case .jdk: "Eclipse Temurin JDK 25 from Adoptium, about 130 MB, SHA-256 checked."
        case .node: "Node.js 24.22.2 from nodejs.org, about 50 MB, SHA-256 checked."
        case .rea: "REA 6.8.0 from npm (about 220 MB with dependencies) plus Frida's native component from GitHub."
        case .jadx: "jadx-headless-mcp from GitHub, about 42 MB, checked against the SHA-256 REA specifies."
        case .fridaBridge: "frida-java-bridge 7.0.13 from npm, about 1 MB; built locally with REA's Frida."
        case .fridaServer: "frida-server from Frida's GitHub releases, about 17 MB, SHA-256 checked."
        case .androidSDK: "Google's Android command-line tools and SDK packages."
        }
    }
    /// What has to be in place before this tool can be installed.
    var prerequisites: [ToolID] {
        switch self {
        case .rea: [.node]
        case .jadx: [.rea]
        case .fridaBridge: [.node, .rea]
        case .fridaServer: [.rea]
        case .androidSDK: [.jdk]
        default: []
        }
    }
}

extension AnalyxerModel {
    var toolSetup: ToolSetupService {
        ToolSetupService(toolsFolder: toolsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }, sdkRoot: paths.root, configured: analysisTools)
    }
    var suggestedToolsFolder: URL { paths.root.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("analyxer-tools", isDirectory: true) }

    func checkTools() {
        let setup = toolSetup
        Task {
            let statuses = await setup.check()
            self.toolStatuses = statuses
            // Point the analysis profile at whatever is ready, so REA, JADX and Frida work without editing paths.
            let profile = setup.resolvedProfile(from: statuses)
            if profile != self.analysisTools { self.analysisTools = profile; self.saveAnalysisTools() }
        }
    }

    func chooseToolsFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = toolsFolder.map { URL(fileURLWithPath: $0) } ?? suggestedToolsFolder.deletingLastPathComponent()
        panel.message = String(localized: "Choose a folder for the analysis tools (Node.js, REA, JADX, Frida, JDK)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        toolsFolder = url.path; UserDefaults.standard.set(url.path, forKey: "toolsFolder")
        checkTools()
    }

    func useSuggestedToolsFolder() {
        toolsFolder = suggestedToolsFolder.path; UserDefaults.standard.set(toolsFolder, forKey: "toolsFolder")
        checkTools()
    }

    func status(_ tool: ToolID) -> ToolStatus? { toolStatuses.first { $0.id == tool } }

    /// Prerequisites that are not ready yet, in display order.
    func missingPrerequisites(_ tool: ToolID) -> [ToolID] { tool.prerequisites.filter { status($0)?.state != .ready } }

    func installTool(_ tool: ToolID, includePlayImage: Bool = false) {
        guard toolInstalling == nil else { return }
        let setup = toolSetup
        toolInstalling = tool; toolMessage = ""; toolFraction = nil; error = nil
        Task {
            do {
                try await setup.install(tool, includePlayImage: includePlayImage) { message, fraction in
                    Task { @MainActor in self.toolMessage = message; self.toolFraction = fraction }
                }
                self.message = String(localized: "\(String(localized: tool.titleText)) is installed.")
            } catch { self.error = error.localizedDescription }
            self.toolInstalling = nil
            self.checkTools()
        }
    }

    /// Everything missing except the Android SDK, which needs the licence step; installed in dependency order.
    func installMissingTools() {
        guard toolInstalling == nil else { return }
        let setup = toolSetup
        Task {
            for tool in ToolID.allCases where tool != .androidSDK {
                let statuses = await setup.check()
                guard let state = statuses.first(where: { $0.id == tool })?.state, state != .ready else { continue }
                self.toolStatuses = statuses
                self.toolInstalling = tool; self.toolMessage = ""; self.toolFraction = nil
                do {
                    try await setup.install(tool) { message, fraction in Task { @MainActor in self.toolMessage = message; self.toolFraction = fraction } }
                } catch { self.error = error.localizedDescription; break }
            }
            self.toolInstalling = nil
            self.checkTools()
        }
    }

    func loadAndroidLicenses() {
        guard toolInstalling == nil else { return }
        let setup = toolSetup
        toolInstalling = .androidSDK; androidLicenseText = nil
        Task {
            do {
                let text = try await setup.androidLicenses { message, fraction in Task { @MainActor in self.toolMessage = message; self.toolFraction = fraction } }
                self.androidLicenseText = text
            } catch { self.error = error.localizedDescription }
            self.toolInstalling = nil
        }
    }

    func acceptLicensesAndInstallSDK() {
        guard toolInstalling == nil else { return }
        let setup = toolSetup, play = includePlayImage, needsAcceptance = !(androidLicenseText ?? "").isEmpty
        showAndroidSetup = false
        toolInstalling = .androidSDK
        Task {
            do {
                if needsAcceptance { try await setup.acceptAndroidLicenses() }
                try await setup.install(.androidSDK, includePlayImage: play) { message, fraction in Task { @MainActor in self.toolMessage = message; self.toolFraction = fraction } }
                self.message = String(localized: "The Android SDK is set up.")
                self.ownAVDs = []; self.studioAVDs = []; self.devices = []
                await self.refresh()
            } catch { self.error = error.localizedDescription }
            self.toolInstalling = nil
            self.checkTools()
        }
    }
}

extension ToolID {
    /// Plain string for messages built in code.
    var titleText: String.LocalizationValue {
        switch self {
        case .jdk: "Java Development Kit"
        case .node: "Node.js"
        case .rea: "REA"
        case .jadx: "JADX headless MCP"
        case .fridaBridge: "Frida Java bridge"
        case .fridaServer: "frida-server"
        case .androidSDK: "Android SDK"
        }
    }
}

/// Analysis tools on the Setup page: status, install and update.
struct ToolSetupView: View {
    @EnvironmentObject var model: AnalyxerModel
    @State private var pendingInstall: ToolID?
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Analysis Tools").font(.headline)
                Text("Checks and installs what code and runtime analysis need. Downloads come only from the official sources and are checked against published checksums before anything is unpacked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools folder").font(.system(size: 9, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    if let folder = model.toolsFolder { Text(folder).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    else { Text("Not chosen yet. Suggested: \(model.suggestedToolsFolder.path)").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                if model.toolsFolder == nil { Button("Use Suggestion") { model.useSuggestedToolsFolder() } }
                Button("Choose Folder …") { model.chooseToolsFolder() }
            }.padding(16).card().disabled(model.toolInstalling != nil)

            VStack(spacing: 0) {
                ForEach(ToolID.allCases) { tool in
                    row(tool)
                    if tool != ToolID.allCases.last { Divider().opacity(0.4) }
                }
            }.card()

            HStack {
                Button("Check Again", systemImage: "arrow.clockwise") { model.checkTools() }
                Spacer()
                let missing = model.toolStatuses.filter { $0.id != .androidSDK && $0.state != .ready }
                Button("Install Everything Missing …") { pendingInstall = nil; model.confirmInstallMissing = true }
                    .disabled(missing.isEmpty || model.toolsFolder == nil || model.toolInstalling != nil)
            }
        }
        .task { model.checkTools() }
        .confirmationDialog(pendingInstall.map { Text("Install \(String(localized: $0.titleText))?") } ?? Text(""),
                            isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }), presenting: pendingInstall) { tool in
            Button("Download and Install") { model.installTool(tool) }
            Button("Cancel", role: .cancel) {}
        } message: { tool in Text(tool.source) }
        .confirmationDialog("Install everything missing?", isPresented: $model.confirmInstallMissing) {
            Button("Download and Install") { model.installMissingTools() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Missing tools are downloaded from their official sources into the tools folder and checked against published checksums. The Android SDK is set up separately because of its licences.")
        }
        .sheet(isPresented: $model.showAndroidSetup) { AndroidSDKSetupSheet() }
    }

    @ViewBuilder private func row(_ tool: ToolID) -> some View {
        let status = model.status(tool), installing = model.toolInstalling == tool
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(status?.state)).foregroundStyle(color(status?.state)).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.title).font(.callout.weight(.semibold))
                    if let version = status?.version { Text(version).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                if let location = status?.location, status?.state != .missing {
                    Text(location.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let note = status?.note { Text(verbatim: note).font(.caption).foregroundStyle(.orange) }
                if installing {
                    HStack(spacing: 8) {
                        if let fraction = model.toolFraction { ProgressView(value: fraction).frame(width: 160) } else { ProgressView().controlSize(.small) }
                        Text(model.toolMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            action(tool, status: status)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func action(_ tool: ToolID, status: ToolStatus?) -> some View {
        let blocked = model.missingPrerequisites(tool)
        let disabled = model.toolInstalling != nil || (tool != .androidSDK && model.toolsFolder == nil) || !blocked.isEmpty
        let help = blocked.isEmpty ? (model.toolsFolder == nil && tool != .androidSDK ? String(localized: "Choose a tools folder first.") : "")
            : String(localized: "Needs \(blocked.map { String(localized: $0.titleText) }.joined(separator: ", ")) first.")
        if tool == .androidSDK {
            Button(status?.state == .ready ? "Add Packages …" : "Set Up …") { model.androidLicenseText = nil; model.showAndroidSetup = true }
                .disabled(disabled).help(help)
        } else if let state = status?.state, state != .ready {
            Button(state == .outdated ? "Update …" : state == .problem ? "Repair …" : "Install …") { pendingInstall = tool }
                .disabled(disabled).help(help)
        }
    }

    private func icon(_ state: ToolStatus.State?) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .outdated: "arrow.up.circle"
        case .problem: "exclamationmark.triangle.fill"
        case .missing: "circle.dashed"
        case nil: "hourglass"
        }
    }
    private func color(_ state: ToolStatus.State?) -> Color {
        switch state {
        case .ready: accent
        case .outdated, .problem: .orange
        default: .secondary
        }
    }
}

/// Android SDK set-up: target folder, packages and the licences the user must accept before anything is installed.
struct AndroidSDKSetupSheet: View {
    @EnvironmentObject var model: AnalyxerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up the Android SDK").font(.title2.weight(.semibold))
            Text("Target folder: \(model.sdkRoot)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Text("Installs Google's command-line tools if needed, then: \(ToolRequirements.androidPackages.joined(separator: ", ")).").font(.callout)
            Toggle(isOn: $model.includePlayImage) {
                Text("Also install a Google Play system image (\(ToolRequirements.playImage(arm: ToolSetupService.hostIsARM)), about 2 GB)")
            }
            Divider()
            if let text = model.androidLicenseText {
                if text.isEmpty {
                    Text("All Android SDK licences are already accepted.").foregroundStyle(.secondary)
                } else {
                    Text("Google requires you to accept these licences before the SDK packages are installed:").font(.callout.weight(.semibold))
                    EvidenceTextView(text: text).frame(minHeight: 260)
                }
            } else if model.toolInstalling == .androidSDK {
                HStack(spacing: 8) {
                    if let fraction = model.toolFraction { ProgressView(value: fraction).frame(width: 200) } else { ProgressView().controlSize(.small) }
                    Text(model.toolMessage).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Loading the licence texts needs a JDK and downloads Google's command-line tools (about 150 MB) if they are missing. Nothing is accepted yet.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Show Licences") { model.loadAndroidLicenses() }.disabled(model.status(.jdk)?.state != .ready)
            }
            Spacer()
            HStack {
                Link("Android SDK terms", destination: URL(string: "https://developer.android.com/studio/terms")!).font(.caption)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button((model.androidLicenseText ?? "").isEmpty ? "Install" : "Accept Licences and Install") { model.acceptLicensesAndInstallSDK() }
                    .buttonStyle(.borderedProminent).disabled(model.androidLicenseText == nil || model.toolInstalling != nil)
            }
        }.padding(24).frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
    }
}
