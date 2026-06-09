import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatStore {
    var threads: [ChatThread]
    var selectedThreadID: UUID?
    var selectedProfile: HermesProfile
    var availableProfiles: [HermesProfile]
    var sendState: ChatSendState = .idle
    var agentSendStates: [UUID: ChatSendState] = [:]
    /// True while any thread (main or agent) is still streaming a reply. Used to
    /// lock profile switching until the agent finishes responding.
    var isResponding: Bool {
        sendState == .sending || agentSendStates.values.contains(.sending)
    }
    var pendingAttachments: [Attachment] = []
    var agentPendingAttachments: [UUID: [Attachment]] = [:]
    var pendingPermissionRequest: PermissionRequest?
    var agentPendingPermissionRequests: [UUID: PermissionRequest] = [:]
    var pendingClarificationRequest: ClarificationRequest?
    var agentPendingClarificationRequests: [UUID: ClarificationRequest] = [:]
    var taskSubagents: [SubagentProgress] = []
    var activeTaskThreadID: UUID?
    var sessionInfo = HermesSessionInfo()
    var agentSessionInfos: [UUID: HermesSessionInfo] = [:]
    /// Per-agent-thread working directory overrides (codex/claude/agy). Defaults
    /// to the running Hermes session's cwd.
    var agentWorkingDirectories: [UUID: URL] = [:]
    /// Hermes gateway slash commands for the main composer's `/` popup (ignored
    /// ones excluded). Loaded per selected profile.
    var hermesSlashCommands: [SlashCommand] = []
    var latestAgentRouteRequest: AgentRouteRequest?
    /// Set when a `@codex` / `@claude` / `@gemini` mention routes from the main
    /// chat; the right sidebar opens the matching external-agent panel.
    var pendingExternalAgentPanel: AgentBackend?
    var sessionListState: HermesSessionListState = .idle
    /// Recent sessions for the selected profile, shown in the sidebar History.
    var historySessions: [HermesSessionListItem] = []
    var modelListState: HermesModelListState = .idle
    var toolListState: HermesToolListState = .idle
    var skillListState: HermesSkillListState = .idle
    var jobListState: HermesJobListState = .idle
    var kanbanListState: HermesKanbanListState = .idle
    var profileMainModels: [String: String] = [:]
    var profileGatewayRunning: [String: Bool] = [:]
    var startingGatewayProfiles: Set<String> = []
    var canLoadMoreSessions = false
    var isLoadingMoreSessions = false
    /// Whether the hermes backend CLI is installed. Drives the "not installed"
    /// placeholder in the main chat area. Optimistic default avoids a flash.
    var hermesInstalled = true

    private let agentClient: any HermesAgentClient
    private let profileProvider: any HermesProfileProvider
    private let sessionProvider: any HermesSessionProvider
    private let modelConfigurationProvider: any HermesModelConfigurationProvider
    private let pluginProvider: any HermesPluginProvider
    private let skillProvider: any HermesSkillProvider
    private let jobProvider: any HermesJobProvider
    private let kanbanProvider: any HermesKanbanProvider
    private let gatewayProvider: any HermesGatewayProvider
    private let sessionPageSize: Int
    private var sessionLoadGeneration = 0
    private var historyThreadIDs: Set<UUID> = []
    private var threadBackends: [UUID: AgentBackend] = [:]
    var sessionSearchQuery = ""

    var selectedThread: ChatThread? {
        get {
            guard let selectedThreadID else { return nil }
            return threads.first { $0.id == selectedThreadID }
        }
        set {
            guard let newValue, let index = threads.firstIndex(where: { $0.id == newValue.id }) else { return }
            threads[index] = newValue
        }
    }

    var agentProfiles: [HermesProfile] {
        availableProfiles.filter { profile in
            profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "default"
        }
    }

    /// Running subagents — drives the Task rail-icon badge.
    var runningSubagentCount: Int {
        taskSubagents.filter { $0.status == .running }.count
    }

    /// Kanban tasks in an active column (scheduled → review) — drives the Kanban
    /// rail-icon badge.
    var activeKanbanTaskCount: Int {
        let active: Set<KanbanStatus> = [.scheduled, .ready, .running, .blocked, .review]
        return kanbanListState.tasks.filter { task in
            guard let status = task.kanbanStatus else { return false }
            return active.contains(status)
        }.count
    }

    /// External (non-Hermes) agents reachable from the main chat via `@alias`.
    /// Profile ids/backends mirror the dedicated agent panels so a routed thread
    /// is shared with its panel.
    var externalAgentMentionTargets: [ExternalAgentMentionTarget] {
        [
            ExternalAgentMentionTarget(
                aliases: ["codex"],
                profile: HermesProfile(id: "acp:codex", displayName: ACPAgent.codex.displayName),
                backend: .acp(.codex)
            ),
            ExternalAgentMentionTarget(
                aliases: ["claude", "claude-code", "claudecode"],
                profile: HermesProfile(id: "claude-cli", displayName: "Claude Code"),
                backend: .claudeCLI
            ),
            ExternalAgentMentionTarget(
                aliases: ["gemini", "antigravity", "agy"],
                profile: HermesProfile(id: "agy", displayName: "Gemini (Antigravity)"),
                backend: .agy
            ),
        ]
    }

    private func externalAgentRoute(for text: String) -> (target: ExternalAgentMentionTarget, message: String)? {
        for target in externalAgentMentionTargets {
            if let message = AgentMentionRouteParser.routedMessage(in: text, aliases: target.aliases) {
                return (target, message)
            }
        }
        return nil
    }

    private func mentionRouteTarget(for text: String) -> (target: AgentRouteTarget, message: String, returnsReply: Bool, isExternal: Bool)? {
        if let external = externalAgentRoute(for: text) {
            let directive = AgentReturnDirective.parse(external.message)
            return (
                AgentRouteTarget(profile: external.target.profile, backend: external.target.backend),
                directive.message,
                directive.returnsReply,
                true
            )
        }

        if let route = AgentMentionRouteParser.parse(text, profiles: agentProfiles) {
            let directive = AgentReturnDirective.parse(route.message)
            return (
                AgentRouteTarget(profile: route.profile, backend: .hermes),
                directive.message,
                directive.returnsReply,
                false
            )
        }

        return nil
    }

    /// Working directory for an agent thread: an explicit in-session override,
    /// else the last value persisted for that backend (claude / codex / gemini),
    /// else the default workspace.
    func agentWorkingDirectory(for threadID: UUID) -> URL {
        if let override = agentWorkingDirectories[threadID] { return override }
        if let key = Self.workdirDefaultsKey(for: threadBackends[threadID]),
           let path = UserDefaults.standard.string(forKey: key) {
            return URL(fileURLWithPath: path)
        }
        return Self.defaultAgentWorkingDirectory()
    }

    /// UserDefaults key under which a backend's chosen working directory is
    /// persisted across cold starts. `nil` for the main Hermes chat, which is
    /// not backed by a dedicated panel directory.
    private static func workdirDefaultsKey(for backend: AgentBackend?) -> String? {
        switch backend {
        case .acp(let agent): "agentWorkdir.acp.\(agent.rawValue)"
        case .agy: "agentWorkdir.agy"
        case .claudeCLI: "agentWorkdir.claude-cli"
        case .hermes, .none: nil
        }
    }

    /// Default agent working directory: a dedicated, non-TCC-protected folder
    /// (`~/.hermes/workspace`) rather than HOME. Running an agent (codex) in HOME
    /// makes it touch ~/Desktop, ~/Documents, ~/Downloads, … each of which
    /// triggers a separate macOS permission prompt.
    static func defaultAgentWorkingDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/workspace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func setAgentWorkingDirectory(_ url: URL, for threadID: UUID) {
        agentWorkingDirectories[threadID] = url
        if let key = Self.workdirDefaultsKey(for: threadBackends[threadID]) {
            UserDefaults.standard.set(url.path(percentEncoded: false), forKey: key)
        }
    }

    /// Whether `text` mentions a forwardable agent (external or Hermes profile).
    func hasMentionRoute(_ text: String) -> Bool {
        mentionRouteTarget(for: text) != nil
    }

    /// Forwards an `@mention` prompt to its target agent when the source is
    /// allowed to route. Hermes profiles can route to Hermes and external
    /// agents; external agents cannot route to any other agent and should treat
    /// denied prompts as ordinary messages to their current backend.
    @discardableResult
    func routePromptIfAllowed(
        _ text: String,
        from source: PromptRouteSource,
        sourceThreadID: UUID,
        notifiesPanel: Bool = true
    ) async -> PromptRouteResult {
        guard let route = mentionRouteTarget(for: text) else { return .notMention }
        guard case .hermes = source else { return .denied(.externalSourceCannotRoute) }

        let sourceAttachments = takePendingAttachmentsForRoute(from: sourceThreadID)
        append(ChatMessage(role: .user, content: text, attachments: sourceAttachments), to: sourceThreadID)
        historyThreadIDs.insert(sourceThreadID)

        let agentThreadID = threadIDForAgentProfile(route.target.profile)
        threadBackends[agentThreadID] = route.target.backend
        agentPendingAttachments[agentThreadID, default: []].append(contentsOf: sourceAttachments)
        if notifiesPanel {
            if route.isExternal {
                pendingExternalAgentPanel = route.target.backend
            } else {
                latestAgentRouteRequest = AgentRouteRequest(
                    profile: route.target.profile,
                    threadID: agentThreadID,
                    sourceThreadID: sourceThreadID
                )
            }
        }

        let routedResult = await send(
            route.message,
            in: agentThreadID,
            profile: route.target.profile,
            routedSourceProfileName: source.displayName
        )
        if route.returnsReply, let routedResult, !routedResult.isEmpty {
            append(
                ChatMessage(role: .assistant, content: "\(route.target.profile.displayName):\n\n\(routedResult)", completedAt: .now),
                to: sourceThreadID
            )
        }
        return .routed
    }

    func thread(id: UUID?) -> ChatThread? {
        guard let id else { return nil }
        return threads.first { $0.id == id }
    }

    init(
        agentClient: any HermesAgentClient,
        profileProvider: (any HermesProfileProvider)? = nil,
        sessionProvider: (any HermesSessionProvider)? = nil,
        modelConfigurationProvider: (any HermesModelConfigurationProvider)? = nil,
        pluginProvider: (any HermesPluginProvider)? = nil,
        skillProvider: (any HermesSkillProvider)? = nil,
        jobProvider: (any HermesJobProvider)? = nil,
        kanbanProvider: (any HermesKanbanProvider)? = nil,
        gatewayProvider: (any HermesGatewayProvider)? = nil,
        sessionPageSize: Int = 100,
        threads: [ChatThread] = []
    ) {
        // Providers are constructed here (in this @MainActor init body) rather
        // than as default arguments: the actor-backed providers are main-actor
        // isolated under the project's default-isolation setting, and default
        // arguments evaluate in a nonisolated context, which would warn.
        self.agentClient = agentClient
        self.profileProvider = profileProvider ?? LocalHermesProfileProvider()
        self.sessionProvider = sessionProvider ?? LocalHermesSessionProvider()
        self.modelConfigurationProvider = modelConfigurationProvider ?? LocalHermesModelConfigurationProvider()
        self.pluginProvider = pluginProvider ?? LocalHermesPluginProvider()
        self.skillProvider = skillProvider ?? LocalHermesSkillProvider()
        self.jobProvider = jobProvider ?? LocalHermesJobProvider()
        self.kanbanProvider = kanbanProvider ?? LocalHermesKanbanProvider()
        self.gatewayProvider = gatewayProvider ?? LocalHermesGatewayProvider()
        self.sessionPageSize = max(1, sessionPageSize)
        self.selectedProfile = .defaultProfile
        self.availableProfiles = HermesProfile.presets
        self.threads = threads.isEmpty ? [ChatThread(title: "New Chat")] : threads
        self.selectedThreadID = self.threads.first?.id
    }

    func createThread(title: String = "New Chat") {
        let thread = ChatThread(title: title, profile: selectedProfile)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
    }

    func openAgentProfile(_ profile: HermesProfile) {
        selectedProfile = profile
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            selectedThreadID = thread.id
            return
        }

        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
    }

    @discardableResult
    func threadIDForAgentProfile(_ profile: HermesProfile) -> UUID {
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            return thread.id
        }

        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        return thread.id
    }

    /// Finds or creates the chat thread bound to an ACP agent and tags it with
    /// the `.acp` backend so sends route to that agent.
    @discardableResult
    func acpThread(for agent: ACPAgent) -> UUID {
        let profile = HermesProfile(id: "acp:\(agent.rawValue)", displayName: agent.displayName)
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            threadBackends[thread.id] = .acp(agent)
            return thread.id
        }
        let thread = ChatThread(title: agent.displayName, profile: profile)
        threads.insert(thread, at: 0)
        threadBackends[thread.id] = .acp(agent)
        return thread.id
    }

    /// Boots the ACP agent ahead of the first prompt so its startup latency is
    /// hidden behind the user opening the panel and typing.
    func prewarmACP(_ agent: ACPAgent) async {
        await agentClient.warmUp(backend: .acp(agent))
    }

    func sendToACP(_ rawText: String, agent: ACPAgent, threadID: UUID) async {
        threadBackends[threadID] = .acp(agent)
        let profile = thread(id: threadID)?.profile ?? HermesProfile(id: "acp:\(agent.rawValue)", displayName: agent.displayName)
        await send(rawText, in: threadID, profile: profile)
    }

    /// Finds or creates the chat thread bound to the Antigravity (`agy`) CLI.
    @discardableResult
    func agyThread() -> UUID {
        let profile = HermesProfile(id: "agy", displayName: "Gemini (Antigravity)")
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            threadBackends[thread.id] = .agy
            return thread.id
        }
        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        threadBackends[thread.id] = .agy
        return thread.id
    }

    func sendToAgy(_ rawText: String, threadID: UUID) async {
        threadBackends[threadID] = .agy
        let profile = thread(id: threadID)?.profile ?? HermesProfile(id: "agy", displayName: "Gemini (Antigravity)")
        await send(rawText, in: threadID, profile: profile)
    }

    /// Finds or creates the chat thread bound to the local `claude` CLI backend.
    @discardableResult
    func claudeCLIThread() -> UUID {
        let profile = HermesProfile(id: "claude-cli", displayName: "Claude Code")
        if let thread = threads.first(where: { $0.profile.id == profile.id }) {
            threadBackends[thread.id] = .claudeCLI
            return thread.id
        }
        let thread = ChatThread(title: profile.displayName, profile: profile)
        threads.insert(thread, at: 0)
        threadBackends[thread.id] = .claudeCLI
        return thread.id
    }

    func sendToClaudeCLI(_ rawText: String, threadID: UUID) async {
        threadBackends[threadID] = .claudeCLI
        let profile = thread(id: threadID)?.profile ?? HermesProfile(id: "claude-cli", displayName: "Claude Code")
        await send(rawText, in: threadID, profile: profile)
    }

    func sendState(forAgentThreadID threadID: UUID?) -> ChatSendState {
        guard let threadID else { return .idle }
        return agentSendStates[threadID] ?? .idle
    }

    func pendingAttachments(forAgentThreadID threadID: UUID?) -> [Attachment] {
        guard let threadID else { return [] }
        return agentPendingAttachments[threadID] ?? []
    }

    func pendingPermissionRequest(forAgentThreadID threadID: UUID?) -> PermissionRequest? {
        guard let threadID else { return nil }
        return agentPendingPermissionRequests[threadID]
    }

    func pendingClarificationRequest(forAgentThreadID threadID: UUID?) -> ClarificationRequest? {
        guard let threadID else { return nil }
        return agentPendingClarificationRequests[threadID]
    }

    func sessionInfo(forAgentThreadID threadID: UUID?) -> HermesSessionInfo {
        guard let threadID else { return HermesSessionInfo() }
        return agentSessionInfos[threadID] ?? HermesSessionInfo()
    }

    func select(_ thread: ChatThread) {
        selectedThreadID = thread.id
        selectedProfile = thread.profile
    }

    func setProfile(_ profile: HermesProfile) {
        selectedProfile = profile
        mutateSelectedThread { thread in
            thread.profile = profile
            thread.updatedAt = .now
        }
    }

    /// Switches the active profile and starts a fresh chat session under it. Used
    /// when the user changes profile while on the chat page.
    func setProfileStartingNewThread(_ profile: HermesProfile) {
        selectedProfile = profile
        createThread()
    }

    func loadProfiles() async {
        do {
            let profiles = try await profileProvider.profiles()
            guard !profiles.isEmpty else { return }
            availableProfiles = profiles
            if let refreshed = profiles.first(where: { $0.id == selectedProfile.id }) {
                setProfile(refreshed)
            } else if let first = profiles.first {
                setProfile(first)
            }
            // Refresh main models now that the real profiles are loaded — an
            // earlier load ran against the presets and missed these ids.
            await loadProfileMainModels()
        } catch {
            availableProfiles = HermesProfile.presets
        }
    }

    /// Reads each profile's configured main model (`model.default` in that
    /// profile's config.yaml) for display in the profile picker.
    func refreshAllGatewayStatuses() async {
        var map: [String: Bool] = [:]
        for profile in availableProfiles {
            map[profile.id] = await gatewayProvider.isRunning(profile: profile)
        }
        profileGatewayRunning = map
    }

    func isGatewayStarting(_ profile: HermesProfile) -> Bool {
        startingGatewayProfiles.contains(profile.id)
    }

    func startGateway(for profile: HermesProfile) async {
        guard !startingGatewayProfiles.contains(profile.id) else { return }
        startingGatewayProfiles.insert(profile.id)
        try? await gatewayProvider.start(profile: profile)
        // Poll until the gateway reports running (or give up after ~12s).
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(600))
            if await gatewayProvider.isRunning(profile: profile) {
                profileGatewayRunning[profile.id] = true
                startingGatewayProfiles.remove(profile.id)
                return
            }
        }
        profileGatewayRunning[profile.id] = await gatewayProvider.isRunning(profile: profile)
        startingGatewayProfiles.remove(profile.id)
    }

    func loadProfileMainModels() async {
        let profiles = availableProfiles
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        profileMainModels = await Task.detached { () -> [String: String] in
            var map: [String: String] = [:]
            for profile in profiles {
                let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let home = (id == "default" || id.isEmpty)
                    ? root
                    : root.appendingPathComponent("profiles").appendingPathComponent(id)
                let config = HermesConfigurationFile(url: home.appendingPathComponent("config.yaml"))
                try? config.load()
                if let model = (try? config.string(at: ["model", "default"])) ?? nil, !model.isEmpty {
                    map[profile.id] = model
                }
            }
            return map
        }.value
    }

    func loadConfiguredModels() async {
        modelListState = .loading
        do {
            modelListState = .loaded(try await modelConfigurationProvider.configuredModels())
        } catch {
            modelListState = .failed(error.localizedDescription)
        }
    }

    func loadInstalledTools() async {
        toolListState = .loading
        let profile = selectedProfile
        do {
            toolListState = .loaded(try await pluginProvider.installedTools(profile: profile))
        } catch {
            toolListState = .failed(error.localizedDescription)
        }
    }

    func setTool(_ tool: HermesInstalledTool, enabled: Bool) async {
        let profile = selectedProfile
        do {
            try await pluginProvider.setTool(tool.name, enabled: enabled, profile: profile)
            toolListState = .loaded(try await pluginProvider.installedTools(profile: profile))
        } catch {
            toolListState = .failed(error.localizedDescription)
        }
    }

    func loadInstalledSkills() async {
        skillListState = .loading
        let profile = selectedProfile
        do {
            skillListState = .loaded(try await skillProvider.installedSkills(profile: profile))
        } catch {
            skillListState = .failed(error.localizedDescription)
        }
    }

    func setSkill(_ skill: HermesInstalledSkill, enabled: Bool) async {
        let profile = selectedProfile
        do {
            try await skillProvider.setSkill(skill.name, enabled: enabled, profile: profile)
            skillListState = .loaded(try await skillProvider.installedSkills(profile: profile))
        } catch {
            skillListState = .failed(error.localizedDescription)
        }
    }

    func loadJobs(for profile: HermesProfile) async {
        jobListState = .loading
        do {
            jobListState = .loaded(try await jobProvider.jobs(for: profile))
        } catch {
            jobListState = .failed(error.localizedDescription)
        }
    }

    /// Picks the profile to show in the Jobs panel: the preferred one if it has
    /// jobs, otherwise the first profile (default-first) that does. Falls back to
    /// the preferred profile when none have jobs.
    func profileWithJobs(preferring preferred: HermesProfile?) async -> HermesProfile {
        var ordered: [HermesProfile] = []
        if let preferred { ordered.append(preferred) }
        if let defaultProfile = availableProfiles.first(where: { $0.id == HermesProfile.defaultProfile.id }),
           !ordered.contains(where: { $0.id == defaultProfile.id }) {
            ordered.append(defaultProfile)
        }
        for profile in availableProfiles where !ordered.contains(where: { $0.id == profile.id }) {
            ordered.append(profile)
        }
        for profile in ordered {
            if let jobs = try? await jobProvider.jobs(for: profile), !jobs.isEmpty {
                return profile
            }
        }
        return preferred ?? availableProfiles.first ?? selectedProfile
    }

    @discardableResult
    func performJobAction(_ action: HermesJobAction, jobID: String, for profile: HermesProfile) async -> String? {
        do {
            try await jobProvider.performJobAction(action, jobID: jobID, profile: profile)
            await reloadJobsPreservingList(for: profile)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reloads jobs without flipping to `.loading` first, so the panel's rows
    /// (and their transient state like toasts) survive an in-place refresh.
    private func reloadJobsPreservingList(for profile: HermesProfile) async {
        if let jobs = try? await jobProvider.jobs(for: profile) {
            jobListState = .loaded(jobs)
        }
    }

    /// Returns nil on success, or an error message to surface inline.
    @discardableResult
    func updateJob(_ edit: HermesJobEdit, for profile: HermesProfile) async -> String? {
        do {
            try await jobProvider.updateJob(edit, profile: profile)
            await reloadJobsPreservingList(for: profile)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func loadKanbanTasks(silent: Bool = false) async {
        // Silent (polling) refreshes keep the current data on screen — no
        // spinner, and a transient failure doesn't clobber a loaded board.
        if !silent { kanbanListState = .loading }
        do {
            kanbanListState = .loaded(try await kanbanProvider.tasks())
        } catch {
            if !silent { kanbanListState = .failed(error.localizedDescription) }
        }
    }

    /// Refreshes whether the hermes backend CLI is installed.
    func refreshHermesInstalled() {
        hermesInstalled = HermesRuntimeInfoService.isInstalled
    }

    /// Loads the most recent sessions for the selected profile into the sidebar
    /// History, independent of any in-app threads.
    func loadHistorySessions(limit: Int = 10) async {
        let profile = selectedProfile
        do {
            let page = try await sessionProvider.sessions(
                page: SessionPageRequest(limit: limit, offset: 0),
                profile: profile
            )
            guard profile.id == selectedProfile.id else { return }
            historySessions = Array(page.prefix(limit))
        } catch {
            if error is CancellationError { return }
            historySessions = []
        }
    }

    func loadSessions() async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration

        sessionListState = .loading
        canLoadMoreSessions = false
        isLoadingMoreSessions = false
        let profile = selectedProfile
        do {
            let page = try await sessionProvider.sessions(page: SessionPageRequest(limit: sessionPageSize, offset: 0, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery), profile: profile)
            guard generation == sessionLoadGeneration else { return }
            sessionListState = .loaded(page)
            canLoadMoreSessions = page.count == sessionPageSize
        } catch {
            guard generation == sessionLoadGeneration else { return }
            if error is CancellationError { return }
            sessionListState = .failed(error.localizedDescription)
        }
    }

    func loadMoreSessions() async {
        guard !isLoadingMoreSessions, canLoadMoreSessions else { return }
        let currentSessions = sessionListState.sessions
        guard !currentSessions.isEmpty else { return }

        let generation = sessionLoadGeneration
        isLoadingMoreSessions = true
        let profile = selectedProfile
        do {
            let page = try await sessionProvider.sessions(
                page: SessionPageRequest(limit: sessionPageSize, offset: currentSessions.count, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery),
                profile: profile
            )
            guard generation == sessionLoadGeneration else {
                isLoadingMoreSessions = false
                return
            }
            sessionListState = .loaded(currentSessions + page)
            canLoadMoreSessions = page.count == sessionPageSize
        } catch {
            guard generation == sessionLoadGeneration else {
                isLoadingMoreSessions = false
                return
            }
            if error is CancellationError {
                isLoadingMoreSessions = false
                return
            }
            sessionListState = .failed(error.localizedDescription)
        }
        isLoadingMoreSessions = false
    }

    func deleteSession(id: String) async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration

        let profile = selectedProfile
        do {
            try await sessionProvider.deleteSession(id: id, profile: profile)

            // Sidebar History is a separate list from the session list, so drop
            // the deleted session there too instead of waiting for a reload.
            historySessions.removeAll { $0.id == id }

            guard generation == sessionLoadGeneration else { return }

            let currentCount = sessionListState.sessions.count
            if currentCount > 0 {
                let limit = max(sessionPageSize, currentCount)
                let page = try await sessionProvider.sessions(page: SessionPageRequest(limit: limit, offset: 0, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery), profile: profile)
                guard generation == sessionLoadGeneration else { return }
                sessionListState = .loaded(page)
                canLoadMoreSessions = page.count == limit
            } else {
                let page = try await sessionProvider.sessions(page: SessionPageRequest(limit: sessionPageSize, offset: 0, query: sessionSearchQuery.isEmpty ? nil : sessionSearchQuery), profile: profile)
                guard generation == sessionLoadGeneration else { return }
                sessionListState = .loaded(page)
                canLoadMoreSessions = page.count == sessionPageSize
            }
        } catch {
            guard generation == sessionLoadGeneration else { return }
            if error is CancellationError { return }
            sessionListState = .failed(error.localizedDescription)
        }
    }

    func loadSessionIntoChat(id: String) async {
        let profile = selectedProfile
        do {
            var thread = try await sessionProvider.sessionThread(id: id, profile: profile)
            thread.profile = profile
            threads.insert(thread, at: 0)
            selectedThreadID = thread.id
            selectedProfile = profile
        } catch {
            sessionListState = .failed(error.localizedDescription)
        }
    }

    func attach(urls: [URL]) {
        let attachments = urls.map { url in
            Attachment(name: url.lastPathComponent, url: url, contentType: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier)
        }
        pendingAttachments.append(contentsOf: attachments)
    }

    func addAttachments(_ attachments: [Attachment], to threadID: UUID? = nil) {
        if let threadID {
            agentPendingAttachments[threadID, default: []].append(contentsOf: attachments)
        } else {
            pendingAttachments.append(contentsOf: attachments)
        }
    }

    func attach(urls: [URL], toAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        let attachments = urls.map { url in
            Attachment(name: url.lastPathComponent, url: url, contentType: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier)
        }
        agentPendingAttachments[threadID, default: []].append(contentsOf: attachments)
    }

    func removeAttachment(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func removeAttachment(_ attachment: Attachment, fromAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        agentPendingAttachments[threadID]?.removeAll { $0.id == attachment.id }
    }

    func filteredThreads(query: String) -> [ChatThread] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return threads }
        return threads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(trimmed)
                || thread.messages.contains { $0.content.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func historyThreads(query: String) -> [ChatThread] {
        let historyThreads = threads.filter { historyThreadIDs.contains($0.id) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return historyThreads }
        return historyThreads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(trimmed)
                || thread.messages.contains { $0.content.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // `@codex` / `@claude` / `@gemini` and `@<hermes-profile>` forward the
        // prompt to that agent and echo its reply back into the current thread.
        if hasMentionRoute(text) {
            if selectedThread == nil {
                createThread(title: title(for: text))
            }
            guard let sourceThreadID = selectedThreadID else { return }
            let routeResult = await routePromptIfAllowed(
                text,
                from: .hermes(profile: selectedProfile),
                sourceThreadID: sourceThreadID,
                notifiesPanel: false
            )
            if routeResult == .routed { return }
        }

        // A leading `/` is a Hermes gateway slash command (e.g. `/help`,
        // `/model`): run it via slash.exec rather than submitting it as a prompt.
        if text.hasPrefix("/") {
            await runSlashCommand(text)
            return
        }

        if selectedThread == nil {
            createThread(title: title(for: text))
        }
        guard let selectedThreadID else { return }

        await send(
            text,
            in: selectedThreadID,
            profile: selectedProfile,
            usesGlobalSendState: true
        )
        await loadHistorySessions()
    }

    /// Slash commands handled by the app's own UI (or not meaningful here), so
    /// they are ignored rather than run through the gateway.
    private static let ignoredSlashCommands: Set<String> = ["help", "model", "history", "redraw"]

    /// Slash commands that mean "start a fresh session"; the app maps these to a
    /// new thread (new conversation id → new gateway session on next prompt)
    /// rather than running them on the current session's gateway.
    private static let newSessionSlashCommands: Set<String> = ["clear", "new", "reset"]

    /// Loads the selected profile's slash commands for the composer popup,
    /// dropping the ignored ones.
    func loadHermesSlashCommands() async {
        guard let all = try? await agentClient.commandsCatalog(for: selectedProfile) else { return }
        hermesSlashCommands = all.filter { !Self.ignoredSlashCommands.contains($0.name.lowercased()) }
    }

    /// Runs a Hermes `/slash` command in the current thread and renders its
    /// text output as an assistant message.
    private func runSlashCommand(_ command: String) async {
        let base = command.dropFirst()
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first
            .map { $0.lowercased() } ?? ""
        if Self.ignoredSlashCommands.contains(base) { return }

        // `/clear`, `/new`, `/reset`: start a fresh conversation in the app.
        if Self.newSessionSlashCommands.contains(base) {
            createThread()
            return
        }

        if selectedThread == nil {
            createThread(title: title(for: command))
        }
        guard let threadID = selectedThreadID else { return }

        append(ChatMessage(role: .user, content: command), to: threadID)
        historyThreadIDs.insert(threadID)
        setSendState(.sending, for: threadID, usesGlobalSendState: true)

        let request = HermesChatRequest(
            conversationID: threadID,
            profile: selectedProfile,
            messages: thread(id: threadID)?.messages ?? [],
            attachments: [],
            backend: .hermes,
            workingDirectory: agentWorkingDirectory(for: threadID),
            resumeSessionID: thread(id: threadID)?.hermesSessionID
        )
        do {
            let output = try await agentClient.slashExec(command, for: request)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            append(
                ChatMessage(role: .assistant, content: output.isEmpty ? "(no output)" : output, completedAt: .now),
                to: threadID
            )
            setSendState(.idle, for: threadID, usesGlobalSendState: true)
        } catch {
            setSendState(.failed(error.localizedDescription), for: threadID, usesGlobalSendState: true)
            append(ChatMessage(role: .system, content: "Slash command failed: \(error.localizedDescription)"), to: threadID)
        }
        await loadHistorySessions()
    }

    @discardableResult
    func send(
        _ rawText: String,
        in threadID: UUID,
        profile: HermesProfile,
        routedSourceProfileName: String? = nil
    ) async -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return await send(
            text,
            in: threadID,
            profile: profile,
            usesGlobalSendState: false,
            routedSourceProfileName: routedSourceProfileName
        )
    }

    @discardableResult
    private func send(
        _ text: String,
        in threadID: UUID,
        profile: HermesProfile,
        usesGlobalSendState: Bool,
        routedSourceProfileName: String? = nil
    ) async -> String? {
        guard thread(id: threadID) != nil else { return nil }
        let attachments = pendingAttachments(for: threadID, usesGlobalSendState: usesGlobalSendState)
        clearPendingAttachments(for: threadID, usesGlobalSendState: usesGlobalSendState)
        clearPermissionRequest(for: threadID, usesGlobalSendState: usesGlobalSendState)
        clearClarificationRequest(for: threadID, usesGlobalSendState: usesGlobalSendState)
        activeTaskThreadID = threadID
        taskSubagents = []
        let userMessage = ChatMessage(
            role: .user,
            content: text,
            attachments: attachments,
            routedSourceProfileName: routedSourceProfileName
        )
        append(userMessage, to: threadID)
        historyThreadIDs.insert(threadID)
        setSendState(.sending, for: threadID, usesGlobalSendState: usesGlobalSendState)

        var assistantMessageID: UUID?
        var finalAssistantText = ""
        defer {
            if let id = assistantMessageID {
                // Freeze any still-running thinking timer on every exit path
                // (normal end, error, cancellation), not just the events that
                // emit output — otherwise a turn that ends on reasoning leaves
                // the timer ticking forever.
                finalizeOpenThinking(messageID: id, in: threadID)
                markCompletedIfNeeded(id: id, in: threadID)
            }
        }

        do {
            let request = HermesChatRequest(
                conversationID: threadID,
                profile: profile,
                messages: thread(id: threadID)?.messages ?? [userMessage],
                attachments: attachments,
                backend: threadBackends[threadID] ?? .hermes,
                workingDirectory: agentWorkingDirectory(for: threadID),
                promptEnvelope: AgentPromptEnvelope(
                    text: text,
                    attachments: attachments,
                    sourceProfileName: routedSourceProfileName
                ),
                resumeSessionID: thread(id: threadID)?.hermesSessionID
            )
            for try await event in agentClient.eventStream(for: request) {
                try Task.checkCancellation()
                switch event {
                case .messageStart:
                    if assistantMessageID == nil {
                        assistantMessageID = appendAssistantDraft(to: threadID)
                    }
                case .messageDelta(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    appendToMessage(id: id, text: text, in: threadID)
                case .messageComplete(_, let text, let status, let usage):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    if !text.isEmpty {
                        replaceMessage(id: id, text: text, in: threadID)
                        finalAssistantText = text
                    }
                    if let usage {
                        updateSessionInfo(
                            HermesSessionInfo(
                                contextLength: usage.contextLength,
                                usedTokens: usage.usedTokens
                            ),
                            for: threadID,
                            usesGlobalSendState: usesGlobalSendState
                        )
                    }
                    if status != "complete" {
                        setSendState(.failed(status), for: threadID, usesGlobalSendState: usesGlobalSendState)
                    }
                    markCompletedIfNeeded(id: id, in: threadID)
                case .error(_, let message):
                    setSendState(.failed(message), for: threadID, usesGlobalSendState: usesGlobalSendState)
                    append(ChatMessage(role: .system, content: message), to: threadID)
                case .toolStart(_, let tool):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    upsertToolEvent(messageID: id, tool, in: threadID)
                case .toolGenerating(_, let tool):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    upsertToolEvent(messageID: id, tool, in: threadID)
                case .toolComplete(_, let tool):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    upsertToolEvent(messageID: id, tool, in: threadID)
                case .clarifyRequest(_, let question, let choices):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    finalizeOpenThinking(messageID: id, in: threadID)
                    let clarification = ClarificationRequest(
                        question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                        choices: choices
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                    appendClarification(messageID: id, clarification, in: threadID)
                    showClarificationRequest(clarification, for: threadID, usesGlobalSendState: usesGlobalSendState)
                    setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)
                case .thinkingDelta(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    appendThinking(messageID: id, text: text, in: threadID)
                case .reasoningDelta(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    appendReasoning(messageID: id, text: text, in: threadID)
                case .reasoningAvailable(_, let text):
                    let id = assistantMessageID ?? appendAssistantDraft(to: threadID)
                    assistantMessageID = id
                    replaceReasoning(messageID: id, text: text, in: threadID)
                case .sessionInfo(_, let info):
                    updateSessionInfo(info, for: threadID, usesGlobalSendState: usesGlobalSendState)
                case .subagentSpawnRequested(_, let progress):
                    upsertSubagent(progress, status: .queued)
                case .subagentStart(_, let progress):
                    upsertSubagent(progress, status: .running)
                case .subagentThinking(_, let progress):
                    upsertSubagent(progress) { subagent in
                        if let text = progress.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            subagent.thinking.append(text)
                        }
                        if subagent.status == .queued {
                            subagent.status = .running
                        }
                    }
                case .subagentTool(_, let progress):
                    upsertSubagent(progress) { subagent in
                        let toolLine = Self.subagentToolLine(progress)
                        if !toolLine.isEmpty {
                            subagent.tools.append(toolLine)
                            subagent.toolCount = max(subagent.toolCount, subagent.tools.count)
                        }
                        if subagent.status == .queued {
                            subagent.status = .running
                        }
                    }
                case .subagentProgress(_, let progress):
                    upsertSubagent(progress) { subagent in
                        if let text = progress.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            subagent.notes.append(text)
                        }
                        if subagent.status == .queued {
                            subagent.status = .running
                        }
                    }
                case .subagentComplete(_, let progress):
                    upsertSubagent(progress, status: progress.status ?? .completed) { subagent in
                        subagent.summary = progress.summary ?? progress.text ?? subagent.summary
                    }
                case .approvalRequest(_, let requestID, let text, let options):
                    // Note: we intentionally do NOT set sendState to .idle here
                    // (unlike .clarifyRequest which does). The turn is still
                    // in-flight while the backend waits for the permission
                    // answer — the Stop button must remain visible.
                    if let id = assistantMessageID {
                        // Stop the thinking timer while the user decides; the
                        // model has paused reasoning to wait for approval.
                        finalizeOpenThinking(messageID: id, in: threadID)
                    }
                    showPermissionRequest(text, options: options, requestID: requestID, for: threadID, usesGlobalSendState: usesGlobalSendState)
                case .gatewayReady, .statusUpdate:
                    break
                }
            }
            // Streaming backends (Claude CLI, Codex ACP) build the reply from
            // deltas and finish with an empty messageComplete, so fall back to
            // the assistant message's accumulated content for the return value.
            if finalAssistantText.isEmpty,
               let id = assistantMessageID,
               let message = thread(id: threadID)?.messages.first(where: { $0.id == id }) {
                finalAssistantText = message.content
            }
            if sendState(for: threadID, usesGlobalSendState: usesGlobalSendState) == .sending {
                setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)
            }
            return finalAssistantText
        } catch is CancellationError {
            setSendState(.idle, for: threadID, usesGlobalSendState: usesGlobalSendState)
            return nil
        } catch {
            setSendState(.failed(error.localizedDescription), for: threadID, usesGlobalSendState: usesGlobalSendState)
            append(ChatMessage(role: .system, content: error.localizedDescription), to: threadID)
            return nil
        }
    }

    private func upsertSubagent(
        _ progress: SubagentProgressEvent,
        status: SubagentStatus? = nil,
        mutate: ((inout SubagentProgress) -> Void)? = nil
    ) {
        let normalizedGoal = progress.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextStatus = status ?? progress.status
        let index = taskSubagents.firstIndex { $0.id == progress.id }
        var subagent = index.map { taskSubagents[$0] } ?? SubagentProgress(
            id: progress.id,
            parentID: progress.parentID,
            taskIndex: progress.taskIndex,
            taskCount: progress.taskCount,
            depth: progress.depth,
            goal: normalizedGoal.isEmpty ? "Subagent \(progress.taskIndex + 1)" : normalizedGoal,
            status: nextStatus ?? .running,
            model: progress.model
        )

        subagent.parentID = progress.parentID ?? subagent.parentID
        subagent.taskIndex = progress.taskIndex
        subagent.taskCount = progress.taskCount
        subagent.depth = progress.depth
        if !normalizedGoal.isEmpty {
            subagent.goal = normalizedGoal
        }
        subagent.status = nextStatus ?? subagent.status
        subagent.model = progress.model ?? subagent.model
        subagent.toolCount = progress.toolCount ?? subagent.toolCount
        subagent.durationSeconds = progress.durationSeconds ?? subagent.durationSeconds
        subagent.inputTokens = progress.inputTokens ?? subagent.inputTokens
        subagent.outputTokens = progress.outputTokens ?? subagent.outputTokens
        subagent.reasoningTokens = progress.reasoningTokens ?? subagent.reasoningTokens
        subagent.apiCalls = progress.apiCalls ?? subagent.apiCalls
        subagent.costUSD = progress.costUSD ?? subagent.costUSD
        if !progress.filesRead.isEmpty {
            subagent.filesRead = progress.filesRead
        }
        if !progress.filesWritten.isEmpty {
            subagent.filesWritten = progress.filesWritten
        }
        if !progress.outputTail.isEmpty {
            subagent.outputTail = progress.outputTail
        }

        mutate?(&subagent)

        if let index {
            taskSubagents[index] = subagent
        } else {
            taskSubagents.append(subagent)
        }
        taskSubagents.sort { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.taskIndex < rhs.taskIndex
        }
    }

    private static func subagentToolLine(_ progress: SubagentProgressEvent) -> String {
        let name = (progress.toolName ?? "tool").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (progress.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return name }
        return "\(name): \(text)"
    }

    @discardableResult
    private func appendAssistantDraft(to threadID: UUID) -> UUID {
        let message = ChatMessage(role: .assistant, content: "")
        append(message, to: threadID)
        return message.id
    }

    private func append(_ message: ChatMessage, to threadID: UUID) {
        mutateThread(id: threadID) { thread in
            // Safety net: any thinking timer left running on an earlier message
            // is frozen now that a new message has arrived, so no segment ever
            // ticks forever even if its turn missed an explicit finalize.
            let now = Date.now
            for index in thread.messages.indices {
                Self.freezeOpenThinking(in: &thread.messages[index], endingAt: thread.messages[index].completedAt ?? now)
            }
            thread.messages.append(message)
            thread.updatedAt = .now
            if thread.title == "New Chat" {
                thread.title = title(for: message.content)
            }
        }
    }

    /// Freezes every still-running thinking segment in `message`, recording its
    /// elapsed time. Idempotent: segments with a duration already set are left
    /// untouched.
    private static func freezeOpenThinking(in message: inout ChatMessage, endingAt end: Date) {
        for index in message.segments.indices {
            guard case .thinking(var segment) = message.segments[index],
                  segment.durationSeconds == nil,
                  let startedAt = segment.startedAt else { continue }
            segment.durationSeconds = max(0, end.timeIntervalSince(startedAt))
            message.segments[index] = .thinking(segment)
        }
    }

    private func appendToMessage(id: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            thread.messages[index].content += text
            thread.updatedAt = .now
        }
    }

    private func replaceMessage(id: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            thread.messages[index].content = text
            thread.updatedAt = .now
        }
    }

    private func markCompletedIfNeeded(id: UUID, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
            if thread.messages[index].completedAt == nil {
                thread.messages[index].completedAt = .now
            }
        }
    }

    private func upsertToolEvent(messageID: UUID, _ event: ToolCallEvent, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            if let segmentIndex = matchingToolSegmentIndex(for: event, in: thread.messages[messageIndex].segments),
               case .tool(var existing) = thread.messages[messageIndex].segments[segmentIndex] {
                existing.merge(with: event)
                thread.messages[messageIndex].segments[segmentIndex] = .tool(existing)
            } else {
                thread.messages[messageIndex].segments.append(.tool(event))
            }
            thread.updatedAt = .now
        }
    }

    private func matchingToolSegmentIndex(for event: ToolCallEvent, in segments: [AssistantSegment]) -> Int? {
        if let toolID = event.toolID {
            return segments.firstIndex {
                if case .tool(let existing) = $0 { existing.toolID == toolID } else { false }
            }
        }
        return segments.lastIndex {
            guard case .tool(let existing) = $0 else { return false }
            return existing.toolID == nil
                && existing.name == event.name
                && existing.state != .complete
        }
    }

    private func appendClarification(messageID: UUID, _ clarification: ClarificationRequest, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[messageIndex].segments.append(.clarify(clarification))
            thread.updatedAt = .now
        }
    }

    private func appendThinking(messageID: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            let segments = thread.messages[messageIndex].segments
            if case .thinking(var segment) = segments.last, segment.durationSeconds == nil {
                segment.text += text
                thread.messages[messageIndex].segments[segments.count - 1] = .thinking(segment)
            } else {
                thread.messages[messageIndex].segments.append(.thinking(ThinkingSegment(text: text, startedAt: .now)))
            }
            thread.updatedAt = .now
        }
    }

    /// Freezes the in-progress thinking segment's duration once reasoning ends
    /// (the model starts emitting output or a tool call). Called before any
    /// non-thinking content is appended to the same message.
    private func finalizeOpenThinking(messageID: UUID, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            Self.freezeOpenThinking(in: &thread.messages[messageIndex], endingAt: .now)
        }
    }

    private func appendReasoning(messageID: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[messageIndex].reasoningText += text
            thread.updatedAt = .now
        }
    }

    private func replaceReasoning(messageID: UUID, text: String, in threadID: UUID) {
        mutateThread(id: threadID) { thread in
            guard let messageIndex = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[messageIndex].reasoningText = text
            thread.updatedAt = .now
        }
    }

    private func pendingAttachments(for threadID: UUID, usesGlobalSendState: Bool) -> [Attachment] {
        if usesGlobalSendState {
            return pendingAttachments
        }
        return agentPendingAttachments[threadID] ?? []
    }

    private func clearPendingAttachments(for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            pendingAttachments = []
        } else {
            agentPendingAttachments[threadID] = []
        }
    }

    private func takePendingAttachmentsForRoute(from sourceThreadID: UUID) -> [Attachment] {
        if let attachments = agentPendingAttachments[sourceThreadID], !attachments.isEmpty {
            agentPendingAttachments[sourceThreadID] = []
            return attachments
        }
        guard sourceThreadID == selectedThreadID else { return [] }
        let attachments = pendingAttachments
        pendingAttachments = []
        return attachments
    }

    private func updateSessionInfo(_ info: HermesSessionInfo, for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            sessionInfo.merge(info)
        } else {
            var current = agentSessionInfos[threadID] ?? HermesSessionInfo()
            current.merge(info)
            agentSessionInfos[threadID] = current
        }
    }

    private func sendState(for threadID: UUID, usesGlobalSendState: Bool) -> ChatSendState {
        if usesGlobalSendState {
            return sendState
        }
        return agentSendStates[threadID] ?? .idle
    }

    private func setSendState(_ state: ChatSendState, for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            sendState = state
        } else {
            agentSendStates[threadID] = state
        }
    }

    func dismissPermissionRequest() {
        cancelPermission(pendingPermissionRequest)
        pendingPermissionRequest = nil
    }

    func dismissPermissionRequest(forAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        cancelPermission(agentPendingPermissionRequests[threadID])
        agentPendingPermissionRequests[threadID] = nil
    }

    func answerPermission(at index: Int) {
        guard pendingPermissionRequest?.isAnswerable == true else { return }
        respondToPermission(pendingPermissionRequest, at: index)
        pendingPermissionRequest = nil
    }

    func answerPermission(at index: Int, forAgentThreadID threadID: UUID?) {
        guard let threadID, agentPendingPermissionRequests[threadID]?.isAnswerable == true else { return }
        respondToPermission(agentPendingPermissionRequests[threadID], at: index)
        agentPendingPermissionRequests[threadID] = nil
    }

    private func respondToPermission(_ request: PermissionRequest?, at index: Int) {
        guard let request, let requestID = request.requestID, request.options.indices.contains(index) else { return }
        let optionID = request.options[index].id
        let client = agentClient
        Task { await client.respondToPermission(requestID: requestID, optionID: optionID) }
    }

    private func cancelPermission(_ request: PermissionRequest?) {
        guard let request, let requestID = request.requestID else {
            return
        }
        let client = agentClient
        Task { await client.respondToPermission(requestID: requestID, optionID: request.cancelOptionID) }
    }

    func dismissClarificationRequest() {
        pendingClarificationRequest = nil
    }

    func dismissClarificationRequest(forAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        agentPendingClarificationRequests[threadID] = nil
    }

#if DEBUG
    func simulatePermissionRequest() {
        guard let selectedThreadID else { return }
        showPermissionRequest("Allow simulated shell command?", options: Self.simulatedOptions, requestID: nil, for: selectedThreadID, usesGlobalSendState: true)
    }

    func simulatePermissionRequest(forAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        showPermissionRequest("Allow simulated shell command?", options: Self.simulatedOptions, requestID: nil, for: threadID, usesGlobalSendState: false)
    }

    private static let simulatedOptions = ["Yes", "No", "Always allow"].map { PermissionOption(id: $0, label: $0) }
#endif

    private func clearPermissionRequest(for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            pendingPermissionRequest = nil
        } else {
            agentPendingPermissionRequests[threadID] = nil
        }
    }

    private func clearClarificationRequest(for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            pendingClarificationRequest = nil
        } else {
            agentPendingClarificationRequests[threadID] = nil
        }
    }

    private func showPermissionRequest(_ text: String, options: [PermissionOption], requestID: String?, for threadID: UUID, usesGlobalSendState: Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOptions = options
            .map { PermissionOption(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.label.isEmpty }
        let fallback = [PermissionOption(id: "yes", label: "Yes"), PermissionOption(id: "no", label: "No")]
        let request = PermissionRequest(
            message: message.isEmpty ? "Permission requested." : message,
            options: normalizedOptions.isEmpty ? fallback : normalizedOptions,
            requestID: requestID
        )
        if usesGlobalSendState {
            pendingPermissionRequest = request
        } else {
            agentPendingPermissionRequests[threadID] = request
        }
    }

    private func showClarificationRequest(_ request: ClarificationRequest, for threadID: UUID, usesGlobalSendState: Bool) {
        let normalizedQuestion = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChoices = request.choices
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let clarification = ClarificationRequest(
            question: normalizedQuestion.isEmpty ? "Hermes needs more information." : normalizedQuestion,
            choices: normalizedChoices
        )
        if usesGlobalSendState {
            pendingClarificationRequest = clarification
        } else {
            agentPendingClarificationRequests[threadID] = clarification
        }
    }

    private func mutateSelectedThread(_ update: (inout ChatThread) -> Void) {
        guard let selectedThreadID, let index = threads.firstIndex(where: { $0.id == selectedThreadID }) else { return }
        update(&threads[index])
    }

    private func mutateThread(id threadID: UUID, _ update: (inout ChatThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        update(&threads[index])
    }

    private func title(for text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(44))
    }
}
