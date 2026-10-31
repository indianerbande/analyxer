import SwiftUI
import AppKit
import AnalyxerCore

struct AnalysisProjectView: View {
    @EnvironmentObject var model: AnalyxerModel
    @State private var componentFilter = ""
    @State private var detailsExpanded = false
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                if model.project != nil {
                    Button("Back to Overview", systemImage: "chevron.left") { model.closeProject() }
                        .help("Close the project and return to the project overview")
                }
                Button("New Project from APK …", systemImage: "plus") { model.chooseAPK() }.buttonStyle(.borderedProminent)
                Button("Open Project …", systemImage: "folder") { model.chooseProject() }
                Spacer()
                if model.project != nil {
                    Button("Export All …", systemImage: "square.and.arrow.up") { model.exportProject() }
                    Button("Show in Finder") { if let root = model.projectDirectory { NSWorkspace.shared.activateFileViewerSelecting([root]) } }
                }
            }.disabled(model.busy)
            if let project = model.project {
                AppProfileView(project: project)
                staticReport(project)
                runtime(project)
                DeepAnalysisView()
                notes
                history(project)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 40)).foregroundStyle(accent)
                    Text("From the APK to a traceable finding").font(.title2.weight(.semibold))
                    Text("1. Open an APK and choose a project folder\n2. Check the manifest, permissions and DEX inventory\n3. Start a test session with an Android device\n4. Install and launch the app, then save observations")
                        .lineSpacing(9).foregroundStyle(.secondary)
                    Text("Every project contains its own copy of the APK. Reports, logs, screenshots and notes stay together and can be opened again later.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(26).projectCard()
                if !model.recentProjects.isEmpty {
                    Text("Recently Opened Projects").font(.headline)
                    ForEach(model.recentProjects, id: \.self) { path in
                        Button { model.openProject(URL(fileURLWithPath: path)) } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                                    Text(path).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right")
                            }.padding(14).projectCard()
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }
            }
        }
    }

    private func staticReport(_ project: AnalysisProject) -> some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
        VStack(alignment: .leading, spacing: 16) {
            Text("SHA-256  " + project.analysis.apk.sha256).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if let source = project.installedSource {
                Text("Imported from the device · APKs: \(project.apkFiles.count) · \(source.serial). Manifest details come from the base APK; choose further APKs individually under code analysis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Version \(project.analysis.manifest.versionName ?? String(localized: "unknown")) · minSdk \(project.analysis.manifest.minSDK ?? String(localized: "not declared")) · targetSdk \(project.analysis.manifest.targetSDK ?? String(localized: "not declared"))")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                ForEach(project.evidence.filter { $0.sessionID == nil && [.staticReport, .manifest, .dex].contains($0.kind) }) { item in
                    Button(item.kind.title, systemImage: "doc.text.magnifyingglass") { model.showEvidence(item) }
                }
            }.disabled(model.busy)
            DisclosureGroup("Components and Declared Reachability") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Filter by name or component type …", text: $componentFilter).textFieldStyle(.roundedBorder)
                    Text("exported is the explicit manifest value. Undeclared values, permissions and actual reachability must be checked separately.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(project.analysis.manifest.components.filter { componentFilter.isEmpty || ($0.name + $0.kind).localizedCaseInsensitiveContains(componentFilter) }) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.kind.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                                    Spacer()
                                    Text(verbatim: "exported: \(item.exported ?? String(localized: "not declared"))").font(.caption)
                                }
                                Text(item.name).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                if let permission = item.permission { Text("Permission: \(permission)").font(.caption).foregroundStyle(.secondary) }
                                ForEach(item.actions, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).projectCard()
                        }
                    }
                }.padding(.top, 12)
            }
            DisclosureGroup("Permissions and Limitations") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(project.analysis.apk.permissions, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    Divider()
                    ForEach(project.analysis.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 12)
            }
        }.padding(.top, 14)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Details & Evidence").font(.headline)
                Text("Hash, tool report, manifest, DEX inventory, all components (\(project.analysis.manifest.components.count)) and the raw list of permissions").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).projectCard()
    }
    private func runtime(_ project: AnalysisProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1 · Test on an Android Device").font(.headline)
            HStack {
                Picker("Target device", selection: $model.serial) {
                    Text("Choose a device").tag("")
                    ForEach(model.devices) { device in
                        Text("\(device.avdName ?? device.model) · \(device.serial) · \(device.state)").tag(device.serial)
                    }
                }.disabled(model.busy)
                Button("Emulators") { model.page = .devices }
            }
            if let session = model.activeSession {
                Text("Active session: \(session.device.serial) · Android \(session.device.properties["ro.build.version.release"] ?? "?") · \(session.device.properties["ro.product.cpu.abi"] ?? "?")")
                    .font(.caption).foregroundStyle(accent)
                if !model.projectSessionSelected {
                    Text("Choose the device bound to this session. For another device or after a restart, start a new session.").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Adopt Installed App") { model.projectAdoptInstalled() }
                    Button("Install APKs", systemImage: "arrow.down.app") { model.projectInstall() }
                    Button("Launch Project App", systemImage: "play.fill") { model.projectLaunch() }.disabled(!model.projectInstalled)
                    Button("Save Screenshot", systemImage: "camera") { model.projectScreenshot() }
                    Button("Save App Logcat", systemImage: "terminal") { model.projectLogs() }
                }.disabled(model.busy || !model.projectSessionSelected)
                HStack {
                    Button("Back") { model.projectNavigate(4) }
                    Button("Home") { model.projectNavigate(3) }
                    Button("Recent Apps") { model.projectNavigate(187) }
                    Spacer()
                    Button("End Session") { model.finishSession() }.disabled(model.busy)
                }.disabled(model.busy || !model.projectSessionSelected)
                // Ending a disconnected session must remain possible.
                if !model.projectSessionSelected { Button("End Disconnected Session") { model.finishSession() }.disabled(model.busy) }
            } else {
                HStack {
                    Text("A session binds all following actions to this device and its current Android boot.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Test Session", systemImage: "record.circle") { model.beginSession() }.buttonStyle(.borderedProminent)
                        .disabled(!model.connected || model.busy)
                }
            }
            Text("Actions in this area are saved automatically. Installing changes the target device. Screenshots show the whole device screen; App Logcat captures the current main process.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).projectCard()
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3 · Record Observations").font(.headline)
            TextEditor(text: $model.projectNote).font(.body).frame(height: 80).scrollContentBackground(.hidden)
                .padding(8).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)).disabled(model.busy)
                .accessibilityLabel("Project note")
            HStack {
                (model.activeSessionID == nil ? Text("The note is saved for the whole project.") : Text("The note belongs to the active test session.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save Note") { model.saveProjectNote() }.disabled(model.busy || model.projectNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).projectCard()
    }
    private func history(_ project: AnalysisProject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved Findings and Actions").font(.headline)
            Text("Static findings and runtime observations stay separate. Every file has its own hash and timestamp.").font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(project.evidence.reversed()) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.kind == .failure ? "exclamationmark.triangle" : (item.kind == .screenshot ? "photo" : "doc.text"))
                            .foregroundStyle(item.kind == .failure ? .orange : accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.kind.title).fontWeight(.medium)
                            Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.timestamp, format: .dateTime.day().month().hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                            if let id = item.sessionID, let session = project.sessions.first(where: { $0.id == id }) {
                                Text("\(session.device.serial) · Session \(String(id.uuidString.prefix(8)))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("View") { model.showEvidence(item) }.disabled(model.busy)
                    }.padding(.vertical, 12)
                    Divider()
                }
            }
        }
    }
}

private extension View {
    func projectCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.065), lineWidth: 1))
    }
}
