# PI-adaptor 接口契约

- 状态：**FROZEN**（2026-10-30；前三轮 `advisor` 阻塞项已处置，最终契约由 48 方法 schema、99 合法 fixture、27 错误、18 事件与 5 非法 fixture 的自动化门禁验证）
- 协议版本：`2.0.0`
- 上游基线：`@earendil-works/pi-coding-agent@1.3.0`
- 传输：SSH `direct-tcpip` 上的 WebSocket / JSON-RPC 2.0
- 路径：`/v1/racp/ws`
- 子协议：`pi-racp.v2.jsonrpc`
- 机器可读 schema：`docs/api/pi-adaptor.schema.json`

## 1. 范围与不变量

本契约定义 PI-IOS 与新版 Host 的完整交互。新版 Host 不实现旧 Host 的内部 Rust RPC，也不读取旧 Host 私有数据库；但保留原生 Pi v3 JSONL 会话文件。

必须成立：

1. WebSocket 只监听 `127.0.0.1`，只能经 SSH 隧道访问。
2. 除 `connection/initialize` 与 `connection/pair` 外，所有请求都要求设备令牌。
3. 所有写操作都携带 `context.requestId`；可重试写操作还必须携带 `context.idempotencyKey`。
4. 事件只通过持久游标去重；不得用墙钟时间判断新旧。
5. provider 密钥永不进入响应、日志、事件或错误体。
6. 运行中会话不得被静默换 provider/model，也不得被删除。
7. 删除会话前必须确认目标 ID；删除后不得继续返回该会话。

## 2. 传输、握手与身份

### 2.1 WebSocket

- 只接受文本帧；二进制帧以 close code `1003` 关闭。
- 单条控制帧 UTF-8 最大 1 MiB。
- `attachment/chunk` 的 base64 载荷最大 512 KiB；整帧最大 700 KiB。
- 升级请求必须携带 `Sec-WebSocket-Protocol: pi-racp.v2.jsonrpc`。
- 设备令牌使用 `Authorization: Bearer <token>`；不得放入 URL。
- 配对令牌前缀 `ppt2.`，设备令牌前缀 `pdt2.`。

### 2.2 JSON-RPC 帧

请求：

```json
{"jsonrpc":"2.0","id":1,"method":"session/list","params":{}}
```

成功响应：

```json
{"jsonrpc":"2.0","id":1,"result":{}}
```

失败响应（JSON-RPC 2.0 的 `error.code` 必须是整数；业务码放在 `error.data.code`）：

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"session not found","data":{"code":"NOT_FOUND","requestId":"..."}}}
```

通知：

```json
{"jsonrpc":"2.0","method":"events/event","params":{"event":{}}}
```

`events/event` 的 `event` 必须按 §7.2 的 `kind` 匹配对应 payload schema；非法事件帧关闭连接。

### 2.3 握手

`connection/initialize` 的 `params`：

```json
{
  "client": {
    "name": "PI-IOS",
    "version": "1.0.0",
    "capabilities": {
      "attachments": true,
      "imageOutput": true,
      "skills": true,
      "providers": true,
      "sessionBranches": true
    }
  },
  "protocolVersion": "2.0.0"
}
```

结果：

```json
{
  "protocolVersion": "2.0.0",
  "server": {
    "name": "pi-adaptor",
    "version": "0.0.1",
    "hostId": "uuid",
    "piVersion": "1.3.0"
  },
  "connectionId": "conn_uuid",
  "roles": ["owner"],
  "policy": {
    "defaultPermissionMode": "ask",
    "allowedPermissionModes": ["ask", "auto"],
    "maxImageBytes": 20971520,
    "maxImagesPerMessage": 10,
    "approvalDisconnectSeconds": 86400
  },
  "capabilities": {
    "attachments": true,
    "imageOutput": true,
    "skills": true,
    "providers": true,
    "sessionBranches": true,
    "sessionDelete": true,
    "nativePiSessions": true
  }
}
```

客户端收到结果后必须发送 `notifications/initialized`，之后连接才进入 online。

### 2.4 配对与撤销

`connection/pair` 只允许使用一次性配对令牌。配对令牌有效期 10 分钟，只能成功消费一次。配对连接在返回设备令牌后立即失去特权；客户端必须断开并用设备令牌重连，才能调用其他方法。

```json
{"deviceLabel":"iPhone","context":{"requestId":"req_pair"}}
```

结果：

```json
{"deviceId":"dev_uuid","deviceToken":"pdt2.<opaque>","hostId":"host_uuid"}
```

`connection/revoke` 只允许 owner：

```json
{"deviceId":"dev_uuid","context":{"requestId":"req_revoke"}}
```

结果：`{"revoked":true}`。重复撤销返回 `{"revoked":false}`，不得返回 500。

撤销成功后，Host 必须关闭该设备已建立的全部 WebSocket；该设备后续请求返回 `UNAUTHORIZED`。

`connection/rotate-token` 只允许当前设备调用：

```json
{"context":{"requestId":"req_rotate","idempotencyKey":"rotate-key"}}
```

结果：

```json
{
  "rotationId": "rot_uuid",
  "deviceId": "dev_uuid",
  "deviceToken": "pdt2.<new opaque>",
  "previousTokenValidUntil": "2026-10-30T00:05:00Z"
}
```

轮换是两阶段的：

1. Host 保留旧令牌 5 分钟并生成新令牌；同 `idempotencyKey` 重试返回同一待确认结果。
2. 客户端持久化新令牌后，用新令牌调用 `connection/confirm-rotation`。
3. 确认后旧令牌立即失效，其他旧连接收到 `events/closed`。

若 Host 在确认前重启，未确认轮换失效，旧令牌继续有效。

`connection/confirm-rotation`：

```json
{"rotationId":"rot_uuid","context":{"requestId":"req_confirm","idempotencyKey":"rotate-key"}}
```

结果：`{"confirmed":true}`。

### 2.5 设备记录

Host 只持久化令牌 SHA-256 哈希，不保存明文。设备记录至少包含：

```json
{
  "deviceId": "dev_uuid",
  "label": "iPhone",
  "role": "owner",
  "tokenHash": "64 hex chars",
  "createdAt": "2026-10-30T00:00:00Z",
  "lastUsedAt": "2026-10-30T00:00:00Z",
  "revokedAt": null
}
```

审计日志只写 `deviceId`、操作和结果码。

### 2.6 设备与配对令牌管理

- `device/list`：`{"context":{"requestId":"req_devices"}}` → `{"devices":[{...}]}`；只返回元数据，不返回令牌。
- `device/pairing-token`：owner 设备调用 `{"ttlSeconds":600,"context":{...}}` → `{"token":"ppt2.<opaque>","expiresAt":"..."}`。
- 配对令牌只通过当前 owner 的加密连接返回，不写日志、不写 URL。
- Host 也保留 `--pair` CLI 路径；CLI 必须通过 owner-only admin socket 请求当前 Host 签发，而不是启动第二个数据库写者。

## 3. 通用结构

### 3.1 Context

读取与一次性设备操作的 `context` 只必填 `requestId`。可重试写操作使用 `writeContext`，必须携带 `requestId` 与 `idempotencyKey`。审批/输入使用 `revisionContext`，必须携带 `requestId`、`idempotencyKey` 和 `expectedRevision`。

读取与一次性设备操作的 `context` 只必填 `requestId`。可重试写操作使用 `writeContext`，必须携带 `requestId` 与 `idempotencyKey`。审批/输入使用 `revisionContext`，必须携带 `requestId`、`idempotencyKey` 和 `expectedRevision`。

`writeContext` 示例：

```json
{"requestId":"req_uuid","idempotencyKey":"opaque"}
```

`revisionContext` 示例：

```json
{"requestId":"req_uuid","idempotencyKey":"opaque","expectedRevision":12}
```

同一幂等键收到不同参数时返回 `IDEMPOTENCY_CONFLICT`；同参数重试必须返回第一次结果或明确的 `CONFLICT`。过期幂等键也必须返回明确错误，不得当作新请求。

幂等矩阵：

| 写方法 | context | 确认 |
| --- | --- | --- |
| `connection/pair` | `writeContext` | 一次性配对令牌消费 |
| `connection/revoke` | `writeContext` | 设备撤销 + 关闭连接 |
| `connection/rotate-token` / `confirm-rotation` | `writeContext` | 两阶段确认 |
| `device/pairing-token` | `writeContext` | 新令牌过期时间 |
| project/register/update/delete | `writeContext` | project 版本/删除结果 |
| session/create/configure/rename/archive/branch/delete | `writeContext` | session revision |
| turn/start/interrupt/cancel | `writeContext` | turn 终态/幂等键 |
| approval/respond、input/respond | `revisionContext` | revision + alreadyResolved |
| provider/create/update/delete | `writeContext` | provider revision/删除结果 |
| skill/install/update/delete | `writeContext` | skill 版本/删除结果 |
| attachment/create/chunk/complete | `writeContext` | 字节数/attachment 状态 |

### 3.2 Cursor

```json
{"epoch":"epoch_uuid","sequence":42}
```

`sequence` 是 Host 的**全局**持久序号（所有 scope/会话共用一条递增序列），不是每会话连续序号。因此：

- 会话级订阅只会收到该会话的事件，其间其它会话/主机事件的序号会穿插进来，「本会话收到的序号不连续」是正常现象，**服务端与客户端都不得**据此判定丢事件；
- 唯一的重同步信号是服务端显式返回 `CURSOR_EXPIRED`（epoch 变化，或游标所需事件已被保留窗口淘汰）。服务端在淘汰事件后必须维护可证明的保留水位，并在返回任何后续事件之前先判断游标是否仍可完整回放。

### 3.3 Project

```json
{
  "id": "proj_uuid",
  "label": "PI-IOS",
  "path": "/home/user/PI-IOS",
  "archived": false,
  "sessionCount": 3
}
```

项目路径必须规范化并确认是可访问目录。项目元数据由 Host 保存；删除项目只删除元数据，不删除目录。

### 3.4 Session summary

```json
{
  "id": "session-id",
  "title": "修复构建",
  "projectId": "proj_uuid",
  "projectPath": "/home/user/PI-IOS",
  "mode": "agent",
  "permissionMode": "ask",
  "providerId": "provider_uuid",
  "modelId": "model-id",
  "thinkingLevel": "high",
  "revision": 12,
  "activeTurnId": "turn_uuid",
  "archived": false,
  "readOnlyReason": null,
  "messageCount": 18,
  "source": "native-pi",
  "createdAt": "2026-10-30T00:00:00Z",
  "updatedAt": "2026-10-30T00:10:00Z"
}
```

`readOnlyReason` 非空时，所有会写 JSONL 的操作必须拒绝，并返回 `SESSION_READ_ONLY`。

### 3.5 Item

```json
{
  "id": "item-id",
  "itemType": "message",
  "kind": "message",
  "role": "assistant",
  "text": "partial or final text",
  "status": "streaming",
  "turnId": "turn_uuid",
  "toolName": null,
  "attachments": [],
  "content": {}
}
```

已知 `itemType`：`message`、`tool`、`approval`、`input`、`image`、`error`。客户端必须保留未知 `itemType` 与原始 `content`，不得崩溃或当作成功。

### 3.6 Turn

```json
{
  "id": "turn_uuid",
  "sessionId": "session-id",
  "status": "running",
  "createdAt": "2026-10-30T00:00:00Z",
  "settledAt": null
}
```

`status`：`queued | running | waiting_approval | waiting_input | completed | interrupted | uncertain | failed | canceled`。

`uncertain` 表示 Host 无法证明旧执行已停止或结果未落地；客户端不得显示为“已中断”。turn 可带 `settledReason`：

```json
{"settledReason":"agent_restarted_unconfirmed"}
```

### 3.7 Attachment

```json
{
  "id": "att_uuid",
  "sessionId": "session-id",
  "kind": "input",
  "fileName": "photo.jpg",
  "mimeType": "image/jpeg",
  "byteLength": 12345,
  "sha256": "64 hex chars",
  "state": "ready",
  "createdAt": "2026-10-30T00:00:00Z"
}
```

`state`：`uploading | ready | failed | deleted`。消息和会话只可引用 `ready`。

### 3.8 Snapshot

```json
{
  "session": {},
  "revision": 12,
  "cursor": {"epoch":"epoch_uuid","sequence":42},
  "items": [],
  "activeItems": [],
  "activeTurn": null,
  "queuedTurns": [],
  "pendingApprovals": [],
  "pendingInputs": [],
  "hasMoreHistory": false,
  "replayComplete": true
}
```

## 4. 操作表

| 方法 | 角色 | 写 | 说明 |
| --- | --- | --- | --- |
| `connection/initialize` | anonymous/pairing/device | 否 | 握手与能力 |
| `connection/ping` | device | 否 | 心跳 |
| `connection/pair` | pairing | 是 | 交换设备令牌 |
| `connection/revoke` | owner | 是 | 撤销设备 |
| `connection/rotate-token` | device | 是 | 两阶段轮换当前设备令牌 |
| `connection/confirm-rotation` | device | 是 | 确认新令牌并废除旧令牌 |
| `device/list` | owner | 否 | 设备列表 |
| `device/pairing-token` | owner | 是 | 为新增设备签发一次性配对令牌 |
| `project/list` | owner | 否 | 项目列表 |
| `project/browse` | owner | 否 | 浏览服务器目录 |
| `project/register` | owner | 是 | 注册目录 |
| `project/update` | owner | 是 | 改名/归档 |
| `project/delete` | owner | 是 | 删除 Host 元数据 |
| `session/list` | owner | 否 | 会话目录 |
| `session/search` | owner | 否 | 标题/历史搜索 |
| `session/get` | owner | 否 | 单会话元数据 |
| `session/create` | owner | 是 | 新建原生会话 |
| `session/attach` | owner | 否 | 快照与当前状态 |
| `session/history` | owner | 否 | 分页历史 |
| `session/configure` | owner | 是 | 模式/权限/provider/model/thinking |
| `session/rename` | owner | 是 | 写入 `session_info` |
| `session/archive` | owner | 是 | Host 元数据归档 |
| `session/branch` | owner | 是 | 从指定 item 创建新 JSONL |
| `session/delete` | owner | 是 | 删除 JSONL 与独占媒体 |
| `events/subscribe` | owner | 否 | 订阅 Host 或会话事件 |
| `events/unsubscribe` | owner | 否 | 取消订阅 |
| `events/ack` | owner | 否 | 确认持久游标 |
| `turn/start` | owner | 是 | 开始或排队 turn |
| `turn/get` | owner | 否 | 查询 turn |
| `turn/interrupt` | owner | 是 | 中断运行中 turn |
| `turn/cancel` | owner | 是 | 取消排队 turn |
| `approval/respond` | owner | 是 | 审批 |
| `input/respond` | owner | 是 | AskTool 回答 |
| `provider/list` | owner | 否 | 掩码 provider 列表 |
| `provider/create` | owner | 是 | 新建 provider |
| `provider/update` | owner | 是 | 更新 provider/替换密钥 |
| `provider/delete` | owner | 是 | 删除 provider |
| `provider/test` | owner | 否 | 验证认证/模型 |
| `provider/discover` | owner | 否 | 发现模型 |
| `skill/list` | owner | 否 | 已安装 Skill |
| `skill/get` | owner | 否 | Skill 详情 |
| `skill/install` | owner | 是 | 从 Git/目录安装 |
| `skill/update` | owner | 是 | 更新安装副本 |
| `skill/delete` | owner | 是 | 删除安装副本 |
| `attachment/create` | owner | 是 | 开始上传 |
| `attachment/chunk` | owner | 是 | 上传分片 |
| `attachment/complete` | owner | 是 | 校验并发布 |
| `attachment/read` | owner | 否 | 读取图片分片 |

## 5. 项目操作

### 5.1 `project/list`

请求：`{}`。结果：`{"projects":[]}`。

### 5.2 `project/browse`

请求：`{"path":"/home/user"}`，省略时从用户 home 开始。

结果：

```json
{
  "path": "/home/user",
  "entries": [
    {"name":"PI-IOS","path":"/home/user/PI-IOS","kind":"directory","readable":true}
  ]
}
```

路径必须存在、可读、位于允许根下。符号链接必须解析后重新检查。

### 5.3 `project/register`

请求：`{"path":"/home/user/PI-IOS","label":"PI-IOS"}`。结果：`{"project":{}}`。同路径重复注册复用同一项目并更新 label。

### 5.4 `project/update`

请求：`{"projectId":"proj_uuid","label":"新名称","archived":true,"context":{"requestId":"req","idempotencyKey":"key"}}`。未提供字段不变。

### 5.5 `project/delete`

请求：`{"projectId":"proj_uuid","confirmProjectId":"proj_uuid","context":{"requestId":"req","idempotencyKey":"key"}}`。只删 Host 元数据；有活跃会话时返回 `SESSION_BUSY`，不得删除目录。

## 6. 会话操作

### 6.1 `session/list`

请求：`{"includeArchived":true}`。结果：`{"sessions":[],"revision":1}`。

### 6.2 Session writer actor

Host 对每个会话只允许一个 in-process writer actor。actor 写入顺序固定为：

1. 获取/续租协作 lease。
2. 校验 canonical path、device/inode、文件大小、完整前缀哈希与当前 leaf。
3. 追加一条 Pi 原生 entry。
4. `fsync` 文件与目录。
5. 重新读取尾部和 leaf；验证恰好新增一条预期 entry。
6. 发布对应事件。

任一步失败或发现外部变化，会话进入 `SESSION_READ_ONLY`，原因必须是 `external_write_conflict | append_unverified | lease_unavailable` 之一。客户端收到后禁止继续发送，直到手动刷新成功或用户重新打开。

### 6.2 `session/search`

请求：`{"query":"build","limit":50}`。结果：`{"sessions":[]}`。搜索标题、项目名和正文；不得阻塞流式事件线程超过 2 秒。

### 6.3 `session/create`

请求：

```json
{
  "title": "可选",
  "projectId": "proj_uuid",
  "mode": "agent",
  "permissionMode": "ask",
  "providerId": "provider_uuid",
  "modelId": "model-id",
  "thinkingLevel": "high",
  "context": {}
}
```

结果：`{"session":{}}`。Host 必须创建 Pi `SessionManager`，cwd 取项目路径。

### 6.4 `session/attach`

请求：`{"sessionId":"session-id"}`。结果：`{"session":{},"snapshot":{},"replayComplete":true}`。

### 6.5 `session/history`

请求：`{"sessionId":"session-id","beforeItemId":"optional","limit":100}`。`limit` 范围 1–200。

结果：`{"items":[],"hasMore":false,"revision":12}`。

### 6.6 `session/configure`

请求：

```json
{
  "sessionId": "session-id",
  "mode": "agent",
  "permissionMode": "ask",
  "providerId": "provider_uuid",
  "modelId": "model-id",
  "thinkingLevel": "high",
  "context": {}
}
```

结果：`{"session":{}}`。运行中会话允许修改未来 turn 的配置，但不得改变当前 turn 的 provider/model；权限模式变更从下一次工具调用开始生效。

### 6.7 `session/rename`

请求：`{"sessionId":"session-id","title":"新标题","context":{"requestId":"req","idempotencyKey":"key"}}`。结果：`{"session":{}}`。标题写入 Pi `session_info`。

### 6.8 `session/archive`

请求：`{"sessionId":"session-id","archived":true,"context":{"requestId":"req","idempotencyKey":"key"}}`。结果：`{"session":{}}`。归档是 Host 元数据，不修改 JSONL。

### 6.9 `session/branch`

请求：`{"sessionId":"session-id","fromItemId":"item-id","title":"optional","context":{"requestId":"req","idempotencyKey":"key"}}`。结果：`{"session":{}}`。新会话文件为 Pi v3 JSONL，父路径写入 `parentSession`；原会话不改。

### 6.10 `session/delete`

请求：`{"sessionId":"session-id","confirmSessionId":"session-id","context":{"requestId":"req","idempotencyKey":"key"}}`。结果：`{"deleted":true,"sessionId":"session-id"}`。

拒绝条件：运行中、有排队 turn、被其他活动会话引用、目标不匹配、JSONL 在校验后发生变化。

### 6.11 项目与会话 tombstone

Host 持久化 project tombstone 与 session archive tombstone。目录扫描只产生候选；被 tombstone 覆盖的原生目录/会话不得重新出现在主列表。恢复显式取消 tombstone 后才可重新注册。原生会话文件外部消失时，Host 将对应会话标记 `session.deleted` 并保留 tombstone，不重建。

## 7. 事件

### 7.1 订阅

`events/subscribe`：

```json
{"scope":"session","sessionId":"session-id","after":{"epoch":"e","sequence":41}}
```

结果：

```json
{"subscriptionId":"sub_uuid","starting":{"epoch":"e","sequence":42},"replayComplete":true}
```

`scope:"host"` 时忽略 `sessionId`。

`events/ack`：`{"subscriptionId":"sub_uuid","sequence":42}`。

游标无法满足时返回 `CURSOR_EXPIRED`；客户端必须调用 `session/attach` 或重新拉取目录。

订阅终态通知 `events/closed`：

```json
{"jsonrpc":"2.0","method":"events/closed","params":{"subscriptionId":"sub_uuid","code":"UNAUTHORIZED","message":"device revoked"}}
```

`notifications/initialized` 在握手结果后发送，`params` 为 `{}`；Host 收到前不得将连接标记为完全 online。

### 7.2 事件类型

每个事件 payload 同时含 `scope`、`kind`、`sessionId?`、`revision?`。

事件必须携带 durable cursor `{epoch, sequence}` 或 ephemeral `afterSequence`。所有 schema 定义的 payload 均为必填；客户端必须忽略未知 `kind` 并按 `resync.required` 处理连续无法理解的事件流。

| kind | scope | payload 必填 |
| --- | --- | --- |
| `turn.started` | session | `{turn}` |
| `item.delta` | session | `{itemId,itemType,delta}` |
| `item.completed` | session | `{item}` |
| `tool.started` | session | `{itemId,toolName,input}` |
| `tool.updated` | session | `{itemId,delta}` |
| `tool.completed` | session | `{itemId,status,result}` |
| `approval.requested` | session | `{approval}` |
| `approval.resolved` | session | `{approvalId,status}` |
| `input.requested` | session | `{input}` |
| `input.resolved` | session | `{inputId,status}` |
| `turn.completed` | session | `{turn}` |
| `turn.interrupted` | session | `{turn}` |
| `turn.failed` | session | `{turn,error}` |
| `session.changed` | host | `{session}` |
| `session.created` | host | `{session}` |
| `session.deleted` | host | `{sessionId}` |
| `host.changed` | host | `{revision,entities}` |
| `resync.required` | host | `{reason}` |

事件示例：

```json
{
  "jsonrpc": "2.0",
  "method": "events/event",
  "params": {
    "event": {
      "scope": "session",
      "kind": "item.delta",
      "sessionId": "session-id",
      "epoch": "e",
      "sequence": 43,
      "revision": 13,
      "payload": {
        "itemId": "item-id",
        "itemType": "message",
        "delta": "world"
      }
    }
  }
}
```

## 8. Turn、审批与输入

### 8.1 `turn/start`

```json
{
  "sessionId": "session-id",
  "admission": "reject_if_busy",
  "input": {
    "text": "检查构建",
    "attachments": ["att_uuid"],
    "messageId": "client-message-id"
  },
  "context": {"requestId":"req","idempotencyKey":"key"}
}
```

`admission`：`reject_if_busy`（默认）或 `queue`。结果：`{"turn":{}}`。

`attachments` 只能引用同会话、`ready`、总数 ≤10 的图片。单条消息所有图片的声明字节总和不得超过 200 MiB（209,715,200 bytes）。纯图片消息允许 `text:""`。

### 8.2 中断与取消

`turn/interrupt` 与 `turn/cancel`：`{"turnId":"turn_uuid","context":{"requestId":"req","idempotencyKey":"key"}}`。结果：`{"turn":{}}`。

重复中断已完成 turn 返回相同终态，不产生第二次执行。Host 未确认中断前，不得推送 `turn.interrupted`。

### 8.3 `approval/respond`

```json
{
  "approvalId": "approval_uuid",
  "decision": "allow-once",
  "permissionMode": "ask",
  "context": {"requestId":"req","idempotencyKey":"key","expectedRevision":14}
}
```

工具决策：`allow-once | allow-session | deny`。Plan/Goal 决策：`approve | reject`。

结果：`{"resolved":true,"alreadyResolved":false,"effectivePermissionMode":"ask"}`。

### 8.4 `input/respond`

```json
{
  "inputId": "input_uuid",
  "answers": [["选项 A"]],
  "context": {"requestId":"req","idempotencyKey":"key","expectedRevision":14}
}
```

结果：`{"resolved":true,"alreadyResolved":false}`。答案必须是该问题声明的选项。

## 9. Provider 与模型

### 9.1 Provider 视图

```json
{
  "id": "provider_uuid",
  "name": "DeepSeek",
  "vendorKey": "deepseek",
  "type": "openai_compatible",
  "protocol": "openai_compatible",
  "baseUrl": "https://api.deepseek.com/v1",
  "authKind": "api_key",
  "hasApiKey": true,
  "apiKeyMask": "sk-…1234",
  "isDefault": false,
  "models": [
    {
      "id": "deepseek-chat",
      "displayName": "DeepSeek Chat",
      "contextWindow": 1000000,
      "maxTokens": 393216,
      "thinkingLevels": ["off", "low", "high", "max"],
      "defaultThinkingLevel": "high",
      "supportsImages": false
    }
  ],
  "createdAt": "2026-10-30T00:00:00Z",
  "updatedAt": "2026-10-30T00:00:00Z"
}
```

### 9.2 `provider/list`

请求：`{}`。结果：`{"providers":[],"revision":1}`。任何密钥明文都不得出现。

### 9.3 `provider/create` / `provider/update`

请求：

```json
{
  "provider": {
    "name": "DeepSeek",
    "vendorKey": "deepseek",
    "type": "openai_compatible",
    "protocol": "openai_compatible",
    "baseUrl": "https://api.deepseek.com/v1",
    "authKind": "api_key",
    "apiKey": "temporary plaintext input",
    "models": []
  },
  "context": {}
}
```

`provider/update` 还需 `providerId`。`apiKey` 省略表示保留旧密钥，空字符串表示拒绝。结果：`{"provider":{}}`。

Host 不自动导入旧 `~/.pi-desktop` provider 或密钥；现有配置必须通过 iOS 重新导入或录入。响应和日志永远不得返回密钥明文。

v2 CRUD 首版只接受 `authKind: api_key | none`。若只读外部 provider 带 OAuth 凭据，可出现在列表中但不可由 v2 新建或修改。

`baseUrl` 出站策略：默认只允许 `https` 公网地址；拒绝 loopback、私网、链路本地、IPv6 映射私网、云元数据地址和重定向。DNS 解析结果必须固定到本次请求，连接时校验目标 IP 未变化。测试环境通过显式 allowlist 放行本地 mock。

### 9.4 `provider/delete`

请求：`{"providerId":"id","confirmProviderId":"id","context":{"requestId":"req","idempotencyKey":"key"}}`。结果：`{"deleted":true}`。若目标仍是默认项，Host 清空默认项但不自动选择替代项。

### 9.5 `provider/test` / `provider/discover`

请求：`{"providerId":"id"}`。`test` 结果：`{"ok":true,"checkedAt":"..."}` 或失败码。`discover` 结果：`{"models":[]}`，仅返回发现结果，必须由客户端显式保存后才改变 provider。

## 10. Skill 管理

### 10.1 Skill 视图

```json
{
  "id": "skill_uuid",
  "name": "example",
  "description": "Example skill",
  "source": {
    "type": "git",
    "url": "https://github.com/example/skills.git",
    "subdir": "example",
    "ref": "main",
    "refType": "branch"
  },
  "installedAt": "2026-10-30T00:00:00Z",
  "updatedAt": "2026-10-30T00:00:00Z",
  "status": "ready",
  "path": "/home/user/.pi/agent/skills/example"
}
```

`source.type`：`git | directory`。本地目录来源必须有 `path`；Git 来源必须有 `url`，可选 `subdir` 与 `ref`。

### 10.2 操作

- `skill/list`：`{}` → `{"skills":[]}`
- `skill/get`：`{"skillId":"id"}` → `{"skill":{},"instructions":"SKILL.md body"}`
- `skill/install`：`{"source":{},"replace":false,"context":{"requestId":"req","idempotencyKey":"key"}}` → `{"skill":{}}`
- `skill/update`：`{"skillId":"id","source":{},"context":{"requestId":"req","idempotencyKey":"key"}}` → `{"skill":{}}`
- `skill/delete`：`{"skillId":"id","confirmSkillId":"id","context":{"requestId":"req","idempotencyKey":"key"}}` → `{"deleted":true}`

Git 操作必须使用受控子进程、超时、目录边界和来源 URL 白名单。失败或结果不确定必须显式返回，不能伪装成功。

Git 来源只允许公开 HTTPS URL；拒绝私网/回环/链路本地目标和重定向。本地目录来源必须解析 realpath 并位于配置的允许根目录（默认当前服务器用户 home）内，拒绝符号链接逃逸。

安装/更新顺序：

1. 下载或复制到 staging。
2. 验证 `SKILL.md`、来源不可变 commit 或内容哈希、路径边界和符号链接逃逸。
3. 发布到不可变版本目录。
4. 原子切换 Host 指针。
5. 更新 registry。

每个新 turn 开始前调用 `resourceLoader.reload()`。运行中的 turn 使用启动时解析的 Skill 版本；reload 失败时该 turn 以明确错误终止，不得静默使用旧版本。

## 11. 图片

### 11.1 上传

`attachment/create`：

```json
{
  "sessionId": "session-id",
  "fileName": "photo.jpg",
  "mimeType": "image/jpeg",
  "byteLength": 12345,
  "sha256": "64 hex chars",
  "context": {}
}
```

结果：`{"attachmentId":"att_uuid","chunkSize":524288,"expiresAt":"..."}`。

`attachment/chunk`：

```json
{"attachmentId":"att_uuid","offset":0,"dataBase64":"...","context":{"requestId":"req","idempotencyKey":"key"}}
```

结果：`{"receivedBytes":12345}`。offset 必须连续；重复同 offset + 同内容返回已接收字节数。

`attachment/complete`：

```json
{"attachmentId":"att_uuid","sha256":"64 hex chars","context":{"requestId":"req","idempotencyKey":"key"}}
```

结果：`{"attachment":{}}`。长度或哈希不符时返回 `ATTACHMENT_INVALID` 并删除临时文件。

### 11.2 读取

`attachment/read`：`{"attachmentId":"att_uuid","offset":0,"length":262144}`。

结果：`{"attachment":{},"offset":0,"dataBase64":"...","eof":false}`。

### 11.3 边界与清理

- 原始文件字节 ≤ 20 MiB（20,971,520 bytes）。
- 每条消息 ≤ 10 张；只接受 `image/jpeg`、`image/png`、`image/webp`。
- 单条消息图片声明总字节 ≤ 200 MiB；staging 总量 ≤ 1 GiB/用户，超过时返回 `PAYLOAD_TOO_LARGE`。
- 解码后像素总数 ≤ 100,000,000；超过时返回 `ATTACHMENT_INVALID`。
- 必须校验文件魔数，不信任客户端 MIME。WebP 动图只解码首帧。
- 未完成上传 1 小时后失效；孤儿 blob 24 小时内清理。
- 删除会话时删除无其他引用的 blob；仍有引用的 blob 保留。
- 输出图片以 `image` item 引用 `attachmentId`，不以 base64 持久化。
- 提交顺序必须是：发布不可变 blob → 标记 attachment `ready` → 追加消息引用 → 发事件。消息追加失败时产生无引用 ready blob，由 24 小时保护窗后的 GC 清理。
- GC 以已提交 JSONL/消息中的媒体引用为权威来源，引用计数仅为派生缓存；每次删除前重新扫描引用并应用 24 小时保护窗。

## 12. 错误模型

标准 JSON-RPC 错误码：

- `-32700` parse error
- `-32600` invalid request
- 这两类响应允许 `id:null`，不携带 `error.data`；其余错误必须带 `error.data.code`。
- `-32601` method not found
- `-32602` invalid params
- `-32603` internal error

应用错误使用 `-32000..-32099`，业务码放在 `error.data.code`：

| numeric | code | 状态上下文 | 可重试 |
| --- | --- | --- | --- |
| `-32001` | `UNAUTHORIZED` | 令牌缺失/无效/撤销 | 否 |
| `-32002` | `FORBIDDEN` | 角色不足 | 否 |
| `-32003` | `PROTOCOL_MISMATCH` | 协议或 schema 不一致 | 否 |
| `-32004` | `INVALID_ARGUMENT` | 参数/schema 失败 | 否 |
| `-32005` | `NOT_FOUND` | 目标不存在 | 否 |
| `-32006` | `CONFLICT` | revision/状态冲突 | 是 |
| `-32007` | `IDEMPOTENCY_CONFLICT` | 同 key 不同参数 | 否 |
| `-32008` | `CURSOR_EXPIRED` | 游标过期 | 是（需快照） |
| `-32009` | `CLIENT_TOO_SLOW` | 订阅积压 | 是（需重订阅） |
| `-32010` | `PAYLOAD_TOO_LARGE` | 帧或参数超限 | 否 |
| `-32011` | `APPROVAL_EXPIRED` | 审批已失效 | 否 |
| `-32012` | `APPROVAL_STALE` | revision 不匹配 | 是（重新拉取） |
| `-32013` | `SESSION_BUSY` | 会话运行中/有队列 | 否 |
| `-32014` | `SESSION_READ_ONLY` | 会话损坏/不支持/外部占用 | 否 |
| `-32015` | `PROVIDER_NOT_CONFIGURED` | 目标 provider/model 不可用 | 否 |
| `-32016` | `PROVIDER_SECRET_MISSING` | 密钥缺失 | 否 |
| `-32017` | `PROVIDER_IN_USE` | 运行中会话使用中 | 是 |
| `-32018` | `SKILL_SOURCE_UNAVAILABLE` | Git/目录不可达 | 是 |
| `-32019` | `SKILL_CONFLICT` | 同名安装冲突 | 否 |
| `-32020` | `ATTACHMENT_INVALID` | 类型/尺寸/哈希失败 | 否 |
| `-32021` | `ATTACHMENT_INCOMPLETE` | 上传未完成 | 是 |
| `-32022` | `AGENT_RESTARTED` | 进程重启导致 turn 不确定 | 否 |
| `-32023` | `DEVICE_NOT_FOUND` | 设备记录不存在或已清除 | 否 |
| `-32024` | `RATE_LIMITED` | 请求限流 | 是 |
| `-32025` | `PAIRING_FAILED` | 配对令牌无效或已使用 | 否 |
| `-32026` | `PAIRING_TOKEN_EXPIRED` | 配对令牌过期 | 否 |
| `-32000` | `INTERNAL` | 未分类服务端错误 | 是（一次） |

错误 `data` 可包含 `requestId`、`field`、`currentRevision`、`retryAfterMs`；不得包含密钥或文件内容。

## 13. 版本与兼容

1. `2.0.0` 为大版本；`connection/initialize` 必须精确匹配，否则返回 `PROTOCOL_MISMATCH`。
2. 新增可选字段属于小版本；客户端必须忽略未知字段。
3. 删除/改名/类型变更属于大版本。
4. Host 必须同时公布 `capabilities`；客户端不能通过 `METHOD_NOT_FOUND` 才推断核心能力。
5. 旧 v1 Host 不满足本契约；iOS 必须依据子协议或握手失败给出明确升级提示。
6. Host 记录、Keychain account 与 iOS SQLite 复合键必须包含协议大版本；v1 与 v2 Host 不得共享事件游标、缓存主键或设备令牌。
7. Host 进程重启后必须更换事件 `epoch`；未完成 turn 先确认/终止旧进程组。能证明已停止且未产生后续输出时标记 `interrupted`，否则标记 `uncertain` 并带 `settledReason:"agent_restarted_unconfirmed"`；不得自动续跑。

## 14. 验收标准映射

| AC | 操作 / 事件 | 主要验证 |
| --- | --- | --- |
| AC-01 | 全链路 | Ubuntu aarch64 隔离安装 + create/start/events |
| AC-02 | 仓库结构 | `仓库根`、`docs/api` 文件检查 |
| AC-03 | 握手/文档 | `piVersion:1.3.0`、无 v1 兼容声明 |
| AC-04 | `skill/install`、`skill/list`、`turn/start` | 真实本地 Git fixture + reload |
| AC-05 | `skill/install`（directory） | 临时目录安装 + reload |
| AC-06 | `skill/update`、`skill/delete` | 版本目录/指针测试 |
| AC-07 | Skill 错误码 | 不可达/冲突/失败注入 |
| AC-08 | `session/list`、`session/get` | 真实 Pi JSONL 扫描 |
| AC-09 | `turn/start`、事件、`session/attach` | 原版 Pi/Host 双向续写 |
| AC-10 | `project/*`、`session/create`、`turn/start` | 临时项目 E2E |
| AC-11 | `item.delta`、`tool.*` | 流式事件断言 |
| AC-12 | `turn/interrupt` | 确认前后状态与幂等 |
| AC-13 | `provider/create`、`provider/list` | 跨进程重启查询 |
| AC-14 | `provider/update`、`turn/start` | 密钥替换与解析快照 |
| AC-15 | `provider/delete` | 删除矩阵/密钥清除 |
| AC-16 | provider 视图/日志 | Key canary |
| AC-17 | provider 错误码 | 超时/不确定响应 |
| AC-18 | `session/configure`、审批 | ask/auto 行为矩阵 |
| AC-19 | `approval/respond` | allow-once/session/deny |
| AC-20 | `attachment/*`、`turn/start` | JPEG/PNG/WebP 正常路径 |
| AC-21 | `attachment/create`/`complete` | 20 MiB、20 MiB+1、10/11 张 |
| AC-22 | `attachment/read`、image item | 输出读取/保存句柄 |
| AC-23 | `session/delete`、GC | 引用扫描/24 小时保护窗 |
| AC-24 | turn/事件 | 断线后服务器继续执行 |
| AC-25 | cursor/replay/snapshot | 重连补齐与缺口回退 |
| AC-26 | `approval.requested/resolved` | 审批跨重连 |
| AC-27 | SessionManager | 真实 Pi 双向互操作矩阵 |
| AC-28 | writer actor/lease | 外写与 SIGKILL 注入 |
| AC-29 | attachment 状态机 | 崩溃点事务测试 |
| AC-30 | Skill 版本/reload | 运行中固定、新 turn 更新 |
| AC-31 | `device/list`、`connection/revoke` | 双设备撤销与 socket 关闭 |

## 15. 冻结检查清单

- [x] schema 覆盖所有方法和事件；正反 golden fixture 覆盖错误码、18 类事件、幂等 context 与 provider 条件
- [x] 每个写操作都有幂等/确认规则
- [x] 错误码覆盖校验、鉴权、不存在、冲突、资源超限和服务端失败
- [x] 图片与密钥不会泄漏到日志
- [x] 原生 Pi 双向互操作与外部写入/SIGKILL 注入有自动化测试计划
- [x] 设备撤销会关闭活跃连接
- [x] Skill 版本目录与逐 turn reload 语义可验证
- [x] v1/v2 协议代际隔离写入验收
- [x] `advisor` 三轮阻塞项已处置；最终自动化契约门禁通过
- [x] 规格 AC-01 至 AC-31 均可映射到操作、事件和测试

