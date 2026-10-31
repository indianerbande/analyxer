import SwiftUI
import AppKit
import AndroidAnalyxerCore

struct AnalysisProjectView: View {
    @EnvironmentObject var model: AnalyxerModel
    @State private var componentFilter = ""
    @State private var detailsExpanded = false
    private let accent = Color(red: 0.19, green: 0.81, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                if model.project != nil {
                    Button("Zur Übersicht", systemImage: "chevron.left") { model.closeProject() }
                        .help("Projekt schließen und zur Projektübersicht zurückkehren")
                }
                Button("Neues Projekt aus APK …", systemImage: "plus") { model.chooseAPK() }.buttonStyle(.borderedProminent)
                Button("Projekt öffnen …", systemImage: "folder") { model.chooseProject() }
                Spacer()
                if model.project != nil {
                    Button("Gesamtexport …", systemImage: "square.and.arrow.up") { model.exportProject() }
                    Button("Im Finder") { if let root = model.projectDirectory { NSWorkspace.shared.activateFileViewerSelecting([root]) } }
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
                    Text("Von der APK zum nachvollziehbaren Befund").font(.title2.weight(.semibold))
                    Text("1. APK öffnen und Projektordner wählen\n2. Manifest, Berechtigungen und DEX-Inventar prüfen\n3. Testsitzung mit einem Android-Gerät beginnen\n4. App installieren, starten und Beobachtungen speichern")
                        .lineSpacing(9).foregroundStyle(.secondary)
                    Text("Jedes Projekt enthält eine eigene APK-Kopie. Berichte, Logs, Screenshots und Notizen bleiben zusammen und lassen sich später wieder öffnen.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(26).projectCard()
                if !model.recentProjects.isEmpty {
                    Text("Zuletzt geöffnete Projekte").font(.headline)
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
                Text("Vom Gerät importiert · \(project.apkFiles.count) APKs · \(source.serial). Manifest-Angaben stammen aus der Basis-APK; weitere APKs einzeln unter Codeanalyse auswählen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Version \(project.analysis.manifest.versionName ?? "unbekannt") · minSdk \(project.analysis.manifest.minSDK ?? "nicht deklariert") · targetSdk \(project.analysis.manifest.targetSDK ?? "nicht deklariert")")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                ForEach(project.evidence.filter { $0.sessionID == nil && [.staticReport, .manifest, .dex].contains($0.kind) }) { item in
                    Button(item.kind.title, systemImage: "doc.text.magnifyingglass") { model.showEvidence(item) }
                }
            }.disabled(model.busy)
            DisclosureGroup("Komponenten und deklarierte Erreichbarkeit") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Name oder Komponententyp filtern …", text: $componentFilter).textFieldStyle(.roundedBorder)
                    Text("exported ist der explizite Manifest-Wert. Nicht deklarierte Werte, Berechtigungen und tatsächliche Erreichbarkeit müssen gesondert geprüft werden.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(project.analysis.manifest.components.filter { componentFilter.isEmpty || ($0.name + $0.kind).localizedCaseInsensitiveContains(componentFilter) }) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.kind.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                                    Spacer()
                                    Text("exported: \(item.exportDescription)").font(.caption)
                                }
                                Text(item.name).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                if let permission = item.permission { Text("Berechtigung: \(permission)").font(.caption).foregroundStyle(.secondary) }
                                ForEach(item.actions, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).projectCard()
                        }
                    }
                }.padding(.top, 12)
            }
            DisclosureGroup("Berechtigungen und Grenzen") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(project.analysis.apk.permissions, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    Divider()
                    ForEach(project.analysis.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 12)
            }
        }.padding(.top, 14)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Details & Belege").font(.headline)
                Text("Hash, Werkzeugbericht, Manifest, DEX-Inventar, alle \(project.analysis.manifest.components.count) Komponenten und die Rohliste der Berechtigungen").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).projectCard()
    }
    private func runtime(_ project: AnalysisProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1 · Im Android-Gerät testen").font(.headline)
            HStack {
                Picker("Zielgerät", selection: $model.serial) {
                    Text("Gerät auswählen").tag("")
                    ForEach(model.devices) { device in
                        Text("\(device.avdName ?? device.model) · \(device.serial) · \(device.state)").tag(device.serial)
                    }
                }.disabled(model.busy)
                Button("Emulatoren") { model.page = .devices }
            }
            if let session = model.activeSession {
                Text("Aktive Sitzung: \(session.device.serial) · Android \(session.device.properties["ro.build.version.release"] ?? "?") · \(session.device.properties["ro.product.cpu.abi"] ?? "?")")
                    .font(.caption).foregroundStyle(accent)
                if !model.projectSessionSelected {
                    Text("Für diese Sitzung das gebundene Gerät auswählen. Bei einem anderen Gerät oder Neustart eine neue Sitzung beginnen.").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Installierte App zuordnen") { model.projectAdoptInstalled() }
                    Button("APKs installieren", systemImage: "arrow.down.app") { model.projectInstall() }
                    Button("Projekt-App starten", systemImage: "play.fill") { model.projectLaunch() }.disabled(!model.projectInstalled)
                    Button("Screenshot speichern", systemImage: "camera") { model.projectScreenshot() }
                    Button("App-Logcat speichern", systemImage: "terminal") { model.projectLogs() }
                }.disabled(model.busy || !model.projectSessionSelected)
                HStack {
                    Button("Zurück") { model.projectNavigate(4) }
                    Button("Home") { model.projectNavigate(3) }
                    Button("Letzte Apps") { model.projectNavigate(187) }
                    Spacer()
                    Button("Sitzung beenden") { model.finishSession() }.disabled(model.busy)
                }.disabled(model.busy || !model.projectSessionSelected)
                // Ending a disconnected session must remain possible.
                if !model.projectSessionSelected { Button("Getrennte Sitzung beenden") { model.finishSession() }.disabled(model.busy) }
            } else {
                HStack {
                    Text("Eine Sitzung bindet alle folgenden Aktionen an dieses Gerät und dessen aktuellen Android-Start.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Testsitzung beginnen", systemImage: "record.circle") { model.beginSession() }.buttonStyle(.borderedProminent)
                        .disabled(!model.connected || model.busy)
                }
            }
            Text("Aktionen in diesem Bereich werden automatisch gespeichert. Installation verändert das Zielgerät. Screenshots zeigen den gesamten Gerätebildschirm; App-Logcat erfasst den aktuellen Hauptprozess.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).projectCard()
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3 · Beobachtungen festhalten").font(.headline)
            TextEditor(text: $model.projectNote).font(.body).frame(height: 80).scrollContentBackground(.hidden)
                .padding(8).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)).disabled(model.busy)
                .accessibilityLabel("Projektnotiz")
            HStack {
                Text(model.activeSessionID == nil ? "Die Notiz wird projektweit gespeichert." : "Die Notiz gehört zur aktiven Testsitzung.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Notiz speichern") { model.saveProjectNote() }.disabled(model.busy || model.projectNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).projectCard()
    }
    private func history(_ project: AnalysisProject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gespeicherte Befunde und Aktionen").font(.headline)
            Text("Statische Befunde und Laufzeitbeobachtungen bleiben getrennt. Jede Datei besitzt einen eigenen Hash und Zeitstempel.").font(.caption).foregroundStyle(.secondary)
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
                                Text("\(session.device.serial) · Sitzung \(id.uuidString.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Ansehen") { model.showEvidence(item) }.disabled(model.busy)
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
