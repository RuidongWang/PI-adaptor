# 规格：v2 Host 的独立配置与环境隔离（不改动原 host）

- 日期：2026-10-31
- 实现位置：`仓库根`（= PI-adaptor / `pi-adaptor`，契约 `docs/api/pi-adaptor.md`）
- 关系：本文件补充 `docs/specs/pi-adaptor.md` 决策 1「Host 安装到独立用户目录、systemd user unit、原地保留既有 pi/会话」，把它落成**可执行的配置契约**。
- 前提（本任务硬约束）：**原 host（PI-Desktop 的 legacy `pi-host`，配置在 `~/.pi-desktop`）配置完全不变**；依赖它的既有应用行为不受任何影响。

> 术语：**原 host** = PI-Desktop 的 `pi-host`（数据/配置 `~/.pi-desktop/pi-host/*`，默认端口 44271 或随机，`admin.sock` 做 provider-import/remove）。**v2 host** = 本项目 `仓库根`（独立数据根，loopback TCP，RACP v2 协议）。

## 1. 目标

1. v2 host 有**单一独立配置根**，其默认路径不引用原 host 或 pi 共享全局目录。
2. 明确定义配置项、**配置层级与优先级**、每项作用。
3. 新旧 host **完全环境隔离、互不干扰**：目录、端口、socket、锁、env 命名空间、进程/服务、版本目录全部分开。
4. 给出**配置示例**与**接入步骤**。
5. 保证原 host 及其既有客户端（PI-Desktop/renderer、旧 iOS 客户端走 v1 兼容握手）**行为零变化**。

## 2. 配置层级与优先级

四层，高优先级覆盖低优先级：

| 优先级 | 层 | 来源 | 说明 |
|---|---|---|---|
| 1（最高）| CLI flag | 进程参数 | 一次性/调试覆盖 |
| 2 | `PI_ADAPTOR_*` 环境变量 | 进程 env（systemd `Environment=`） | 服务化推荐层，命名空间隔离 |
| 3 | 配置文件 | `<home>/config.json`（或 `--config <path>`） | 可版本化、可读的默认值 |
| 4（最低）| 派生默认 | 由 `<home>` 推导 | 保证自包含 |

`--home` / `PI_ADAPTOR_HOME` 先决定 `<home>`，再读 `<home>/config.json`，其余项按上表逐层解析。

## 3. 配置项清单（新增 / 修改 / 不变）

### 3.1 新增

| 配置项 | 层 | 作用 |
|---|---|---|
| `--home <dir>` / `PI_ADAPTOR_HOME` | CLI / env | **单一独立配置根**，默认 `~/.pi-adaptor`。所有派生默认值都在其下。 |
| `--config <path>` | CLI | 显式指向配置文件；缺省用 `<home>/config.json`。 |
| `<home>/config.json` | 文件 | 默认值层（见 3.1 表下方的键）。 |
| `PI_ADAPTOR_AGENT_DIR` | env | 命名空间化的 agent 目录覆盖（替代泛化的 `PI_AGENT_DIR`）。 |
| `PI_ADAPTOR_SESSION_DIR` | env | 命名空间化的会话目录覆盖（替代泛化的 `PI_SESSION_DIR`）。 |
| `<home>/logs/`、`<home>/run/` | 派生目录 | 日志与运行态（`run/host.pid`）根，独立于原 host。 |

`config.json` 键（全部可选）：`dataDir`、`agentDir`、`sessionDir`、`port`、`pair`、`hostId`、`hostVersion`、`piVersion`。

### 3.2 修改（**仅默认值**，显式配置时行为不变）

| 配置项 | 原默认 | 新默认 | 作用 / 原因 |
|---|---|---|---|
| `dataDir` | `~/.pi-ios-host` | `<home>/data` | 归入独立根；原默认既非命名空间也非规范位置。 |
| `agentDir` | **`~/.pi/agent`** | `<home>/agent` | **关键**：`~/.pi/agent` 是 `pi` CLI / 其它工具共享的全局目录，会造成串扰；改为根内独立目录。 |
| `sessionRoots` | `<agentDir>/sessions` | `<dataDir>/sessions` | 与 host 实际写入会话的目录（`<dataDir>/sessions`）对齐，修正原先「扫描目录 ≠ 写入目录」的不一致。 |
| `logsDir` / `runDir` | 无 | `<home>/logs`、`<home>/run` | 提供独立运维目录。 |

> 修改仅影响「未显式配置」的部署。既有显式部署（例如服务器上 `--data-dir … --agent-dir …`）**完全不变**。

### 3.3 不变（向后兼容）

| 配置项 | 状态 |
|---|---|
| CLI：`--data-dir` / `--agent-dir` / `--session-dir` / `--port` / `--pair` / `--host-id` | 保留，语义不变 |
| env：`PI_ADAPTOR_DATA_DIR` / `PI_ADAPTOR_PORT` / `PI_ADAPTOR_PAIR` / `PI_ADAPTOR_HOST_ID` / `PI_ADAPTOR_VERSION` / `PI_CODING_AGENT_VERSION` / `PI_ADAPTOR_DETERMINISTIC` | 保留 |
| 旧泛化别名：`PI_AGENT_DIR` / `PI_SESSION_DIR` / `PI_CODING_AGENT_VERSION` | 仍接受（低于命名空间化变量），**标注 deprecated**（因为它们是共享命名空间） |
| `PI_HOST_READY` / `PI_HOST_PAIRING_TOKEN` 输出格式 | 不变（客户端解析依赖它） |

## 4. 环境隔离与互不干扰方案

### 4.1 资源分界（默认值即隔离）

| 资源 | 原 host（不动） | v2 host（独立） |
|---|---|---|
| 配置/数据根 | `~/.pi-desktop`（`~/.pi-desktop/pi-host/*`） | `~/.pi-adaptor/data` |
| agent / 全局配置 | `~/.pi-desktop` 内部 | `~/.pi-adaptor/agent` |
| 会话 JSONL | 由原 host 管理 | `~/.pi-adaptor/data/sessions` |
| 端口 | 44271 / 随机 | `--port`（部署用 19445） |
| 传输 | `admin.sock`（unix）+ RACP | **仅** `127.0.0.1` loopback TCP + RACP |
| 锁 / 身份 | `~/.pi-desktop/pi-host/*.lock` | `<home>/run/host.pid`；`<data>/meta/host.json`（hostId） |
| env 命名空间 | PI-Desktop / 历史 | `PI_ADAPTOR_*` |
| 进程 / 服务 | `pi-host`（PI-Desktop 管理） | 独立 user unit `pi-adaptor.service` |
| 版本目录 / 切换 | `~/.pi-desktop/pi-host/sha256-*` + `current` | v2 host 自己的版本目录 + `current`（不碰原 host 的 `current`） |

**保证**：v2 host 的**默认路径中不含** `~/.pi-desktop`，也不含 `~/.pi/agent`（见 §6 自动化测试断言）。因此

- PI-Desktop 的 bootstrap 只写 `~/.pi-desktop`，**无法覆盖** v2 host 的根（这是本次服务器上 `current` 被覆盖那次事故的根因；v2 独立根后不受影响）。
- 原 host 的 systemd unit / `admin.sock` / `*.lock` / `current` 均不被 v2 触碰。

### 4.2 可选强化（按需）

- **同用户 + 隔离 HOME（推荐）**：systemd 里设 `Environment=HOME=%h/.pi-adaptor`，即使将来有依赖读 `HOME` 也能留在根内（示例 unit 已包含）。
- **专用 OS 用户**：用独立账号（如 `pi-adaptor`）承载 v2 host，做到 UID 级隔离；这是最强方案，代价是多一个账号。

### 4.3 客户端不受影响

- 原 host 的 RACP v1 兼容握手与旧 iOS 客户端路径**未改动**（契约 `docs/api/ios-client.md` 未动）。
- v2 host 的客户端改动（模型镜像、审批回放、SSH 自动端口）只作用于 v2 连接；对原 host 的 `provider-import/remove` 调用方式（SSH + `~/.pi-desktop/pi-host/current/pi-host.js`）保持不变。

## 5. 配置示例与接入步骤

### 5.1 示例 A：环境变量（systemd 推荐）

```ini
Environment=PI_ADAPTOR_HOME=%h/.pi-adaptor
Environment=PI_ADAPTOR_PORT=19445
Environment=PI_ADAPTOR_HOST_ID=pi-adaptor-aarch64
Environment=HOME=%h/.pi-adaptor
ExecStart=/usr/bin/node %h/.pi-adaptor/current/dist/main.js
```

完整 unit 见 `deploy/pi-adaptor.service`。

### 5.2 示例 B：配置文件 `<home>/config.json`

见 `config.example.json`：

```json
{
  "dataDir": "/home/pi/.pi-adaptor/data",
  "agentDir": "/home/pi/.pi-adaptor/agent",
  "sessionDir": "/home/pi/.pi-adaptor/data/sessions",
  "port": 19445,
  "hostId": "pi-adaptor-aarch64",
  "hostVersion": "0.0.1",
  "piVersion": "1.3.0"
}
```

### 5.3 接入步骤（不触碰原 host）

1. 构建：` pnpm install && pnpm build`。
2. 在**独立目录**部署产物，例如 `~/.pi-adaptor/version-0.0.1/`，并原子切换 `~/.pi-adaptor/current`（只动 v2 自己的 `current`）。
3. 写入 `~/.pi-adaptor/config.json`（示例 B）或选择用 env（示例 A）。
4. 安装 **user unit**（新 unit 名 `pi-adaptor.service`，不改动任何原 host unit）：
   `cp deploy/pi-adaptor.service ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now pi-adaptor.service`
5. 从 App 配对/连接；核对 `PI_HOST_READY`（`hostId`/`port`）。
6. **回归核对**原 host：`~/.pi-desktop/pi-host/current`、`admin.sock`、`*.lock`、原 unit 状态与内容逐字节不变；原 host 客户端（PI-Desktop、旧 iOS v1 路径）行为不变。

> 端口冲突注意：v2 的 `--port` 是 loopback 监听端口，需与原 host 的端口不同（默认即不同）。

## 6. 验证证据

- 自动化：`test/config.test.ts` 断言
  - 默认路径全部落在 `<home>/.pi-adaptor/**`，且**不含** `.pi-desktop` / `.pi/agent`；
  - 四层优先级（CLI > env > 文件 > 默认）；
  - 命名空间化 env 优先于 deprecated 泛化别名；
  - 配置文件损坏时 fail-loud。
- 手工：以隔离 `HOME` 运行 v2 host，实际只创建 `<HOME>/.pi-adaptor/{agent,data,logs,run}`，无 `.pi-desktop` / `.pi`（见 `docs/qa/evidence/2026-10-31-v2-host-isolation.md`）。
- `仓库根` 全量：`tsc --noEmit` 通过、`vitest` 全绿。

## 7. 非目标

- 不修改、不重新打包、不重新部署原 host（`server/**` 交付物不变）。
- 不改变 `PI_ADAPTOR` 的 RACP 协议帧。
- 不做旧 `~/.pi-desktop` provider/会话的自动迁移（沿用 v2 规格决策 7）。
