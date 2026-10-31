import Foundation

extension ProjectWorkflow {
    public func observeProcess(sessionID: UUID, instrumentation: InstrumentationService, request: InstrumentationRequest) async throws {
        try await action(sessionID: sessionID, label: "Prozessbeobachtung") { session, project in
            guard project.evidence.contains(where: { $0.sessionID == sessionID && [.installation, .installedApp].contains($0.kind) }) else {
                throw AndroidAnalyxerError.failed("Bitte zuerst die Projekt-APK in dieser Sitzung installieren und starten.")
            }
            _ = try await store.verifiedAPKs()
            let verifiedAt: Date
            if project.installedSource != nil || project.apkFiles.count > 1 {
                verifiedAt = try await service.verifyInstalledSet(serial: session.device.serial, package: project.packageName, expected: project.apkFiles.map(\.sha256))
            } else {
                verifiedAt = try await service.verifyInstalledAPK(serial: session.device.serial, package: project.packageName, expectedSHA256: project.analysis.apk.sha256).verifiedAt
            }
            do {
                let capture = try await instrumentation.capture(service: service, serial: session.device.serial, package: project.packageName,
                    expectedBootID: session.device.properties["boot_id"] ?? "", request: request)
                let script = try await store.record(kind: .probeScript, summary: "Messpunkte · \(project.packageName)", data: capture.script, sessionID: sessionID)
                let evidence = try await store.record(kind: .instrumentation, summary: capture.summary, data: capture.evidenceJSON, sessionID: sessionID)
                let parameters = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                let context = "Prozessbeobachtung\nAPK SHA-256: \(project.analysis.apk.sha256)\nInstallierte APK geprüft: \(verifiedAt.ISO8601Format())\nGerät: \(session.device.serial)\nBoot-ID: \(session.device.properties["boot_id"] ?? "?")\nPID: \(capture.pid)\nBeginn: \(capture.observedAt.ISO8601Format())\nParameter: \(parameters)\nSkript: \(script.relativePath)\nSkript SHA-256: \(script.sha256)\nREA-Befund: \(evidence.relativePath)\n\(capture.summary)\n\(capture.warnings.joined(separator: "\n"))"
                try await store.record(kind: .note, summary: "Aufnahmekontext · \(capture.summary)", data: Data(context.utf8), sessionID: sessionID)
            } catch let error as InstrumentationError {
                if let script = error.script { try await store.record(kind: .probeScript, summary: "Fehlgeschlagene Prozessbeobachtung", data: script, sessionID: sessionID) }
                if let raw = error.evidenceJSON { try await store.record(kind: .instrumentation, summary: "UNVOLLSTÄNDIG · \(error.message.prefix(120))", data: raw, sessionID: sessionID) }
                throw error
            }
        }
    }

    public func captureTraffic(sessionID: UUID, seconds: TimeInterval) async throws {
        try await action(sessionID: sessionID, label: "Mobilfunk/WAN aufnehmen") { session, _ in
            let capture = try await service.captureNetwork(serial: session.device.serial, duration: seconds)
            guard capture.metadata.bootID == session.device.properties["boot_id"] else { throw AndroidAnalyxerError.failed("Bootidentität geändert; keine Zuordnung zur Sitzung möglich.") }
            let analysis = try PCAPInspector.inspect(capture.pcap)
            let file = try await store.record(kind: .networkCapture, summary: "Legacy-WAN · \(capture.metadata.packetCount) Pakete · keine App-Zuordnung", data: capture.pcap, sessionID: sessionID)
            let report = "Datei: \(file.relativePath)\nSHA-256: \(file.sha256)\n\n" + capture.metadata.reportText + "\n" + analysis.reportText
            try await store.record(kind: .networkReport, summary: "Legacy-WAN · \(capture.metadata.packetCount) Pakete", data: Data(report.utf8), sessionID: sessionID)
        }
    }

    public func importTraffic(sessionID: UUID, file: URL) async throws {
        _ = try await store.session(sessionID)
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
        let data = try Data(contentsOf: file)
        let analysis = try PCAPInspector.inspect(data)
        let evidence = try await store.record(kind: .networkCapture, summary: "Import · \(analysis.packetCount) Pakete · Herkunft nicht verifiziert", data: data, sessionID: sessionID)
        let report = "Importiert: \(Date().ISO8601Format())\nQuelldatei: \(file.lastPathComponent)\nDatei: \(evidence.relativePath)\nSHA-256: \(evidence.sha256)\nZuordnung zur Sitzung durch Benutzer; Aufnahmegerät, Aufnahmezeit und App-Zuordnung nicht verifiziert.\n\n" + analysis.reportText
        try await store.record(kind: .networkReport, summary: "Importierter PCAP-Bericht", data: Data(report.utf8), sessionID: sessionID)
    }
}
