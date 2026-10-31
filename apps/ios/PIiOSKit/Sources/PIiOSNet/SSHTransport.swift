import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - 凭证

/// SSH 用户凭证。密码与私钥都只放在内存里，落盘一律走 Keychain（spec AC-G4）。
///
/// 私钥可以带口令（spec E6）：`passphrase` 只在解密 `openssh-key-v1` 容器时用一次，
/// 任何对外描述都不包含它（AC-G2）。
public enum SSHCredential: Sendable, Equatable {
    case password(String)
    /// OpenSSH 私钥文本；`passphrase` 为 `nil` 表示未加密私钥。
    case privateKey(openSSHText: String, passphrase: String?)

    /// 未加密私钥的便捷构造（保持旧调用点可读）。
    public static func privateKey(openSSHText: String) -> SSHCredential {
        .privateKey(openSSHText: openSSHText, passphrase: nil)
    }

    /// 只用于日志/界面：绝不包含凭证内容（spec AC-G2）。
    public var redactedDescription: String {
        switch self {
        case .password: return "密码认证（内容已隐藏）"
        case .privateKey(_, let passphrase): return passphrase == nil ? "私钥认证（内容已隐藏）" : "私钥认证（带口令，内容已隐藏）"
        }
    }
}

// MARK: - 错误

public enum SSHTransportError: Error, Equatable, CustomStringConvertible {
    case invalidPrivateKey(String)
    case hostKeyUnreadable
    case hostKeyRejected(fingerprint: String)
    /// 服务器没有提供本机接受的主机密钥算法（典型：只支持 ssh-rsa）。
    case hostKeyAlgorithmUnsupported
    case authenticationFailed
    case timedOut(String)
    case channelClosed
    /// 对端在握手/转发阶段直接关闭了连接（NIO `ChannelError.eof` 等）。
    /// 之前这类错误会以 `NIOCore.ChannelError错误9` 的原文出现在界面上，看不出该查什么。
    case closedByPeer(phase: String)
    /// 服务器拒绝打开转发通道：目标回环端口上没有服务在监听（pi-host 未启动或端口不符）。
    case tunnelRefused(phase: String, detail: String)
    /// 其它网络层失败（不可达、地址无效等），保留原始描述用于排查。
    case networkFailure(phase: String, detail: String)


    public var description: String {
        switch self {
        case .invalidPrivateKey(let detail):
            return detail
        case .hostKeyUnreadable:
            return "服务器送来的主机公钥无法解析，已中止连接"
        case .hostKeyRejected(let fingerprint):
            return "已拒绝连接：主机指纹 \(fingerprint) 未经确认或与固定记录不一致"
        case .hostKeyAlgorithmUnsupported:
            return "握手失败：服务器只提供 ssh-rsa（SHA-1）主机密钥，本机按安全策略不接受。"
                + "请在服务器上启用 rsa-sha2-256 / rsa-sha2-512（OpenSSH 7.2+ 默认启用，"
                + "检查 /etc/ssh/sshd_config 的 HostKeyAlgorithms），或改用 ed25519 / ECDSA 主机密钥。"
                + "不会静默降级到 ssh-rsa。"
        case .authenticationFailed:
            return "认证失败：用户名、密码、私钥或口令与服务端不匹配"
        case .timedOut(let phase):
            return "连接超时：\(phase)"
        case .channelClosed:
            return "SSH 通道已关闭"
        case .closedByPeer(let phase):
            return "服务器在「\(phase)」阶段直接关闭了连接（EOF）。"
                + "常见原因：SSH 端口填成了 pi-host 的端口；sshd 未运行或被防火墙拦在中间；"
                + "服务器限流（MaxStartups）或正在重启；账号被 sshd 拒绝（DenyUsers / AllowUsers）。"
                + "先在另一台机器上用 `ssh -v 用户@地址 -p 端口` 确认能登录，再来连。"
        case .tunnelRefused(let phase, let detail):
            return "「\(phase)」被服务器拒绝：目标端口上没有服务在监听（\(detail)）。"
                + "这通常表示 pi-host 没在跑，或设置里的 pi-host 端口与服务实际端口不一致："
                + "在服务器上执行 `ss -ltn | grep <端口>` 确认；"
                + "pi-host 用 `--port 0` 启动时端口是随机的，需要用固定端口（如 `--port 33381`）重启后才能长期连接。"
        case .networkFailure(let phase, let detail):
            return "「\(phase)」网络失败：\(detail)。检查地址与端口、手机网络/VPN，以及服务器防火墙是否放行该端口。"
        }
    }
}

// MARK: - 连接参数

public struct SSHConnectionRequest: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential
    /// 已固定的主机公钥；`nil` 表示首次连接（必须问用户，AC-02.1）。
    public var pinnedHostKey: SSHHostKey?

    public init(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        pinnedHostKey: SSHHostKey?
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.pinnedHostKey = pinnedHostKey
    }
}

/// `exec` 通道的执行结果（契约 §4.1 provider-import / §5 bootstrap 都靠它读 stdout）。
public struct SSHExecResult: Sendable, Equatable {
    public let exitStatus: Int
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

// MARK: - 传输层

/// 一条 SSH 连接：TOFU 校验主机指纹、密码/私钥认证、`exec` 通道与 `direct-tcpip` 转发。
///
/// 依据契约 §2.1：客户端必须自己实现 SSH exec 与 `direct-tcpip`，不得依赖系统 `ssh`——
/// 这里用的是 Apple 官方 `swift-nio-ssh`（纯 Swift）。
public final class SSHTransport {
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    private let handler: NIOSSHHandler
    public private(set) var presentedHostKey: SSHHostKey?

    private init(
        channel: Channel,
        group: MultiThreadedEventLoopGroup,
        handler: NIOSSHHandler,
        presentedHostKey: SSHHostKey?
    ) {
        self.channel = channel
        self.group = group
        self.handler = handler
        self.presentedHostKey = presentedHostKey
    }

    /// 建立 SSH 连接并完成握手 + 认证。
    ///
    /// 主机指纹在握手期间就完成判定：`.reject` 会让握手失败，不存在「先连上再问」的路径。
    public static func connect(
        _ request: SSHConnectionRequest,
        confirmer: any HostKeyConfirming,
        timeout: TimeInterval = 20
    ) async throws -> SSHTransport {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        func remainingBudget() -> TimeInterval {
            max(0.1, deadline.timeIntervalSinceNow)
        }
        // 私钥先本地解析一次：格式/类型不支持要在联网前就报错，不能等到握手里只显示「认证失败」。
        if case let .privateKey(text, passphrase) = request.credential {
            do {
                _ = try SSHPrivateKeyParser.parse(openSSHPrivateKey: text, passphrase: passphrase)
            } catch let error as SSHPrivateKeyError {
                throw SSHTransportError.invalidPrivateKey(error.description)
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let presentedBox = PresentedKeyBox()
        let verifier = HostKeyVerifier(
            pinned: request.pinnedHostKey,
            confirmer: confirmer,
            onPresented: { presentedBox.set($0) }
        )
        let authDelegate = CredentialAuthDelegate(
            username: request.username,
            credential: request.credential
        )

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(remainingBudget() * 1_000)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(
                            SSHClientConfiguration(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: verifier
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: request.host, port: request.port).get()
        } catch {
            try? await group.shutdownGracefully()
            throw Self.mapTransportError(error, phase: "建立 TCP 连接")
        }

        do {
            let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            let transport = SSHTransport(
                channel: channel,
                group: group,
                handler: handler,
                presentedHostKey: presentedBox.value
            )
            // 握手 + 认证完成的判据：能力激活后才可能开出第一个子通道。这里开一个空 session
            // 通道再立刻关闭，作为「已可认证并可用」的探针；随后 createChannel 都不会再等握手。
            try await transport.probeActivation(timeout: remainingBudget())
            transport.presentedHostKey = presentedBox.value
            return transport
        } catch {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw Self.mapTransportError(error, phase: "SSH 握手与认证")
        }
    }

    /// 把 NIOSSH 的握手错误翻译成用户能看懂、能动手解决的原因。
    ///
    /// 最关键的一条：服务器只提供 `ssh-rsa`（SHA-1）主机密钥时，协商会失败成
    /// `keyExchangeNegotiationFailure`——必须明说原因与修复办法，不能只显示「连接失败」。
    private static func mapHandshakeError(_ error: Error) -> Error {
        guard let sshError = error as? NIOSSHError else { return error }
        switch sshError.type {
        case .keyExchangeNegotiationFailure, .invalidHostKeyForKeyExchange:
            return SSHTransportError.hostKeyAlgorithmUnsupported
        case .invalidExchangeHashSignature:
            return SSHTransportError.hostKeyRejected(fingerprint: "（主机公钥签名校验失败）")
        default:
            return error
        }
    }
    /// 网络层错误 → 可执行的中文原因（原来的 `NIOCore.ChannelError错误9` 直接显示给用户）。
    ///
    /// 先交给 NIOSSH 专用映射（ssh-rsa 主机密钥、签名校验等），再处理 NIO 的 `ChannelError`：
    /// - `eof` / `inputClosed` / `outputClosed` / `alreadyClosed` / `ioOnClosedChannel` → 对端关闭；
    /// - `connectTimeout` → 本机侧超时；
    /// - 其它 → 网络失败并保留原始描述。
    static func mapTransportError(_ error: Error, phase: String) -> Error {
        if let sshMapped = mapHandshakeError(error) as? SSHTransportError {
            return sshMapped
        }
        if let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
            // 服务器拒绝转发：目标回环端口没人监听。这是 pi-host 未启动/端口不符的典型症状。
            return SSHTransportError.tunnelRefused(phase: phase, detail: sshError.description)
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .inputClosed, .outputClosed, .alreadyClosed, .ioOnClosedChannel:
                return SSHTransportError.closedByPeer(phase: phase)
            case .connectTimeout:
                return SSHTransportError.timedOut(phase)
            default:
                return SSHTransportError.networkFailure(phase: phase, detail: String(describing: channelError))
            }
        }
        return error
    }
    /// 关闭连接（幂等）。
    public func close() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    // MARK: exec

    /// 打开 `exec` 通道执行命令，返回 stdout / stderr / 退出码。
    public func exec(
        _ command: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> SSHExecResult {
        var openChildChannel: Channel?
        do {
            return try await withTimeout(seconds: timeout, phase: "执行远端命令") {
                let collector = ExecCollector()
                let childChannel = try await self.createChannel(channelType: .session) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(collector)
                    }
                }
                openChildChannel = childChannel
                let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                childChannel.triggerUserOutboundEvent(execRequest).whenFailure { _ in }
                if let stdin {
                    var buffer = childChannel.allocator.buffer(capacity: stdin.count)
                    buffer.writeBytes(stdin)
                    try await childChannel.writeAndFlush(buffer).get()
                    try await childChannel.close(mode: .output).get()
                }
                let exitStatus = try await collector.exitStatus()
                try? await childChannel.close().get()
                openChildChannel = nil
                return SSHExecResult(
                    exitStatus: exitStatus,
                    stdout: await collector.stdoutData(),
                    stderr: await collector.stderrData()
                )
            }
        } catch {
            if let openChildChannel {
                try? await openChildChannel.close().get()
            }
            throw Self.mapTransportError(error, phase: "执行远端命令")
        }
    }

    // MARK: direct-tcpip

    /// 打开 `direct-tcpip` 通道转发到服务器回环地址上的 `127.0.0.1:<port>`（契约 §2.1）。
    ///
    /// 返回的通道收发 `ByteBuffer`：入站 `SSHChannelData(channel)` 已转成字节，出站字节已包成 SSH 帧。
    public func directTCPIP(
        toRemoteHost remoteHost: String = "127.0.0.1",
        port: Int,
        timeout: TimeInterval = 15
    ) async throws -> Channel {
        let originator = channel.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
        guard let originator else { throw SSHTransportError.channelClosed }
        do {
            return try await withTimeout(seconds: timeout, phase: "打开 direct-tcpip 通道") {
                try await self.createChannel(
                    channelType: .directTCPIP(
                        .init(
                            targetHost: remoteHost,
                            targetPort: port,
                            originatorAddress: originator
                        )
                    )
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteStreamHandler())
                    }
                }
            }
        } catch {
            throw Self.mapTransportError(error, phase: "打开 direct-tcpip 通道（目标 \(remoteHost):\(port)）")
        }
    }

    // MARK: 内部

    private func createChannel(
        channelType: SSHChannelType,
        initializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            self.handler.createChannel(promise, channelType: channelType) { childChannel, _ in
                initializer(childChannel)
            }
        }
        return try await promise.futureResult.get()
    }

    private func probeActivation(timeout: TimeInterval) async throws {
        let probe = try await withTimeout(seconds: timeout, phase: "SSH 握手与认证") {
            try await self.createChannel(channelType: .session) { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
        }
        try? await probe.close().get()
    }
}

// MARK: - 握手期的主机指纹判定

private final class PresentedKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SSHHostKey?

    func set(_ key: SSHHostKey) {
        lock.lock()
        stored = key
        lock.unlock()
    }

    var value: SSHHostKey? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let pinned: SSHHostKey?
    private let confirmer: any HostKeyConfirming
    private let onPresented: @Sendable (SSHHostKey) -> Void

    init(
        pinned: SSHHostKey?,
        confirmer: any HostKeyConfirming,
        onPresented: @escaping @Sendable (SSHHostKey) -> Void
    ) {
        self.pinned = pinned
        self.confirmer = confirmer
        self.onPresented = onPresented
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented: SSHHostKey
        do {
            presented = try SSHHostKey(nioKey: hostKey)
        } catch {
            validationCompletePromise.fail(SSHTransportError.hostKeyUnreadable)
            return
        }
        onPresented(presented)
        let status = HostKeyTrust.evaluate(presented: presented, pinned: pinned)
        let confirmer = self.confirmer
        Task {
            let confirmation = await confirmer.confirmHostKey(presented, status: status)
            switch confirmation {
            case .trust:
                validationCompletePromise.succeed(())
            case .reject:
                validationCompletePromise.fail(
                    SSHTransportError.hostKeyRejected(fingerprint: presented.fingerprint)
                )
            }
        }
    }
}

private final class CredentialAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let credential: SSHCredential
    private var attemptedPassword = false
    private var attemptedKey = false

    init(username: String, credential: SSHCredential) {
        self.username = username
        self.credential = credential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        switch credential {
        case let .password(password):
            guard !attemptedPassword, availableMethods.contains(.password) else {
                nextChallengePromise.succeed(nil)
                return
            }
            attemptedPassword = true
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )
        case let .privateKey(text, passphrase):
            guard !attemptedKey, availableMethods.contains(.publicKey) else {
                nextChallengePromise.succeed(nil)
                return
            }
            attemptedKey = true
            do {
                let key = try SSHPrivateKeyParser.parse(openSSHPrivateKey: text, passphrase: passphrase)
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(privateKey: key))
                    )
                )
            } catch let error as SSHPrivateKeyError {
                nextChallengePromise.fail(SSHTransportError.invalidPrivateKey(error.description))
            } catch {
                nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            }
        }
    }
}

// MARK: - 通道 Handler

/// `exec` 通道：收集 stdout / stderr 与退出码。
private final class ExecCollector: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int?
    private var waiters: [CheckedContinuation<Int, Error>] = []
    private var failure: Error?

    func exitStatus() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
                return
            }
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func stdoutData() async -> Data { stdoutSnapshot() }

    func stderrData() async -> Data { stderrSnapshot() }

    // Locking is confined to synchronous helpers so the async accessors above
    // never call `NSLock` from an async context (a Swift 6 error).
    private func stdoutSnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }

    private func stderrSnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = frame.data else { return }
        let bytes = Data(buffer.readableBytesView)
        lock.lock()
        switch frame.type {
        case .channel: stdout.append(bytes)
        case .stdErr: stderr.append(bytes)
        default: break
        }
        lock.unlock()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            finish(with: .success(exit.exitStatus))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: .failure(SSHTransportError.channelClosed))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: .failure(error))
        context.close(promise: nil)
    }

    private func finish(with result: Result<Int, Error>) {
        lock.lock()
        if status != nil || failure != nil {
            lock.unlock()
            return
        }
        switch result {
        case .success(let value):
            status = value
        case .failure(let error):
            failure = error
        }
        let waiters = self.waiters
        self.waiters = []
        let status = self.status
        let failure = self.failure
        lock.unlock()
        for waiter in waiters {
            if let status {
                waiter.resume(returning: status)
            } else {
                waiter.resume(throwing: failure ?? SSHTransportError.channelClosed)
            }
        }
    }
}

/// `direct-tcpip` 通道：把 SSH 通道数据变成普通字节流（WebSocket 层直接在这上面搭）。
private final class ByteStreamHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = frame.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

// MARK: - 超时辅助

/// 把任意 async 操作套一个截止时间（契约 §2.2 的 10 秒握手、bootstrap 的 30 秒都靠它）。
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    phase: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let state = TimeoutRaceState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.install(continuation)
            let bodyTask = Task {
                do {
                    state.resolve(.success(try await body()))
                } catch {
                    state.resolve(.failure(error))
                }
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
                state.resolve(.failure(SSHTransportError.timedOut(phase)))
            }
            state.register([bodyTask, timeoutTask])
        }
    } onCancel: {
        state.resolve(.failure(CancellationError()))
    }
}

/// Resolve exactly once without waiting for a non-cancellable body task when the deadline wins.
private final class TimeoutRaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var completed = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let settled {
            lock.unlock()
            continuation.resume(with: settled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func register(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if completed {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        if continuation == nil {
            settled = result
        }
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
