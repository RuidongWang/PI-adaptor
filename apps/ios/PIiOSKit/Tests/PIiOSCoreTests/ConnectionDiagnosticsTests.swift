import XCTest
@testable import PIiOSCore

final class ConnectionDiagnosticsTests: XCTestCase {
    // MARK: - systemd unit 状态

    func testParsesActiveUnit() throws {
        let snapshot = try HostUnitSnapshotParser.parse(
            """
            LoadState=loaded
            ActiveState=active
            UnitFileState=enabled
            """
        )

        XCTAssertEqual(snapshot.loadState, "loaded")
        XCTAssertEqual(snapshot.activeState, "active")
        XCTAssertEqual(snapshot.unitFileState, "enabled")
        XCTAssertTrue(snapshot.isActive)
    }

    func testParsesInactiveUnit() throws {
        let snapshot = try HostUnitSnapshotParser.parse(
            "LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled"
        )

        XCTAssertEqual(snapshot.activeState, "inactive")
        XCTAssertEqual(snapshot.unitFileState, "disabled")
        XCTAssertFalse(snapshot.isActive)
    }

    func testParsesFailedUnit() throws {
        let snapshot = try HostUnitSnapshotParser.parse(
            "LoadState=loaded\nActiveState=failed\nUnitFileState=enabled"
        )

        XCTAssertEqual(snapshot.activeState, "failed")
        XCTAssertFalse(snapshot.isActive)
    }

    func testParsesFieldsInAnyOrderAndIgnoresExtraLines() throws {
        let snapshot = try HostUnitSnapshotParser.parse(
            """
            WantedBy=default.target
            ActiveState=active
            noise from ssh
            UnitFileState=enabled
            ExecMainPID=1234
            LoadState=loaded
            """
        )

        XCTAssertEqual(snapshot.loadState, "loaded")
        XCTAssertEqual(snapshot.activeState, "active")
        XCTAssertEqual(snapshot.unitFileState, "enabled")
    }

    func testHandlesCRLFAndWhitespace() throws {
        let snapshot = try HostUnitSnapshotParser.parse(
            " LoadState = loaded \r\n ActiveState = active \r\n UnitFileState = enabled \r\n"
        )

        XCTAssertEqual(snapshot.loadState, "loaded")
        XCTAssertEqual(snapshot.activeState, "active")
        XCTAssertEqual(snapshot.unitFileState, "enabled")
    }

    func testMissingFieldThrows() {
        XCTAssertThrowsError(
            try HostUnitSnapshotParser.parse(
                "LoadState=loaded\nActiveState=active"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostUnitParseError,
                .missingField("UnitFileState")
            )
        }
    }

    func testEmptyFieldIsTreatedAsMissing() {
        XCTAssertThrowsError(
            try HostUnitSnapshotParser.parse(
                "LoadState=loaded\nActiveState=\nUnitFileState=enabled"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostUnitParseError,
                .missingField("ActiveState")
            )
        }
    }

    // MARK: - 连接失败分类

    func testOfflineTakesPrecedence() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                code: "RATE_LIMITED",
                httpStatus: 429,
                isOffline: true,
                message: "SSL certificate error"
            ),
            .offline
        )
    }

    func testHTTPStatusClassification() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 401),
            .authentication
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 403),
            .authentication
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 429),
            .rateLimit
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 402),
            .insufficientBalance
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 408),
            .timeout
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 504),
            .timeout
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(httpStatus: 503),
            .remoteUnavailable
        )
    }

    func testRACPCodesClassification() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "racp.UNAUTHORIZED"),
            .authentication
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "racp.RATE_LIMITED"),
            .rateLimit
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "racp.AGENT_UNAVAILABLE"),
            .remoteUnavailable
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "racp.PROTOCOL_MISMATCH"),
            .protocolViolation
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "racp.NOT_CONNECTED"),
            .offline
        )
    }

    func testEveryHTTPServerFailureHasAFixedClassification() {
        for status in 500...599 {
            let expected: ConnectionFailureKind = status == 504 ? .timeout : .remoteUnavailable
            XCTAssertEqual(ConnectionFailureClassifier.classify(httpStatus: status), expected)
        }
    }

    func testHTTPStatusInTransportReasonUsesSameClassification() {
        let cases: [(Int, ConnectionFailureKind)] = [
            (401, .authentication), (403, .authentication),
            (402, .insufficientBalance), (408, .timeout),
            (429, .rateLimit), (500, .remoteUnavailable),
            (503, .remoteUnavailable), (504, .timeout), (599, .remoteUnavailable),
        ]
        for (status, expected) in cases {
            for prefix in ["HTTP", "HTTP/1.1", "HTTP/2", "HTTP status"] {
                let kind = ConnectionFailureClassifier.classify(
                    message: "\(prefix) \(status): PRIVATE_SERVER_DETAIL"
                )
                XCTAssertEqual(kind, expected, "\(prefix) \(status)")
                XCTAssertEqual(kind.userMessage, expected.userMessage)
                XCTAssertFalse(kind.userMessage.contains("PRIVATE_SERVER_DETAIL"))
            }
        }
        XCTAssertEqual(ConnectionFailureClassifier.classify(message: "request id 503"), .unknown)
    }

    func testStructuredStatusTakesPrecedenceOverUntrustedMessage() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                code: "TLS_ERROR", httpStatus: 403, message: "DNS timeout"
            ),
            .authentication
        )
    }

    func testRACPDisplayUsesFixedMessagesForKnownCodes() {
        let cases: [(RACPErrorCode, String)] = [
            (.unauthorized, ConnectionFailureKind.authentication.userMessage),
            (.forbidden, ConnectionFailureKind.authentication.userMessage),
            (.agentUnavailable, ConnectionFailureKind.remoteUnavailable.userMessage),
            (.serverInternal, ConnectionFailureKind.remoteUnavailable.userMessage),
            (.rateLimited, ConnectionFailureKind.rateLimit.userMessage),
            (.protocolMismatch, ConnectionFailureKind.protocolViolation.userMessage),
            (.invalidArgument, "参数不合法"),
            (.notFound, "对象不存在，列表已刷新"),
            (.methodNotFound, "这台服务器不支持该操作"),
            (.agentBusy, "Host 正忙"),
            (.conflict, "状态已变化，重新拉取后再试"),
            (.idempotencyConflict, "同一幂等键对应了不同内容，需要人工确认"),
            (.cursorExpired, "事件游标已过期，已按快照重建"),
            (.clientTooSlow, "客户端处理过慢，已丢弃订阅并按快照重建"),
            (.approvalExpired, "审批已过期"),
            (.approvalStale, "审批已失效"),
            (.payloadTooLarge, "内容超过上限，请压缩后重试"),
            (.pairingFailed, "配对失败"),
            (.pairingTokenExpired, "配对令牌已过期，需要重启 Host 取新令牌"),
            (.capabilityUnavailable, "服务器未提供该能力"),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(ConnectionFailureClassifier.userMessage(forRACPCode: code), expected)
        }
    }

    func testUnknownRACPWireCodesNeverEchoServerText() throws {
        let rawCodes = [
            "FUTURE_SERVER_CODE", "", "PRIVATE_CANARY_WITHOUT_SECRET_PREFIX",
            "Authorization: Bearer PRIVATE_CANARY_TOKEN",
            "token=PRIVATE_CANARY_TOKEN", "sk-PRIVATE_CANARY_API_KEY",
            "HTTP 401 DNS TLS timeout", "RATE_LIMITED_PRIVATE_CANARY",
            "<script>alert('PRIVATE_CANARY')</script>\n\u{001B}[31m",
            "恶意文本\u{202E}PRIVATE_CANARY", String(repeating: "PRIVATE_CANARY", count: 1_000),
        ]
        for raw in rawCodes {
            let data = try JSONSerialization.data(withJSONObject: [
                "code": raw, "message": "PRIVATE_SERVER_MESSAGE", "data": ["token": "PRIVATE_TOKEN"],
            ])
            let body = try JSONDecoder().decode(RACPErrorBody.self, from: data)
            XCTAssertEqual(body.normalizedCode, .unknown(raw))
            XCTAssertEqual(
                ConnectionFailureClassifier.userMessage(forRACPCode: body.normalizedCode),
                ConnectionFailureKind.unknown.userMessage
            )
        }
        let numeric = try JSONDecoder().decode(
            RACPErrorBody.self,
            from: Data(#"{"code":-32099,"message":"PRIVATE_SERVER_MESSAGE"}"#.utf8)
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.userMessage(forRACPCode: numeric.normalizedCode),
            ConnectionFailureKind.unknown.userMessage
        )
        // An unknown enum value must not be reinterpreted by substring heuristics.
        XCTAssertEqual(
            ConnectionFailureClassifier.userMessage(forRACPCode: .unknown("UNAUTHORIZED")),
            ConnectionFailureKind.unknown.userMessage
        )
    }

    func testAllConnectionCategoriesDiscardUntrustedReasonText() {
        let cases: [(String, String, ConnectionFailureKind)] = [
            ("DNS_FAILURE", "getaddrinfo failed", .dns),
            ("TLS_FAILURE", "SSL certificate problem", .tls),
            ("TIMEOUT", "Operation timed out", .timeout),
            ("OFFLINE", "The Internet connection appears to be offline.", .offline),
            ("HOST_KEY_REJECTED", "Host key verification failed", .hostKey),
            ("PROTOCOL_MISMATCH", "received malformed frame", .protocolViolation),
        ]
        for (code, reason, expected) in cases {
            let kindFromCode = ConnectionFailureClassifier.classify(
                code: code, message: "PRIVATE_SERVER_DETAIL"
            )
            let kindFromReason = ConnectionFailureClassifier.classify(
                message: reason + ": PRIVATE_SERVER_DETAIL"
            )
            XCTAssertEqual(kindFromCode, expected)
            XCTAssertEqual(kindFromReason, expected)
            XCTAssertFalse(kindFromCode.userMessage.contains("PRIVATE_SERVER_DETAIL"))
            XCTAssertFalse(kindFromReason.userMessage.contains("PRIVATE_SERVER_DETAIL"))
        }
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(message: "PRIVATE_SERVER_DETAIL").userMessage,
            ConnectionFailureKind.unknown.userMessage
        )
    }

    func testSSHCodesClassification() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "ssh.authenticationFailed"),
            .authentication
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "ssh.hostKeyRejected"),
            .hostKey
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "ssh.tunnelRefused"),
            .remoteUnavailable
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(code: "ssh.timedOut"),
            .timeout
        )
    }

    func testDNSAndTLSMessagesClassification() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "curl: (6) Could not resolve host: example.invalid"
            ),
            .dns
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "SSL certificate problem: self-signed certificate"
            ),
            .tls
        )
    }

    func testNetworkMessagesClassification() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "A server with the specified hostname could not be found."
            ),
            .dns
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "Operation timed out after 10 seconds"
            ),
            .timeout
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "connect: Connection refused"
            ),
            .remoteUnavailable
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "HTTP 401 Unauthorized"
            ),
            .authentication
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "HTTP 429 Too Many Requests"
            ),
            .rateLimit
        )
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                message: "The Internet connection appears to be offline."
            ),
            .offline
        )
    }

    func testClassifiedMessageNeverEchoesTransportDetails() {
        let canary = "Authorization: Bearer SECRET_CANARY_TOKEN_123456"
        let kind = ConnectionFailureClassifier.classify(
            code: "ssh.authenticationFailed",
            message: canary
        )

        XCTAssertEqual(kind, .authentication)
        XCTAssertFalse(kind.userMessage.contains("SECRET_CANARY_TOKEN_123456"))
        XCTAssertFalse(kind.userMessage.contains(canary))
    }

    func testUnknownFailureIsRetrySafeAndDoesNotEchoDetail() {
        let kind = ConnectionFailureClassifier.classify(
            message: "token=SECRET_CANARY_TOKEN_123456"
        )

        XCTAssertEqual(kind, .unknown)
        XCTAssertFalse(kind.isRetryable)
        XCTAssertFalse(kind.userMessage.contains("SECRET_CANARY_TOKEN_123456"))
    }

    // MARK: - 诊断文本脱敏

    func testRedactorRemovesCredentialShapes() {
        let canary = "SECRET_CANARY"
        let begin = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        let end = "-----END " + "OPENSSH PRIVATE KEY-----"
        let input = """
        Authorization: Bearer \(canary)_BEARER
        API_KEY=\(canary)_API_KEY
        password=\(canary)_PASSWORD
        token=\(canary)_TOKEN
        pairing=ppt1.\(canary)_PAIRING_TOKEN
        value=sk-\(canary)_API_KEY_VALUE
        \(begin)
        \(canary)_PRIVATE_KEY_MATERIAL
        \(end)
        """

        let redacted = ConnectionDiagnosticRedactor.redact(input)

        XCTAssertFalse(redacted.contains(canary))
        XCTAssertTrue(redacted.contains("[已隐藏]"))
        XCTAssertTrue(redacted.contains("[已隐藏配对令牌]"))
        XCTAssertTrue(redacted.contains("[已隐藏 API Key]"))
        XCTAssertTrue(redacted.contains("[已隐藏私钥]"))
    }

    func testRedactorLeavesOrdinaryGuidanceReadable() {
        let input = "认证失败：请检查用户名、密码或私钥后重试。"

        XCTAssertEqual(ConnectionDiagnosticRedactor.redact(input), input)
    }
}
