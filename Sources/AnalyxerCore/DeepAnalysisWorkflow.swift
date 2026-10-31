import Foundation

extension ProjectWorkflow {
    public func observeProcess(sessionID: UUID, instrumentation: InstrumentationService, request: InstrumentationRequest) async throws {
        try await action(sessionID: sessionID, label: "Process Observation") { session, project in
            guard project.evidence.contains(where: { $0.sessionID == sessionID && [.installation, .installedApp].contains($0.kind) }) else {
                throw AnalyxerError.failed(String(localized: "Install and launch the project APK in this session first."))
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
                let script = try await store.record(kind: .probeScript, summary: "Probes · \(project.packageName)", data: capture.script, sessionID: sessionID)
                let evidence = try await store.record(kind: .instrumentation, summary: capture.summary, data: capture.evidenceJSON, sessionID: sessionID)
                let parameters = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                let context = "Process observation\nAPK SHA-256: \(project.analysis.apk.sha256)\nInstalled APK verified: \(verifiedAt.ISO8601Format())\nDevice: \(session.device.serial)\nBoot ID: \(session.device.properties["boot_id"] ?? "?")\nPID: \(capture.pid)\nStart: \(capture.observedAt.ISO8601Format())\nParameters: \(parameters)\nScript: \(script.relativePath)\nScript SHA-256: \(script.sha256)\nREA finding: \(evidence.relativePath)\n\(capture.summary)\n\(capture.warnings.joined(separator: "\n"))"
                try await store.record(kind: .note, summary: "Capture context · \(capture.summary)", data: Data(context.utf8), sessionID: sessionID)
            } catch let error as InstrumentationError {
                if let script = error.script { try await store.record(kind: .probeScript, summary: "Failed process observation", data: script, sessionID: sessionID) }
                if let raw = error.evidenceJSON { try await store.record(kind: .instrumentation, summary: "INCOMPLETE · \(error.message.prefix(120))", data: raw, sessionID: sessionID) }
                throw error
            }
        }
    }

    public func captureTraffic(sessionID: UUID, seconds: TimeInterval) async throws {
        try await action(sessionID: sessionID, label: "Capture Cellular/WAN") { session, _ in
            let capture = try await service.captureNetwork(serial: session.device.serial, duration: seconds)
            guard capture.metadata.bootID == session.device.properties["boot_id"] else { throw AnalyxerError.failed(String(localized: "The boot identity changed; the capture cannot be assigned to the session.")) }
            let analysis = try PCAPInspector.inspect(capture.pcap)
            let file = try await store.record(kind: .networkCapture, summary: "Legacy WAN · \(packets(capture.metadata.packetCount)) · not attributed to an app", data: capture.pcap, sessionID: sessionID)
            let report = "File: \(file.relativePath)\nSHA-256: \(file.sha256)\n\n" + capture.metadata.reportText + "\n" + analysis.reportText
            try await store.record(kind: .networkReport, summary: "Legacy WAN · \(packets(capture.metadata.packetCount))", data: Data(report.utf8), sessionID: sessionID)
        }
    }

    public func importTraffic(sessionID: UUID, file: URL) async throws {
        _ = try await store.session(sessionID)
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw AnalyxerError.outputTooLarge }
        let data = try Data(contentsOf: file)
        let analysis = try PCAPInspector.inspect(data)
        let evidence = try await store.record(kind: .networkCapture, summary: "Import · \(packets(analysis.packetCount)) · origin not verified", data: data, sessionID: sessionID)
        let report = "Imported: \(Date().ISO8601Format())\nSource file: \(file.lastPathComponent)\nFile: \(evidence.relativePath)\nSHA-256: \(evidence.sha256)\nAssigned to the session by the user; capture device, capture time and app attribution not verified.\n\n" + analysis.reportText
        try await store.record(kind: .networkReport, summary: "Imported PCAP report", data: Data(report.utf8), sessionID: sessionID)
    }
}

/// Packet count for evidence summaries; plain English because summaries are stored in project.json.
private func packets(_ count: Int) -> String { count == 1 ? "1 packet" : "\(count) packets" }
