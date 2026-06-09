import SwiftUI

struct ComposerView: View {
    @Bindable var store: ChatStore
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    var presentation: ComposerPresentation = .floating
    var sendState: ChatSendState?
    var attachments: [Attachment]
    var permissionRequest: PermissionRequest?
    var clarificationRequest: ClarificationRequest?
    var sessionInfo: HermesSessionInfo
    var removeAttachment: (Attachment) -> Void
    var dismissPermissionRequest: () -> Void
    var answerPermission: (Int) -> Void = { _ in }
    var dismissClarificationRequest: () -> Void
    var simulatePermissionRequest: () -> Void
    var requestFileImport: () -> Void
    var sendAction: (String) async -> Void = { _ in }
    /// Hermes slash commands for the `/` popup; empty disables it.
    var slashCommands: [SlashCommand] = []
    @State private var sendTask: Task<Void, Never>?
    @State private var speechTranscriber = SpeechTranscriber()
    @State private var speechBaselineDraft = ""
    @State private var mentionSelectedIndex = 0
    @State private var suppressedMentionQuery: String?
    @State private var mentionPopupHeight: CGFloat = 0
    @State private var slashSelectedIndex = 0
    @State private var suppressedSlashQuery: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentChip(attachment: attachment) {
                            removeAttachment(attachment)
                        }
                    }
                }
            }

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

            VStack(alignment: .leading, spacing: 4) {
                TextField("Ask anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.system(size: 14.5))
                    .frame(minHeight: 24, alignment: .topLeading)
                    .onSubmit(send)
                    .onKeyPress { press in handleComposerKey(press) }

                HStack(alignment: .center, spacing: 4) {
                    if speechTranscriber.isRecording {
                        WaveformView(levels: speechTranscriber.audioLevels, tint: .blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .allowsHitTesting(false)
                    } else {
                        ComposerIconButton(systemImage: "paperclip", accessibilityLabel: "Attach") {
                            requestFileImport()
                        }

                        Spacer(minLength: 10)

                        if sessionInfo.hasModelInfo {
                            Button {
                            } label: {
                                Text(sessionInfo.displayText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 28)
                                    .padding(.horizontal, 9)
                            }
                            .buttonStyle(.plain)
                            .disabled(true)
                        }
                    }

                    ComposerIconButton(
                        systemImage: speechTranscriber.isRecording ? "stop.fill" : "mic",
                        accessibilityLabel: speechTranscriber.isRecording ? "Stop Voice Input" : "Voice Input",
                        tint: speechTranscriber.isRecording ? .red : .secondary
                    ) {
                        toggleVoiceInput()
                    }
                    .disabled(isSending || speechTranscriber.isLockedOut)
                    .help(speechTranscriber.helpText)

                    if !speechTranscriber.isRecording {
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
                            .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(sendButtonForeground)
                        .background(sendButtonBackground, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(color: sendButtonShadow, radius: 12, x: 0, y: 4)
                        .disabled(!canSend && !isSending)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 10)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .composerSurface(presentation: presentation, cornerRadius: 13, border: inputBorder)
            .overlay(alignment: .topLeading) {
                if let mention = activeMention {
                    let candidates = filteredCandidates(for: mention.query)
                    if !candidates.isEmpty {
                        MentionAutocompleteList(
                            candidates: candidates,
                            selectedIndex: mentionSelectedIndex
                        ) { candidate in
                            insertMention(candidate, replacing: mention.range)
                        }
                        .readHeight(MentionPopupHeightPreferenceKey.self)
                        .offset(y: -(mentionPopupHeight + 6))
                        .onPreferenceChange(MentionPopupHeightPreferenceKey.self) { mentionPopupHeight = $0 }
                        .onChange(of: mention.query) { _, _ in mentionSelectedIndex = 0 }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let slash = activeSlash {
                    let commands = filteredSlashCommands(for: slash.query)
                    if !commands.isEmpty {
                        SlashAutocompleteList(
                            commands: commands,
                            selectedIndex: slashSelectedIndex
                        ) { command in
                            insertSlash(command, replacing: slash.range)
                        }
                        .readHeight(MentionPopupHeightPreferenceKey.self)
                        .offset(y: -(mentionPopupHeight + 6))
                        .onPreferenceChange(MentionPopupHeightPreferenceKey.self) { mentionPopupHeight = $0 }
                        .onChange(of: slash.query) { _, _ in slashSelectedIndex = 0 }
                    }
                }
            }

            if case .failed(let message) = currentSendState {
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

    // MARK: - @ mention autocomplete

    private var mentionCandidates: [MentionCandidate] {
        let hermes = store.agentProfiles.map { profile in
            MentionCandidate(
                id: profile.id,
                label: profile.displayName,
                subtitle: store.profileMainModels[profile.id] ?? "Hermes profile",
                alias: profile.id
            )
        }
        let external = store.externalAgentMentionTargets.map { target in
            MentionCandidate(
                id: target.profile.id,
                label: target.profile.displayName,
                subtitle: Self.backendLabel(target.backend),
                alias: target.aliases.first ?? target.profile.id
            )
        }
        return hermes + external
    }

    private static func backendLabel(_ backend: AgentBackend) -> String {
        switch backend {
        case .hermes: "Hermes"
        case .acp(let agent): "\(agent.displayName) (ACP)"
        case .claudeCLI: "Claude CLI"
        case .agy: "Antigravity CLI"
        }
    }

    /// The mention being typed, unless the user pressed Esc on this exact query.
    private var activeMention: (range: Range<String.Index>, query: String)? {
        guard let mention = ComposerMention.activeQuery(in: draft) else { return nil }
        if let suppressed = suppressedMentionQuery, suppressed == mention.query { return nil }
        return mention
    }

    private func filteredCandidates(for query: String) -> [MentionCandidate] {
        guard !query.isEmpty else { return mentionCandidates }
        return mentionCandidates.filter {
            $0.alias.lowercased().contains(query) || $0.label.lowercased().contains(query)
        }
    }

    private func insertMention(_ candidate: MentionCandidate, replacing range: Range<String.Index>) {
        draft.replaceSubrange(range, with: "@\(candidate.alias) ")
        suppressedMentionQuery = nil
        mentionSelectedIndex = 0
    }

    private func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
        guard let mention = activeMention else { return .ignored }
        let candidates = filteredCandidates(for: mention.query)
        guard !candidates.isEmpty else { return .ignored }

        switch press.key {
        case .downArrow:
            mentionSelectedIndex = (mentionSelectedIndex + 1) % candidates.count
            return .handled
        case .upArrow:
            mentionSelectedIndex = (mentionSelectedIndex - 1 + candidates.count) % candidates.count
            return .handled
        case .return, .tab:
            let index = min(max(mentionSelectedIndex, 0), candidates.count - 1)
            insertMention(candidates[index], replacing: mention.range)
            return .handled
        case .escape:
            suppressedMentionQuery = mention.query
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - / slash-command autocomplete (Hermes)

    private var activeSlash: (range: Range<String.Index>, query: String)? {
        guard !slashCommands.isEmpty else { return nil }
        guard let slash = ComposerSlash.activeQuery(in: draft) else { return nil }
        if let suppressed = suppressedSlashQuery, suppressed == slash.query { return nil }
        return slash
    }

    private func filteredSlashCommands(for query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return slashCommands }
        return slashCommands.filter { $0.name.lowercased().contains(query) }
    }

    private func insertSlash(_ command: SlashCommand, replacing range: Range<String.Index>) {
        draft.replaceSubrange(range, with: "/\(command.name) ")
        suppressedSlashQuery = nil
        slashSelectedIndex = 0
    }

    private func handleSlashKey(_ press: KeyPress) -> KeyPress.Result {
        guard let slash = activeSlash else { return .ignored }
        let commands = filteredSlashCommands(for: slash.query)
        guard !commands.isEmpty else { return .ignored }

        switch press.key {
        case .downArrow:
            slashSelectedIndex = (slashSelectedIndex + 1) % commands.count
            return .handled
        case .upArrow:
            slashSelectedIndex = (slashSelectedIndex - 1 + commands.count) % commands.count
            return .handled
        case .return, .tab:
            let index = min(max(slashSelectedIndex, 0), commands.count - 1)
            insertSlash(commands[index], replacing: slash.range)
            return .handled
        case .escape:
            suppressedSlashQuery = slash.query
            return .handled
        default:
            return .ignored
        }
    }

    /// Routes keys to whichever autocomplete popup is active (mention or slash).
    private func handleComposerKey(_ press: KeyPress) -> KeyPress.Result {
        if activeMention != nil { return handleMentionKey(press) }
        if activeSlash != nil { return handleSlashKey(press) }
        return .ignored
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && currentSendState != .sending
    }

    private var isSending: Bool {
        currentSendState == .sending
    }

    private var currentSendState: ChatSendState {
        sendState ?? store.sendState
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

    private var sendButtonShadow: Color {
        if isSending { return .red.opacity(0.24) }
        if presentation == .inline { return .clear }
        return canSend ? .accentColor.opacity(0.32) : .clear
    }

    private var composerPadding: EdgeInsets {
        switch presentation {
        case .floating:
            EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
        case .inline:
            EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0)
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
            await MainActor.run {
                sendTask = nil
            }
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
            await MainActor.run {
                sendTask = nil
            }
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
        // 不门控 isRecording：最终 (isFinal) 结果到达时 state 已被重置为 .idle，
        // SwiftUI 在合并的视图更新里触发 onChange，此时 isRecording 必为 false。
        guard !transcript.isEmpty else { return }
        let separator = speechBaselineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        draft = speechBaselineDraft + separator + transcript
    }
}
