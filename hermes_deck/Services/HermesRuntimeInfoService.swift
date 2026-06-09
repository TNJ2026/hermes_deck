import Foundation

/// Basic info about the installed hermes backend CLI, shown in Settings.
struct HermesRuntimeInfo: Equatable, Sendable {
    var version: String
    var executablePath: String
}

/// Reads the hermes backend CLI version by invoking `hermes --version`. The CLI
/// lives in the hermes-agent virtualenv created during backend setup.
enum HermesRuntimeInfoService {
    private static var hermesExecutableURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes")
    }

    /// Whether the hermes backend CLI is installed (cheap synchronous check).
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: hermesExecutableURL.path)
    }

    /// Loads runtime info off the main thread. Returns `nil` when the CLI is
    /// missing or the invocation fails.
    static func load() async -> HermesRuntimeInfo? {
        let executableURL = hermesExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runVersion(executableURL: executableURL))
            }
        }
    }

    private static func runVersion(executableURL: URL) -> HermesRuntimeInfo? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]

        // The CLI is a venv console script; point PATH/VIRTUAL_ENV at its venv so
        // its shebang interpreter and dependencies resolve.
        let binDir = executableURL.deletingLastPathComponent()
        let venvURL = binDir.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["VIRTUAL_ENV"] = venvURL.path
        let existingPath = environment["PATH"] ?? ""
        let fallbackPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        environment["PATH"] = binDir.path + ":" + (existingPath.isEmpty ? fallbackPath : existingPath)
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return HermesRuntimeInfo(version: parseVersion(from: raw), executablePath: executableURL.path)
    }

    /// Extracts a version token from the CLI banner, e.g. the first line
    /// "Hermes Agent v0.16.0 (2026.6.5) · upstream f8adefde" yields "v0.16.0".
    /// Falls back to the first line when no semver-like token is found.
    static func parseVersion(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = trimmed.split(separator: "\n").first.map(String.init),
              !firstLine.isEmpty else { return "unknown" }
        if let range = firstLine.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return String(firstLine[range])
        }
        return firstLine
    }
}
