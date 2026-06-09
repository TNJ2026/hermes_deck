<p align="center">
  <img src="assets/icon.png" width="128" alt="Hermes Deck icon">
</p>

<h1 align="center">Hermes Deck</h1>

<p align="center">🇨🇳 <a href="README.zh-CN.md">中文文档 / Chinese</a></p>

A native macOS client for the **Hermes** agent backend. Hermes Deck gives the local Hermes agent — and a set of external coding agents — a fast, chat-first SwiftUI interface, with session history, productivity panels, voice input, and per-profile configuration.

<!-- Built with SwiftUI + Swift Observation, talking to the Hermes backend over a JSON-RPC TUI gateway. -->

<p align="center">
  <img src="assets/screenshot.png" width="820" alt="Hermes Deck main window">
</p>

## Features

- **Multi-agent chat** — Talk to the Hermes agent, or route a message to an external agent inline:
  - `Hermes` — the local agent backend, over a JSON-RPC TUI gateway (stdio)
  - `@codex` — [Codex](https://github.com/zed-industries/codex-acp) over the Agent Client Protocol (ACP)
  - `@claude` — Claude via the Claude CLI
  - `@gemini` — `agy` in single-shot print mode
- **Profiles** — Switch between Hermes profiles (default / coding / research / custom); the picker is hidden when only one profile exists and locked while a reply is streaming.
- **Sessions & history** — Browse past Hermes sessions (read from the backend SQLite database) and reopen them in chat; clickable rows in the sidebar History.
- **Productivity panels** (right sidebar) — Kanban board, scheduled Jobs (cron), per-agent panels for Codex / Claude / Gemini, plus a Settings panel.
- **Tools & Skills** — View and toggle installed Hermes tools and skills.
- **Voice input** — Dictation via `SFSpeechRecognizer`, with a selectable recognition language (Settings → Dictation Language).
- **Settings** — App theme (System / Light / Dark, follows the OS by default), dictation language, and the installed Hermes backend version.
- **Graceful degradation** — Clear placeholder when the Hermes backend isn't installed; friendly errors when a command (hermes / sqlite3 / node / an ACP adapter) is missing, instead of raw POSIX failures; bounded ACP handshake so a stuck adapter can't hang the UI.

## Requirements

- **macOS 14.0 (Sonoma) or later** — the deployment target. (Built with the macOS 27 SDK / a recent Xcode.)
- **Hermes agent backend** installed at `~/.hermes/hermes-agent` (provides the `hermes` CLI, a Python virtualenv, and the SQLite databases).
- `sqlite3` available at `/usr/bin/sqlite3`.
- For external agents: Node/`npx` (Codex ACP), the Claude CLI (`@claude`), and `agy` (`@gemini`) on `PATH` as needed.

## Build & Run

**Xcode**

1. Open `hermes_deck.xcodeproj`.
2. Select the `hermes_deck` scheme.
3. Run (⌘R). The **Yams** Swift Package dependency resolves automatically.

**Command line**

```bash
xcodebuild build \
  -project hermes_deck.xcodeproj \
  -scheme hermes_deck \
  -destination 'platform=macOS'
```

## Testing

129 unit tests (Swift Testing). The suite mixes behavioral tests with source-introspection checks.

```bash
xcodebuild test \
  -project hermes_deck.xcodeproj \
  -scheme hermes_deck \
  -destination 'platform=macOS' \
  -only-testing:hermes_deckTests
```

## Packaging a `.dmg` (no Apple Developer account)

An Apple Developer account is only needed to **notarize** for distribution — you can still build, ad-hoc sign, and package a `.dmg` for local use.

```bash
# 1. Release build, ad-hoc signed ("Sign to Run Locally")
xcodebuild build \
  -project hermes_deck.xcodeproj -scheme hermes_deck -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""

# 2. Styled dmg (brew install create-dmg)
create-dmg \
  --volname "Hermes Deck" --window-size 600 400 --icon-size 120 \
  --icon "Hermes Deck.app" 150 190 --app-drop-link 450 190 --no-internet-enable \
  "Hermes Deck.dmg" "build/Build/Products/Release/Hermes Deck.app"
```

On another Mac the app is unsigned by Apple, so Gatekeeper blocks the first launch — right-click → **Open**, or:

```bash
xattr -dr com.apple.quarantine "/Applications/Hermes Deck.app"
```

## Architecture

- **UI** — SwiftUI with Swift `Observation`. `ChatStore` (`@MainActor @Observable`) is the single source of truth.
- **Service layer** — Protocol-per-capability (`HermesSessionProvider`, `HermesProfileProvider`, `HermesGatewayProvider`, tools/skills/jobs/kanban/models …) with `Local*Provider` implementations backed by actors and `Process`.
- **Agent clients** — `HermesTUIGatewayClient` (JSON-RPC over the gateway's stdio), `ACPAgentClient` + `ACPConnection` (Agent Client Protocol for Codex), `ClaudeCLIClient`, `AgyClient`, all multiplexed by `RoutingAgentClient`.
- **Config** — YAML parsed with [Yams](https://github.com/jpsim/Yams); Hermes config under `~/.hermes`.

## License

Released under the [MIT License](LICENSE) © 2026 Hermes Deck.
