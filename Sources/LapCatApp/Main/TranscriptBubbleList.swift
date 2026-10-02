import LapCatCore
import SwiftUI

/// The live transcript beside the notes while recording.
struct LiveTranscriptPanel: View {
    let segments: [Segment]
    let participants: [Participant]
    @State private var showEcho = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live transcript").font(.headline)
                Spacer()
                Toggle("Show echo duplicates", isOn: $showEcho)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            TranscriptBubbleList(
                paragraphs: TranscriptGrouping.paragraphs(segments, showEcho: showEcho),
                participants: participants)
        }
    }
}

/// Speaker bubbles: Them (system channel) left in grey, Me (mic) right in the accent color, the
/// in-progress hypothesis italic at 60 % opacity. Follows new text while scrolled to the bottom;
/// otherwise offers a "Jump to latest" pill.
struct TranscriptBubbleList: View {
    let paragraphs: [TranscriptParagraph]
    let participants: [Participant]
    @State private var atBottom = true
    @State private var hasUnseen = false
    private static let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if paragraphs.isEmpty {
                        Text("Waiting for speech…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(paragraphs) { paragraph in
                        TranscriptBubble(paragraph: paragraph, speaker: speaker(for: paragraph))
                            .id(paragraph.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onAppear {
                            atBottom = true
                            hasUnseen = false
                        }
                        .onDisappear { atBottom = false }
                }
                .padding(10)
            }
            .overlay(alignment: .bottom) {
                if hasUnseen {
                    Button {
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: paragraphs) {
                if atBottom {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } else {
                    hasUnseen = true
                }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private func speaker(for paragraph: TranscriptParagraph) -> String {
        guard let first = paragraph.segments.first else { return "" }
        return TranscriptFormatter.speakerName(for: first, participants: participants)
    }
}

private struct TranscriptBubble: View {
    let paragraph: TranscriptParagraph
    let speaker: String

    private var isMe: Bool { paragraph.channel == .mic }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 40) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(paragraph.text)
                    .italic(paragraph.isVolatile)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isMe ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 10))
                    .opacity(paragraph.isVolatile ? 0.6 : 1)
            }
            if !isMe { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speaker): \(paragraph.text)")
    }
}
