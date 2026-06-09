import SwiftUI

/// A live scrolling audio waveform: one capsule bar per recent input level,
/// newest on the right. Heights animate as the rolling `levels` buffer shifts.
struct WaveformView: View {
    /// Normalized levels (0…1), oldest first.
    let levels: [Float]
    var tint: Color = .accentColor

    private let spacing: CGFloat = 1.5
    private let minBarHeight: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.35 + 0.65 * Double(levels[index])))
                        .frame(
                            width: barWidth,
                            height: max(minBarHeight, CGFloat(levels[index]) * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}
