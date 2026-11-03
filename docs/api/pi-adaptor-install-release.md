# PI-adaptor 安装与发布契约

- 状态：**FROZEN**（2026-11-01；已吸收 advisor 契约评审）
- 契约版本：`1.0.0`
- 适用范围：PI-IOS iOS 客户端、远端 bootstrap、`host-release.json`、PI-adaptor release 资产
- 需求来源：`docs/specs/pi-adaptor-reinstall-version.md`
- 兼容基线：既有 bootstrap 状态推进与 `PI_HOST_BOOTSTRAP*` / `PI_HOST_READY` / `PI_HOST_PAIRING_TOKEN` / `PI_HOST_FAILED` 标记

## 1. 范围与不变量

本契约定义“下载哪个 PI-adaptor、安装到哪里、启动哪个 service、如何证明运行的是目标版本”。RACP v2 wire protocol 仍由 `docs/api/pi-adaptor.md` 定义。

必须成立：

1. 版本、Release tag、平台资产、安装根、入口和 unit 都由同一个 release manifest 决定。
2. 默认安装目标只能是 PI-adaptor；legacy `pi-host` 不能作为 receipt 命中、运行中二进制的替代或成功证明。
3. 安装目录不可变。同一版本但资产摘要变化时，必须形成新的安装目录并原子切换 `current`。
4. 安装成功的最终证据必须来自本次新配对后的 RACP 连接：`server.name == "pi-adaptor"` 且 `server.version == manifest.version`。
5. 旧 `pi-host` 的用户数据目录不得被读取、删除或迁移到 PI-adaptor 数据根。
6. 安装失败不得报告成功；若已经切换 `current`，必须按 §8 恢复安装前状态。

## 2. Release manifest

### 2.1 权威文件与 schema

仓库根 `host-release.json` 是唯一权威源，iOS 内置常量、Host 包版本、发布脚本和一致性测试必须从中派生或与它比对。

`schemaVersion` 升级为 `2`。必需字段如下：

```json
{
  "schemaVersion": 2,
  "repository": "Owner/Repo",
  "version": "2.0.1",
  "releaseTag": "pi-adaptor-v2.0.1",
  "protocolVersion": "2.0.0",
  "runtime": {
    "serverName": "pi-adaptor"
  },
  "install": {
    "home": "~/.pi-adaptor",
    "versionsDirectory": "~/.pi-adaptor/releases",
    "currentLink": "~/.pi-adaptor/current",
    "unitName": "pi-adaptor.service",
    "entrypoint": "dist/main.js",
    "installer": "scripts/install.sh",
    "packageManifest": "package.json",
    "minimumNodeVersion": "22.19.0"
  },
  "artifacts": {
    "linux-x64": {
      "bundleDirectory": "pi-adaptor-2.0.1-linux-x64",
      "file": "pi-adaptor-2.0.1-linux-x64.tar.gz",
      "sha256": "__64_LOWERCASE_HEX__"
    },
    "linux-arm64": {
      "bundleDirectory": "pi-adaptor-2.0.1-linux-arm64",
      "file": "pi-adaptor-2.0.1-linux-arm64.tar.gz",
      "sha256": "__64_LOWERCASE_HEX__"
    }
  }
}
```

约束：

- `schemaVersion` 必须为 `2`。
- `version` 必须与 `package.json.version` 完全相同。
- `releaseTag` 必须为 `pi-adaptor-v<version>`。现有 `pi-adaptor-v2.0.1` Release 保持该命名。
- `repository` 必须是 `<owner>/<repo>`，默认 `RuidongWang/PI-adaptor`。
- `protocolVersion` 必须是 Host 实际支持的 RACP 协议版本。
- `runtime.serverName` 必须为 `pi-adaptor`；安装器用它校验 RACP `server.name`。
- `install.home` 和 `install.currentLink` 必须位于同一根；`currentLink` 必须是 `home/current`。
- `install.entrypoint` 必须为相对路径 `dist/main.js`。
- `install.unitName` 必须为 `pi-adaptor.service`。
- `install.minimumNodeVersion` 必须是完整三段式版本 `22.19.0`，运行时不得只比较 major 版本。
- `artifacts` 的键必须恰好是 `linux-x64` 和 `linux-arm64`。
- 每个 `file` 必须等于 `<bundleDirectory>.tar.gz`。
- `bundleDirectory` 必须包含 PI-adaptor 名称、完整版本和目标架构。
- `sha256` 必须是 64 位小写十六进制。
- 不允许回退到通用 `pi-adaptor-<version>.tar.gz` 作为默认资产；架构成交与原生依赖必须由独立资产证明。

### 2.2 URL

资产 URL 必须按以下公式生成，不得由界面拼接另一套规则：

```text
https://github.com/<repository>/releases/download/<releaseTag>/<file>
https://github.com/<repository>/releases/download/<releaseTag>/<file>.sha256
```

adjacent `.sha256` 只用于发现远端摘要。客户端必须再与 manifest 中固定摘要比对；二者不一致时在下载后、解包前失败。

生产安装不得通过环境变量、用户输入或远端配置覆盖 manifest 的 `version`、artifact、固定 SHA-256 或 runtime name。测试可注入 base URL 和本地 fixture，但 fixture 必须同时显式提供期望 SHA-256 并经过同一校验；缺少 checksum、checksum 非法或不匹配都必须失败。测试不得把 checksum 校验改成可选路径。

### 2.3 发布门禁

发布前必须同时通过：

1. manifest 结构检查。
2. `host-release.json.version == package.json.version`。
3. iOS release 常量与 manifest 的 repository、version、tag、target、file、bundleDirectory、sha256 全部一致。
4. 本地 x64/arm64 产物的实际 SHA-256 与 manifest 一致。
5. GitHub Release 两个资产和 adjacent checksum 均存在，下载后的摘要与 manifest 一致。
6. 两个 Linux 资产分别执行 `install.sh --verify` 和 Host smoke test。

任一失败时不得发布，也不得让 iOS 安装入口继续展示“可安装”。

## 3. 发布包布局

每个平台 tarball 顶层恰好是一个 `bundleDirectory`：

```text
pi-adaptor-2.0.1-linux-arm64/
  package.json
  dist/main.js
  node_modules/
  scripts/install.sh
  SHA256SUMS
```

约束：

- `package.json.name` 必须为 `@pi-ios/pi-adaptor`。
- `package.json.version` 必须等于 manifest `version`。
- `dist/main.js` 必须存在，且是 Node 可直接启动的 ESM 入口。
- `scripts/install.sh` 必须实现 §4.4 的 `--install`、`--verify`、`--rollback` 接口。
- `node_modules/` 必须包含目标 OS/CPU 的生产依赖；不得以 macOS 原生包、另一 Linux 架构的原生包或未裁剪的 devDependencies 冒充目标资产。
- `node_modules/` 必须是实体文件目录，不得依赖符号链接；构建时应按目标平台安装并展开生产依赖。
- bundle 中不得包含 plaintext provider key、设备令牌、配对令牌、remote `.env` 或用户数据。

### 3.1 SHA256SUMS 定义

`SHA256SUMS` 是安装树完整性清单，不是 tarball 摘要：

- 覆盖 bundle 中除 `SHA256SUMS` 自身外的全部普通文件：`package.json`、`dist/**`、`scripts/install.sh`、`node_modules/**`。
- 每行格式固定为 `<64 位小写十六进制>  <相对路径>\n`，文件名与 `sha256sum` 可兼容；路径使用 `/` 分隔且不得以 `/` 或 `../` 开头。
- 哈希对象是文件原始字节，不解压、不转码、不规范化换行。
- 行按相对路径的 bytewise C 顺序排序；文件只含 UTF-8/ASCII 路径与 LF，无空行、注释或额外字段。
- 不得跟随符号链接；bundle 内出现符号链接直接视为无效。
- `installedManifestSha256` 和 install.sh 的 `--manifest-sha256` 都是对 `SHA256SUMS` 文件原始字节计算的 SHA-256。
- 生成后必须在干净目录解包并执行 `sha256sum -c SHA256SUMS` 或等价校验。

## 4. 安装目录与 state layout

### 4.1 默认路径

```text
home:            ~/.pi-adaptor
versions:        ~/.pi-adaptor/releases
bootstrap work:  ~/.pi-adaptor/.bootstrap
receipt:         ~/.pi-adaptor/.bootstrap/install-receipt.json
current:         ~/.pi-adaptor/current -> releases/<version>-<asset-sha256>
unit:            ~/.config/systemd/user/pi-adaptor.service
entrypoint:      ~/.pi-adaptor/current/dist/main.js
data:            ~/.pi-adaptor/data
agent:           ~/.pi-adaptor/agent
logs:            ~/.pi-adaptor/logs
run:             ~/.pi-adaptor/run
```

`<asset-sha256>` 是 manifest 中资产完整 64 位 SHA-256，不得截断或使用哈希前缀。

### 4.2 不可变版本目录

激活目录名必须为：

```text
<version>-<asset-sha256>
```

目录一旦发布不得原地覆盖。以下任一条件成立时必须创建新目录：

- 版本不同。
- 资产 SHA-256 不同。
- 目录内 `package.json.version` 或 `dist/main.js` 与期望不符。
- receipt 不完整或无法解析。

`current` 只通过 `current.next` + `rename`/等价原子重命名切换。不得先删除当前 `current` 再重建。

### 4.3 安装 receipt

receipt JSON：

```json
{
  "schemaVersion": 1,
  "version": "2.0.1",
  "target": "linux-arm64",
  "assetSha256": "__64_LOWERCASE_HEX__",
  "installedManifestSha256": "__64_LOWERCASE_HEX__",
  "bundleDirectory": "pi-adaptor-2.0.1-linux-arm64",
  "installDirectory": "~/.pi-adaptor/releases/2.0.1-<asset-sha256>",
  "entrypoint": "dist/main.js",
  "unitName": "pi-adaptor.service",
  "activatedAt": "2026-11-01T00:00:00Z"
}
```

普通重装只有在以下条件全部成立时才可复用：

- receipt schema、version、target、asset SHA-256 与当前 manifest 完全一致。
- receipt 的 install directory 位于 `~/.pi-adaptor/releases`。
- receipt JSON 与其记录的不可变目录名必须包含 manifest 中完整 64 位资产 SHA-256。
- 该目录的 `package.json.version`、`dist/main.js` 与 receipt 一致。
- §4.4 的 `scripts/install.sh --verify` 成功，且 `SHA256SUMS` 校验通过。
- `current` 解析到该目录。

`forceReinstall=true` 必须忽略复用判定，重新下载、校验并激活；若资产摘要未变，可以在预览后复用已经验证过的不可变目录，但仍必须重新执行 verify、原子切换和运行时身份验证。

legacy `~/.pi-desktop/pi-host/.release.sha256` 不得进入上述判定，也不得被迁移成 PI-adaptor receipt。

### 4.4 `install.sh` 接口

调用者必须使用绝对路径。未知 action、缺参数、重复参数或路径越界都返回退出码 `2`，且不得修改目标目录。

#### `--install`

```text
scripts/install.sh --install \
  --bundle <absolute-bundle-root> \
  --home <absolute-pi-adaptor-home> \
  --version <manifest-version> \
  --target <linux-x64|linux-arm64> \
  --asset-sha256 <64-lowercase-hex> \
  --manifest-sha256 <64-lowercase-hex>
```

语义：

- 验证 `bundle/package.json.version == --version`。
- 计算并验证 bundle `SHA256SUMS`，再得到 `--manifest-sha256`；传入值不一致时失败。
- 目标目录固定为 `<home>/releases/<version>-<asset-sha256>`。
- 先写同文件系统内的临时目录，验证后原子 rename 为最终目录；已存在的最终目录只有通过完整 verify 才可复用。
- 通过 `current.next` 原子切换 `<home>/current`。
- 成功时 stdout 只输出单行 JSON：

```json
{"installDirectory":"/abs/.pi-adaptor/releases/2.0.1-<sha>","previousCurrentTarget":null,"currentTarget":"releases/2.0.1-<sha>"}
```

#### `--verify`

```text
scripts/install.sh --verify \
  --install-dir <absolute-install-directory> \
  --version <manifest-version> \
  --target <linux-x64|linux-arm64> \
  --asset-sha256 <64-lowercase-hex> \
  --manifest-sha256 <64-lowercase-hex>
```

必须验证：

- 安装目录 basename 等于 `<version>-<asset-sha256>`。
- `package.json.name`、`package.json.version`、`dist/main.js`、`scripts/install.sh` 均存在且匹配。
- `SHA256SUMS` 逐文件校验通过，且其自身 SHA-256 等于 `--manifest-sha256`。
- 当前 Node 版本 `>= 22.19.0`。
- target 字段与 manifest target 一致。

成功时不修改文件，stdout 输出：

```json
{"verified":true,"version":"2.0.1","target":"linux-arm64","installDirectory":"/abs/path"}
```

#### `--rollback`

```text
scripts/install.sh --rollback \
  --home <absolute-pi-adaptor-home> \
  --previous-current-target <relative-target|none> \
  --failed-install-dir <absolute-install-directory|none>
```

语义：

- `--previous-current-target` 只允许 `<home>/releases/` 下的相对路径，或字面量 `none`。
- 若 previous target 存在，先用 `current.next` 原子恢复，再校验它可解析且位于 versions directory。
- 删除本次未激活的 failed install directory；不得删除 previous target 或其他 release。
- 成功时 stdout 输出：

```json
{"rolledBack":true,"currentTarget":"releases/2.0.1-<sha-or-null>"}
```

文件回滚与 service、未来 pairing/runtime 验证的完整补偿由 §8 编排；`install.sh --rollback` 不读取或修改 Keychain、配对令牌和 legacy 数据。

#### 退出码

| 退出码 | 条件 |
| --- | --- |
| `0` | action 成功 |
| `2` | 用法错误、未知 action、缺/重复参数、非法版本/target/SHA/target path |
| `3` | package/entrypoint/Node 版本或目标架构不匹配 |
| `4` | `SHA256SUMS` 缺失、格式错误或逐文件哈希不匹配 |
| `5` | receipt、current 或 rollback 目标状态不一致 |
| `6` | owner-only 权限、临时目录、rename 或文件系统操作失败 |
| `7` | verify 成功前失败 |
| `8` | rollback 失败 |

stdout 不得含 token、Keychain 内容或敏感路径之外的数据；stderr 输出单行 JSON `{"code":"...","details":{...}}`，`code` 使用 `usage-invalid`、`version-mismatch`、`manifest-integrity-failed`、`state-mismatch`、`filesystem-failed`、`verify-failed`、`rollback-failed`。

## 5. Bootstrap 行为

### 5.1 状态与命令

- 现有状态顺序保持不变。
- `PI_HOST_BOOTSTRAP*` 等 marker 为兼容保留；其中 “HOST” 不表示 legacy 产品名。
- bootstrap command 与 diagnostics 的路径必须指向 `~/.pi-adaptor/.bootstrap`。
- 日志路径为 `~/.pi-adaptor/.bootstrap/bootstrap.log`。

### 5.2 探测与选择资产

`uname -s == Linux` 且：

- `x86_64` / `amd64` → `linux-x64`
- `aarch64` / `arm64` → `linux-arm64`

不支持其他平台或架构。不得下载后才发现架构不符。

### 5.3 安装步骤

1. 探测平台和架构。
2. 解析 manifest，下载对应 adjacent checksum。
3. 与 fixed SHA-256 比对。
4. 检查 receipt 与不可变目录；不命中则下载 tarball。
5. 在 owner-only stage 中校验、解包并检查 package version、入口和安装脚本。
6. 安装到 `releases/<version>-<asset-sha256>`，完整 SHA-256 不得截断。
7. 执行 `install.sh --verify`，生成 receipt。
8. 原子切换 `current`。
9. 写 `pi-adaptor.service`；`ExecStart` 指向 `current/dist/main.js`，并设置 `PI_ADAPTOR_HOME`、`PI_ADAPTOR_PORT`、`PI_ADAPTOR_HOST_ID`。
10. 停止已存在的 PI-adaptor unit。仅在 legacy `pi-host.service` / `pi-host-v2.service` 存在且其进程实际占用目标端口时，记录原状态（exists、active、enabled）后停止并禁用对应 legacy unit；不存在或未冲突时不得操作。不得删除 legacy 目录或数据。
11. 启动 `pi-adaptor.service`，确认 unit active。
12. 用本次安装新启动进程签发的 pairing token 完成新配对，再用该新 device token 执行 RACP 验证。
13. 只有运行时身份与版本都匹配后写 `status=ok`。

若第 10 步确认存在目标端口冲突但无法停止 legacy unit，或停止后仍有非 PI-adaptor 进程占用目标端口，返回 `unit-failed`，`error.details.reason` 为 `legacy-service-conflict`，并在 `error.details.legacyUnits` 中记录 unit、原 active/enabled 状态与占用证据。

安装成功时 legacy 状态记录写入非秘密 bootstrap state；安装失败时由 §8 按记录恢复之前停止/禁用的 legacy unit 状态。全程不得把 legacy unit 当作 PI-adaptor 就绪依据。

### 5.4 Unit

生成的 user unit 至少包含：

```ini
[Unit]
Description=PI-adaptor
After=network.target

[Service]
Type=simple
Environment=PI_ADAPTOR_HOME=%h/.pi-adaptor
Environment=PI_ADAPTOR_PORT=<port>
Environment=PI_ADAPTOR_HOST_ID=<target-derived-id>
ExecStart=<absolute-node> %h/.pi-adaptor/current/dist/main.js --port <port>
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
```

禁止：

- unit 名继续使用 `pi-host.service`。
- `ExecStart` 指向 `pi-host.js` 或 `~/.pi-desktop/pi-host/current`。
- 用 unit 环境变量把版本覆盖成与包内 `package.json.version` 不同的值作为默认行为。

## 6. 运行时身份验证

### 6.1 配对令牌与设备令牌

- 默认安装路径只接受本次 PI-adaptor process 输出的 `ppt2.` pairing token。
- `ppt1.` 只能由显式 legacy compatibility 模式接受；该模式默认关闭，PI-adaptor 重装流程永远不得启用。
- Runner configuration 必须显式携带 `allowLegacyPPT1=false`；只有独立 legacy compatibility 调用点可以传 `true`，安装 UI 和管理页不得暴露该开关。
- 当前安装 attempt 必须使用随机 attempt ID 对应的 staging Keychain account 保存 new `pdt2.` device token。
- runtime identity/version 和 ping 全部通过后，才把 staging token 原子提升为主 host token。
- 失败或取消时不得覆盖原主 token；若对端已签发 token，best-effort 调用 `connection/revoke`，随后清除 staging token。

安装器必须使用本次 `--pair` 产生并刚写入内存的设备 token；不得使用 Keychain 中重装前的 token 证明新安装成功。

验证顺序：

1. 用新 device token 打开 RACP v2。
2. 发送 `connection/initialize`。
3. 检查 `server.name == manifest.runtime.serverName`。
4. 检查 `server.version == manifest.version`，比较完整版本字符串。
5. 发送 `connection/ping`，确认同一连接可用后才算验证完成。

任何一项失败都不得写成功回执。不得以 SSH 端口可达、隧道握手成功或 unit active 代替这一步。

## 7. 错误模型

兼容保留现有 `BootstrapFailureCode`。需要附加诊断时，扩展 `error.details`；未知 detail 必须保留，不得静默丢弃。

```json
{
  "code": "verify-device-failed",
  "details": {
    "reason": "runtime-identity-mismatch",
    "expectedName": "pi-adaptor",
    "actualName": "pi-host",
    "expectedVersion": "2.0.1",
    "actualVersion": "0.21.0",
    "unitName": "pi-adaptor.service",
    "port": 19445
  }
}
```

约定：

- `installed-verification-failed`：解包后或激活后的文件/package 版本不匹配。
- `unit-failed` + `details.reason=legacy-service-conflict`：旧 unit 无法停止或目标端口仍被旧进程占用。
- `pair-failed` + `details.reason=legacy-pairing-token`：默认 PI-adaptor 安装收到 `ppt1.`。
- `verify-device-failed` + `details.reason=runtime-identity-mismatch`：RACP 返回非 PI-adaptor。
- `verify-device-failed` + `details.reason=runtime-version-mismatch`：名称正确但版本不同。
- `verify-device-failed` + `details.reason=ping-failed`：initialize 身份正确，但同一连接 ping 失败。
- `verify-device-failed` + `details.reason=cancelled`：配对、身份校验或 ping 阶段收到取消。

`error.details` 为可选 JSON object；现有字段保持原义。新字段至少支持 `reason`、`phase`、`expectedName`、`actualName`、`expectedVersion`、`actualVersion`、`installDirectory`、`unitName`、`port`、`legacyUnits`。客户端必须保留未知字段和未知 reason。

管理 UI 必须显示期望值、实际值和失败阶段；没有 detail 时仍显示既有错误文案。

## 8. 回滚

### 8.1 事务快照

切换前记录到 owner-only 的 attempt state：

- `previousCurrentTarget`（若存在）。
- `previousServiceActive`。
- `previousActiveTokenAccount`（仅账户名，不含 token）。
- 本次 `stagingTokenAccount`。
- 本次是否已签发 device token。
- 被停止/禁用 legacy unit 的原 active/enabled 状态。

### 8.2 文件与服务补偿

写出 `current` 后的任一步失败时：

1. 停止新 `pi-adaptor.service`。
2. 执行 `install.sh --rollback` 原子恢复 previous target；无 previous target 时移除 `current`。
3. 若 previous PI-adaptor service 在安装前 active，则重启它；否则保持 inactive。
4. 若本次曾停止/禁用 legacy unit，只有在 PI-adaptor 回滚后仍不能恢复 previous current 时才按原状态恢复它；不得因此把 legacy 当作安装成功。
5. 关闭本 attempt 的 RACP client，停止 pair reader 与 manual pair process，清理 FIFO、pair/verify marker 和内存 token。
6. 若本次已签发 device token，best-effort 撤销；删除 staging Keychain entry，主 token 保持安装前值。
7. 删除未激活的 stage/release 目录，并写 `status=failed`、原始 `error.details` 与 rollback 结果。
8. 保留 `bootstrap.log`、state 与非秘密诊断。

回滚只作用于 PI-adaptor 根和 `pi-adaptor.service`。不得重新启用 legacy host 来掩盖失败。

### 8.3 配对、runtime identity、ping 与取消

- 配对成功、identity/version 失败或 ping 失败时，均执行 §8.2 的 token 与文件/服务补偿；不得写成功回执。
- 用户在任意阶段取消时，先写 cancel marker；runner、pair reader 与 manual process 必须观察到 marker 并走同一补偿。若 process 被强制终止，下次进入页面必须先读取未完成 state 和事务快照并完成 rollback 或重新安装。
- 取消只终止本次 attempt 的 process/client，不得 broad `pkill pi-adaptor`，不得终止不属于本 attempt 的其他 PI-adaptor 实例。
- 回滚本身失败时写 `status=failed`，`error.code=rollback-failed`，保留 previous/failed target 和所有诊断，禁止下一次安装静默覆盖该 state。

## 9. 可观测性

成功状态和安装页必须能显示：

- manifest version 与 target。
- 资产名和 SHA-256。
- `current` 解析后的绝对路径。
- `pi-adaptor.service` 的 active 状态。
- SSH 隧道目标端口。
- RACP `server.name`、`server.version`。

安装日志不得包含 pairing token、device token、API key 或私钥。

## 10. 验收映射

| 契约 | Spec |
| --- | --- |
| §2 manifest 与 URL | AC-1, AC-1.1, AC-1.2 |
| §3 包布局 | AC-1.1, AC-2 |
| §4 receipt 与不可变目录 | AC-2.1, AC-2.2 |
| §5 legacy 故障处理、unit | AC-2, AC-2.3, AC-3, AC-3.1 |
| §6 新 token + RACP 身份 | AC-3.2, AC-4 |
| §7 error details | AC-4.2 |
| §8 rollback | AC-5.1 |
| §9 observability | AC-4.1 |

## 11. FROZEN 决策记录

advisor 提出的关键点已冻结为：

1. 使用完整 asset SHA-256 的不可变目录，receipt 同时绑定资产与 `SHA256SUMS` 摘要。
2. legacy unit 仅在存在且实际占用目标端口时停止/禁用，并记录、按回滚条件恢复原状态。
3. `error.details` 是向前兼容的可选 object；未知字段与未知 reason 必须保留。
4. x64/arm64 使用独立生产依赖资产；checksum 在生产与测试路径都不可选。
5. 运行时名称与版本在安装 verification adapter 中校验，bootstrap 只根据该回调成功写最终回执；ping 必须在同一连接上完成。
6. 回滚恢复安装前 PI-adaptor current 与 service active 状态；配对 token 使用 attempt staging，成功后提交、失败后撤销并清理。
