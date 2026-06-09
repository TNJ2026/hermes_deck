import SwiftUI

struct ToolCallSection: View {
    let events: [ToolCallEvent]

    var body: some View {
        ProcessSection(
            dotColor: aggregateDotColor
        ) {
            title
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    ToolCallRow(event: event)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Tool calls")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(toolTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.5), in: Capsule())
            Text(tokenEstimate(forCharacters: characterCount))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }

    private var aggregateDotColor: Color {
        events.contains { $0.state != .complete } ? .purple : .green
    }

    private var toolTitle: String {
        let names = events
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) {
                result.append(name)
            }
        }
        let joined = uniqueNames.isEmpty ? "tool" : uniqueNames.joined(separator: ", ")
        return joined.count > 12 ? String(joined.prefix(12)) + "…" : joined
    }

    private var characterCount: Int {
        events.reduce(0) { total, event in
            total + (event.context?.count ?? 0) + (event.summary?.count ?? 0)
        }
    }
}

struct ToolCallRow: View {
    let event: ToolCallEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolJSONText(text: toolCallJSONText)
            if let summary = completionSummary {
                ToolJSONText(text: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var completionSummary: String? {
        guard let summary = event.summary, !summary.isEmpty, summary != event.context else { return nil }
        return summary
    }

    private var toolCallJSONText: String {
        guard let context = event.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
            return "{}"
        }
        return context
    }
}

struct ToolJSONText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolSummaryContent: View {
    let summary: String
    @Binding var disclosure: ToolMessageContentDisclosureState
    @State private var fullTextHeight: CGFloat = 0
    @State private var singleLineTextHeight: CGFloat = 0

    private var isOverflowing: Bool {
        fullTextHeight > singleLineTextHeight + 1
    }

    var body: some View {
        Group {
            if isOverflowing {
                Button {
                    withAnimation(.smooth(duration: 0.16)) {
                        disclosure.toggle()
                    }
                } label: {
                    summaryRow(showsIndicator: true)
                }
                .buttonStyle(.plain)
            } else {
                summaryRow(showsIndicator: false)
            }
        }
        .onPreferenceChange(ToolSummaryFullHeightPreferenceKey.self) { height in
            fullTextHeight = height
        }
        .onPreferenceChange(ToolSummarySingleLineHeightPreferenceKey.self) { height in
            singleLineTextHeight = height
        }
    }

    private func summaryRow(showsIndicator: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showsIndicator {
                Text(disclosure.indicatorText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, alignment: .leading)
            }

            measuredSummaryText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var measuredSummaryText: some View {
        Text(summary)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(isOverflowing ? disclosure.lineLimit : nil)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                Text(summary)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .readHeight(ToolSummaryFullHeightPreferenceKey.self)
            }
            .background(alignment: .topLeading) {
                Text(summary)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .readHeight(ToolSummarySingleLineHeightPreferenceKey.self)
            }
    }
}

struct ToolSummaryFullHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ToolSummarySingleLineHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
