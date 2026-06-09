import SwiftUI

struct MentionCandidate: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String
    let alias: String
}

/// Floating list shown above the composer when the user types `@`, listing the
/// Hermes profiles and external agents (Codex/Claude/Gemini) that can be
/// mentioned. Mirrors the profile menu's panel styling.
struct MentionAutocompleteList: View {
    let candidates: [MentionCandidate]
    let selectedIndex: Int
    let onSelect: (MentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("@\(candidate.alias) · \(candidate.subtitle)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        index == selectedIndex ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

/// Floating list shown above the composer when the user types `/`, listing the
/// Hermes gateway slash commands.
struct SlashAutocompleteList: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    let onSelect: (SlashCommand) -> Void
    @State private var contentHeight: CGFloat = 0

    private let maxPopupHeight: CGFloat = 400

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                        Button {
                            onSelect(command)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/\(command.name)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !command.subtitle.isEmpty {
                                    Text(command.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                index == selectedIndex ? Color.primary.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(6)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SlashContentHeightPreferenceKey.self, value: geometry.size.height)
                })
            }
            .onChange(of: selectedIndex) { _, index in
                // Keep the keyboard-selected row visible.
                proxy.scrollTo(index, anchor: .center)
            }
        }
        // Size to content (so it doesn't fill the small overlay proposal), capped.
        .frame(width: 300, height: min(contentHeight, maxPopupHeight))
        .onPreferenceChange(SlashContentHeightPreferenceKey.self) { contentHeight = $0 }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

struct MentionPopupHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SlashContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
