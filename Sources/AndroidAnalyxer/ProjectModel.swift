import SwiftUI
import AppKit
import AndroidAnalyxerCore

extension AnalyxerModel {
    var activeSession: AnalysisSession? { project?.sessions.first { $0.id == activeSessionID && $0.endedAt == nil } }
    var projectSessionSelected: Bool { activeSession?.device.serial == serial && connected }
    var projectInstalled: Bool { project?.evidence.contains { $0.sessionID == activeSessionID && [.installation, .installedApp].contains($0.kind) } == true }

    func createProject(from source: URL) {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Analyseprojekt anlegen"
        panel.message = "Eine eigene APK-Kopie, der Bericht und alle späteren Befunde werden in diesem Projektordner gespeichert."
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".androidlab"
        panel.prompt = "Projekt anlegen"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let current = service
        perform("Projekt wird angelegt und APK statisch analysiert …") {
            let store = try await ProjectStore.create(at: destination, apk: source, service: current)
            try await self.useProject(store)
            self.message = "Analyseprojekt gespeichert. Für Laufzeittests eine Testsitzung beginnen."
        }
    }
    func chooseProject() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Analyseprojekt-Ordner mit project.json auswählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }
    func openProject(_ url: URL) {
        guard !busy else { return }
        perform("Projekt wird geöffnet und APK-Hash geprüft …") {
            let store = try await ProjectStore.open(at: url)
            try await self.useProject(store)
            self.message = "Projekt geöffnet. Neue Laufzeitaktionen benötigen eine neue Testsitzung."
        }
    }
    /// Back to the project overview. Like switching projects, unsaved note text is stored and an open test session ends.
    func closeProject() {
        guard !busy, let store = projectStore else { return }
        let note = projectNote, session = activeSessionID
        let keepNote = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        perform("Projekt wird geschlossen …") {
            if keepNote { try await store.addNote(note, sessionID: session) }
            if let session { try await store.endSession(session) }
            self.projectStore = nil; self.project = nil; self.projectDirectory = nil; self.appProfile = nil; self.profileLoading = false
            self.activeSessionID = nil; self.projectNote = ""; self.evidencePreview = nil
            self.analysisComponent = "input/application.apk"; self.apk = nil; self.report = nil
            self.message = "Projekt geschlossen." + (keepNote ? " Die offene Notiz ist im Projekt gespeichert." : "") + (session == nil ? "" : " Die Testsitzung wurde beendet.")
        }
    }
    private func useProject(_ incoming: ProjectStore) async throws {
        var store = incoming
        // Unsaved note text is retained when switching to another verified project.
        if let old = projectStore {
            if !projectNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try await old.addNote(projectNote, sessionID: activeSessionID) }
            if let id = activeSessionID { try await old.endSession(id) }
            if old.directory == incoming.directory { store = try await ProjectStore.open(at: incoming.directory) }
        }
        let value = await store.snapshot()
        let input = try await store.verifiedAPK()
        projectStore = store; project = value; projectDirectory = store.directory
        activeSessionID = nil; projectNote = ""; evidencePreview = nil
        analysisComponent = "input/application.apk"
        apk = input; report = value.analysis.apk; page = .projects
        resetInventory(); logText = ""; screenshot = nil; screenshotData = nil
        recentProjects = ([store.directory.path] + recentProjects.filter { $0 != store.directory.path }).prefix(8).map { $0 }
        UserDefaults.standard.set(recentProjects, forKey: "recentProjects")
        loadAppProfile()
    }
    func projectOperation(_ label: String, completion: String? = nil, operation: @escaping (ProjectStore, ProjectWorkflow) async throws -> Void) {
        guard !busy, let store = projectStore else { return }
        let workflow = ProjectWorkflow(store: store, service: service)
        perform(label) {
            do { try await operation(store, workflow) }
            catch { self.project = await store.snapshot(); throw error }
            self.project = await store.snapshot()
            self.message = completion ?? "\(label) – im Projekt gespeichert."
        }
    }
    func beginSession() {
        guard connected else { return }
        let target = serial
        projectOperation("Testsitzung beginnen") { _, workflow in
            let session = try await workflow.begin(serial: target)
            await MainActor.run { self.activeSessionID = session.id }
        }
    }
    func finishSession() {
        guard let id = activeSessionID else { return }
        projectOperation("Testsitzung beenden") { store, _ in
            try await store.endSession(id)
            await MainActor.run { self.activeSessionID = nil }
        }
    }
    func projectInstall() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation("Projekt-APK installieren") { _, workflow in try await workflow.install(sessionID: id) }
    }
    func projectAdoptInstalled() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation("Installierte App prüfen und zuordnen") { _, workflow in try await workflow.adoptInstalled(sessionID: id) }
    }
    func importInstalledApp(_ package: String) {
        guard connected, !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Installierte App untersuchen"
        panel.message = "Basis-APK und alle derzeit installierten Splits werden in einem eigenen Analyseprojekt gesichert."
        panel.nameFieldStringValue = package + ".androidlab"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let current = service, target = serial
        perform("Installierte APKs werden gesichert und analysiert …") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("android-analyxer-import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let capture = try await current.captureInstalledApp(serial: target, package: package, to: temporary)
            let store = try await ProjectStore.create(at: destination, apk: capture.baseAPK, service: current, installed: capture)
            try await self.useProject(store)
            let workflow = ProjectWorkflow(store: store, service: current)
            let session = try await workflow.begin(serial: target)
            self.activeSessionID = session.id
            do { try await workflow.adoptInstalled(sessionID: session.id) }
            catch { self.project = await store.snapshot(); throw error }
            self.project = await store.snapshot()
            self.message = "\(capture.files.count) APKs gesichert. Installierte App geprüft und zur Untersuchung bereit."
        }
    }
    func projectLaunch() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation("Projekt-App starten") { _, workflow in try await workflow.launch(sessionID: id) }
    }
    func projectLogs() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation("App-Logcat aufnehmen") { _, workflow in try await workflow.captureLogs(sessionID: id) }
    }
    func projectScreenshot() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation("Screenshot aufnehmen") { _, workflow in try await workflow.captureScreenshot(sessionID: id) }
    }
    func projectNavigate(_ key: Int) {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation("Navigation ausführen") { _, workflow in try await workflow.navigate(sessionID: id, keyCode: key) }
    }
    func saveProjectNote() {
        let text = projectNote, session = activeSessionID
        projectOperation("Notiz speichern") { store, _ in
            try await store.addNote(text, sessionID: session)
            await MainActor.run { self.projectNote = "" }
        }
    }
    func showEvidence(_ item: ProjectEvidence) {
        guard let store = projectStore, !busy else { return }
        perform("Befund wird geprüft …") {
            let data = try await store.evidenceData(id: item.id)
            self.evidencePreview = EvidencePreview(item: item, data: data)
            self.message = "Befund geöffnet: \(item.kind.title)"
        }
    }
    func exportProject() {
        guard projectStore != nil, !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Gesamtes Analyseprojekt exportieren"
        panel.message = "Der Export enthält die APK, alle Befunde und einen Gesamtbericht."
        panel.nameFieldStringValue = (project?.title ?? "Analyse") + "-export.androidlab"
        panel.prompt = "Exportieren"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        projectOperation("Gesamtes Projekt exportieren") { store, _ in try await store.export(to: destination) }
    }
}
