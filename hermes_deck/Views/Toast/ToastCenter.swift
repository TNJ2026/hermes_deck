import Observation
import SwiftUI

/// App-wide, top-center transient messages (e.g. voice-input errors). A single
/// shared instance lets any component post a toast without threading a binding
/// through the view tree; the root view renders it via `.toastOverlay()`.
/// An optional tappable action shown alongside a toast (e.g. "Open Settings").
@MainActor
struct ToastAction {
    let label: String
    let handler: () -> Void
}

@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var message: String?
    @ObservationIgnored private(set) var action: ToastAction?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Shows `text` at the top-center for `duration` seconds, replacing any
    /// currently visible toast. An optional `action` renders a trailing button.
    func show(_ text: String, action: ToastAction? = nil, duration: Duration = .seconds(3.5)) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.action = action
        message = trimmed
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
        action = nil
    }
}

private struct ToastOverlay: ViewModifier {
    @State private var toasts = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = toasts.message {
                ToastBanner(message: message, action: toasts.action) { toasts.dismiss() }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(message)
            }
        }
        .animation(.smooth(duration: 0.22), value: toasts.message)
    }
}

private struct ToastBanner: View {
    let message: String
    var action: ToastAction?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                // Size the toast to the text instead of stretching to a fixed
                // max width.
                .fixedSize(horizontal: true, vertical: false)
            if let action {
                Button(action.label) {
                    action.handler()
                    onClose()
                }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 6)
    }
}

extension View {
    /// Renders top-center toasts from `ToastCenter.shared`. Apply once near the
    /// window root.
    func toastOverlay() -> some View {
        modifier(ToastOverlay())
    }
}
