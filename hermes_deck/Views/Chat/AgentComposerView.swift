import SwiftUI

/// A trimmed-down composer for the external agent panels (Claude / Codex /
/// Gemini): a text field, voice input, and a send/cancel button — no
/// attachments, session chip, or mention popup. Permission and clarification
/// banners are kept so an ACP agent (Codex) can still prompt for approval.
///
/// Implemented independently of `ComposerView` so changes here don't affect the
/// main Hermes composer. Reuses the shared `ComposerIconButton`,
/// `SpeechTranscriber`, banner views, and `.composerSurface` styling.
struct AgentComposerView: View {
    @Binding var draft: String
    var sendState: ChatSendState = .idle
    var presentation: ComposerPresentation = .inline
    var permissionRequest: PermissionRequest?
    var clarificationRequest: ClarificationRequest?
    var answerPermission: (Int) -> Void = { _ in }
    var dismissPermissionRequest: () -> Void = {}
    var dismissClarificationRequest: () -> Void = {}
    var sendAction: (String) async -> Void = { _ in }

    @State private var sendTask: Task<Void, Never>?
    @State private var speechTranscriber = SpeechTranscriber()
    @State private var speechBaselineDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = permissionRequest {
                PermissionRequestBanner(request: request, onAnswer: answerPermission) {
                    dismissPermissionRequest()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = clarificationRequest {
                ClarificationRequestBanner(
                    request: request,
                    isSending: isSending,
                    onAnswer: answerClarification,
                    onDismiss: dismissClarificationRequest
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Group {
                if speechTranscriber.isRecording {
                    // Two-part recording layout: live transcript on top, waveform
                    // and the stop button on the row below.
                    VStack(alignment: .leading, spacing: 8) {
                        inputField
                        HStack(alignment: .center, spacing: 6) {
                            WaveformView(levels: speechTranscriber.audioLevels, tint: .blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                                .allowsHitTesting(false)
                            voiceButton
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 6) {
                        inputField
                        voiceButton
                        Button(action: sendOrCancel) {
                            Group {
                                if isSending {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(sendButtonForeground)
                        .background(sendButtonBackground, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!canSend && !isSending)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .composerSurface(presentation: presentation, cornerRadius: 13, border: inputBorder)

            if case .failed(let message) = sendState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(composerPadding)
        .onChange(of: speechTranscriber.transcript) { _, newValue in
            updateDraft(withTranscript: newValue)
        }
        .onDisappear {
            speechTranscriber.stopRecording()
        }
    }

    private var inputField: some View {
        TextField("Ask anything", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(.system(size: 14.5))
            .frame(minHeight: 24, alignment: .topLeading)
            .onSubmit(send)
    }

    private var voiceButton: some View {
        Button {
            toggleVoiceInput()
        } label: {
            Image(systemName: speechTranscriber.isRecording ? "stop.fill" : "mic")
                .font(.system(size: 14))
                .foregroundStyle(speechTranscriber.isRecording ? .red : .secondary)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speechTranscriber.isRecording ? "Stop Voice Input" : "Voice Input")
        .disabled(isSending || speechTranscriber.isLockedOut)
        .help(speechTranscriber.helpText)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sendState != .sending
    }

    private var isSending: Bool {
        sendState == .sending
    }

    private var inputBorder: Color {
        canSend ? .accentColor.opacity(0.3) : .secondary.opacity(0.18)
    }

    private var sendButtonBackground: Color {
        if isSending { return .red.opacity(0.88) }
        return canSend ? .accentColor : .secondary.opacity(0.16)
    }

    private var sendButtonForeground: Color {
        canSend || isSending ? .white : .secondary
    }

    private var composerPadding: EdgeInsets {
        switch presentation {
        case .floating:
            EdgeInsets(top: 24, leading: 14, bottom: 10, trailing: 14)
        case .inline:
            EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14)
        }
    }

    private func sendOrCancel() {
        if isSending {
            sendTask?.cancel()
            sendTask = nil
        } else {
            send()
        }
    }

    private func send() {
        guard canSend else { return }
        speechTranscriber.stopRecording()
        let message = draft
        draft = ""
        sendTask = Task {
            await sendAction(message)
            await MainActor.run { sendTask = nil }
        }
    }

    private func answerClarification(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        dismissClarificationRequest()
        speechTranscriber.stopRecording()
        draft = ""
        sendTask = Task {
            await sendAction(trimmed)
            await MainActor.run { sendTask = nil }
        }
    }

    private func toggleVoiceInput() {
        if speechTranscriber.isRecording {
            speechTranscriber.stopRecording()
        } else {
            speechBaselineDraft = draft
            Task { @MainActor in
                await speechTranscriber.startRecording()
            }
        }
    }

    private func updateDraft(withTranscript transcript: String) {
        guard !transcript.isEmpty else { return }
        let separator = speechBaselineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        draft = speechBaselineDraft + separator + transcript
    }
}
