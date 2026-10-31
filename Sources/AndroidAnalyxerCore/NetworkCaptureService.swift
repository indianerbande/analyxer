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
        "Network capture (PCAP)\nDevice: \(serial)\nBoot ID: \(bootID)\nStart: \(startedAt.ISO8601Format())\nEnd: \(endedAt.ISO8601Format())\nRequested duration: \(requestedDuration) s\nPackets: \(packetCount)\nBytes: \(byteCount)\nScope: \(scope)\n\n" + limitations.map { "• " + $0 }.joined(separator: "\n") + "\n"
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
        guard serials.insert(serial).inserted else { throw AndroidAnalyxerError.failed(String(localized: "A capture is already running for this device in this app.")) }
    }
    func release(_ serial: String) { serials.remove(serial) }
}

extension EmulatorService {
    /// SDK console capture covers the legacy QEMU WAN path. Modern netsim Wi-Fi
    /// is intentionally NOT described as captured. No proxy or guest setting changes.
    public func captureNetwork(serial: String, duration: TimeInterval = 10) async throws -> NetworkCapture {
        guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil,
              duration.isFinite, (1...60).contains(duration) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "Network capture needs an SDK emulator and a duration of 1 to 60 seconds."))
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
            throw AndroidAnalyxerError.failed(String(localized: "The local AVD path could not be determined unambiguously."))
        }
        let avd = URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL
        let folder = avd.appendingPathComponent("console_out", isDirectory: true)
        guard avd.resolvingSymlinksInPath().path == avd.path,
              folder.resolvingSymlinksInPath().path == folder.path else {
            throw AndroidAnalyxerError.failed(String(localized: "The AVD output path contains a symbolic link."))
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw AndroidAnalyxerError.failed(String(localized: "The AVD output path is not a folder."))
            }
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let filename = "android-analyxer-\(UUID().uuidString).pcap"
        let file = folder.appendingPathComponent(filename)
        // SDK 37 only accepts a bare name and writes under AVD/console_out. Reserve
        // our unique file privately; the SDK's truncating open preserves this mode.
        let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AndroidAnalyxerError.failed(String(localized: "The private PCAP file could not be created.")) }
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
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AndroidAnalyxerError.failed(String(localized: "Invalid PCAP output file.")) }
                guard (info.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard try await bootIdentity(serial: serial) == bootID else {
                started = false // Never send stop to a new guest reusing the serial.
                throw AndroidAnalyxerError.failed(String(localized: "The device restarted during the capture. The capture is discarded."))
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
                scope: "Device-wide legacy WAN/cellular capture via the emulator console (QEMU/slirp)",
                limitations: ["Modern netsim Wi-Fi (emulator 36.5 and later) is not captured by this console.",
                    "Packets are not attributed to the project app; other apps and system services may be included.",
                    "TLS content is not decrypted here. Process instrumentation is a separate analysis source.",
                    "An empty capture does not prove the absence of network traffic.",
                    "The console command replaces a console capture that may have been started elsewhere.",
                    "At most 60 seconds; size checked every 100 ms, at most 32 MiB kept. Brief growth beyond that discards the capture."])
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
                        guard try await bootIdentity(serial: serial) == bootID else { return String(localized: "Boot identity changed; no stop was sent to the replaced device.") }
                        _ = try await captureConsole(serial: serial, arguments: ["network", "capture", "stop"])
                        return nil
                    } catch { return error.localizedDescription }
                }.value
                if let cleanupError { throw AndroidAnalyxerError.failed(String(localized: "\(error.localizedDescription)\nThe capture could not be confirmed as stopped: \(cleanupError)")) }
            }
            throw error
        }
    }

    private func captureConsole(serial: String, arguments: [String]) async throws -> CommandResult {
        let result = try await adb(serial: serial, arguments: ["emu"] + arguments, timeout: 5)
        let lines = result.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !result.truncated, !lines.contains(where: { $0.hasPrefix("KO:") }), lines.contains("OK") else {
            throw AndroidAnalyxerError.failed(String(localized: "The emulator console did not confirm the capture command: \(String(result.text.prefix(1000)))"))
        }
        return result
    }
}

enum PCAPValidation {
    static func packetCount(_ data: Data) throws -> Int {
        guard data.count >= 24 else { throw AndroidAnalyxerError.failed(String(localized: "The emulator did not deliver a complete PCAP header.")) }
        let bytes = [UInt8](data)
        let magic = Array(bytes.prefix(4))
        let little: Bool
        switch magic {
        case [0xd4, 0xc3, 0xb2, 0xa1], [0x4d, 0x3c, 0xb2, 0xa1]: little = true
        case [0xa1, 0xb2, 0xc3, 0xd4], [0xa1, 0xb2, 0x3c, 0x4d]: little = false
        default: throw AndroidAnalyxerError.failed(String(localized: "Unknown PCAP format."))
        }
        func word(_ offset: Int) -> UInt32 {
            let values = Array(bytes[offset..<(offset + 4)])
            return (little ? Array(values.reversed()) : values).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let major = little ? Int(bytes[4]) | Int(bytes[5]) << 8 : Int(bytes[4]) << 8 | Int(bytes[5])
        guard major == 2 else { throw AndroidAnalyxerError.failed(String(localized: "Unsupported PCAP version.")) }
        let snaplen = word(16)
        var offset = 24, count = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 16 else { throw AndroidAnalyxerError.failed(String(localized: "Truncated PCAP packet header.")) }
            let size = Int(word(offset + 8))
            guard size <= Int(snaplen), size <= Int(word(offset + 12)), size <= bytes.count - offset - 16 else {
                throw AndroidAnalyxerError.failed(String(localized: "Truncated or invalid PCAP packet data."))
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
        var lines = ["PCAP endpoint summary", "Packets: \(packetCount) · Bytes: \(byteCount) · Link type: \(linkType)",
                     "IP packets with readable endpoints: \(decodedPackets)",
                     "Device/app attribution and capture scope must be determined from where the capture came from.",
                     "No TLS decryption, no payload display, no reconstruction of streams or DNS names.",
                     "Supported: classic PCAP, Ethernet (up to two VLAN tags), Linux cooked v1/v2, raw IPv4/IPv6. IPv6 extension headers and fragmented packets are only partly evaluated.",
                     "At most 1,000 distinct directed endpoint pairs; packets omitted beyond that: \(omittedEndpointPackets)", ""]
        lines += endpoints.map { "\($0.transport) \($0.source) → \($0.destination) · \($0.packets) packets · \($0.capturedBytes) captured frame bytes" }
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
