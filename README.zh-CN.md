<p align="center">
  <img src="assets/icon.png" width="128" alt="Hermes Deck icon">
</p>

<h1 align="center">Hermes Deck</h1>

<p align="center">🇬🇧 <a href="README.md">English / 英文文档</a></p>

**Hermes** agent 后端的原生 macOS 客户端。Hermes Deck 为本地 Hermes agent 以及一组外部编码 agent 提供以聊天为核心的 SwiftUI 界面,带会话历史、效率面板、语音输入和按 profile 的配置。

<p align="center">
  <img src="assets/screenshot.png" width="820" alt="Hermes Deck 主界面">
</p>

## 功能

- **多 agent 聊天** —— 与 Hermes agent 对话,或用 `@mention` 在消息中内联路由到另一个 agent(带输入联想补全):
  - `Hermes` —— 本地 agent 后端,经 JSON-RPC TUI gateway(stdio)
  - `@codex` —— 经 Agent Client Protocol(ACP)的 [Codex](https://github.com/zed-industries/codex-acp)
  - `@claude` —— 经 Claude CLI 的 Claude
  - `@gemini` —— 单次 print 模式的 `agy`
  - `@<profile>` / `@default` —— 任意 Hermes profile,或主 Hermes agent
- **Agent 间委派** —— agent 可调用内置的 Hermes tool `deck_delegate_agent` 把任务的一部分交给另一个 agent,也可回退到 ` ```AgentRouting ` 块(`@<target> <prompt>`)。Deck 负责转发、把回复回传,并在触发消息下方显示实时状态卡片(等待 → 已回复,可展开)。每个会话自动种入文本块约定与当前可用目标列表,格式写错的块还有一次自动纠错机会。
- **Profile** —— 在 Hermes profile 间切换(default / coding / research / 自定义);只有一个 profile 时隐藏选择器,回复流式输出期间锁定。会话进行中切换 profile 会另起新会话,不会把两个 gateway 的对话混在一起。
- **会话与历史** —— 浏览过往 Hermes 会话(读取后端 SQLite 数据库)并重新打开;侧边栏 History 整行可点击。
- **效率面板**(右侧栏)—— 看板(Kanban)、定时任务(cron Jobs)、Codex / Claude / Gemini 各自的 agent 面板,以及设置面板。
- **工具与技能** —— 查看并开关已安装的 Hermes tools 和 skills。
- **语音输入** —— 经 `SFSpeechRecognizer` 听写,识别语言可选(设置 → Dictation Language)。
- **设置** —— App 主题(System / Light / Dark,默认跟随系统)、语音识别语言、已安装的 Hermes 后端版本。
- **顺滑的流式阅读** —— 流式回复期间向上滚动会暂停自动跟随;停止滚动 2 秒后恢复(跳回底部),或一旦滚回底部立即恢复。已完成的消息不会随每个 token 重渲染,长回复即使开着侧边面板也保持流畅。
- **生命周期** —— 关闭窗口时 App(及预热的各 profile gateway)保留在 Dock;⌘Q 才真正退出,并清理拉起的子进程(gateway + ACP adapter 进程树)。
- **优雅降级** —— 后端未安装时主区显示明确提示;命令(hermes / sqlite3 / node / ACP adapter)缺失时给友好错误而非裸 POSIX 报错;ACP 握手有超时,卡死的 adapter 不会让界面无限转圈。

## 环境要求

- **macOS 14.0 (Sonoma) 或更高** —— 部署目标。(使用 macOS 27 SDK / 较新 Xcode 构建。)
- 安装在 `~/.hermes/hermes-agent` 的 **Hermes agent 后端**(提供 `hermes` CLI、Python 虚拟环境、SQLite 数据库)。
- `/usr/bin/sqlite3` 可用。
- 外部 agent 按需:Node/`npx`(Codex ACP)、Claude CLI(`@claude`)、`agy`(`@gemini`)在 `PATH` 上。

## Agent 委派

Hermes Deck 支持两种委派路径。优先使用 tool;tool 不可用时回退到文本块。

**优先方式:`deck_delegate_agent` tool**

要使用 `deck_delegate_agent` 功能，必须先在左侧 Menu 列表的 **Tools** 页面中安装 `deck_delegate_agent` 并确认安装成功。安装成功之后，需要重启 Hermes Deck 应用才能生效使用。Tools更新之后也需要重启App才能使用。

在使用之前，最好跟Agent对话让它熟悉下怎么使用 `deck_delegate_agent`  tool和AgentRouting 文本块怎么使用。

![Tools Installation](assets/tools_install.png)


tool 参数:

- `target` —— Deck 目标别名,不带 `@`,例如 `coding`、`researcher`、`codex`、`claude`、`gemini`,或其它 Hermes profile。
- `prompt` —— 发给目标 agent 的自包含 prompt。
- `wait` —— 可选布尔值。当前 Deck handoff 是异步排队;除非未来 tool 版本明确支持同步等待,一般不要设置。
- `dry_run` —— 可选布尔值,用于安装测试。它只校验参数并返回请求,不会调用 Deck IPC。

tool 参数示例:

```json
{
  "target": "coding",
  "prompt": "检查 parser 改动并报告潜在回归。",
  "dry_run": false
}
```

该 tool 只能在 Deck 桌面 App 启动的 Hermes gateway/session 中工作。它通过 `HERMES_DECK_ROUTE_HOST`、`HERMES_DECK_ROUTE_PORT` 和 `HERMES_DECK_ROUTE_TOKEN` 回调 Deck。如果这些环境变量缺失,通常说明 gateway 是在 Deck 外部启动的,或安装/更新 tool 后还没有重启 gateway。

调用成功后,Deck 会在源 thread 中插入可见的 `AgentRouting` 块,执行路由,显示委派状态卡片,并把目标 agent 的回复回传给源 agent。

**回退方式:`AgentRouting` 文本块**

如果 tool 缺失、不可用,或返回 IPC/环境错误,agent 可以只输出下面这个块来委派:

```AgentRouting
@coding
检查 parser 改动并报告潜在回归。
```

规则:

- 每个块只写一个目标。
- 目标写在第一行,后续行写 prompt。
- prompt 要自包含。
- 不要在外面再包一层代码块。

## 构建与运行

**Xcode**

1. 打开 `hermes_deck.xcodeproj`。
2. 选择 `hermes_deck` scheme。
3. 运行(⌘R)。**Yams** Swift Package 依赖自动解析。

**命令行**

```bash
xcodebuild build \
  -project hermes_deck.xcodeproj \
  -scheme hermes_deck \
  -destination 'platform=macOS'
```

## 测试

157 个单元测试(Swift Testing),混合行为测试与源码内省检查。(占位的 UI 测试 target 已跳过。)

```bash
xcodebuild test \
  -project hermes_deck.xcodeproj \
  -scheme hermes_deck \
  -destination 'platform=macOS' \
  -only-testing:hermes_deckTests
```

## 架构

- **UI** —— SwiftUI + Swift `Observation`。`ChatStore`(`@MainActor @Observable`)是唯一数据源。
- **服务层** —— 每个能力一个协议(`HermesSessionProvider`、`HermesProfileProvider`、`HermesGatewayProvider`,以及 tools/skills/jobs/kanban/models …),由 actor + `Process` 支撑的 `Local*Provider` 实现。
- **Agent 客户端** —— `HermesTUIGatewayClient`(经 gateway stdio 的 JSON-RPC)、`ACPAgentClient` + `ACPConnection`(Codex 的 Agent Client Protocol)、`ClaudeCLIClient`、`AgyClient`,由 `RoutingAgentClient` 统一多路复用。
- **路由** —— `@mention` 解析与 `AgentRouting` 块语法在 `AgentMentionRouteParser`;`ChatStore+Routing` 驱动 fan-out、状态卡片与自动纠错;会话通过 `AgentRoutingPrimer` 种入约定。完整设计见 [docs/AgentRoutingPrimer.zh-CN.md](docs/AgentRoutingPrimer.zh-CN.md)。
- **配置** —— 用 [Yams](https://github.com/jpsim/Yams) 解析 YAML;Hermes 配置位于 `~/.hermes`。

## 许可

基于 [MIT License](LICENSE) 发布 © 2026 Hermes Deck。
