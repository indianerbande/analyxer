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
        panel.title = String(localized: "Create Analysis Project")
        panel.message = String(localized: "A separate copy of the APK, the report and all later findings are stored in this project folder.")
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".androidlab"
        panel.prompt = String(localized: "Create Project")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let current = service
        perform(String(localized: "Creating the project and analysing the APK statically …")) {
            let store = try await ProjectStore.create(at: destination, apk: source, service: current)
            try await self.useProject(store)
            self.message = String(localized: "Analysis project saved. Start a test session for runtime tests.")
        }
    }
    func chooseProject() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = String(localized: "Choose the analysis project folder that contains project.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }
    func openProject(_ url: URL) {
        guard !busy else { return }
        perform(String(localized: "Opening the project and verifying the APK hash …")) {
            let store = try await ProjectStore.open(at: url)
            try await self.useProject(store)
            self.message = String(localized: "Project opened. New runtime actions need a new test session.")
        }
    }
    /// Back to the project overview. Like switching projects, unsaved note text is stored and an open test session ends.
    func closeProject() {
        guard !busy, let store = projectStore else { return }
        let note = projectNote, session = activeSessionID
        let keepNote = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        perform(String(localized: "Closing the project …")) {
            if keepNote { try await store.addNote(note, sessionID: session) }
            if let session { try await store.endSession(session) }
            self.projectStore = nil; self.project = nil; self.projectDirectory = nil; self.appProfile = nil; self.profileLoading = false
            self.activeSessionID = nil; self.projectNote = ""; self.evidencePreview = nil
            self.analysisComponent = "input/application.apk"; self.apk = nil; self.report = nil
            self.message = String(localized: "Project closed.") + (keepNote ? " " + String(localized: "The open note was saved in the project.") : "")
                + (session == nil ? "" : " " + String(localized: "The test session was ended."))
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
            self.message = completion ?? String(localized: "\(label) – saved in the project.")
        }
    }
    func beginSession() {
        guard connected else { return }
        let target = serial
        projectOperation(String(localized: "Start test session")) { _, workflow in
            let session = try await workflow.begin(serial: target)
            await MainActor.run { self.activeSessionID = session.id }
        }
    }
    func finishSession() {
        guard let id = activeSessionID else { return }
        projectOperation(String(localized: "End test session")) { store, _ in
            try await store.endSession(id)
            await MainActor.run { self.activeSessionID = nil }
        }
    }
    func projectInstall() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Install project APK")) { _, workflow in try await workflow.install(sessionID: id) }
    }
    func projectAdoptInstalled() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Verify and adopt installed app")) { _, workflow in try await workflow.adoptInstalled(sessionID: id) }
    }
    func importInstalledApp(_ package: String) {
        guard connected, !busy else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Examine Installed App")
        panel.message = String(localized: "The base APK and all currently installed splits are saved in a separate analysis project.")
        panel.nameFieldStringValue = package + ".androidlab"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let current = service, target = serial
        perform(String(localized: "Saving and analysing the installed APKs …")) {
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
            let count = capture.files.count
            self.message = count == 1 ? String(localized: "1 APK saved. Installed app verified and ready for examination.")
                : String(localized: "\(count) APKs saved. Installed app verified and ready for examination.")
        }
    }
    func projectLaunch() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Launch project app")) { _, workflow in try await workflow.launch(sessionID: id) }
    }
    func projectLogs() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Capture app Logcat")) { _, workflow in try await workflow.captureLogs(sessionID: id) }
    }
    func projectScreenshot() {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Capture screenshot")) { _, workflow in try await workflow.captureScreenshot(sessionID: id) }
    }
    func projectNavigate(_ key: Int) {
        guard let id = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Perform navigation")) { _, workflow in try await workflow.navigate(sessionID: id, keyCode: key) }
    }
    func saveProjectNote() {
        let text = projectNote, session = activeSessionID
        projectOperation(String(localized: "Save note")) { store, _ in
            try await store.addNote(text, sessionID: session)
            await MainActor.run { self.projectNote = "" }
        }
    }
    func showEvidence(_ item: ProjectEvidence) {
        guard let store = projectStore, !busy else { return }
        perform(String(localized: "Checking the finding …")) {
            let data = try await store.evidenceData(id: item.id)
            self.evidencePreview = EvidencePreview(item: item, data: data)
            self.message = String(localized: "Finding opened: \(item.kind.title)")
        }
    }
    func exportProject() {
        guard projectStore != nil, !busy else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Entire Analysis Project")
        panel.message = String(localized: "The export contains the APK, all findings and a combined report.")
        panel.nameFieldStringValue = (project?.title ?? "analysis") + "-export.androidlab"
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        projectOperation(String(localized: "Export entire project")) { store, _ in try await store.export(to: destination) }
    }
}
