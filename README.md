<p align="center">
  <img src="assets/brand/icon-rounded.png" alt="Codo" width="128" height="128" />
</p>

<h1 align="center">Codo</h1>

<p align="center">把本地脚本和 Claude Code 的运行事件送到 Mac 桌面，集中查看项目与会话记录。</p>

<p align="center">
  <a href="docs/README.en.md">English</a>
</p>

## 这是什么

Codo 是 macOS 菜单栏应用和 Bun CLI 组成的通知工具。脚本通过 Unix socket 发送消息，应用在桌面显示横幅；Claude Code hook 可以把任务完成、工具结果和需要关注的事件送入同一条路径。

原生 Dashboard 按项目和会话整理事件、历史及日志。可选的 AI Guardian 根据近期事件决定是否通知，并生成中文摘要；基础通知不需要模型或 API key。

## 功能

- 从命令行参数或 stdin JSON 发送标题、正文和副标题，使用现成通知模板。
- 用自绘 AppKit 横幅依次显示消息，鼠标悬停可暂停自动关闭，支持手动关闭。
- 接收 Claude Code 的 Stop、SubagentStop、Notification、PostToolUse、PostToolUseFailure、SessionStart 和 SessionEnd 事件。
- 在 SwiftUI Dashboard 查看活跃会话、项目事件、通知历史、Guardian 决策和日志。
- 用 SQLite 保存事件和统计，API key 放在 macOS Keychain；支持登录时启动。
- 在源码运行环境启用 Guardian，通过 Anthropic / OpenAI 兼容接口整理通知，调用失败或 Guardian 不可用时回退到基础通知规则。

当前应用使用自绘横幅，CLI 中的 `sound`、`threadId` 等字段保留在协议中；当前横幅实现不播放提示音，也不按 thread 合并通知。Guardian 只决定发送或抑制通知，不执行终端命令。

## 使用

### 构建与安装

需要 macOS 14+、Swift 工具链、完整 Xcode、Bun，以及可用的 Apple Development 签名身份。先按开发步骤克隆和安装依赖，并把 `scripts/build.sh` 中的签名身份与团队调整为自己的配置，然后运行：

```bash
bash scripts/build.sh
bash scripts/install.sh
open ~/Applications/Codo.app
```

安装脚本将应用复制到 `~/Applications/Codo.app`，将 CLI 和 hook 脚本复制到 `~/.codo/`。当 `/usr/local/bin` 可写时，它会创建 `codo` 命令包装脚本；否则使用 `bun ~/.codo/codo.ts` 代替下面的 `codo`。

```bash
codo "Build complete" "Ready for review"
codo "Build complete" "Checks passed" --template success
codo "Build failed" "See the build log" --template error
codo --template list

echo '{"title":"Build complete","body":"Ready for review"}' | codo
```

| 参数 | 用途 |
| --- | --- |
| `--template <name>` | 选择模板，设置默认副标题及协议声音字段 |
| `--subtitle <text>` | 设置副标题，覆盖模板值 |
| `--thread <id>` | 设置协议的 thread ID |
| `--silent` | 将协议声音字段设为 `none` |
| `--hook <type>` | 将 stdin JSON 作为指定 hook 事件发送 |
| `--help` / `--version` | 查看帮助或版本 |

模板有 `success`、`error`、`warning`、`info`、`progress`、`question`、`deploy`、`review`。CLI 在服务未运行时返回退出码 `2`，参数错误或服务拒绝请求时返回 `1`。

### Claude Code 接入

把以下内容合并进自己的 Claude Code `settings.json`，保留已有 hook。示例只接入任务停止和通知事件：

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ]
  }
}
```

其他支持的事件可使用同一脚本；完整配置见 [Claude Code hook 接入](docs/features/04-claude-hook-integration.md)。hook 脚本会转发事件并记录日志，发送失败时退出 `0`。用 `CODO_DEBUG_HOOKS=1` 查看诊断输出。安装的 CLI/hook 是副本，修改仓库文件后需重新复制或运行安装脚本。

### Guardian 与数据

在 Dashboard 设置模型服务、base URL、模型名称和 API key，再启用 Guardian。调用模型时会发送相关 hook 内容和近期项目上下文；Guardian 当前的提示词要求生成简体中文通知。

当前 `build.sh` 没有将 `guardian/` 和依赖复制到 `.app`，因此安装到 `~/Applications` 的应用通常无法启动 Guardian。需要此功能时，在完成依赖安装和构建后，从仓库中的 bundle 启动，让应用向上找到 `guardian/main.ts`：

```bash
open .build/release/Codo.app
```

基础通知不受此打包缺口影响。Guardian 的启动还需要可发现的 Bun、启用开关和有效 API key。

| 本地路径 | 内容 |
| --- | --- |
| `~/.codo/codo.sock` | CLI 与应用的 Unix socket |
| `~/.codo/codo.db` | Dashboard 事件与统计 |
| `~/.codo/hooks.log` | hook 转发日志 |
| `~/.codo/guardian.log` | Guardian 进程日志 |

## 开发

从仓库根目录开始。Swift package 声明 Swift 5.10；当前单元测试使用 Swift Testing，需要包含该模块的 Xcode 工具链。

```bash
git clone https://github.com/nocoo/codo.git
cd codo
bun install --frozen-lockfile
cd guardian
bun install --frozen-lockfile
cd ..

swift build
bun cli/codo.ts --help
```

`swift build` 编译应用、核心库和测试服务；可显示在桌面的 `.app` 还需要上面的 `build.sh` 打包。SwiftLint 和 Biome 用于静态检查；例如 `swiftlint lint --strict --quiet`，以及在 `cli/`、`guardian/` 分别运行 `bunx biome check --error-on-warnings .`。

```text
Sources/Codo/          菜单栏应用、横幅和原生 Dashboard
Sources/CodoCore/      IPC、消息路由、SQLite 与 Guardian 进程管理
Sources/CodoTestServer/ 隔离测试服务
cli/                  Bun CLI
guardian/             事件分类、上下文与模型调用
hooks/                Claude Code hook 入口
scripts/              构建、安装和测试工具
docs/                 架构、功能记录与英文 README
```

## 测试

从仓库根目录运行：

| 测试层 | 命令 |
| --- | --- |
| Swift 单元测试 | `swift test` |
| CLI 单元与进程测试 | `cd cli && bun test` |
| Guardian 单元测试 | `cd guardian && bun test` |
| Unix socket 集成测试 | `bash scripts/integration-test.sh` |
| 原生 UI 手动检查 | `bash scripts/e2e-test.sh` |

每一行从根目录单独执行。集成测试会构建 `CodoTestServer`，使用临时用户目录和 socket 验证真实 Swift/Bun 通信。Guardian 单元测试模拟模型调用，不需要真实凭据。原生 UI 脚本会重新构建、停止已有 Codo 进程并重启应用，需要在可交互的 Mac 桌面中人工确认横幅、菜单和 Guardian 行为；它不是无人值守的自动化测试。

## 技术栈

![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-007AFF)
![AppKit](https://img.shields.io/badge/AppKit-555555)
![TypeScript](https://img.shields.io/badge/TypeScript-3178C6?logo=typescript&logoColor=white)
![Bun](https://img.shields.io/badge/Bun-14151A?logo=bun&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-003B57?logo=sqlite&logoColor=white)

| 部分 | 实现 |
| --- | --- |
| Mac 应用 | Swift、SwiftUI、AppKit、Swift Package Manager |
| 通信与存储 | Unix domain socket、JSON 行协议、SQLite、Keychain |
| CLI / Guardian | TypeScript、Bun、Anthropic SDK、OpenAI SDK |
| 测试 | Swift Testing、Bun test、本地 IPC 测试服务 |

依赖以 [Package.swift](Package.swift)、[CLI](cli/package.json) 和 [Guardian package.json](guardian/package.json) 为准。

## 文档

- [文档索引](docs/README.md)
- [系统设计](docs/architecture/01-system-design.md)
- [IPC 协议](docs/architecture/02-ipc-protocol.md)
- [通知模板](docs/features/01-notification-templates.md)
- [Guardian 设计](docs/features/03-ai-guardian-detail.md)
- [Dashboard](docs/features/05-dashboard.md)
- [日志统一记录](docs/features/08-dashboard-log-unification.md)
- [变更记录](CHANGELOG.md)

部分设计文档和手动检查项来自早期系统通知实现；当前应用入口使用上述自绘横幅。

## 许可证

[MIT](LICENSE) © 2026 Zheng Li
