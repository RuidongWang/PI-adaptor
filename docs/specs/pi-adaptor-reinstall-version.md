# Spec: 重装后必须安装并运行配置指定的 PI-adaptor

## 背景

用户重新安装 Host 后，远端仍在运行旧版 `pi-host`，没有切换到当前配置指定版本的 PI-adaptor。现有代码同时保留两套命名、目录、服务与 release 坐标：

- `host-release.json` 仍描述 `pi-host 0.21.0+remove.1`。
- iOS bootstrap 仍写入 `~/.pi-desktop/pi-host`，安装 `pi-host.js`，启动 `pi-host.service`。
- PI-adaptor 的当前包版本是 `0.0.1`，安装根为 `~/.pi-adaptor`，服务为 `pi-adaptor.service`。
- 端口探测和界面错误文案仍把 legacy `pi-host` 当作主要安装目标。

因此，即使下载、校验或激活步骤显示成功，结果也可能只是复用旧目录、旧 unit 或旧进程。

## 用户故事

- US-1：作为 PI-IOS 用户，我希望重新安装时始终下载并运行当前配置指定的 PI-adaptor 版本，避免界面显示成功但实际仍连接旧 Host。
- US-2：作为维护者，我希望所有版本、产物名、安装目录和服务名来自同一个当前 release 配置，版本未发布、字节不一致或旧坐标混入时在安装前失败。
- US-3：作为已有旧 Host 的用户，我希望安装完成前能看到“正在运行的就是目标 PI-adaptor”的确定证据；若实际版本不匹配，流程必须失败并保留可诊断信息。

## 验收标准

### 单一版本与发布坐标

- AC-1 Given App 内置或读取了当前 PI-adaptor release 配置，When 用户打开安装或强制重装页面，Then 页面展示的版本、iOS 生成的下载 URL、checksum URL、资产名、解包目录和服务版本均来自该配置，且均为当前 PI-adaptor 版本；验证方式：自动化测试。
- AC-1.1 Given `host-release.json`、PI-adaptor `package.json` 与 iOS 内置 release 常量任一发生版本或发布坐标漂移，When 运行发布一致性测试，Then 测试失败并明确指出漂移字段；验证方式：自动化测试。
- AC-1.2 Given 当前配置指定 `0.0.1`，When 生成安装脚本，Then 不得出现 `pi-host 0.21.0+remove.1` 的下载地址、资产名、解包目录或作为安装目标的 `pi-host.js`；验证方式：自动化测试。

### 重装与复用

- AC-2 Given 服务器曾安装 legacy 目录 `~/.pi-desktop/pi-host` 或运行 legacy `pi-host.service`，When 用户执行 PI-adaptor 安装或强制重装，Then 安装根为配置约定的独立 PI-adaptor 根，激活文件为其中 `current/dist/main.js`，不得把 legacy `current/pi-host.js` 当作已经安装目标；验证方式：脚本集成测试。
- AC-2.1 Given PI-adaptor 本地 receipt 记录的版本或摘要与当前配置不一致，When 执行普通重装，Then 不信任该 receipt，必须重新下载、校验并激活当前配置对应资产；验证方式：脚本集成测试。
- AC-2.2 Given PI-adaptor receipt 版本相同但当前资产摘要发生变化，When 用户勾选强制重装，Then 即使 receipt 存在也必须重新下载、校验并原子激活；验证方式：脚本集成测试。
- AC-2.3 Given 旧版或旧命名的 manual process/unit 占用目标端口，When 新 PI-adaptor 尝试启动，Then App 不得把旧进程的连接成功当作安装成功，并应返回可识别的端口/服务冲突错误；验证方式：脚本集成测试与手动检查。

### 服务与启动

- AC-3 Given 当前配置指定 PI-adaptor 版本 V，When 安装进入写 unit 阶段，Then unit 名称为 `pi-adaptor.service`，其 `ExecStart` 指向 PI-adaptor 根下的 `current/dist/main.js`，并通过环境变量或随包 manifest 报告版本 V；验证方式：自动化测试。
- AC-3.1 Given 安装完成，When App 查询 Host 状态，Then 只把 `pi-adaptor.service` 的 active 状态作为服务就绪依据，不得再以 `pi-host.service` 的 active 状态证明安装成功；验证方式：自动化测试与手动检查。
- AC-3.2 Given 安装结束且设备验证通过，When 客户端读取 `connection/initialize` 的 server info，Then `server.name` 为 `pi-adaptor` 且 `server.version` 与当前配置版本完全一致；不一致时流程必须失败；验证方式：端到端测试。

### 重装后的连接与可观测性

- AC-4 Given 已有旧端口、旧 Keychain 配对或旧本机安装回执，When 用户重装当前 PI-adaptor，Then App 不得复用旧 Host 的设备令牌来宣称新安装成功，并应在完成新配对和设备验证后更新记录；验证方式：自动化测试与手动检查。
- AC-4.1 Given 重装成功，When 用户打开设置或查看安装日志，Then 可见当前 PI-adaptor 版本、`pi-adaptor.service`、实际端口和激活路径；验证方式：手动检查。
- AC-4.2 Given 重装任一校验失败，When 用户查看结果，Then 错误信息包含失败阶段、期望版本和实际不匹配项，且不报告“安装成功”；验证方式：自动化测试与手动检查。

### 回归保护

- AC-5 Given 当前版本是 `0.0.1`，When 运行 Host 与 iOS 的测试套件，Then 不得有测试继续断言旧 `pi-host 0.21.0+remove.1` 是本 App 的默认安装目标；legacy 兼容测试若保留，必须明确标注 legacy 且不能进入默认安装路径；验证方式：自动化测试。
- AC-5.1 Given 安装被中断或旧服务仍在运行，When 重新进入安装页，Then 状态机可依据最终激活资产和运行时 server info 恢复或重新安装，并以实际目标版本为准；验证方式：脚本集成测试。

## 非目标

- 不改变 RACP v2 的 wire protocol 或 PI-adaptor 的会话、Provider、Skill 功能。
- 不删除用户未经确认的会话、Provider、密钥或个人数据。
- 不要求清理 PI-Desktop legacy Host 的全部历史状态；legacy 兼容可以保留，但不得作为默认安装或成功证明。
- 不改变 release 资产的内容和部署拓扑；本需求聚焦版本坐标、安装根、服务选择、重装语义与运行时校验。

## 开放问题

无。
