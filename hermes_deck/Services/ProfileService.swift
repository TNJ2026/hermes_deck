import Foundation
import Yams

actor LocalHermesProfileProvider: HermesProfileProvider {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]

    init(
        executableURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/hermes-agent/venv/bin/python"),
        arguments: [String] = LocalHermesProfileProvider.defaultArguments(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        var environment = environment
        environment["HERMES_HOME"] = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes")
            .path(percentEncoded: false)
        self.environment = environment
    }

    func profiles() async throws -> [HermesProfile] {
        let executableURL = executableURL
        let arguments = arguments
        let environment = environment

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment

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
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "Failed to load Hermes profiles.")
            }

            return try HermesProfileListParser.parse(outputData)
        }.value
    }

    private nonisolated static func defaultArguments() -> [String] {
        [
            "-c",
            """
            import json
            from hermes_cli.profiles import list_profiles
            print(json.dumps([{"id": p.name, "display_name": p.name} for p in list_profiles()]))
            """,
        ]
    }
}

enum HermesProfileListParser {
    static func parse(_ data: Data) throws -> [HermesProfile] {
        let rows = try JSONDecoder().decode([HermesProfileRow].self, from: data)
        return rows.compactMap { row in
            let id = row.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { return nil }
            let displayName = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            // The CLI echoes the raw profile id as display_name; treat that as
            // "no display name" so HermesProfile derives a friendly label
            // (e.g. "default" -> "Hermes agent").
            let isEcho = displayName.isEmpty || displayName.lowercased() == id
            return HermesProfile(id: id, displayName: isEcho ? nil : displayName)
        }
    }
}

private struct HermesProfileRow: Decodable {
    var id: String
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

final class HermesConfigurationFile {
    enum ConfigurationError: LocalizedError {
        case notLoaded
        case invalidRoot
        case emptyPath
        case missingParent([String])

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Hermes configuration has not been loaded."
            case .invalidRoot:
                return "Hermes configuration root must be a mapping."
            case .emptyPath:
                return "Hermes configuration path cannot be empty."
            case .missingParent(let path):
                return "Missing parent path: \(path.joined(separator: "."))"
            }
        }
    }

    var url: URL
    var yaml: String { yamlText }
    private var yamlText = ""
    private var parsedRoot: [String: Any] = [:]

    nonisolated init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml")) {
        self.url = url
    }

    func load() throws {
        yamlText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try refreshParsedRoot()
    }

    func save() throws {
        try refreshParsedRoot()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yamlText.write(to: url, atomically: true, encoding: .utf8)
    }

    func string(at path: [String]) throws -> String? {
        try value(at: path) as? String
    }

    func stringArray(at path: [String]) throws -> [String] {
        guard let values = try value(at: path) as? [Any] else { return [] }
        return values.compactMap { $0 as? String }
    }

    func setString(_ value: String, at path: [String]) throws {
        try ensureLoadedPath(path)
        var lines = splitLines()
        if let match = match(for: path, in: lines) {
            lines[match.index] = replacingScalarValue(in: lines[match.index], with: value)
        } else {
            try append(value: value, at: path, to: &lines)
        }
        yamlText = joined(lines)
        try refreshParsedRoot()
    }

    func setStringArray(_ values: [String], at path: [String]) throws {
        try ensureLoadedPath(path)
        var lines = splitLines()
        if let match = match(for: path, in: lines) {
            let replacement = sequenceLines(values, indent: match.indent, key: path.last!)
            lines.replaceSubrange(match.index..<match.childEndIndex, with: replacement)
        } else {
            try append(sequence: values, at: path, to: &lines)
        }
        yamlText = joined(lines)
        try refreshParsedRoot()
    }

    func removeValue(at path: [String]) throws {
        try ensureLoadedPath(path)
        var lines = splitLines()
        guard let match = match(for: path, in: lines) else { return }
        lines.removeSubrange(match.index..<match.childEndIndex)
        yamlText = joined(lines)
        try refreshParsedRoot()
    }

    private func value(at path: [String]) throws -> Any? {
        try ensureLoadedPath(path)
        var current: Any = parsedRoot
        for key in path {
            guard let mapping = current as? [String: Any] else { return nil }
            guard let next = mapping[key] else { return nil }
            current = next
        }
        return current
    }

    private func ensureLoadedPath(_ path: [String]) throws {
        guard !path.isEmpty else { throw ConfigurationError.emptyPath }
        guard !yamlText.isEmpty || !parsedRoot.isEmpty || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
    }

    private func refreshParsedRoot() throws {
        let trimmed = yamlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parsedRoot = [:]
            return
        }
        let object = try Yams.load(yaml: yamlText) ?? [:]
        guard let root = object as? [String: Any] else {
            throw ConfigurationError.invalidRoot
        }
        parsedRoot = root
    }

    private struct LineMatch {
        var index: Int
        var indent: Int
        var childEndIndex: Int
    }

    private func match(for path: [String], in lines: [String]) -> LineMatch? {
        var searchRange = 0..<lines.count
        var expectedIndent = 0
        var found: LineMatch?

        for key in path {
            guard let match = firstKeyLine(key, indent: expectedIndent, in: searchRange, lines: lines) else {
                return nil
            }
            found = match
            searchRange = (match.index + 1)..<match.childEndIndex
            expectedIndent = match.indent + 2
        }

        return found
    }

    private func firstKeyLine(_ key: String, indent: Int, in range: Range<Int>, lines: [String]) -> LineMatch? {
        for index in range where lineIndent(lines[index]) == indent && keyName(in: lines[index]) == key {
            return LineMatch(index: index, indent: indent, childEndIndex: childEndIndex(after: index, indent: indent, lines: lines))
        }
        return nil
    }

    private func childEndIndex(after index: Int, indent: Int, lines: [String]) -> Int {
        var cursor = index + 1
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                cursor += 1
                continue
            }
            let currentIndent = lineIndent(lines[cursor])
            if currentIndent < indent || (currentIndent == indent && !trimmed.hasPrefix("- ")) {
                break
            }
            cursor += 1
        }
        return cursor
    }

    private func append(value: String, at path: [String], to lines: inout [String]) throws {
        try appendMissing(path: path, leafLines: { indent, key in
            [String(repeating: " ", count: indent) + "\(key): \(yamlScalar(value))"]
        }, to: &lines)
    }

    private func append(sequence values: [String], at path: [String], to lines: inout [String]) throws {
        try appendMissing(path: path, leafLines: { indent, key in
            sequenceLines(values, indent: indent, key: key)
        }, to: &lines)
    }

    private func sequenceLines(_ values: [String], indent: Int, key: String) -> [String] {
        let leading = String(repeating: " ", count: indent)
        guard !values.isEmpty else {
            return [leading + "\(key): []"]
        }
        return [leading + "\(key):"] + values.map { leading + "- \(yamlScalar($0))" }
    }

    private func appendMissing(
        path: [String],
        leafLines: (Int, String) -> [String],
        to lines: inout [String]
    ) throws {
        if path.count == 1 {
            if !lines.isEmpty, lines.last != "" {
                lines.append("")
            }
            lines.append(contentsOf: leafLines(0, path[0]))
            return
        }

        let parentPath = Array(path.dropLast())
        if let parent = match(for: parentPath, in: lines) {
            let insertionIndex = parent.childEndIndex
            let childIndent = parent.indent + 2
            lines.insert(contentsOf: leafLines(childIndent, path.last!), at: insertionIndex)
            return
        }

        if !lines.isEmpty, lines.last != "" {
            lines.append("")
        }
        for (index, key) in parentPath.enumerated() {
            lines.append(String(repeating: " ", count: index * 2) + "\(key):")
        }
        lines.append(contentsOf: leafLines(parentPath.count * 2, path.last!))
    }

    private func replacingScalarValue(in line: String, with value: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let prefix = line[...colon]
        let suffixStart = line.index(after: colon)
        let suffix = String(line[suffixStart...])
        let comment = inlineComment(in: suffix)
        return "\(prefix) \(yamlScalar(value))\(comment)"
    }

    private func inlineComment(in suffix: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var previous: Character?

        for (index, character) in suffix.enumerated() {
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
            } else if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
            } else if character == "#", !inSingleQuote, !inDoubleQuote, previous?.isWhitespace != false {
                let offset = suffix.index(suffix.startIndex, offsetBy: index)
                return " " + suffix[offset...].trimmingCharacters(in: .whitespaces)
            }
            previous = character
        }
        return ""
    }

    private func keyName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- ") else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private func lineIndent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private func yamlScalar(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./")
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func splitLines() -> [String] {
        yamlText.components(separatedBy: .newlines)
    }

    private func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
