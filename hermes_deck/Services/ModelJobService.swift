import Foundation

struct LocalHermesModelConfigurationProvider: HermesModelConfigurationProvider {
    var configURL: URL
    var environmentURL: URL

    nonisolated init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml"),
        environmentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/.env")
    ) {
        self.configURL = configURL
        self.environmentURL = environmentURL
    }

    func configuredModels() async throws -> [HermesConfiguredModel] {
        let config = HermesConfigurationFile(url: configURL)
        try config.load()
        let environment = (try? String(contentsOf: environmentURL, encoding: .utf8)) ?? ""
        return HermesModelConfigurationParser.parse(config.yaml, environment: environment)
    }
}

struct LocalHermesJobProvider: HermesJobProvider {
    var hermesRootURL: URL
    var pythonExecutableURL: URL
    var hermesAgentURL: URL
    var baseEnvironment: [String: String]

    nonisolated init(
        hermesRootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
        pythonExecutableURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/venv/bin/python"),
        hermesAgentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent"),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.hermesRootURL = hermesRootURL
        self.pythonExecutableURL = pythonExecutableURL
        self.hermesAgentURL = hermesAgentURL
        self.baseEnvironment = baseEnvironment
    }

    func jobs(for profile: HermesProfile) async throws -> [HermesScheduledJob] {
        let jobsURL = jobsURL(for: profile)

        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: jobsURL.path(percentEncoded: false)) else {
                return []
            }
            let data = try Data(contentsOf: jobsURL)
            return try HermesScheduledJobParser.parse(data)
        }.value
    }

    func performJobAction(_ action: HermesJobAction, jobID: String, profile: HermesProfile) async throws {
        try await runCronjob(.object([
            "action": .string(action.rawValue),
            "job_id": .string(jobID),
        ]), profile: profile)
    }

    func updateJob(_ edit: HermesJobEdit, profile: HermesProfile) async throws {
        var params: [String: TUIJSONValue] = [
            "action": .string("update"),
            "job_id": .string(edit.jobID),
        ]
        if let name = edit.name { params["name"] = .string(name) }
        if let schedule = edit.schedule { params["schedule"] = .string(schedule) }
        if let prompt = edit.prompt { params["prompt"] = .string(prompt) }
        if let deliver = edit.deliver { params["deliver"] = .string(deliver) }
        if let script = edit.script { params["script"] = .string(script) }
        if let skills = edit.skills { params["skills"] = .array(skills.map(TUIJSONValue.string)) }
        try await runCronjob(.object(params), profile: profile)
    }

    /// Invokes the Hermes `cronjob` tool with the given params under the
    /// profile's HERMES_HOME. Params are passed as a single JSON argv value to
    /// avoid any shell/quoting issues.
    private func runCronjob(_ params: TUIJSONValue, profile: HermesProfile) async throws {
        let paramsJSON = String(data: try JSONEncoder().encode(params), encoding: .utf8) ?? "{}"
        let pythonExecutableURL = pythonExecutableURL
        let hermesAgentURL = hermesAgentURL
        var environment = baseEnvironment
        environment["HERMES_HOME"] = hermesHomeURL(for: profile).path(percentEncoded: false)

        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = pythonExecutableURL
            process.currentDirectoryURL = hermesAgentURL
            process.environment = environment
            process.arguments = [
                "-c",
                """
                import json, sys
                from tools.cronjob_tools import cronjob
                print(cronjob(**json.loads(sys.argv[1])))
                """,
                paramsJSON,
            ]

            let output = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = output
            process.standardError = errorPipe

            try process.runTranslatingMissingCommand(named: "Hermes")
            let outputDataTask = Task { output.fileHandleForReading.readDataToEndOfFile() }
            let errorDataTask = Task { errorPipe.fileHandleForReading.readDataToEndOfFile() }
            let outputData = await outputDataTask.value
            let errorData = await errorDataTask.value
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "Hermes cron command failed.")
            }
            // The tool reports success/error in its JSON result.
            if let result = try? JSONDecoder().decode(CronjobResult.self, from: outputData), result.success == false {
                throw HermesAgentError.rpcError(result.error?.isEmpty == false ? result.error! : "Hermes cron command failed.")
            }
        }.value
    }

    private func hermesHomeURL(for profile: HermesProfile) -> URL {
        let profileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if profileID == "default" || profileID.isEmpty {
            return hermesRootURL
        }
        return hermesRootURL.appendingPathComponent("profiles").appendingPathComponent(profileID)
    }

    private func jobsURL(for profile: HermesProfile) -> URL {
        let profileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profileRootURL: URL
        if profileID == "default" || profileID.isEmpty {
            profileRootURL = hermesRootURL
        } else {
            profileRootURL = hermesRootURL
                .appendingPathComponent("profiles")
                .appendingPathComponent(profileID)
        }
        return profileRootURL.appendingPathComponent("cron/jobs.json")
    }
}

enum HermesScheduledJobParser {
    static func parse(_ data: Data) throws -> [HermesScheduledJob] {
        let payload = try JSONDecoder().decode(HermesScheduledJobPayload.self, from: data)
        return payload.jobs.sorted { lhs, rhs in
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

private struct HermesScheduledJobPayload: Decodable {
    var jobs: [HermesScheduledJob]
}

private struct CronjobResult: Decodable {
    var success: Bool?
    var error: String?
}

extension HermesScheduledJob {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case scheduleDisplay = "schedule_display"
        case state
        case enabled
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastStatus = "last_status"
        case lastError = "last_error"
        case deliver
        case skills
        case script
        case profile
        case prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        schedule = try container.decodeIfPresent(String.self, forKey: .scheduleDisplay) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        nextRunAt = try container.decodeIfPresent(String.self, forKey: .nextRunAt)
        lastRunAt = try container.decodeIfPresent(String.self, forKey: .lastRunAt)
        lastStatus = try container.decodeIfPresent(String.self, forKey: .lastStatus)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        deliver = try container.decodeIfPresent(String.self, forKey: .deliver)
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        script = try container.decodeIfPresent(String.self, forKey: .script)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    }
}


enum HermesModelConfigurationParser {
    static func parse(_ config: String, environment: String = "") -> [HermesConfiguredModel] {
        let env = parseEnvironment(environment)
        var models: [HermesConfiguredModel] = []

        if let defaultModel = parseDefaultModel(config, env: env) {
            models.append(defaultModel)
        }
        models.append(contentsOf: parseProviderModels(config, env: env))
        models.append(contentsOf: parseAuxiliaryModels(config, env: env))
        models.append(contentsOf: parseFallbackModels(config, env: env))

        return models
    }

    private static func parseDefaultModel(_ config: String, env: Set<String>) -> HermesConfiguredModel? {
        let fields = fields(in: block(named: "model", in: config))
        guard let provider = fields["provider"], let model = fields["default"] else { return nil }
        return HermesConfiguredModel(
            id: "default",
            category: "Default",
            title: "Default Model",
            provider: provider,
            model: model,
            baseURL: fields["base_url"] ?? "",
            apiKeyStatus: apiKeyStatus(provider: provider, explicitAPIKey: fields["api_key"], envVar: fields["api_key_env_var"], env: env)
        )
    }

    private static func parseProviderModels(_ config: String, env: Set<String>) -> [HermesConfiguredModel] {
        parseNamedSections(in: block(named: "providers", in: config)).compactMap { provider, content in
            let fields = fields(in: content)
            let model = fields["model"] ?? fields["default"] ?? fields["name"] ?? ""
            guard !model.isEmpty || !provider.isEmpty else { return nil }
            return HermesConfiguredModel(
                id: "provider-\(provider)",
                category: "Provider",
                title: provider,
                provider: provider,
                model: model.isEmpty ? "Not specified" : model,
                baseURL: fields["base_url"] ?? "",
                apiKeyStatus: apiKeyStatus(provider: provider, explicitAPIKey: fields["api_key"], envVar: fields["api_key_env_var"], env: env)
            )
        }
    }

    private static func parseAuxiliaryModels(_ config: String, env: Set<String>) -> [HermesConfiguredModel] {
        parseNamedSections(in: block(named: "auxiliary", in: config)).compactMap { name, content in
            let fields = fields(in: content)
            guard let provider = fields["provider"], provider != "auto", let model = fields["model"], !model.isEmpty else { return nil }
            return HermesConfiguredModel(
                id: "auxiliary-\(name)",
                category: "Auxiliary",
                title: name.replacingOccurrences(of: "_", with: " "),
                provider: provider,
                model: model,
                baseURL: fields["base_url"] ?? "",
                apiKeyStatus: apiKeyStatus(provider: provider, explicitAPIKey: fields["api_key"], envVar: fields["api_key_env_var"], env: env)
            )
        }
    }

    private static func parseFallbackModels(_ config: String, env: Set<String>) -> [HermesConfiguredModel] {
        guard let fallbackBlock = block(named: "fallback_providers", in: config), !fallbackBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard !fallbackBlock.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[]") else {
            return []
        }

        var rows: [[String: String]] = []
        var current: [String: String] = [:]
        for rawLine in fallbackBlock.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("- ") {
                if !current.isEmpty { rows.append(current) }
                current = parseInlineListField(String(line.dropFirst(2)))
            } else if let (key, value) = keyValue(line) {
                current[key] = value
            }
        }
        if !current.isEmpty { rows.append(current) }

        return rows.enumerated().compactMap { index, fields in
            guard let provider = fields["provider"], let model = fields["model"] ?? fields["default"] else { return nil }
            return HermesConfiguredModel(
                id: "fallback-\(index)",
                category: "Fallback",
                title: "Fallback \(index + 1)",
                provider: provider,
                model: model,
                baseURL: fields["base_url"] ?? "",
                apiKeyStatus: apiKeyStatus(provider: provider, explicitAPIKey: fields["api_key"], envVar: fields["api_key_env_var"], env: env)
            )
        }
    }

    private static func block(named name: String, in yaml: String) -> String? {
        let lines = yaml.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0 == "\(name):" || $0.hasPrefix("\(name): ") }) else { return nil }
        let parts = lines[start].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let inlineValue = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !inlineValue.isEmpty {
                return inlineValue
            }
        }

        var blockLines: [String] = []
        for line in lines.dropFirst(start + 1) {
            if !line.hasPrefix(" "), !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            blockLines.append(line)
        }
        return blockLines.joined(separator: "\n")
    }

    private static func parseNamedSections(in block: String?) -> [(String, String)] {
        guard let block else { return [] }
        let lines = block.components(separatedBy: .newlines)
        var sections: [(String, [String])] = []
        var currentName: String?
        var currentLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indentation = line.prefix { $0 == " " }.count
            if indentation == 2, trimmed.hasSuffix(":") {
                if let currentName {
                    sections.append((currentName, currentLines))
                }
                currentName = String(trimmed.dropLast())
                currentLines = []
            } else if currentName != nil {
                currentLines.append(String(line.dropFirst(min(indentation, 4))))
            }
        }

        if let currentName {
            sections.append((currentName, currentLines))
        }
        return sections.map { ($0.0, $0.1.joined(separator: "\n")) }
    }

    private static func fields(in block: String?) -> [String: String] {
        guard let block else { return [:] }
        return block.components(separatedBy: .newlines).reduce(into: [:]) { result, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let (key, value) = keyValue(trimmed) {
                result[key] = value
            }
        }
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = cleanedValue(String(parts[1]))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func parseInlineListField(_ text: String) -> [String: String] {
        guard let (key, value) = keyValue(text) else { return [:] }
        return [key: value]
    }

    private static func cleanedValue(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "''" || trimmed == "\"\"" { return "" }
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        } else if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func parseEnvironment(_ environment: String) -> Set<String> {
        Set(environment.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let (key, value) = environmentKeyValue(trimmed), !value.isEmpty else { return nil }
            return key
        })
    }

    private static func environmentKeyValue(_ line: String) -> (String, String)? {
        let separator = line.contains("=") ? "=" : ":"
        let parts = line.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = cleanedValue(String(parts[1]))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func apiKeyStatus(provider: String, explicitAPIKey: String?, envVar: String?, env: Set<String>) -> String {
        if let explicitAPIKey, !explicitAPIKey.isEmpty {
            return "Configured"
        }
        if let envVar, !envVar.isEmpty {
            return env.contains(envVar) ? "Configured via \(envVar)" : "Missing \(envVar)"
        }
        let inferred = inferredAPIKeyEnvironmentVariable(for: provider)
        if env.contains(inferred) {
            return "Configured via \(inferred)"
        }
        if provider == "ollama" || provider == "local" {
            return "No key required"
        }
        return "Not configured"
    }

    private static func inferredAPIKeyEnvironmentVariable(for provider: String) -> String {
        switch provider.lowercased() {
        case "deepseek": "DEEPSEEK_API_KEY"
        case "google", "gemini": "GEMINI_API_KEY"
        case "openrouter": "OPENROUTER_API_KEY"
        case "openai": "OPENAI_API_KEY"
        case "minimax-cn": "MINIMAX_CN_API_KEY"
        case "minimax": "MINIMAX_API_KEY"
        default: "\(provider.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        }
    }
}
