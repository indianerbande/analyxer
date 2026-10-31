import Foundation
import Darwin

public struct NetworkCaptureMetadata: Codable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let serial: String
    public let bootID: String
    public let requestedDuration: TimeInterval
    public let packetCount: Int
    public let byteCount: Int
    public let scope: String
    public let limitations: [String]
    public var reportText: String {
        "Netzwerkmitschnitt (PCAP)\nGerät: \(serial)\nBoot-ID: \(bootID)\nStart: \(startedAt.ISO8601Format())\nEnde: \(endedAt.ISO8601Format())\nGewünschte Dauer: \(requestedDuration) s\nPakete: \(packetCount)\nBytes: \(byteCount)\nUmfang: \(scope)\n\n" + limitations.map { "• " + $0 }.joined(separator: "\n") + "\n"
    }
}

public struct NetworkCapture: Sendable {
    public let pcap: Data
    public let metadata: NetworkCaptureMetadata
}

private actor CaptureLeases {
    static let shared = CaptureLeases()
    var serials: Set<String> = []
    func acquire(_ serial: String) throws {
        guard serials.insert(serial).inserted else { throw AndroidAnalyxerError.failed("Für dieses Gerät läuft bereits ein Mitschnitt in dieser Anwendung.") }
    }
    func release(_ serial: String) { serials.remove(serial) }
}

extension EmulatorService {
    /// SDK console capture covers the legacy QEMU WAN path. Modern netsim Wi-Fi
    /// is intentionally NOT described as captured. No proxy or guest setting changes.
    public func captureNetwork(serial: String, duration: TimeInterval = 10) async throws -> NetworkCapture {
        guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil,
              duration.isFinite, (1...60).contains(duration) else {
            throw AndroidAnalyxerError.invalidInput("Netzwerkmitschnitt benötigt einen SDK-Emulator und eine Dauer von 1 bis 60 Sekunden.")
        }
        try await CaptureLeases.shared.acquire(serial)
        do {
            let result = try await captureNetworkWithLease(serial: serial, duration: duration)
            await CaptureLeases.shared.release(serial)
            return result
        } catch {
            await CaptureLeases.shared.release(serial)
            throw error
        }
    }

    private func captureNetworkWithLease(serial: String, duration: TimeInterval) async throws -> NetworkCapture {
        let bootID = try await bootIdentity(serial: serial)
        let location = try await captureConsole(serial: serial, arguments: ["avd", "path"])
        let lines = location.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "OK" }
        guard lines.count == 1, lines[0].hasPrefix("/") else {
            throw AndroidAnalyxerError.failed("Der lokale AVD-Pfad konnte nicht eindeutig ermittelt werden.")
        }
        let avd = URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL
        let folder = avd.appendingPathComponent("console_out", isDirectory: true)
        guard avd.resolvingSymlinksInPath().path == avd.path,
              folder.resolvingSymlinksInPath().path == folder.path else {
            throw AndroidAnalyxerError.failed("Der AVD-Ausgabepfad enthält einen symbolischen Link.")
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw AndroidAnalyxerError.failed("Der AVD-Ausgabepfad ist kein Verzeichnis.")
            }
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let filename = "android-analyxer-\(UUID().uuidString).pcap"
        let file = folder.appendingPathComponent(filename)
        // SDK 37 only accepts a bare name and writes under AVD/console_out. Reserve
        // our unique file privately; the SDK's truncating open preserves this mode.
        let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AndroidAnalyxerError.failed("Die private PCAP-Datei konnte nicht angelegt werden.") }
        Darwin.close(fd)
        defer { try? FileManager.default.removeItem(at: file) }
        var started = false
        var startPending = true
        let began = Date()
        do {
            _ = try await captureConsole(serial: serial, arguments: ["network", "capture", "start", filename])
            startPending = false
            started = true
            let deadline = ProcessInfo.processInfo.systemUptime + duration
            repeat {
                try Task.checkCancellation()
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AndroidAnalyxerError.failed("Ungültige PCAP-Ausgabedatei.") }
                guard (info.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard try await bootIdentity(serial: serial) == bootID else {
                started = false // Never send stop to a new guest reusing the serial.
                throw AndroidAnalyxerError.failed("Das Gerät wurde während des Mitschnitts neu gestartet. Der Mitschnitt wird verworfen.")
            }
            _ = try await captureConsole(serial: serial, arguments: ["network", "capture", "stop"])
            started = false
            let ended = Date()
            let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 32 * 1024 * 1024 else {
                throw AndroidAnalyxerError.outputTooLarge
            }
            let data = try Data(contentsOf: file)
            let count = try PCAPValidation.packetCount(data)
            let metadata = NetworkCaptureMetadata(startedAt: began, endedAt: ended, serial: serial, bootID: bootID,
                requestedDuration: duration, packetCount: count, byteCount: data.count,
                scope: "Geräteweiter Legacy-WAN/Cellular-Mitschnitt über die Emulator-Konsole (QEMU/slirp)",
                limitations: ["Modernes netsim-WLAN (Emulator ab 36.5) wird von dieser Konsole nicht erfasst.",
                    "Keine Zuordnung einzelner Pakete zur Projekt-App; andere Apps und Systemdienste können enthalten sein.",
                    "TLS-Inhalte werden hier nicht entschlüsselt. Prozessinstrumentierung ist eine separate Analysequelle.",
                    "Ein leerer Mitschnitt ist kein Nachweis fehlender Netzwerkkommunikation.",
                    "Der Konsolenbefehl ersetzt einen eventuell extern gestarteten Konsolenmitschnitt.",
                    "Dauer maximal 60 Sekunden; Größenprüfung alle 100 ms, maximal 32 MiB werden übernommen. Kurzzeitiges Wachstum darüber führt zum Verwerfen."])
            return NetworkCapture(pcap: data, metadata: metadata)
        } catch {
            // ADB may time out or be cancelled after the console already opened
            // our reserved file. A written header is evidence of that start.
            let openedBeforeAcknowledgment = startPending && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            if started || openedBeforeAcknowledgment {
                // An already-cancelled caller must still stop its capture. Check the
                // boot in the detached cleanup before addressing this serial again.
                let cleanupError = await Task.detached { () -> String? in
                    do {
                        guard try await bootIdentity(serial: serial) == bootID else { return "Bootidentität geändert; kein Stop an das ersetzte Gerät gesendet." }
                        _ = try await captureConsole(serial: serial, arguments: ["network", "capture", "stop"])
                        return nil
                    } catch { return error.localizedDescription }
                }.value
                if let cleanupError { throw AndroidAnalyxerError.failed("\(error.localizedDescription)\nMitschnitt konnte nicht bestätigt beendet werden: \(cleanupError)") }
            }
            throw error
        }
    }

    private func captureConsole(serial: String, arguments: [String]) async throws -> CommandResult {
        let result = try await adb(serial: serial, arguments: ["emu"] + arguments, timeout: 5)
        let lines = result.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !result.truncated, !lines.contains(where: { $0.hasPrefix("KO:") }), lines.contains("OK") else {
            throw AndroidAnalyxerError.failed("Emulator-Konsole bestätigt den Mitschnittbefehl nicht: \(result.text.prefix(1000))")
        }
        return result
    }
}

enum PCAPValidation {
    static func packetCount(_ data: Data) throws -> Int {
        guard data.count >= 24 else { throw AndroidAnalyxerError.failed("Der Emulator lieferte keinen vollständigen PCAP-Kopf.") }
        let bytes = [UInt8](data)
        let magic = Array(bytes.prefix(4))
        let little: Bool
        switch magic {
        case [0xd4, 0xc3, 0xb2, 0xa1], [0x4d, 0x3c, 0xb2, 0xa1]: little = true
        case [0xa1, 0xb2, 0xc3, 0xd4], [0xa1, 0xb2, 0x3c, 0x4d]: little = false
        default: throw AndroidAnalyxerError.failed("Unbekanntes PCAP-Format.")
        }
        func word(_ offset: Int) -> UInt32 {
            let values = Array(bytes[offset..<(offset + 4)])
            return (little ? Array(values.reversed()) : values).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let major = little ? Int(bytes[4]) | Int(bytes[5]) << 8 : Int(bytes[4]) << 8 | Int(bytes[5])
        guard major == 2 else { throw AndroidAnalyxerError.failed("Nicht unterstützte PCAP-Version.") }
        let snaplen = word(16)
        var offset = 24, count = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 16 else { throw AndroidAnalyxerError.failed("Abgeschnittener PCAP-Paketkopf.") }
            let size = Int(word(offset + 8))
            guard size <= Int(snaplen), size <= Int(word(offset + 12)), size <= bytes.count - offset - 16 else {
                throw AndroidAnalyxerError.failed("Abgeschnittene oder ungültige PCAP-Paketdaten.")
            }
            offset += 16 + size; count += 1
        }
        return count
    }
}

public struct NetworkEndpointCount: Codable, Sendable {
    public let source: String
    public let destination: String
    public let transport: String
    public var packets: Int
    public var capturedBytes: Int
}

public struct PCAPReport: Codable, Sendable {
    public let packetCount: Int
    public let byteCount: Int
    public let linkType: UInt32
    public let decodedPackets: Int
    public let endpoints: [NetworkEndpointCount]
    public let omittedEndpointPackets: Int
    public var reportText: String {
        var lines = ["PCAP-Endpunktübersicht", "Pakete: \(packetCount) · Bytes: \(byteCount) · Linktyp: \(linkType)",
                     "IP-Pakete mit lesbaren Endpunkten: \(decodedPackets)",
                     "Geräte-/App-Zuordnung und Aufnahmeumfang müssen aus der Herkunft des Mitschnitts bestimmt werden.",
                     "Keine TLS-Entschlüsselung, keine Nutzdatenanzeige, keine Rekonstruktion von Streams oder DNS-Namen.",
                     "Unterstützt: klassisches PCAP, Ethernet (bis zwei VLAN-Tags), Linux cooked v1/v2, Raw IPv4/IPv6. IPv6-Erweiterungsheader und fragmentierte Pakete werden nur eingeschränkt ausgewertet.",
                     "Maximal 1.000 unterschiedliche gerichtete Endpunktpaare; darüber ausgelassene Pakete: \(omittedEndpointPackets)", ""]
        lines += endpoints.map { "\($0.transport) \($0.source) → \($0.destination) · \($0.packets) Pakete · \($0.capturedBytes) aufgezeichnete Frame-Bytes" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Header-only statistics: no traffic is sent, no host lookup is performed, and
/// packet payloads are not included in the report. PCAPNG requires conversion.
public enum PCAPInspector {
    public static func inspect(_ data: Data) throws -> PCAPReport {
        guard data.count <= 32 * 1024 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
        let count = try PCAPValidation.packetCount(data)
        let bytes = [UInt8](data)
        let little = bytes[0] == 0xd4 || bytes[0] == 0x4d
        func word(_ offset: Int) -> UInt32 {
            let slice = Array(bytes[offset..<(offset + 4)])
            return (little ? Array(slice.reversed()) : slice).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let link = word(20) & 0x0000ffff
        var offset = 24, decoded = 0, omitted = 0
        var counts: [String: NetworkEndpointCount] = [:]
        while offset < bytes.count {
            let size = Int(word(offset + 8))
            let frame = Array(bytes[(offset + 16)..<(offset + 16 + size)])
            if let item = endpoints(frame, link: link) {
                decoded += 1
                let key = item.2 + " " + item.0 + " " + item.1
                if var entry = counts[key] {
                    entry.packets += 1; entry.capturedBytes += size; counts[key] = entry
                } else if counts.count < 1_000 {
                    counts[key] = NetworkEndpointCount(source: item.0, destination: item.1, transport: item.2, packets: 1, capturedBytes: size)
                } else { omitted += 1 }
            }
            offset += 16 + size
        }
        return PCAPReport(packetCount: count, byteCount: data.count, linkType: link, decodedPackets: decoded,
                          endpoints: counts.values.sorted { ($0.transport, $0.source, $0.destination) < ($1.transport, $1.source, $1.destination) }, omittedEndpointPackets: omitted)
    }

    private static func endpoints(_ b: [UInt8], link: UInt32) -> (String, String, String)? {
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        var ip = 0, ether = 0
        switch link {
        case 1:
            guard b.count >= 14 else { return nil }; ip = 14; ether = u16(12)
            for _ in 0..<2 where [0x8100, 0x88a8].contains(ether) {
                guard b.count >= ip + 4 else { return nil }; ether = u16(ip + 2); ip += 4
            }
        case 113: guard b.count >= 16 else { return nil }; ip = 16; ether = u16(14)
        case 276: guard b.count >= 20 else { return nil }; ip = 20; ether = u16(0)
        case 101, 228, 229: guard !b.isEmpty else { return nil }; ether = b[0] >> 4 == 4 ? 0x0800 : 0x86dd
        default: return nil
        }
        var source: String, destination: String, proto: Int, transportAt: Int, end: Int, portsAvailable = true
        if ether == 0x0800 {
            guard b.count >= ip + 20, b[ip] >> 4 == 4 else { return nil }
            let header = Int(b[ip] & 15) * 4, total = u16(ip + 2)
            guard header >= 20, total >= header, b.count >= ip + header else { return nil }
            end = min(b.count, ip + total)
            source = b[(ip + 12)..<(ip + 16)].map(String.init).joined(separator: ".")
            destination = b[(ip + 16)..<(ip + 20)].map(String.init).joined(separator: ".")
            proto = Int(b[ip + 9]); transportAt = ip + header
            portsAvailable = u16(ip + 6) & 0x1fff == 0
        } else if ether == 0x86dd {
            guard b.count >= ip + 40, b[ip] >> 4 == 6 else { return nil }
            func address(_ start: Int) -> String {
                "[" + stride(from: start, to: start + 16, by: 2).map { String(u16($0), radix: 16) }.joined(separator: ":") + "]"
            }
            source = address(ip + 8); destination = address(ip + 24)
            proto = Int(b[ip + 6]); transportAt = ip + 40
            end = min(b.count, ip + 40 + u16(ip + 4))
            // Keep extension-header traffic honest: addresses remain useful, but
            // don't guess where TCP/UDP starts or reconstruct fragments.
            portsAvailable = [6, 17].contains(proto)
        } else { return nil }
        let name = [6: "TCP", 17: "UDP", 1: "ICMP", 58: "ICMPv6"][proto] ?? "IP-\(proto)"
        if portsAvailable, [6, 17].contains(proto), transportAt + 4 <= end {
            source += ":\(u16(transportAt))"; destination += ":\(u16(transportAt + 2))"
        }
        return (source, destination, name)
    }
}
