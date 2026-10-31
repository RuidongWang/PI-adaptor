# PI-IOS

> **手机是遥控器，服务器是工作台。**

PI-IOS 是一个 iOS 原生客户端，用来**遥控**运行在自有 Linux 服务器上的 `pi-host` Agent Host。

模型请求、工具执行、文件读写、密钥存储**全部**发生在服务器侧；手机只负责「看」「批」「发消息」「配置」。
目标机器是一台**空 Linux 服务器**，安装动作由手机发起，不依赖桌面 App 存在。

---

## 1. 项目构成

| 路径 | 内容 |
|---|---|
| `apps/ios/` | SwiftUI 客户端（`PI-IOS`）与 `PIiOSKit` SPM 包（`PIiOSCore` 领域层 / `PIiOSNet` 传输层 / 两个测试 target） |
| `apps/host/` | `pi-host` v2：Node 22 + TypeScript Host，基于 `@earendil-works/pi-coding-agent` |
| `server/` | 「模型服务删除」服务端增量交付物：上游补丁、双架构打包与校验脚本、交付说明 |
| `docs/` | 需求（`specs/`）、跨端契约（`api/`）、QA 与证据（`qa/`）、流程规则（`工作流.md`） |
| `scripts/` | 仓库级门禁：密钥/身份扫描、发布坐标一致性校验 |
| `host-release.json` | 发布坐标（版本、tag、上游 pin、各平台摘要）的**唯一权威源** |
| `tmp-e2e/e2e-turn.mjs` | wire 级端到端脚本：配对 → 建会话 → 跑一个真实 turn |

## 2. 架构

```
┌──────────────┐   SSH (密码 / OpenSSH 私钥)    ┌────────────────────────────┐
│  iPhone      │ ──── direct-tcpip 隧道 ──────▶ │ Linux 服务器               │
│  SwiftUI     │                                │  127.0.0.1:19445           │
│  PIiOSKit    │ ◀─── ws:// RACP v1.0 ────────▶ │  pi-host (Node 22)         │
└──────────────┘                                │   ├─ 会话 / 轮次 / 审批     │
                                                │   ├─ 工具执行 / 本地文件    │
     手机不含模型密钥、不发模型请求              │   └─ HTTPS ─▶ 模型 API      │
                                                └────────────────────────────┘
```

- **网络边界 = SSH**：`pi-host` 只绑定 `127.0.0.1`，客户端经 SSH `direct-tcpip` 转发到回环端口，端口不对外暴露。
- **协议 = RACP**：复用上游 PI-Desktop v0.21.0 已冻结的协议，本仓只做客户端子集 + 增量方法。
- **密钥在两端各自隔离**：provider key 存在服务器侧（不进 provider 索引、不出现在 API 响应）；
  客户端若持有同类 key，只存 iOS Keychain。

## 3. 环境要求

| 用途 | 要求 |
|---|---|
| Swift 包与单测 | macOS 14+、Xcode（含 iOS 17 SDK）。**必须设置 `DEVELOPER_DIR` 指向 Xcode**——只装 Command Line Tools 时缺 `XCTest`，构建会失败 |
| iOS App / IPA | 同上 + `zsh`（构建脚本用） |
| `pi-host` | Node **≥ 22.19.0**、`pnpm` |
| 仓库脚本 | Python 3 |
| 端到端联调 | 一台可 SSH 的 Linux 服务器（x86_64 / arm64），且该服务器能访问模型 API |

## 4. 快速开始

### 4.1 领域层 / 传输层单测（不需要模拟器）

```sh
cd apps/ios/PIiOSKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

本轮实测：`PIiOSCoreTests` 375 例 + `PIiOSNetTests` 133 例（跳过 5 例，需真实服务器），**0 失败**。

只跑一侧：`swift test --filter PIiOSCoreTests`（或 `--filter PIiOSNetTests`）。
注意 `swift test` 末行汇总只统计最后一个 bundle，真实总数要看两个 `PIiOS*Tests.xctest` 的 `Executed` 行，原因见 `Package.swift` 顶部注释。

### 4.2 构建未签名 IPA

```sh
apps/ios/scripts/build-unsigned-ipa.sh
```

产物 `apps/ios/build/ipa/PI-IOS.ipa`；bundle id `dev.piios.PI-IOS`，部署目标 iOS 17.0。
`build/` 已被 `.gitignore` 排除，不会入库。

### 4.3 跑 iOS UI 测试

```sh
cd apps/ios
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project PI-IOS.xcodeproj \
  -scheme PI-IOS \
  -destination 'platform=iOS Simulator,name=<你的模拟器>' \
  -only-testing:PI-IOSUITests/ProjectsLaunchUITests
```

`PI-IOSUITests` 下 22 个用例文件、41 个用例，多数需要一台已配对的真实 Host 或环境变量门禁
（例如 `PI_IOS_DEEPSEEK_CHAT=1`、`PI_IOS_EXPECTED_HOST=<主机片段>`），逐条判据见 `docs/qa/`。

### 4.4 本地起一个 Host

```sh
cd apps/host
pnpm install --ignore-scripts
pnpm start -- --pair        # 打印一次性 `ppt2.` 配对令牌
```

自包含：默认全部落在 `~/.pi-host-v2`（`data/` `agent/` `logs/` `run/`），与旧版 PI-Desktop host 零共享状态。

```sh
pnpm start -- --home "$HOME/.pi-host-v2" --port 19445 --pair
```

配置优先级：CLI 参数 → `PI_HOST_V2_*` 环境变量 → `<home>/config.json` → 派生默认值。
示例配置 `apps/host/config.example.json`，systemd user unit 见 `apps/host/deploy/pi-host-v2.service`。

### 4.5 wire 级端到端

需要一个已在跑的 Host（4.4）和它的配对令牌：

```sh
PAIR_TOKEN="ppt2.…" \
DEEPSEEK_KEY="sk-…" \
RACP_URL="ws://127.0.0.1:19445/v1/racp/ws" \
DEEPSEEK_BASE="https://api.deepseek.com" \
DEEPSEEK_MODEL="deepseek-chat" \
node tmp-e2e/e2e-turn.mjs
```

通过判据（`PAIRED` / `hasApiKey=true` / `FINAL_KINDS` 含 `turn.completed` 等）见
`docs/qa/2026-10-31-deepseek-live-test.md`。**真实 key 只在命令行局部变量里传，不要写回仓库**。

## 5. 常用命令与门禁

| 命令 | 作用 | 本轮实测 |
|---|---|---|
| `cd apps/host && pnpm test` | Host 单测（vitest） | 15 个文件 / **63 例通过** |
| `cd apps/host && pnpm typecheck` | `tsc --noEmit` | 通过 |
| `cd apps/host && pnpm build` | 编译到 `dist/` | — |
| `cd apps/ios/PIiOSKit && DEVELOPER_DIR=… swift test` | Swift 包全量单测 | **508 例，0 失败** |
| `bash scripts/check-secrets.sh` | 提交前密钥/身份扫描 | **0 命中** |
| `python3 scripts/check-host-release-consistency.py` | 校验 `host-release.json` ↔ iOS 常量 ↔ 打包脚本 ↔ 产物摘要 | 一致 |
| `server/scripts/assemble-pi-host-bundles.sh` | 用官方双架构包作底座替换 JS，重算摘要并产出 tarball | 见 `server/README.md` §4 |
| `server/scripts/verify-pi-host-bundle.sh` | 在目标架构执行安装器自校验与导入/删除幂等验证 | 同上 |

## 6. 发布坐标（改动版本号前必读）

版本号、发布 tag、上游 commit 与各平台摘要**只在** [`host-release.json`](host-release.json) 定义一次：

1. 改 `host-release.json` 的 `version`；
2. 跑 `UPDATE_RELEASE_MANIFEST=1 server/scripts/assemble-pi-host-bundles.sh` 把新摘要写回；
3. `python3 scripts/check-host-release-consistency.py` 必须通过；
4. 打 tag `v<version>` 并上传资产。

漏任何一步的现象都是「重新安装还是旧版本」——App 会按旧摘要下载旧字节。
iOS 侧 `PiHostRelease` 常量必须与之一致，漂移时 `HostReleaseManifestTests` 直接失败。

## 7. 文档位置

> **本仓库只收代码与脚本，不收文档。** 需求、契约、QA 证据、设计文档与原型都不参与版本控制
> （见 `.gitignore`：`/docs/`、`/AGENTS.md`、`/apps/ios/design/`），只存在于本地工作区。
> 下面这张表是给拿到本仓库的人**在本地自查**用的路径索引，不是可点击的外部链接。

| 想知道什么 | 本地路径 |
|---|---|
| 产品要做什么、85 条验收标准 | `docs/specs/ios-client.md` |
| 跨端约定（RACP 子集、provider-import 载荷、bootstrap 状态机、缓存 schema） | `docs/api/ios-client.md`（FROZEN） |
| 模型服务删除增量契约 | `docs/api/ios-client-provider-remove-draft.md` |
| Host v2 契约 + schema + golden fixture | `docs/api/pi-host-v2.md`、`docs/api/pi-host-v2.schema.json` |
| 每条 AC 当前状态与证据 | `docs/qa/implementation-status.md` |
| 交互与视觉规范、跳转矩阵、缺口清单、HTML 原型 | `apps/ios/design/` |
| 开发流程规则 | `AGENTS.md` → `docs/工作流.md` |
| Host 隔离配置与部署（**已入库**） | [`apps/host/README.md`](apps/host/README.md) |
| 服务端增量交付说明（**已入库**） | [`server/README.md`](server/README.md) |

## 8. 安全约定（提交前请读）

- **明文密钥绝不入库**：`.gitignore` 已挡 `**/*.seed.json`、`.env*`、`*.local.md`；provider seed 文件只写在仓库外。
- **提交前跑** `bash scripts/check-secrets.sh`。它挡四类：`sk-…` 风格 API Key、`ppt2.`/`pdt2.` 令牌、
  PEM 私钥块、`/Users/<name>/` 本机主路径（含隐藏的 `.env`）。
- **证据脱敏规则**：文档与证据里的真实主机地址一律写成 RFC 5737 保留地址
  （`203.0.113.0/24`、`192.0.2.0/24`、`198.51.100.0/24`）；本机绝对路径写 `<仓库根>`；主机密钥指纹写占位符。
  `docs/qa/evidence/*.pcap` 也已就地改写并重算校验和。
- **运行期**：数据目录 `0700`，令牌/密钥文件 `0600`；设备与配对令牌只存 SHA-256；provider key 不出现在 API 响应；
  撤销设备会关闭其全部已建立的 WebSocket。
- **网络**：Host 只监听 loopback，经 SSH 隧道访问，**不要把端口暴露到公网**。

## 9. 当前状态

`docs/qa/implementation-status.md` 汇总了 42 条 AC：**33 条 DONE**、**9 条 EXTERNAL**（客户端已实现，但仍需上游双架构
bundle、真机手工验证或真实服务器证据）。剩余缺口与取舍见该文件与本地 `apps/ios/design/gaps.md`。

## 10. 来源与许可

- 上游基线：PI-Desktop **v0.21.0**（<https://github.com/vastsa/PI-Desktop>，RACP 协议已冻结）。
- `apps/ios/PIiOSKit/Vendor/swift-nio-ssh` 是 vendored fork（**Apache-2.0**，见该目录 `LICENSE.txt` 与 `PATCHES.md`），
  为补齐 RSA 密钥矩阵在上游 0.15.1 上打补丁。
- 本仓库**当前未附 `LICENSE` 文件**；对外分发或开源前请先补齐。
