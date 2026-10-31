# server/ — 模型服务删除（服务端增量）交付说明

本目录是「模型服务删除」增量的服务端交付物：

| 文件 | 内容 |
|---|---|
| `patches/pi-host-provider-remove.patch` | 相对上游 **v0.21.0** 的完整补丁（`base-commit: d2c9fc44087f24260521c66530c4f92c04790105`，即 tag `v0.21.0`；`apps/pi-host` + `packages/host-runtime` + `packages/shared`，10 个文件） |
| `README.md` | 变更清单、契约映射、构建/打包、T-01~T-56 命令级用例、已知未做项 |
| `scripts/build-pi-host-js.sh` | 从固定 v0.21.0 commit 的临时 `git archive` 树应用补丁并重建架构无关 JS |
| `scripts/assemble-pi-host-bundles.sh` | 用官方两架构包作底座替换 JS、重算 SHA256SUMS、生成可复现 tarball 与 manifest |
| `scripts/verify-pi-host-bundle.sh` | 在目标架构执行安装器自校验、CLI 能力、隔离 Host 启动及导入/删除幂等验证 |
| `dist/` | 两个最终 tarball、`.sha256`、构建 manifest 与架构/QEMU 验证记录 |

唯一依据：`docs/api/ios-client-provider-remove-draft.md`（FROZEN 2026-11-03）。基础契约 `docs/api/ios-client.md`、`docs/specs/**` 均未改动（`docs/` 下没有任何文件被修改）。
## 版本坐标的唯一权威源：`host-release.json`

版本号、发布标签、上游 pin 与各目标摘要都只在仓库根的 [`host-release.json`](../host-release.json) 里定义一次：

- iOS 侧 `PiHostRelease`（`patchedReleaseVersion` / `patchedRepository` / `patchedChecksums`）必须与它一致——
  `HostReleaseManifestTests` 在漂移时直接失败；下载地址由「仓库 + `v<version>`」派生，不再手写标签。
- 本目录的 `scripts/assemble-pi-host-bundles.sh` **从该 JSON 读** `version` / `upstreamVersion` /
  `upstreamCommit` / 上游摘要，脚本里不再出现字面量版本号；产出 tarball 后会把实际摘要与该 JSON 比对，
  不一致就失败（确认是有意升级后，用 `UPDATE_RELEASE_MANIFEST=1` 重跑把摘要写回 JSON）。
- 发布前必须通过 `python3 scripts/check-host-release-consistency.py`：它交叉校验 JSON、iOS 常量、
  发布脚本与本地 `dist/` 产物摘要。

发版顺序：改 `host-release.json` 的 `version` → 跑 assemble（`UPDATE_RELEASE_MANIFEST=1` 写回摘要）→
一致性脚本通过 → 打 tag `v<version>` 并上传资产。少了任何一步，App 会按旧摘要下载旧字节，
表现为「重新安装还是旧版本」。

---


## 1. 应用补丁

```bash
git clone https://github.com/vastsa/PI-Desktop.git pi-desktop-fork
cd pi-desktop-fork
git checkout d2c9fc44087f24260521c66530c4f92c04790105   # = tag v0.21.0（package.json version 0.21.0）
git apply -p1 /path/to/server/patches/pi-host-provider-remove.patch
```

已实测：`git apply --check` 与 `git apply` 在 `git archive` 导出的干净 0.21.0 树上均成功（见 §5 验证记录）。补丁头部 4 行 `#` 注释只是元信息，`git apply` 会忽略。

安装依赖（只装本次改动涉及的 3 个包 + 其依赖，约 180 个包）：

```bash
pnpm install --filter "@pi-desktop/pi-host..." --filter "@pi-desktop/host-runtime..." --filter "@pi-desktop/shared..." --ignore-scripts
```

> 注意：上游仓库的 `patches/` 目录是 pnpm `patchedDependencies` 的输入，缺失会让 `pnpm install` 以 `ERR_PNPM_PATCH_NOT_FOUND` 失败；若用稀疏检出克隆，需 `git sparse-checkout add patches`。

---

## 2. 变更清单（逐文件 → 契约条款）

### 2.1 `packages/shared/src/provider-remove.ts`（新增，443 行）

契约的唯一常量与 schema 来源，`index.ts` 已导出。

| 内容 | 契约条款 |
|---|---|
| `ADMIN_OP_*` / `CLI_PROVIDER_*` / `PI_HOST_*` 前缀常量（唯一字面量，不做任何归一化） | §2.0 |
| (a) stdin / (b) 信封 / (c) 响应 三类字节上限常量（73/164/73/122、111/209/117/165、1024/4096/1024/512） | §2.1.1 |
| `parseProviderRemovePayload` / `parseProviderBindingStatusPayload` / `parseProviderSyncForgetPayload`（严格键集、不回显输入、`confirm` 逐字节等于 `providerId`、无 `force`） | §2.2、§2.4.2、§7.4.1、§7.4.3 |
| `parseProviderRemoveSummary`（`PI_HOST_REMOVED` 独立 schema，四种 golden fixture 双向校验，`effect:"absent"` 不得带 `defaultMoved`，`secretCleared` 非 `true` 即协议错误，拒绝 `defaultMoved` 的 `reason`/`orderingBasis` 越界） | §2.3、§2.6、§6.2、§7.2 |
| `parseProviderBindingStatus` / `parseProviderRemoveStatus`（必选键总出现、可空键出现为 `null`、未知键即失败、枚举封闭、`exists` 被拒绝、`reads ≤ 3`） | §2.4.5 |
| `parseProviderSyncForgetSummary`（恰好四键，`receiptState:"absent"`） | §7.4.1 |
| P1 候选算法：`isEligibleCandidate`（`enabled===true` 严格、`models` 非空、非 OAuth（`authKind==="oauth"` 或 `hasOauth===true`）、`authKind==="none"` 或 `hasSecret===true` 预筛）、`parseCreatedAtInstant`（RFC3339 严格正则 + `Date.parse`）、`orderEligibleCandidates`（`(createdAt, id)` 全序；任一不可比 ⇒ 整批不可比、返回空序 + `orderingBasis:"none"`）、`candidateModelId`（`models[0].id`） | §4.3、§5.6、§5.7 |

### 2.2 `apps/pi-host/src/provider-remove.ts`（新增，678 行）

| 内容 | 契约条款 |
|---|---|
| `removeProvider`：§4.1 步骤 1~8。步骤 1 `providers.get`（不存在 ⇒ `effect:"absent"` 短路，不调 `providers.delete`）；步骤 2 `ownerPluginId` 非空 ⇒ `PLUGIN_OWNED`（`providers.delete` 计数 0）；步骤 3 `settings.get`；步骤 4 目标为默认项时做 `createdAt` 可比性前置检查（不可比 ⇒ `DEFAULT_ORDER_UNDECIDABLE`，0 次写）；步骤 5 单次 `providers.delete`；步骤 6 `providers.get`+`providers.getSecret` 自检（行仍在 ⇒ `RESULT_UNKNOWN`；密钥残留 ⇒ `SECRET_NOT_CLEARED`）；步骤 7/8 默认项转移与迟到默认项检测（不可比 ⇒ `DEFAULT_TRANSFER_ORDER_UNKNOWN` + `removed{providerId,secretCleared}` + `defaultTransfer{state,reason,orderingBasis}`） | §4.1、§4.2 |
| 默认项转移走 P1：候选来自 `providers.list({includeDisabled:true})`，`pluginAllowed` 用 `providers.get` 单条记录（行取不到 ⇒ 未知 ⇒ 不写 `settings.set`，报 `REMOVE_FAILED`），再按全序逐行 `getSecret` 判空取第一个有值者；全部不合格 ⇒ `{to:null,reason:"no_eligible_candidate"|"no_remaining",orderingBasis:"none"}` 且**不写不清空** `settings` | §4.3、§5.7、§5.7 写路径表 |
| 写前/写后三态：所有预写失败保证「未执行」；`providers.delete` 无应答（`host RPC timeout:` 或 `HOST_UNAVAILABLE`）⇒ `RESULT_UNKNOWN`，对端明确错误 ⇒ `REMOVE_FAILED`；`settings.set` 同理拆 `DEFAULT_TRANSFER_UNKNOWN` / `DEFAULT_TRANSFER_FAILED` | §7.2、§8.1 |
| `forgetProvider`：先 `providers.get`（仍在 ⇒ `TARGET_STILL_EXISTS`，字节不变）；只删 `receipts[HMAC].providerId === 目标` 的键；复用上游 `saveJournal`（临时文件 → `file.sync` → `rename` → 目录 `fsync`）；无条目 ⇒ 不写盘、`removedEntries:0`；写盘异常 ⇒ `FORGET_FAILED` | §7.4.1~§7.4.5 |
| `bindingStatusFor`：同一次调用内双读（间隔 ≥50 ms），比较七类输入（会话绑定三项 + `updatedAt` + 相关行字段 + `settings` + `getSecret` 布尔 + `receiptPresent` + 目标行存在性），不一致再读一次，仍不一致 ⇒ `SNAPSHOT_UNSTABLE`；读次数 ≤3 | §7.5.2 |
| `bindingStatusFor` 判定：`pinned`/`effective`（`providerSource` ∈ pin/default/fallback，`modelSource` ∈ session/default/provider_first）、`checks` 八项、短路顺序 `provider_missing > provider_disabled > oauth_unsupported > models_empty > model_removed > secret_missing`、无 pin 且 P1 为空 ⇒ `providerKnown:null` + `no_candidate`、`pluginOwned`/`secretMismatch` 为信息位不参与短路、`isDefault`/`revision:null`/`sessionUpdatedAt`/`maxAgeMs:10000`/`observedAt` | §2.4.2、§5.6.1~§5.6.3 |
| `removeStatusFor`：只用 `providers.get` / `providers.getSecret`（判空）/ `settings.get` 三个只读 RPC + 只读 `provider-sync.json`，双读，`writeOrderingProof:"unproven"`，`boundSessionCount:null`，`recordPresent` 只表示「观察时刻存在性」 | §2.4.3、§7.3、§7.5.3 |
| 四个 CLI runner（`runProviderRemove` / `runProviderBindingStatus` / `runProviderRemoveStatus` / `runProviderSyncForget`）：只接受 `[--data-dir <dir>]`，stdin 单行 JSON 按 (a) 上限读取，stdout 单行 `<PREFIX> {json}`，失败 `PI_HOST_FAILED {"code":…}` + 退出码 1 | §2.1、§2.4.5、§7.4.1 |

### 2.3 `apps/pi-host/src/admin-socket.ts`（改）

| 内容 | 契约条款 |
|---|---|
| `ADMIN_OPS` 白名单扩到 5 个 op（字符串全等，无别名）；信封键仍恰好 `op`/`payload`；未知 op ⇒ `INVALID_REQUEST` | §2.0、§2.4.4、T-39 |
| 读帧仍用统一 `ADMIN_MAX_BYTES = PROVIDER_SYNC_MAX_BYTES + 128`；解析出 `op` 后先校验 (b) 信封上限，再校验 (a) canonical payload 上限 ⇒ `PAYLOAD_TOO_LARGE`（写前拒绝）；（未把 cap 改成按 op 预设，合法大载荷 import 不被误杀） | §2.1.1 封装纪律 1/2/4 |
| 四个新 op 与原 import 共用同一个 `active` 互斥槽（读也占槽） | §6.1 |
| `FAILURE_CODES` 扩到 21 个（6 既有 + 15 新增），供客户端白名单 | §8 |
| `sendAdminOperation`（新）：按 op 的 (c) 上限读响应；`readCapped` 的 `PAYLOAD_TOO_LARGE` 重映射为 `RESPONSE_TOO_LARGE`；**写前**失败 ⇒ `ADMIN_UNAVAILABLE`，**写后**失败 ⇒ `RESULT_UNKNOWN`/`RESPONSE_INVALID`/`RESPONSE_TOO_LARGE`（不再把已发出后的解析失败报成 `ADMIN_UNAVAILABLE`） | §2.1.1 纪律 3、§7.2 |
| 响应严格按 op 解析（成功恰好两键 + 该 op 的 body 键；失败恰好 `ok`/`code`，唯一例外是 `DEFAULT_TRANSFER_ORDER_UNKNOWN` 的四键形态） | §2.3、§2.4.5、§4.2 |
| 审计日志只写 `{op, providerId, code}`，不含配置与密钥 | §3 |
| `sendAdminRequest`（import 客户端）保持原行为不变 | §1 R-1 |

### 2.4 `apps/pi-host/src/provider-import.ts`（改）

- `AdminFailureCode`（21 个码）+ `ImportFailure.code` 放宽到该联合类型，`importFailureCode` 返回同类型（import 路径仍只会产生原来 6 个码）。
- 导出 `journalPath` / `loadJournal` / `saveJournal` / `Journal` / `Receipt`（forget 与 `receiptPresent` 复用同一套严格读取与 fsync 顺序），`importProviders` 改用 `journalPath(dataDir)`。import 语义、回执结构、`version:1` 校验均未变。

### 2.5 `apps/pi-host/src/cli.ts` + `apps/pi-host/src/cli-commands.ts`（改/新增）

- `cli.ts` 只保留 bin 引导（shebang + argv + 退出码 + 唯一 `PI_HOST_FAILED` 行）；命令面移到无副作用的 `cli-commands.ts`，便于测试导入。
- **未知子命令立即非零退出**：首个非 `-` 参数若不是 5 个冻结子命令之一 ⇒ 写 `PI_HOST_FAILED {"code":"INVALID_REQUEST"}`、退出码 1，**不进入** `resolveConfig`/Host 启动路径（旧版会启动 Host）。
- `--help` 列出 5 个子命令（每个独占一行、行首两个空格、整 token 可匹配；`provider-remove` 与 `provider-remove-status` 不互相误命中），`--help` 仍不启动 Host。

### 2.6 `packages/host-runtime/src/launch-resolver.ts`（改，规则 B）

| 内容 | 契约条款 |
|---|---|
| `providers.list` 改 `includeDisabled:true`（只用于区分「不存在 vs 被禁用」，候选集始终按 `enabled === true` 过滤） | §5.2 B2、§5.6 |
| B1 目标解析仍为 `overrides.providerId ?? session.providerId` | §5.2 B1 |
| B2/B3 显式目标：不存在 / `enabled !== true`（严格，含字段缺失）/ 请求的 `modelId` 不在该行 `models[]` ⇒ `MODEL_NOT_CONFIGURED`；OAuth 与插件 agent 伪 id 保持既有拒绝；缺密钥仍是 `PROVIDER_SECRET_MISSING`。**删除** `providers[0]`、`hasSecret` 链式兜底 | §5.2 B2~B4 |
| B4 无显式目标：走 P1 —— `defaultProviderId` 在合格集合内则用它（`default`），否则取全序第一个（`fallback`，**已过滤 disabled**）；P1 为空或 `createdAt` 不可比 ⇒ `MODEL_NOT_CONFIGURED` | §5.2 B4、§4.3 |
| B5 覆盖面：`turn/start`（`runtime-service.ts:304-313`）、`compact`（`runtime-service.ts:457-459`）、计划执行（`plan-dispatch.ts:131-136`）本就调用同一个 `resolve()`，因此三处同时生效（未另开解析路径） | §5.2 B5 |
| B6 fail-closed：任一读失败即抛错拒绝启动，绝不回退到别的 provider | §5.2 B6 |

### 2.7 测试

| 文件 | 内容 |
|---|---|
| `apps/pi-host/src/provider-remove.test.ts`（新增，30 个用例） | 见 §6 覆盖矩阵 |
| `packages/host-runtime/src/launch-resolver.test.ts`（改） | 原「模型被移除后回落到目录配置」的期望按契约 B2③/S11 改为 `MODEL_NOT_CONFIGURED`；新增 5 个规则 B 回归用例（显式 override / session pin / 默认项 / P1 fallback / 不可比） |

---

## 3. 契约实现要点（评审自查用）

1. **命名封闭**：4 个 op、4 个子命令、4 个成功前缀只有一个字面量；服务端按字符串全等比较，错误拼写 ⇒ `INVALID_REQUEST`。
2. **字节上限三类分离**：读帧用统一总上限 → 解析 `op` → 按 op 校验 (b) → 按 op 校验 (a)；(c) 在客户端读响应时执行，超限 `RESPONSE_TOO_LARGE`。合法最小 `providers.remove` 帧 101 字节不会被 (a)=73 误杀（有测试断言）。
3. **`ok` 不证明「本次执行了删除」**：响应显式带 `effect:"deleted"|"absent"`；重复删除幂等返回 `ok:true` + `absent`，绝不返回 `NOT_FOUND`。
4. **密钥只出布尔**：唯一密钥操作是 `providers.getSecret` 判空，值判空后立即丢弃，不进响应/stdout/日志/回执。
5. **默认项**：P1（创建最早的合格候选）；`createdAt` 不可比 ⇒ 删除前 `DEFAULT_ORDER_UNDECIDABLE`（0 次写）/ 删除后 `DEFAULT_TRANSFER_ORDER_UNKNOWN`（不返回 `ok:true`）；候选全不合格 ⇒ `no_eligible_candidate` 且不清空 `settings`。
6. **只读 op 只读**：`bindingStatus`/`removeStatus` 只调 `session.get`/`providers.list`/`providers.get`/`providers.getSecret`/`settings.get` + 读 `provider-sync.json`，没有任何写路径。
7. **双读是观察不是证明**：`snapshotStable` 只表示两次规范化输入相同；`removeStatus` 的 `recordPresent:false` 只写进字段，不产生「删除成功」结论；`writeOrderingProof` 恒 `"unproven"`。
8. **规则 B**：显式 pin（override 或 session）被删除/禁用/模型移除一律 `MODEL_NOT_CONFIGURED`，接口层面没有任何「改用别的 provider 继续跑」的路径。

---

## 4. 构建两个架构的 bundle

### 4.1 当前状态：方案 A 已产出双架构包

`apps/pi-host/scripts/bundle.mjs` 在打包前会**硬拒绝**跨平台/跨架构：

```js
if (!['linux','darwin'].includes(platform) || !['x64','arm64'].includes(arch)
    || platform !== process.platform || arch !== process.arch ...) throw new Error(...)
```

并且它会复制 `bin/pi-desktop-host-core`（来自 `cargo build --release -p host-core`）与 `agent-runtime/dist-bundle/sidecar.js`。因此 `bundle.mjs` 仍不能用于跨平台全量打包；本交付改用 §4.2 方案 A，不重建任何 Rust 或 Node 二进制。

已产出并验证：

- 补丁基于 tag `v0.21.0` 的 peeled commit `d2c9fc44087f24260521c66530c4f92c04790105`。从该 commit **未打补丁**构建的 JS SHA-256 为 `156928a770318c379ccc424dd42749029b0f535e585d044a196c6a9fd78651e4`，与官方 x64、arm64 发布包内的 `pi-host.js` 完全一致。
- 两个最终包均使用官方 v0.21.0 bundle 的 Node、host-core、agent-runtime 与 node-pty 原始字节，仅替换架构无关的 `pi-host.js` 并重算 `SHA256SUMS`。
- arm64 在目标服务器原生运行；x64 在 `ubuntu:22.04` amd64 容器中通过临时 `qemu-x86_64` binfmt 实际运行。两者均完成隔离 Host 启动、provider-import、删除前状态、删除、重复删除幂等和删除后状态验证。
- 连续两次组装得到相同的两个 tarball 与 manifest SHA-256。详细证据见 `dist/pi-host-0.21.0+remove.1-verification.json`。

正式公网托管：

- Release：`https://github.com/RuidongWang/PI-IOS-host/releases/tag/v0.21.0+remove.1`
- 下载目录：`https://github.com/RuidongWang/PI-IOS-host/releases/download/v0.21.0+remove.1`
- 两个 bundle 与 `.sha256`、manifest、verification、补丁、三个脚本、固定 commit 的完整上游源码归档和 LGPL-3.0 许可文本均已上传。
- 已清空隔离用户 `piiosqa` 的安装回执，强制从公网重新下载 arm64 包并完成真实 bootstrap：`downloadedBytes=72,185,547`、`step=done`、`status=ok`、unit `active`。
- x64 仍只有 QEMU 生命周期验证，尚无原生 x64 机器上的完整 bootstrap 安装证据。

### 4.2 方案 A（推荐）：host-core 用上游发布，只替换 JS 产物

契约只要求「`host-core` 与架构匹配」（§11），本增量**没有** Rust/host-core 改动，因此可以用上游 v0.21.0 的 `linux-x64` / `linux-arm64` 发布包作底座，只替换其中的 `pi-host.js`。

在 macOS/Linux 上从固定 commit 重建 JS：

```bash
server/scripts/build-pi-host-js.sh \
  --source /path/to/PI-Desktop \
  --out /tmp/pi-host.js
```

在 Linux 上从官方双架构包组装（脚本会固定官方包 SHA-256、替换 JS、重算全部内部清单，并生成 manifest）：

```bash
server/scripts/assemble-pi-host-bundles.sh \
  --pi-host-js /tmp/pi-host.js \
  --x64-archive /path/to/pi-host-0.21.0-linux-x64.tar.gz \
  --arm64-archive /path/to/pi-host-0.21.0-linux-arm64.tar.gz \
  --out-dir server/dist
```

在对应原生架构（或已配置 binfmt/qemu 的容器）验证完整 Host 生命周期：

```bash
server/scripts/verify-pi-host-bundle.sh \
  --archive server/dist/pi-host-0.21.0+remove.1-linux-arm64.tar.gz
```

脚本不会读取或修改 `~/.pi-desktop/current`；安装与测试数据均使用临时目录。

### 4.3 方案 B：全量构建（含 host-core）

在**目标架构**的 linux 机器（或 CI runner）上：

```bash
cargo build --release --locked -p host-core
pnpm install --frozen-lockfile
pnpm --filter '@pi-desktop/pi-host...' build
pnpm --filter @pi-desktop/pi-host bundle -- \
  --node "$(command -v node)" \
  --host-core target/release/pi-desktop-host-core \
  --platform linux --arch arm64 \
  --out dist-bundle/pi-host-0.21.0+remove.1-linux-arm64
```

产物目录内含 `pi-host.js`、`agent-runtime/`、`bin/node`、`bin/pi-host`、`bin/pi-desktop-host-core`、`node_modules/node-pty`、`install.sh`、`SHA256SUMS`、`package.json`；再按 §4.2 末尾的 `tar` / `sha256sum` 打包。

### 4.4 CI 方案（本机无法执行的部分）

`.github/workflows/linux-package.yml` 目前只做桌面 electron 包与 host-core glibc 校验，没有 pi-host 双架构 job。建议新增（矩阵式，两架构必须同 commit 构建）：

```yaml
jobs:
  pi-host-bundle:
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: ubuntu-22.04        # linux-x64
            arch: x64
          - runner: ubuntu-24.04-arm    # linux-arm64（原生 arm runner，避免 qemu 下 host-core 不可执行）
            arch: arm64
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - run: git apply -p1 server/patches/pi-host-provider-remove.patch
      - uses: pnpm/action-setup@v6
      - uses: actions/setup-node@v7
        with: { node-version: 24, cache: pnpm }
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo build --release --locked -p host-core
      - run: pnpm install --frozen-lockfile
      - run: pnpm --filter '@pi-desktop/pi-host...' build
      - run: pnpm --filter '@pi-desktop/pi-host...' test          # 命令级用例
      - run: pnpm --filter @pi-desktop/pi-host bundle -- --platform linux --arch ${{ matrix.arch }} \
                --host-core target/release/pi-desktop-host-core \
                --out dist-bundle/pi-host-0.21.0+remove.1-linux-${{ matrix.arch }}
      # 能力探针（§11「两个包都必须声明四个子命令」）
      - run: |
          out=dist-bundle/pi-host-0.21.0+remove.1-linux-${{ matrix.arch }}
          for c in provider-remove provider-binding-status provider-remove-status provider-sync-forget; do
            "$out/bin/node" "$out/pi-host.js" --help | grep -Eq "^[[:space:]]*$c[[:space:]]" || { echo "missing $c"; exit 1; }
          done
      - run: tar -C dist-bundle -czf pi-host-0.21.0+remove.1-linux-${{ matrix.arch }}.tar.gz pi-host-0.21.0+remove.1-linux-${{ matrix.arch }}
      - uses: actions/upload-artifact@v4
        with: { name: pi-host-linux-${{ matrix.arch }}, path: '*.tar.gz*' }
```

要点：**不给 bundle 脚本加跨架构允许**（它会复制本机 Node 与 pnpm 的原生 `node-pty`，跨架构产物不可运行）；两架构分别原生构建，再用 `sha256` 与 `--help` 四行断言互相核对（T-34）。

---

## 5. 本机实际执行的验证（真实输出）

环境：macOS arm64，Node v22.22.0，pnpm 12.8.1（`npm i -g pnpm@12.8.1` 装的），上游 0.21.0 克隆 + 补丁。

以下保留补丁开发阶段的 JS/命令级真实输出；最终双架构产物与 Host 生命周期验证见 §4.1 和 `dist/pi-host-0.21.0+remove.1-verification.json`。

```text
$ pnpm install --filter "@pi-desktop/pi-host..." --filter "@pi-desktop/host-runtime..." --filter "@pi-desktop/shared..." --ignore-scripts
Scope: 7 of 12 workspace projects ... Packages: +177 ... Done in 9.7s
（首次因缺失 patches/ 失败：ERR_PNPM_PATCH_NOT_FOUND，git sparse-checkout add patches 后成功）

$ pnpm -r --filter "@pi-desktop/pi-host..." build            # tsc，等价 typecheck
packages/shared build: Done
packages/agent-host build: Done
packages/agent-runtime build: Done
packages/racp build: Done
packages/host-runtime build: Done
packages/pi-host build: Done

$ pnpm --filter @pi-desktop/shared test
Test Files 102 passed (102) · Tests 1332 passed (1332)

$ pnpm --filter @pi-desktop/host-runtime test
Test Files 21 passed (21) · Tests 163 passed (163)

$ pnpm --filter @pi-desktop/pi-host test
Test Files 8 passed (8) · Tests 98 passed | 1 skipped (99)

$ node apps/pi-host/dist/cli.js --help ; echo exit=$?
pi-host — headless PI Agent Host (RACP-WS on loopback)
  provider-import         import selected providers from SSH stdin
  provider-remove         delete one provider from SSH stdin
  provider-binding-status report a session's model binding and its availability
  provider-remove-status  report the observed removal state of one provider
  provider-sync-forget    drop the import receipt of one provider
  ...
exit=0

$ node apps/pi-host/dist/cli.js definitely-not-a-subcommand --data-dir /tmp/x-30675 ; echo exit=$?
PI_HOST_FAILED {"code":"INVALID_REQUEST"}
exit=1
（/tmp/x-30675 未创建：未启动 Host、未建 admin.sock/admin.lock）

$ printf '%s' '{"version":1,"providerId":"6f1c2a3e-4b5d-4c7e-8f90-a1b2c3d4e5f6"}' \
  | node apps/pi-host/dist/cli.js provider-remove --data-dir /tmp/pi-remove-empty ; echo exit=$?
PI_HOST_FAILED {"code":"ADMIN_UNAVAILABLE"}
exit=1
（同样的 provider-remove-status ⇒ 同样是 ADMIN_UNAVAILABLE，fail-closed，不当「可用/不可用」结论）

$ npx esbuild src/cli.ts --bundle --platform=node --format=esm --target=node22 \
    --external:node-pty --external:bufferutil --external:utf-8-validate --outfile=$PI_SCRATCH_DIR/jsbundle/pi-host.js \
    "--banner:js=import { createRequire as __piCreateRequire } from 'node:module'; const require = __piCreateRequire(import.meta.url);"
../../../jsbundle/pi-host.js  10.6mb  ⚡ Done in 284ms
$ node $PI_SCRATCH_DIR/jsbundle/pi-host.js --help | head -6      # 与 dist 输出一致，含四个新子命令
$ node $PI_SCRATCH_DIR/jsbundle/pi-host.js provider-remove-typo --data-dir /tmp/none-here ; echo exit=$?
PI_HOST_FAILED {"code":"INVALID_REQUEST"} ; exit=1

$ # 补丁可应用性（干净 0.21.0 树）
$ git archive HEAD | tar -x -C /tmp/pi-verify && cd /tmp/pi-verify
$ git apply --check /path/server/patches/pi-host-provider-remove.patch && echo APPLY_CHECK_OK
APPLY_CHECK_OK
$ git apply /path/server/patches/pi-host-provider-remove.patch && echo APPLIED
APPLIED
```

上述开发阶段未执行：`cargo build -p host-core`（本增量不动 Rust）、`scripts/bundle.mjs`（硬拒绝跨平台）、全仓 `pnpm install`（只装 3 个包的作用域）与 `biome lint`（配置忽略相关路径）。后续方案 A 已用官方 Rust/Node 产物完成双架构组装和实际 Host 生命周期验证，见 §4.1。

---

## 6. 命令级用例（T-01~T-56）怎么跑

### 6.1 前置

```bash
DATA=$(mktemp -d)                                          # 隔离 dataDir（0700）
PIHOST=~/.pi-desktop/pi-host/current/bin/pi-host           # 已安装 bundle 的启动器（exec bin/node + pi-host.js）
# 未安装时可直接用: PIHOST="node $V_NEW/pi-host.js"
```

`$P` 用一条 `provider-import` 造出来：

```bash
echo '{"version":1,"providers":[{"sourceId":"s1","input":{"name":"Models","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible","baseUrl":"https://models.example/v1","authKind":"api_key","secretValue":"sk-xxx","models":[{"id":"m1","contextWindow":8000,"maxTokens":1000,"thinkingLevels":["off"],"defaultThinkingLevel":null}]}}]}' \
  | "$PIHOST" provider-import --data-dir "$DATA"
# ⇒ PI_HOST_PROVIDERS {"imported":[{"sourceId":"s1","providerId":"<P>"}],...}
P=<上一步的 providerId>
```

### 6.2 覆盖矩阵

「自动」= 本补丁的 vitest 用例（`apps/pi-host/src/provider-remove.test.ts` / `launch-resolver.test.ts`）已断言；「真机」= 需要真实 host-core 会话、真实服务器或尚未覆盖的双架构专项场景。最终 x64/arm64 包已产出，但下表中仍未勾选的专项用例不能由基础生命周期探针替代。

| # | 状态 | 落点 / 命令 |
|---|---|---|
| T-01 | 自动 | `T-01/T-02/T-55 deletes once…`（socket + CLI，golden `PI_HOST_REMOVED`） |
| T-02 | 自动 | 同上第二次调用 ⇒ `effect:"absent"`、退出码 0、`providers.delete` 仍为 1 次 |
| T-03 | 自动 | `T-03 reports an unknown id as absent…`（随机 UUID ⇒ `absent`，delete 计数 0） |
| T-04 | 真机 | 对 v0.21.0 真包跑 `--help`，断言四个 token 均不出现且无 `admin.sock`/`admin.lock`/SQLite 副作用 |
| T-05 | 真机（隔离） | `pi-host provider-remove --data-dir $DATA`（旧包）会启动 Host 并打印 `PI_HOST_READY`；必须用受控子进程 + 超时清理，禁止对常驻实例执行 |
| T-06 | 自动 | `refuses an unknown subcommand immediately…`（`definitely-not-a-subcommand` 与 `provider-remove-typo` ⇒ 退出码 1 + `PI_HOST_FAILED`，`$DATA/pi-host` 未被创建） |
| T-07 | 自动 | `T-07 rejects every malformed payload without echoing it` + `…confirm that does not echo the id` |
| T-08 | 真机补一次 | 既有 `admin-socket.test.ts` 已覆盖同 dataDir 第二实例 `ADMIN_BUSY`；真机只需复核 socket inode 不变 |
| T-09 | 自动（既有） | `admin-socket.test.ts` 的 stale lock / socket 回收用例 |
| T-10 | 真机（双架构已过） | 删后 `recordPresent:false`、`secretPresent:false`；隔离 Host 生命周期脚本已在 linux-arm64 原生与 linux-x64 QEMU 容器分别执行 |
| T-11 | 自动（fixture）+ 真机 | `T-11 moves the default to the earliest eligible candidate`、`T-11 breaks an equal createdAt by id byte order`；真机验 `settings.set` 落盘语义 |
| T-12 | 自动（fixture）+ 真机 | `T-12 leaves settings untouched when no remaining provider is eligible` |
| T-13 | 自动（fixture）+ 真机 | `T-13 reports the empty state without clearing settings` |
| T-14 | 未做 | 需在 import 的 `beforeCreate` 上挂起再发删除/查询；既有 `admin-socket.test.ts` 已覆盖「import 并发 ⇒ ADMIN_BUSY」，删除侧同槽因此结论相同，但未单独立用例 |
| T-15 | 自动 | `T-15/T-51 keeps a pre-write failure in the executed=false class`（`getHost()===null` ⇒ `ADMIN_UNAVAILABLE`） |
| T-16 | 自动 | `T-16/T-19 reports RESULT_UNKNOWN when the reply is lost…`（注入 `host RPC timeout: providers.delete`）；**不是** `ADMIN_UNAVAILABLE`、**不是**成功 |
| T-17 | 自动 | `T-17 reports SECRET_NOT_CLEARED and never retries the delete` |
| T-18 | 自动 | `T-18 reports DEFAULT_TRANSFER_FAILED after the delete already happened` |
| T-19 | 部分自动 | 断言了「无第二次写、无 `settings.set`」；exec 计数用客户端预算核对（§6.3 U4：1 写 + 2 查询）在多设备/真 SSH 场景才能逐次统计 |
| T-20 | 自动 | `T-20/T-56 reports observations only`（`recordPresent:false` 只落字段） |
| T-21 | 未做 | 查询超时/旧版无该 op ⇒ 停在「不确定」；需要真 SSH 或旧 socket fixture |
| T-22 | 未做（真机） | 回执保留时重放同一 import ⇒ `skipped.reason:"remote_missing"`、`providers.create` 计数 0 |
| T-23 | 自动 | `T-23/T-42 removes the receipt once and is idempotent afterwards`（forget 后回执消失） |
| T-24 | 自动 | `T-24 refuses to forget the receipt of a provider that still exists`（字节不变） |
| T-25 | 未做 | forget × import 并发 `ADMIN_BUSY`（同 §6.1 论证，可用 import fixture 补） |
| T-26 | 自动（fixture）+ 真机 | `launch-resolver.test.ts` 的 `createHeadlessLaunchResolver — rule B` 四组；真机需在真 host-core 上跑上游测试并端到端复核 |
| T-27 | 真机 | 用户重选模型后 `available:true` 且 `turn/start` 成功 |
| T-28 | 客户端 + 真机 | 0 次 `turn/start` 断言在 iOS 侧；服务端只保证 `available:false/null` 语义 |
| T-29 | 真机 | 第二台设备无本地记录也能得到 `provider_missing` |
| T-30 | 真机 | 解析窗口内删除；断言无静默改绑（`session.configure` 计数 0）、结果 ∈ {turn 继续, `PROVIDER_SECRET_MISSING`, `MODEL_NOT_CONFIGURED`, host-core 其他形态} |
| T-31 | 客户端 | 取消 = 不发请求；服务端侧可用 `rawRequest` 计数方式复核（socket 上零字节） |
| T-32 | 部分自动 | 现有用例断言 stdout/日志不含注入的密钥；完整抓包/回执扫描留真机 |
| T-33 | 真机（部分自动） | 既有 `admin-socket.test.ts` 断言 socket `0600` 与目录 `0700`、非本 uid 拒绝 |
| T-34 | 部分 | 两架构的包哈希、四行能力探针、T-01/T-02/T-10/T-55 等价生命周期已通过；仍缺 T-22/T-26 的逐项双架构证据 |
| T-35 | 自动（既有） | `admin-socket.test.ts` 的 import 全量用例仍全绿（68→98 用例未回归） |
| T-36/T-37 | 客户端 | 版本目录 realpath + 全目录哈希、执行前复核（§9.1.1），客户端实现 |
| T-38 | 客户端 | 按子命令独立探针（本补丁只保证 help 每行一个完整 token；反例 fixture 在客户端） |
| T-39 | 自动 | `T-39 rejects a misspelled op…`（5 种错误拼写 ⇒ `INVALID_REQUEST`，host 零调用） |
| T-40 | 自动 | `T-40 reports SNAPSHOT_UNSTABLE when the two reads disagree`（3 次 `session.get`） |
| T-41 | 自动 | `T-41 does not treat a repeated delete as evidence…`（超时后 `recordPresent:true` 仍只是观察；`force` 不可用） |
| T-42 | 自动 | 见 T-23（第二次 `removedEntries:0` 且文件字节不变） |
| T-43 | 未做（需注入断点） | `rename` 前/后掉电表述：实现复用上游 `saveJournal`（temp → fsync → rename → dir fsync），用例需要故障注入钩子 |
| T-44 | 自动 | `T-44 skips a candidate whose hasSecret and getSecret disagree`（写路径）+ T-47 的 S6 形态 |
| T-45 | 自动 | `T-45 refuses a plugin-owned row before any delete or settings write`（计数均为 0） |
| T-46 | 自动（①）/ 真机（②） | `T-46 refuses a default transfer whose candidates cannot be ordered`；②（迟到默认项）实现已覆盖（删除后二次 `settings.get`），真机复核一条 |
| T-47 | 自动 | `T-47 answers S1/S2/S5/S10/S11/S12…`、`…no_candidate for an unbound session`、`…unknown input as available:null` |
| T-48 | 真机 | `F-1`/`F-3` 与两条负例（单独 SSH 重连、两次只读观察）在客户端/运维侧；服务端只提供 `slotFree` 与只读观察值 |
| T-49 | 自动 | `T-49 accepts both sessionId bounds and rejects every strict-schema violation`（短 ID、128 字符 ID、缺 `maxAgeMs`、`available:"true"`、多 `exists`、`no_binding` 越界） |
| T-50 | 自动 | `T-50 accepts the exact envelope ceiling and rejects one byte more`（101 字节最小帧、信封 111 通过 / 112 `PAYLOAD_TOO_LARGE`、大载荷 import 仍成功） |
| T-51 | 自动（①③）/ 真机（②） | `T-15/T-51 …` 与 `T-16/T-19 …`；②（写已发出后 SSH 断线）需真 SSH |
| T-52 | 未做（统计型） | 需按 §6.3 逐用户动作统计 exec/已准入写/对账查询；本补丁用「注入失败后无第二次写」间接断言 |
| T-53 | 真机 | `MODEL_NOT_CONFIGURED` 两种送达形态 |
| T-54 | 真机 | `session.configure` 必须带 `mode` 的静默无效行为 |
| T-55 | 自动（fixture）+ 真机（已过） | `T-01/T-02/T-55 …`：两次同 id + 一次伪 UUID，全部 `ok:true`；两个最终 bundle 已在隔离 Host 上实测首次 `effect:"deleted"`、重复删除 `effect:"absent"` |
| T-56 | 自动（观察值结构）+ 真机 | `T-20/T-56 reports observations only`；界面文案属客户端 |

### 6.3 手工冒烟（单条命令即可复核）

```bash
echo "{\"version\":1,\"providerId\":\"$P\"}" | "$PIHOST" provider-remove --data-dir "$DATA" ; echo "exit=$?"
echo "{\"version\":1,\"providerId\":\"$P\"}" | "$PIHOST" provider-remove --data-dir "$DATA" ; echo "exit=$?"   # effect:"absent"
echo "{\"version\":1,\"providerId\":\"$P\"}" | "$PIHOST" provider-remove-status --data-dir "$DATA"
echo "{\"version\":1,\"sessionId\":\"ses_1\"}" | "$PIHOST" provider-binding-status --data-dir "$DATA"
echo "{\"version\":1,\"providerId\":\"$P\",\"confirm\":\"$P\"}" | "$PIHOST" provider-sync-forget --data-dir "$DATA"
```

> 子命令的 argv 只接受 `[--data-dir <dir>]`；`--data-dir` 省略时按 `PI_DESKTOP_DATA_DIR` → `~/.pi-desktop` 解析。stdin 必须是**单行**规范 JSON（`provider-remove` ≤73 字节、`provider-remove-status` ≤73、`provider-binding-status` ≤164、`provider-sync-forget` ≤122）。

---

## 7. 已知未做项、实现取舍与阻塞项

### 7.1 剩余未覆盖与边界

1. **双架构 bundle 已产出**：`dist/pi-host-0.21.0+remove.1-linux-{x64,arm64}.tar.gz` 已生成，包含官方架构二进制、替换后的 JS、完整 `SHA256SUMS` 和安装器自校验证据。原始双架构阻塞项关闭。
2. **仍有未覆盖的合同用例**：T-04/T-05（旧包拒绝）、T-12/T-13（默认项 `settings.set` 落盘分支）、T-22（回执重放）、T-26/T-27/T-29/T-30（真实会话重选与并发）、T-43（掉电窗口）、T-48（客户端重连）、T-51②（写后 SSH 断线）、T-53/T-54（真实 RACP 错误形态）。本次双架构验证覆盖 T-01/T-02/T-03/T-10/T-55 的 bundle 生命周期等价路径，但不替代其余用例。
3. **架构验证边界**：arm64 为服务器原生执行；x64 为 amd64 容器 + QEMU user-mode，不是物理 x64 主机。正式 `~/.pi-desktop/current` 未被修改，也未执行生产切换。
4. **host-core 来源**：本增量无 Rust 改动，host-core 直接沿用官方 v0.21.0 发布字节；未做 Rust 重建或交叉编译。

### 7.2 实现取舍（契约内部张力处，均按冻结文字处理）

1. **`DEFAULT_TRANSFER_ORDER_UNKNOWN` 的响应是 4 键**（`ok`/`code`/`removed`/`defaultTransfer`），与 §2.3「恰好两键信封」字面冲突。此处依 §4.2 与 §8 的**明确冻结**要求（两处都写了这条形态），客户端解析按该例外实现（`sendAdminOperation` 只在该 code 下允许这两键）。
2. **未知 op 返回 `INVALID_REQUEST` 而不是 `UNSUPPORTED_OP`**：§9.2 提到「新 Host 对未知 op 返回 `UNSUPPORTED_OP`」，但 T-39 冻结为「错误拼写一律 `INVALID_REQUEST`」。已按可执行的 T-39 实现；`UNSUPPORTED_OP` 保留在错误码枚举里（能力缺失时由客户端呈现），socket 不发射它。
3. **`slotFree` 恒 `true`**：读取本身占着同一个 `active` 槽，其它 admin 操作不可能在此时运行；字段语义取「除本读取外无其它 admin 操作在跑」，并且它只是 E1，不证明 host-core 写已终结。
4. **`remainingEligible` 用 §4.3 的 `eligible` 口径**（预筛 + `pluginAllowed`，逐个 `providers.get` 取 `ownerPluginId`），**不含** §5.7 的 `getSecret` 复核（该复核只决定默认项转移的目标）。这样「默认项转移」与「剩余合格候选数」用同一份 `planTransfer()`，不出现两套口径。
5. **删除后二次 `settings.get`**：U3 预算行写 `settings.get ×1`，但 T-46② 要求发现「删除后才变成默认项」的迟到情形，故实现为 `×2`（内部 RPC 不计入 §6.3 的四量，仍受 10 s 单次上限与 30 s 总截止约束）。
6. **`bindingStatus` 的 `receiptPresent`** 只作双读比较输入（契约不把它放进响应）；日志/回执读取失败**不**把结论降级为 unknown（它不是判定输入）。
7. **`checks.secretMismatch`** 在行取到即求值（§5.6.2 行 719），因此 S12（disabled）形态下它是 `false` 而不是 `null`；`oauth`/`modelsEmpty` 仍按优先级惰性求值（S4/S12 的 `oauth:null`/`modelsEmpty:null` 保持成立）。
8. **`host.core` 无 Rust 改动**：本增量完全落在 JS 侧，因此 host-core 可沿用上游发布产物（§11 只要求「与架构匹配」）。

### 7.3 明确未做（契约外或本增量不做）

- 批删、改名删除（按 name）、OAuth 账号删除、RACP `provider-list`、RACP 新操作：均按 §1 非范围排除。
- 客户端（iOS）侧规则 A / 禁发断言 / 探针缓存：属 `apps/ios/**`，本任务不触碰。
- `docs/` 下任何文件（契约、spec、qa 脚本）均未修改。

---

## 8. 评审入口

1. 先看 §2 变更清单与 §3 要点，再按 §5 复跑编译与三个包的测试（全绿：1332 / 163 / 98）。
2. 逐条对照 §6 矩阵决定哪些用例需要排真机/双架构；阻塞项集中在 §7.1。
3. 若对 §7.2 的任一条取舍有异议，需要回到 `api-designer` 重开对应条款（这些点都落在契约文字的交叉处，不属实现自由度）。
