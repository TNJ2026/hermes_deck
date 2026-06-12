import SwiftUI

/// Status cards under the bubble that triggered a hand-off — one independent
/// card per routed target: "Waiting for X…" with the classic three-dot
/// thinking animation while the target runs, flipped to an expandable
/// "X replied" row (or a failed row) as its result lands. Collapsed by default.
struct AgentHandoffStatusView: View {
    let items: [AgentHandoffItem]
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                itemCard(item)
            }
        }
    }

    @ViewBuilder
    private func itemCard(_ item: AgentHandoffItem) -> some View {
        Group {
            switch item.phase {
            case .waiting:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Waiting for \(item.targetName)")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    ThreeDotsIndicator()
                }
                .foregroundStyle(.blue)
            case .replied(let reply):
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.smooth(duration: 0.15)) {
                            if expandedIDs.contains(item.id) {
                                expandedIDs.remove(item.id)
                            } else {
                                expandedIDs.insert(item.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(item.targetName) replied")
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: expandedIDs.contains(item.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expandedIDs.contains(item.id) {
                        MarkdownView(reply)
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary)
                            }
                    }
                }
            case .failed:
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(item.targetName) did not reply")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.2))
        }
    }
}

/// The classic thinking indicator: three small dots cycling their alpha with a
/// phase offset.
struct ThreeDotsIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 4, height: 4)
                    .opacity(pulse ? 0.2 : 1)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: pulse
                    )
            }
        }
        .onAppear { pulse = true }
    }
}
