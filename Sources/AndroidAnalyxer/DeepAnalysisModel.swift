import SwiftUI
import AppKit
import AndroidAnalyxerCore

extension AnalyxerModel {
    func loadAnalysisTools() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = "Lokales JSON-Werkzeugprofil auswählen; die Programmpfade werden vor Ausführung angezeigt."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { analysisTools = try AnalysisTools.load(url); saveAnalysisTools() }
        catch { self.error = error.localizedDescription }
    }
    func saveAnalysisTools() {
        do {
            _ = try analysisTools.configuration()
            UserDefaults.standard.set(try JSONEncoder().encode(analysisTools), forKey: "analysisTools")
            message = "Lokale Werkzeugpfade gespeichert."
        } catch { self.error = error.localizedDescription }
    }
    func analyzeWithREA(_ query: REAQuery) {
        let tools = analysisTools, component = analysisComponent
        projectOperation("REA untersucht die Projekt-APK …", completion: "REA-Analyse abgeschlossen und gespeichert.") { store, workflow in
            let result = try await workflow.analyzeCode(using: REAService(configuration: tools.configuration()), query: query, componentPath: component)
            let data = try await store.evidenceData(id: result.id)
            await MainActor.run { self.evidencePreview = EvidencePreview(item: result, data: data) }
        }
    }
    func observeMethod(className: String, methodName: String, argumentTypes: String, seconds: Int) {
        guard let session = activeSessionID, projectSessionSelected else { return }
        let tools = analysisTools
        let args = argumentTypes.trimmingCharacters(in: .whitespacesAndNewlines)
        let types = args.isEmpty ? [] : args.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let request = InstrumentationRequest(probes: [JavaMethodProbe(className: className, methodName: methodName, argumentTypes: types)], durationMilliseconds: seconds * 1000)
        projectOperation("Prozessbeobachtung läuft \(seconds) Sekunden – App jetzt im Android-Fenster bedienen …", completion: "Prozessbeobachtung abgeschlossen. Anzahl der Aufrufe und Abdeckungsgrenzen stehen im Befund.") { _, workflow in
            let instrumentation = try InstrumentationService(rea: tools.configuration(), bridgeURL: tools.bridgeURL())
            try await workflow.observeProcess(sessionID: session, instrumentation: instrumentation, request: request)
        }
    }
    func captureProjectNetwork(seconds: Int) {
        guard let session = activeSessionID, projectSessionSelected else { return }
        projectOperation("Mobilfunk/WAN wird \(seconds) Sekunden aufgezeichnet …", completion: "Mobilfunk/WAN-Aufzeichnung und Netzwerkbericht gespeichert.") { _, workflow in
            try await workflow.captureTraffic(sessionID: session, seconds: TimeInterval(seconds))
        }
    }
    func importProjectCapture() {
        guard let session = activeSessionID, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = "Klassische PCAP-Datei bis 32 MiB; Herkunft wird als externer Import dokumentiert."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        projectOperation("PCAP importieren") { _, workflow in try await workflow.importTraffic(sessionID: session, file: file) }
    }
}
