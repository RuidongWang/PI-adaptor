import XCTest

@testable import PIiOSCore

/// 契约 §4.5 / spec AC-04.5：端点预校验的每条拒绝分支都要有中文原因。
final class EndpointPolicyTests: XCTestCase {
    // MARK: 通过

    func testAC04_5_acceptsCustomVendorWithHTTPSBaseURL() {
        let result = EndpointPolicy.validate(baseUrl: "https://models.example/v1", vendorKey: "custom")
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.rejection)
        XCTAssertNil(result.displayReason)
    }

    func testAC04_5_acceptsPublicIPAndPort() {
        let result = EndpointPolicy.validate(baseUrl: "http://203.0.113.10:8080/v1", vendorKey: "openai_compat")
        XCTAssertTrue(result.isValid)
    }

    func testAC04_5_acceptsOpenAIWithoutBaseURL() {
        XCTAssertTrue(EndpointPolicy.validate(baseUrl: nil, vendorKey: "openai").isValid)
        XCTAssertTrue(EndpointPolicy.validate(baseUrl: "  ", vendorKey: "openai").isValid)
    }

    func testAC04_5_acceptsAnthropicWithoutBaseURL() {
        XCTAssertTrue(EndpointPolicy.validate(baseUrl: nil, vendorKey: "anthropic").isValid)
    }

    func testAC04_5_acceptsGoogleWithoutBaseURL() {
        XCTAssertTrue(EndpointPolicy.validate(baseUrl: nil, vendorKey: "google").isValid)
    }

    // MARK: 回环 / 局域网 / 通配 / 链路本地

    func testAC04_5_rejectsLocalhost() {
        let result = EndpointPolicy.validate(baseUrl: "http://localhost:11434/v1", vendorKey: "custom")
        XCTAssertEqual(result.rejection, .loopbackHost("localhost"))
        XCTAssertTrue(result.displayReason?.contains("回环") ?? false)
    }

    func testAC04_5_rejectsLocalhostSubdomain() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://api.localhost/v1", vendorKey: "custom").rejection,
            .loopbackHost("api.localhost")
        )
    }

    func testAC04_5_rejectsDotLocalHostname() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://box.local/v1", vendorKey: "custom").rejection,
            .localHostname("box.local")
        )
    }

    func testAC04_5_rejectsLoopbackIPv4() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "http://127.0.0.1:8080/v1", vendorKey: "custom").rejection,
            .loopbackHost("127.0.0.1")
        )
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://127.3.2.1/v1", vendorKey: "custom").rejection,
            .loopbackHost("127.3.2.1")
        )
    }

    func testAC04_5_rejectsZeroWildcardIPv4() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "http://0.0.0.0:8080/v1", vendorKey: "custom").rejection,
            .wildcardHost("0.0.0.0")
        )
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "http://0.1.2.3/v1", vendorKey: "custom").rejection,
            .wildcardHost("0.1.2.3")
        )
    }

    func testAC04_5_acceptsDomainStartingWithZero() {
        // `0.*` 只针对字面量 IPv4，不能误伤 `0.example.com` 这类域名。
        XCTAssertTrue(EndpointPolicy.validate(baseUrl: "https://0.example.com/v1", vendorKey: "custom").isValid)
    }

    func testAC04_5_rejectsLinkLocalIPv4() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "http://169.254.10.20/v1", vendorKey: "custom").rejection,
            .linkLocalHost("169.254.10.20")
        )
    }

    // MARK: IPv6

    func testAC04_5_rejectsIPv6Unspecified() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://[::]/v1", vendorKey: "custom").rejection,
            .ipv6Unspecified("::")
        )
    }

    func testAC04_5_rejectsIPv6Loopback() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://[::1]:8443/v1", vendorKey: "custom").rejection,
            .ipv6Loopback("::1")
        )
    }

    func testAC04_5_rejectsIPv4MappedIPv6() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://[::ffff:127.0.0.1]/v1", vendorKey: "custom").rejection,
            .ipv4MappedIPv6("::ffff:127.0.0.1")
        )
    }

    // MARK: - 字面量写法不能绕过回环判定（审查 fix 3）

    func testFix3_rejectsLoopbackWrittenAsNonCanonicalIPLiteral() {
        let cases: [(String, EndpointRejection)] = [
            // WHATWG IPv4：十进制整体值、0x 十六进制、省略段、以 0 开头的八进制。
            ("http://2130706433/v1", .loopbackHost("2130706433")),
            ("http://0x7f000001/v1", .loopbackHost("0x7f000001")),
            ("http://127.1/v1", .loopbackHost("127.1")),
            ("http://0177.0.0.1/v1", .loopbackHost("0177.0.0.1")),
            // IPv6：先展开再判定 ::1 / ::ffff: 变体。
            ("http://[0:0:0:0:0:0:0:1]/v1", .ipv6Loopback("0:0:0:0:0:0:0:1")),
            ("http://[0:0:0:0:0:ffff:127.0.0.1]/v1", .ipv4MappedIPv6("0:0:0:0:0:ffff:127.0.0.1")),
            ("http://[::FFFF:7f00:1]/v1", .ipv4MappedIPv6("::ffff:7f00:1")),
        ]

        for (baseUrl, expected) in cases {
            let result = EndpointPolicy.validate(baseUrl: baseUrl, vendorKey: "custom")
            XCTAssertEqual(result.rejection, expected, "\(baseUrl) 必须被拒绝")
            XCTAssertFalse(result.isValid)
            XCTAssertFalse(result.displayReason?.isEmpty ?? true, "每条拒绝都要带中文原因")
        }
    }

    // MARK: 协议与 URL 组成

    func testAC04_5_rejectsNonHTTPScheme() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "ftp://models.example/v1", vendorKey: "custom").rejection,
            .unsupportedScheme("ftp")
        )
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "ws://models.example/v1", vendorKey: "custom").rejection,
            .unsupportedScheme("ws")
        )
    }

    func testAC04_5_rejectsUserInfo() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://user:s3cr3t@models.example/v1", vendorKey: "custom").rejection,
            .userInfoNotAllowed("https://user:s3cr3t@models.example/v1")
        )
    }

    func testAC04_5_rejectsQuery() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://models.example/v1?api-version=2", vendorKey: "custom").rejection,
            .queryNotAllowed("https://models.example/v1?api-version=2")
        )
    }

    func testAC04_5_rejectsFragment() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "https://models.example/v1#frag", vendorKey: "custom").rejection,
            .fragmentNotAllowed("https://models.example/v1#frag")
        )
    }

    func testAC04_5_rejectsMalformedBaseURL() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: "models.example/v1", vendorKey: "custom").rejection,
            .malformedURL("models.example/v1")
        )
    }

    // MARK: vendorKey

    func testAC04_5_rejectsExcludedVendorKeys() {
        for key in ["ollama", "lmstudio", "local", "OLLAMA"] {
            let result = EndpointPolicy.validate(baseUrl: "https://models.example/v1", vendorKey: key)
            XCTAssertEqual(result.rejection, .excludedVendorKey(key.lowercased()), "vendorKey=\(key)")
            XCTAssertFalse(result.isValid)
        }
    }

    func testAC04_5_rejectsMissingBaseURLWhenVendorDoesNotAllowImplicit() {
        XCTAssertEqual(
            EndpointPolicy.validate(baseUrl: nil, vendorKey: "custom").rejection,
            .missingBaseURL(vendorKey: "custom")
        )
    }

    // MARK: 统一要求：任何拒绝都有中文原因与稳定 code

    func testAC04_5_everyRejectionCarriesChineseReasonAndStableCode() {
        let inputs: [(String?, String)] = [
            (nil, "custom"),
            ("models.example/v1", "custom"),
            ("ftp://models.example/v1", "custom"),
            ("https://user@models.example/v1", "custom"),
            ("https://models.example/v1?a=1", "custom"),
            ("https://models.example/v1#a", "custom"),
            ("http://localhost/v1", "custom"),
            ("http://x.localhost/v1", "custom"),
            ("http://box.local/v1", "custom"),
            ("http://127.0.0.1/v1", "custom"),
            ("http://0.0.0.0/v1", "custom"),
            ("http://169.254.1.1/v1", "custom"),
            ("http://[::]/v1", "custom"),
            ("http://[::1]/v1", "custom"),
            ("http://[::ffff:127.0.0.1]/v1", "custom"),
            ("https://models.example/v1", "ollama"),
        ]

        for (baseUrl, vendorKey) in inputs {
            let result = EndpointPolicy.validate(baseUrl: baseUrl, vendorKey: vendorKey)
            guard let rejection = result.rejection else {
                XCTFail("期望被拒绝：baseUrl=\(baseUrl ?? "nil") vendorKey=\(vendorKey)")
                continue
            }
            XCTAssertFalse(rejection.code.isEmpty)
            XCTAssertFalse(rejection.message.isEmpty)
            XCTAssertTrue(
                rejection.message.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "拒绝原因应为中文：\(rejection.message)"
            )
        }
    }

    func testAC04_5_rejectionCodesAreDistinctAndMessagesNonEmpty() {
        let codes = EndpointPolicyTests.allRejections.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "每个拒绝分支的 code 必须唯一：\(codes)")
        for rejection in EndpointPolicyTests.allRejections {
            XCTAssertFalse(rejection.message.isEmpty)
        }
    }

    private static let allRejections: [EndpointRejection] = [
        .excludedVendorKey("ollama"),
        .missingBaseURL(vendorKey: "custom"),
        .malformedURL("x"),
        .unsupportedScheme("ftp"),
        .userInfoNotAllowed("x"),
        .queryNotAllowed("x"),
        .fragmentNotAllowed("x"),
        .loopbackHost("localhost"),
        .localHostname("box.local"),
        .wildcardHost("0.0.0.0"),
        .linkLocalHost("169.254.1.1"),
        .ipv6Unspecified("::"),
        .ipv6Loopback("::1"),
        .ipv4MappedIPv6("::ffff:127.0.0.1"),
    ]
}
