import SwiftUI
import AppKit
import AndroidAnalyxerCore

extension AnalyxerModel {
    func loadAnalysisTools() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a local JSON tool profile; the program paths are shown before anything runs.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { analysisTools = try AnalysisTools.load(url); saveAnalysisTools() }
        catch { self.error = error.localizedDescription }
    }
    func saveAnalysisTools() {
        do {
            _ = try analysisTools.configuration()
            UserDefaults.standard.set(try JSONEncoder().encode(analysisTools), forKey: "analysisTools")
            message = String(localized: "Local tool paths saved.")
        } catch { self.error = error.localizedDescription }
    }
    func analyzeWithREA(_ query: REAQuery) {
        let tools = analysisTools, component = analysisComponent
        projectOperation(String(localized: "REA is examining the project APK …"), completion: String(localized: "REA analysis finished and saved.")) { store, workflow in
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
        projectOperation(String(localized: "Observing the process for \(seconds) seconds – use the app in the Android window now …"), completion: String(localized: "Process observation finished. The number of calls and the coverage limits are in the finding.")) { _, workflow in
            let instrumentation = try InstrumentationService(rea: tools.configuration(), bridgeURL: tools.bridgeURL())
            try await workflow.observeProcess(sessionID: session, instrumentation: instrumentation, request: request)
        }
    }
    func captureProjectNetwork(seconds: Int) {
        guard let session = activeSessionID, projectSessionSelected else { return }
        projectOperation(String(localized: "Recording mobile/WAN for \(seconds) seconds …"), completion: String(localized: "Mobile/WAN recording and network report saved.")) { _, workflow in
            try await workflow.captureTraffic(sessionID: session, seconds: TimeInterval(seconds))
        }
    }
    func importProjectCapture() {
        guard let session = activeSessionID, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = String(localized: "Classic PCAP file up to 32 MiB; its origin is documented as an external import.")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        projectOperation(String(localized: "Import PCAP")) { _, workflow in try await workflow.importTraffic(sessionID: session, file: file) }
    }
}
