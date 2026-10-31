import SwiftUI
import AppKit
import AndroidAnalyxerCore

struct EvidencePreview: Identifiable {
    let item: ProjectEvidence
    let data: Data
    var id: UUID { item.id }
}

struct EvidencePreviewView: View {
    let preview: EvidencePreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(preview.item.kind.title).font(.title2.weight(.semibold))
                    Text(preview.item.timestamp, format: .dateTime.day().month().year().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(preview.item.summary).font(.callout).textSelection(.enabled)
            Text("SHA-256: " + preview.item.sha256).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            if preview.item.kind == .screenshot, let image = NSImage(data: preview.data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if preview.item.kind == .networkCapture {
                Text("PCAP network capture · \(preview.data.count) bytes\nThe accompanying network report describes scope and limits. The original file is included in the full export and can be opened with Wireshark.").textSelection(.enabled)
                Spacer()
            } else {
                let text = [EvidenceKind.rea, .instrumentation].contains(preview.item.kind) ? REAPresentation.text(preview.data) : String(decoding: preview.data, as: UTF8.self)
                if text.utf8.count > EvidenceTextView.limit {
                    Text("Preview limited to the first \(EvidenceTextView.limit / 1_000_000) MB. The complete file is in the project and in the full export.").font(.caption).foregroundStyle(.orange)
                }
                Text("⌘F searches the text.").font(.caption).foregroundStyle(.secondary)
                EvidenceTextView(text: text)
            }
        }.padding(24).frame(minWidth: 800, idealWidth: 940, minHeight: 600, idealHeight: 720)
    }
}

/// Large evidence files: SwiftUI `Text` renders nothing beyond a few hundred kilobytes, AppKit's text view handles megabytes and brings the find bar.
struct EvidenceTextView: NSViewRepresentable {
    static let limit = 20_000_000
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor; view.drawsBackground = false; scroll.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        // No line wrapping: reports and inventories are tabular.
        view.isHorizontallyResizable = true; scroll.hasHorizontalScroller = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text.utf8.count > Self.limit ? String(decoding: Array(text.utf8.prefix(Self.limit)), as: UTF8.self) : text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

