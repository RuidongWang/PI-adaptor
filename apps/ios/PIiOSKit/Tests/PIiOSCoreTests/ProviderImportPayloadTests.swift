import XCTest

@testable import PIiOSCore

/// 契约 §4.2 / §4.3 / §4.4 / §4.6 / §4.7；spec AC-04.2 / AC-04.5 / AC-04.6 / AC-04.7 / AC-05.3。
final class ProviderImportPayloadTests: XCTestCase {
    // MARK: - golden fixture（契约 §4.7）

    func testAC04_2_goldenFixtureEncodesFieldByField() throws {
        let model = ProviderModelSpec(
            id: "model/a",
            contextWindow: 120_000,
            maxTokens: 8_000,
            thinkingLevels: ["off", "high"],
            defaultThinkingLevel: "high",
            thinkingProtocol: "adaptive",
            nativeWebSearch: true
        )
        let input = ProviderCreateInput(
            name: "Custom",
            vendorKey: "custom",
            type: "openai_compatible",
            protocol: "openai_compatible",
            authKind: "api_key_and_base_url",
            baseUrl: "https://models.example/v1",
            models: [model],
            secretValue: "{{API_KEY}}",
            temperature: 0
        )
        let payload = ProviderImportPayload.make(
            inputs: [input],
            defaultSelection: ProviderImportDefaultSelection(providerIndex: 0, modelId: "model/a")
        )

        let sourceId = payload.providers[0].sourceId
        XCTAssertEqual(sourceId.count, 32, "sourceId 为 sha256 前 16 字节的十六进制")
        XCTAssertTrue(sourceId.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        let encoded = try ProviderImportEncoder.encode(payload)
        let actual = try JSONDecoder().decode(JSONValue.self, from: encoded)

        let expectedJSON = """
        {
          "version": 1,
          "providers": [
            {
              "sourceId": "\(sourceId)",
              "input": {
                "name": "Custom",
                "vendorKey": "custom",
                "type": "openai_compatible",
                "protocol": "openai_compatible",
                "baseUrl": "https://models.example/v1",
                "authKind": "api_key_and_base_url",
                "secretValue": "{{API_KEY}}",
                "temperature": 0,
                "models": [
                  {
                    "id": "model/a",
                    "contextWindow": 120000,
                    "maxTokens": 8000,
                    "thinkingLevels": ["off", "high"],
                    "defaultThinkingLevel": "high",
                    "thinkingProtocol": "adaptive",
                    "nativeWebSearch": true
                  }
                ]
              }
            }
          ],
          "defaultModel": { "sourceId": "\(sourceId)", "modelId": "model/a" }
        }
        """
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(expectedJSON.utf8))

        XCTAssertEqual(actual, expected, "编码结果必须与契约 §4.7 golden fixture 同形（逐字段等价）")
        XCTAssertEqual(actual.value(at: ["providers"])?.arrayValue?.count, 1)
        let modelKeys = actual
            .value(at: ["providers"])?.arrayValue?.first?
            .value(at: ["input", "models"])?.arrayValue?.first?
            .objectValue?.keys.sorted()
        XCTAssertEqual(
            modelKeys,
            ["contextWindow", "defaultThinkingLevel", "id", "maxTokens", "nativeWebSearch", "thinkingLevels", "thinkingProtocol"],
            "models[] 不得出现契约 §4.4 之外的字段"
        )
    }

    func testAC04_2_goldenFixtureJSONIsSingleLine() throws {
        let payload = ProviderImportPayload.make(inputs: [Self.validInput()])
        let text = try ProviderImportEncoder.encodeToString(payload)
        XCTAssertFalse(text.contains("\n"), "stdin 载荷应为单行 JSON")
        XCTAssertTrue(text.hasPrefix("{"))
    }

    func testProviderHeadersGoldenEncodeAsHostStringRecordAndRoundTrip() throws {
        var input = Self.validInput()
        input.headers = [
            "X-Request-Id": "request-42",
            "X-Locale": "zh-CN",
            "X-Latin-1": "café",
        ]
        let payload = ProviderImportPayload.make(inputs: [input])

        let data = try ProviderImportEncoder.encode(payload)
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        let expectedHeaders = JSONValue.object([
            "X-Request-Id": .string("request-42"),
            "X-Locale": .string("zh-CN"),
            "X-Latin-1": .string("café"),
        ])
        XCTAssertEqual(
            raw.value(at: ["providers"])?.arrayValue?.first?
                .value(at: ["input", "headers"]),
            expectedHeaders,
            "Host 要求 headers 是 Record<string, string>，不能编码为 [{name,value}] 数组"
        )

        let decoded = try ProviderImportEncoder.decode(data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(ProviderImportValidation.issues(in: decoded), [])
    }

    // MARK: - sourceId 确定性（AC-05.3）

    func testAC05_3_sourceIdIsDeterministicForSameInput() {
        let input = Self.validInput()
        let first = ProviderSourceID.make(vendorKey: input.vendorKey, baseUrl: input.baseUrl, modelIds: input.models.map(\.id))
        let second = ProviderSourceID.make(vendorKey: input.vendorKey, baseUrl: input.baseUrl, modelIds: input.models.map(\.id))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, input.computedSourceId)
        XCTAssertEqual(ProviderImportEntry.make(input: input).sourceId, first)
    }

    func testAC05_3_sourceIdIgnoresModelDeclarationOrderButChangesWithModelSet() {
        let a = ProviderSourceID.make(vendorKey: "custom", baseUrl: "https://models.example/v1", modelIds: ["model/a", "model/b"])
        let b = ProviderSourceID.make(vendorKey: "custom", baseUrl: "https://models.example/v1", modelIds: ["model/b", "model/a"])
        XCTAssertEqual(a, b, "模型 id 列表排序后参与哈希，声明顺序不影响 sourceId")

        let changed = ProviderSourceID.make(vendorKey: "custom", baseUrl: "https://models.example/v1", modelIds: ["model/a", "model/c"])
        XCTAssertNotEqual(a, changed, "改动任一 model id 必须得到不同 sourceId")
    }

    func testAC05_3_sourceIdChangesWithVendorKeyOrBaseURL() {
        let base = ProviderSourceID.make(vendorKey: "custom", baseUrl: "https://models.example/v1", modelIds: ["model/a"])
        let otherVendor = ProviderSourceID.make(vendorKey: "openai", baseUrl: "https://models.example/v1", modelIds: ["model/a"])
        let otherBase = ProviderSourceID.make(vendorKey: "custom", baseUrl: "https://other.example/v1", modelIds: ["model/a"])
        let noBase = ProviderSourceID.make(vendorKey: "custom", baseUrl: nil, modelIds: ["model/a"])
        XCTAssertEqual(Set([base, otherVendor, otherBase, noBase]).count, 4)
    }

    func testAC05_3_rejectsRandomSourceId() {
        var payload = ProviderImportPayload.make(inputs: [Self.validInput()])
        payload.providers[0].sourceId = UUID().uuidString
        let issues = ProviderImportValidation.issues(in: payload)
        XCTAssertTrue(issues.contains { $0.kind == .sourceIdNotDeterministic })
    }

    // MARK: - 合法载荷通过

    func testAC04_2_acceptsMinimalValidPayload() {
        let payload = ProviderImportPayload.make(inputs: [Self.validInput()])
        XCTAssertEqual(ProviderImportValidation.issues(in: payload), [])
        XCTAssertNoThrow(try ProviderImportValidation.validate(payload))
    }

    func testAC04_2_acceptsModelWithNoThinkingLevels() {
        // AC-07.7：模型可以声明空档位列表（字段仍必须存在）。
        var input = Self.validInput()
        input.models = [ProviderModelSpec(id: "model/plain", contextWindow: 8_000, maxTokens: 1_000, thinkingLevels: [])]
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])
    }

    func testAC04_2_acceptsOmitDefaultThinkingLevel() {
        var input = Self.validInput()
        input.models[0].defaultThinkingLevel = ProviderVendorSchema.defaultThinkingLevelOmit
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])
    }

    // MARK: - 必填与枚举（AC-04.2）

    func testAC04_2_rejectsEmptyAndMissingRequiredFields() throws {
        // name 为空串：解码通过，校验按字段级拦截。
        let emptyName = """
        {"version":1,"providers":[{"sourceId":"deadbeefdeadbeefdeadbeefdeadbeef","input":{
          "name":"","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible",
          "authKind":"api_key","baseUrl":"https://models.example/v1","secretValue":"x",
          "models":[{"id":"m","contextWindow":1,"maxTokens":1,"thinkingLevels":[]}]
        }}]}
        """
        let issues = ProviderImportValidation.issues(in: try Self.jsonValue(emptyName))
        XCTAssertTrue(issues.contains { $0.kind == .emptyField && $0.path.hasSuffix(".name") }, "\(issues)")

        // name 整个缺失：必填字段缺失，解码即失败（不得静默通过）。
        let missingName = """
        {"version":1,"providers":[{"sourceId":"deadbeefdeadbeefdeadbeefdeadbeef","input":{
          "vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible",
          "authKind":"api_key","baseUrl":"https://models.example/v1","secretValue":"x",
          "models":[{"id":"m","contextWindow":1,"maxTokens":1,"thinkingLevels":[]}]
        }}]}
        """
        let missingIssues = ProviderImportValidation.issues(in: Self.rawJSON(missingName))
        XCTAssertTrue(missingIssues.contains { $0.kind == .undecodablePayload }, "\(missingIssues)")
    }

    func testAC04_2_rejectsMissingModelRequiredFieldAtDecode() {
        let json = """
        {"version":1,"providers":[{"sourceId":"x","input":{
          "name":"n","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible",
          "authKind":"api_key","secretValue":"x",
          "models":[{"id":"m","contextWindow":1,"thinkingLevels":[]}]
        }}]}
        """
        let issues = ProviderImportValidation.issues(in: Self.rawJSON(json))
        XCTAssertTrue(issues.contains { $0.kind == .undecodablePayload }, "缺 maxTokens 必须解码失败：\(issues)")
    }

    func testAC04_2_rejectsDisallowedAuthKind() {
        for authKind in ["none", "azure_api_key", "oauth"] {
            var input = Self.validInput()
            input.authKind = authKind
            let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
            XCTAssertTrue(
                issues.contains { $0.kind == .invalidEnumValue && $0.path.hasSuffix("authKind") },
                "authKind=\(authKind) 应被拒绝：\(issues)"
            )
            if authKind == "none" {
                XCTAssertTrue(issues.contains { $0.kind == .secretNotAllowed })
            }
        }
    }

    func testAC04_2_rejectsInvalidTypeAndProtocol() {
        var input = Self.validInput()
        input.type = "ollama_native"
        input.protocol = "grpc"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidEnumValue && $0.path.hasSuffix(".type") })
        XCTAssertTrue(issues.contains { $0.kind == .invalidEnumValue && $0.path.hasSuffix(".protocol") })
    }

    func testAC04_2_rejectsMissingSecretValue() {
        var input = Self.validInput()
        input.secretValue = nil
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .missingRequiredField && $0.path.hasSuffix("secretValue") })
    }

    func testAC04_2_rejectsOversizedSecretValue() {
        var input = Self.validInput()
        input.secretValue = String(repeating: "k", count: ProviderVendorSchema.maxSecretBytes + 1)
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .tooLong && $0.path.hasSuffix("secretValue") })

        input.secretValue = String(repeating: "k", count: ProviderVendorSchema.maxSecretBytes)
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])
    }

    func testUpstreamTextRulesRejectWhitespaceAndControlCharacters() {
        var input = Self.validInput()
        input.secretValue = " key\n"
        var issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(
            issues.contains { $0.kind == .invalidTextValue && $0.path.hasSuffix("secretValue") },
            "API Key 首尾空白/换行必须在上传前拦下：\(issues)"
        )

        input = Self.validInput()
        input.baseUrl = "https://models.example/v1\n"
        issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidTextValue && $0.path.hasSuffix("baseUrl") })

        input = Self.validInput()
        input.models[0].id = "model/a\tcopy"
        issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidTextValue && $0.path.hasSuffix("models[0].id") })
    }

    func testUpstreamTextFieldAndAliasLengthLimits() {
        var input = Self.validInput()
        input.models[0].id = String(repeating: "m", count: ProviderVendorSchema.maxTextLength + 1)
        var issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .tooLong && $0.path.hasSuffix("models[0].id") })

        input = Self.validInput()
        input.models[0].alias = String(repeating: "a", count: ProviderVendorSchema.maxAliasLength + 1)
        issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .tooLong && $0.path.hasSuffix("models[0].alias") })
    }

    func testUpstreamThinkingProtocolEnumIsEnforced() {
        var input = Self.validInput()
        input.models[0].thinkingProtocol = "adaptive_v2"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidEnumValue && $0.path.hasSuffix("thinkingProtocol") })
    }

    func testModelLimitSourcesAcceptOnlyCatalogAndUser() throws {
        var input = Self.validInput()
        input.models[0].contextWindowSource = "catalog"
        input.models[0].maxTokensSource = "user"
        let payload = ProviderImportPayload.make(inputs: [input])
        XCTAssertEqual(ProviderImportValidation.issues(in: payload), [])

        let data = try ProviderImportEncoder.encode(payload)
        XCTAssertEqual(try ProviderImportEncoder.decode(data), payload)
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(
            raw.value(at: ["providers"])?.arrayValue?.first?
                .value(at: ["input", "models"])?.arrayValue?.first?
                .value(at: ["contextWindowSource"]),
            .string("catalog")
        )
        XCTAssertEqual(
            raw.value(at: ["providers"])?.arrayValue?.first?
                .value(at: ["input", "models"])?.arrayValue?.first?
                .value(at: ["maxTokensSource"]),
            .string("user")
        )
    }

    func testModelLimitSourcesRejectUnknownValues() {
        var input = Self.validInput()
        input.models[0].contextWindowSource = "remote"
        input.models[0].maxTokensSource = "inferred"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains {
            $0.kind == .invalidEnumValue && $0.path.hasSuffix("contextWindowSource")
        })
        XCTAssertTrue(issues.contains {
            $0.kind == .invalidEnumValue && $0.path.hasSuffix("maxTokensSource")
        })
    }

    func testModelLimitSourcesRejectExplicitNullAtDecode() {
        let json = """
        {"version":1,"providers":[{"sourceId":"x","input":{
          "name":"n","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible",
          "authKind":"api_key","secretValue":"x",
          "models":[{
            "id":"m","contextWindow":1,"contextWindowSource":null,
            "maxTokens":1,"thinkingLevels":[]
          }]
        }}]}
        """
        let issues = ProviderImportValidation.issues(in: Self.rawJSON(json))
        XCTAssertTrue(issues.contains { $0.kind == .undecodablePayload }, "\(issues)")
    }

    func testAC04_2_rejectsTooManyProviders() {
        let inputs = (0...(ProviderVendorSchema.maxProviders)).map { index in
            var input = Self.validInput()
            input.name = "Custom-\(index)"
            input.models = [ProviderModelSpec(id: "model/\(index)", contextWindow: 1, maxTokens: 1, thinkingLevels: [])]
            return input
        }
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: inputs))
        XCTAssertTrue(issues.contains { $0.kind == .tooManyProviders })
    }

    // MARK: - models（AC-04.7）

    func testAC04_7_rejectsModelCountOutsideRange() {
        var empty = Self.validInput()
        empty.models = []
        XCTAssertTrue(
            ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [empty]))
                .contains { $0.kind == .outOfRange && $0.path.hasSuffix("models") }
        )

        var tooMany = Self.validInput()
        tooMany.models = (0...ProviderVendorSchema.maxModels).map { index in
            ProviderModelSpec(id: "model/\(index)", contextWindow: 1, maxTokens: 1, thinkingLevels: [])
        }
        XCTAssertTrue(
            ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [tooMany]))
                .contains { $0.kind == .outOfRange }
        )
    }

    func testAC04_7_rejectsDuplicateModelIdInBatch() {
        var input = Self.validInput()
        input.models = [
            ProviderModelSpec(id: "model/dup", contextWindow: 1, maxTokens: 1, thinkingLevels: []),
            ProviderModelSpec(id: "model/dup", contextWindow: 2, maxTokens: 2, thinkingLevels: []),
        ]
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .duplicateValue && $0.path.contains("models[1].id") }, "\(issues)")
    }

    func testAC04_7_rejectsEmptyModelId() {
        var input = Self.validInput()
        input.models[0].id = "   "
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .emptyField && $0.path.contains("models[0].id") })
    }

    func testAC04_7_rejectsInvalidAndDuplicateThinkingLevels() {
        var input = Self.validInput()
        input.models[0].thinkingLevels = ["off", "off"]
        var issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .duplicateValue && $0.path.hasSuffix("thinkingLevels") })

        input.models[0].thinkingLevels = ["off", "extreme"]
        issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidEnumValue && $0.path.contains("thinkingLevels[1]") })
    }

    func testAC04_7_rejectsDefaultThinkingLevelOutsideModelLevels() {
        var input = Self.validInput()
        input.models[0].thinkingLevels = ["low", "medium"]
        input.models[0].defaultThinkingLevel = "max"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .defaultNotInList && $0.path.hasSuffix("defaultThinkingLevel") })
    }

    func testAC04_7_rejectsNegativeAndUnsafeIntegers() {
        var input = Self.validInput()
        input.models[0].contextWindow = -1
        input.models[0].maxTokens = ProviderVendorSchema.maxSafeInteger + 1
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .negativeNumber && $0.path.hasSuffix("contextWindow") })
        XCTAssertTrue(issues.contains { $0.kind == .notSafeInteger && $0.path.hasSuffix("maxTokens") })
    }

    func testAC04_2_rejectsDefaultModelIdNotInModels() {
        var input = Self.validInput()
        input.defaultModelId = "model/ghost"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .defaultNotInList && $0.path.hasSuffix("defaultModelId") })

        input.defaultModelId = input.models[0].id
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])
    }

    func testAC04_2_rejectsDefaultModelReferenceOutsideBatch() {
        var payload = ProviderImportPayload.make(
            inputs: [Self.validInput()],
            defaultSelection: ProviderImportDefaultSelection(providerIndex: 0, modelId: "model/a")
        )
        payload.defaultModel?.modelId = "model/ghost"
        XCTAssertTrue(
            ProviderImportValidation.issues(in: payload)
                .contains { $0.kind == .defaultNotInList && $0.path == "defaultModel.modelId" }
        )
    }

    // MARK: - 严格模式与端点（AC-04.2 / AC-04.5）

    func testAC04_2_rejectsUnknownFields() {
        let json = """
        {"version":1,"providers":[{"sourceId":"x","input":{
          "name":"n","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible",
          "authKind":"api_key","secretValue":"x","unexpectedField":true,
          "models":[{"id":"m","contextWindow":1,"maxTokens":1,"thinkingLevels":[],"surprise":1}]
        }}]}
        """
        let issues = ProviderImportValidation.issues(in: Self.rawJSON(json))
        XCTAssertTrue(issues.contains { $0.kind == .unknownField && $0.path.contains("unexpectedField") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.kind == .unknownField && $0.path.contains("surprise") }, "\(issues)")
    }

    func testAC04_2_rejectsInvalidAndReservedHeaderNames() {
        var input = Self.validInput()
        input.headers = [
            "Authorization": "x",
            "bad header": "x",
            "Content-Type": "application/json",
        ]
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .reservedHeaderName })
        XCTAssertTrue(issues.contains { $0.kind == .invalidHeaderName })
        XCTAssertEqual(
            issues.filter { $0.kind == .reservedHeaderName }.count,
            2,
            "保留名必须覆盖上游完整集合并忽略大小写：\(issues)"
        )
    }

    func testHeadersRejectDuplicateNamesIgnoringCase() {
        var input = Self.validInput()
        input.headers = ["X-Test": "a", "x-test": "b"]
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .duplicateValue && $0.path.contains("headers") })
    }

    func testHeaderCountAndCompleteReservedNameSet() {
        var input = Self.validInput()
        input.headers = Dictionary(uniqueKeysWithValues: (0...ProviderVendorSchema.maxHeaders).map {
            ("X-Test-\($0)", "x")
        })
        var issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .outOfRange && $0.path.hasSuffix("headers") })

        let upstreamReservedNames: Set<String> = [
            "authorization", "proxy-authorization", "x-api-key", "api-key", "x-goog-api-key",
            "cookie", "set-cookie", "host", "content-type", "content-length", "connection",
            "transfer-encoding", "te", "trailer", "upgrade", "keep-alive", "chatgpt-account-id",
            "x-opencode-session",
        ]
        XCTAssertEqual(ProviderVendorSchema.reservedHeaderNames, upstreamReservedNames)
        input.headers = Dictionary(uniqueKeysWithValues: upstreamReservedNames.map {
            ($0.uppercased(), "x")
        })
        issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertEqual(
            issues.filter { $0.kind == .reservedHeaderName }.count,
            upstreamReservedNames.count,
            "\(issues)"
        )
    }

    func testHeaderValuesFollowUpstreamByteStringRules() {
        var input = Self.validInput()
        input.headers = [
            "X-Tab": "\tvalue",
            "X-Latin-1": "café",
            "X-Empty": "",
        ]
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])

        input.headers = ["X-Test": "bad\r\nvalue"]
        var issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidHeaderValue && $0.path.contains("X-Test") })

        input.headers = ["X-Test": "汉字"]
        issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .invalidHeaderValue })

        input.headers = ["X-Test": "café"]
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])
    }

    func testHeaderValueUsesUTF8ByteLimit() {
        var input = Self.validInput()
        input.headers = ["X-Test": String(repeating: "a", count: ProviderVendorSchema.maxHeaderValueBytes)]
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input])), [])

        input.headers = ["X-Test": String(repeating: "a", count: ProviderVendorSchema.maxHeaderValueBytes + 1)]
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .tooLong && $0.path.contains("X-Test") })
    }

    func testHeadersMustBeObjectNotLegacyArray() {
        let json = """
        {"version":1,"providers":[{"sourceId":"x","input":{
          "name":"n","vendorKey":"custom","type":"openai_compatible","protocol":"openai_compatible",
          "authKind":"api_key","secretValue":"x",
          "headers":[{"name":"X-Test","value":"x"}],
          "models":[{"id":"m","contextWindow":1,"maxTokens":1,"thinkingLevels":[]}]
        }}]}
        """
        let issues = ProviderImportValidation.issues(in: Self.rawJSON(json))
        XCTAssertTrue(issues.contains { $0.kind == .undecodablePayload }, "\(issues)")
    }

    func testAC04_5_validationRejectsLoopbackEndpointWithChineseReason() {
        var input = Self.validInput()
        input.baseUrl = "http://127.0.0.1:11434/v1"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        guard let issue = issues.first(where: { $0.kind == .endpointRejected }) else {
            return XCTFail("回环端点必须在提交前被拦下：\(issues)")
        }
        XCTAssertTrue(issue.message.contains("回环"))
    }

    func testAC04_5_validationRejectsExcludedVendorKey() {
        var input = Self.validInput()
        input.vendorKey = "ollama"
        input.baseUrl = "http://192.168.1.9:11434/v1"
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))
        XCTAssertTrue(issues.contains { $0.kind == .endpointRejected })
    }

    func testAC04_2_validateThrowsWithAggregatedIssues() {
        var input = Self.validInput()
        input.models[0].contextWindow = -5
        input.secretValue = nil
        do {
            try ProviderImportValidation.validate(ProviderImportPayload.make(inputs: [input]))
            XCTFail("应当抛出校验失败")
        } catch let failure as ProviderImportValidationFailure {
            XCTAssertGreaterThanOrEqual(failure.issues.count, 2)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 回执解析（AC-04.6）

    func testAC04_6_parsesSuccessReceipt() {
        let stdout = """
        some unrelated warning line
        PI_HOST_PROVIDERS {"imported":[{"sourceId":"9f2c1a7b4e6d8053","providerId":"prv_1"}],"skipped":[{"sourceId":"aaaabbbbccccdddd","reason":"remote_missing"}],"defaultSet":true}
        """
        guard case let .success(body) = ProviderImportReceiptParser.parse(stdout: stdout, exitCode: 0) else {
            return XCTFail("应解析为成功回执")
        }
        XCTAssertEqual(body.imported, [ProviderImportImported(sourceId: "9f2c1a7b4e6d8053", providerId: "prv_1")])
        XCTAssertEqual(body.skipped, [ProviderImportSkipped(sourceId: "aaaabbbbccccdddd", reason: .remoteMissing)])
        XCTAssertTrue(body.defaultSet)
        XCTAssertEqual(body.outcome(forSourceId: "9f2c1a7b4e6d8053"), .imported(providerId: "prv_1"))
        XCTAssertEqual(body.outcome(forSourceId: "aaaabbbbccccdddd"), .skipped(reason: .remoteMissing))
        XCTAssertEqual(body.outcome(forSourceId: "ffff"), .missing)
    }

    func testAC04_6_parsesEachFailureCode() {
        let expected: [(String, ProviderImportFailureCode)] = [
            ("INVALID_REQUEST", .invalidRequest),
            ("PAYLOAD_TOO_LARGE", .payloadTooLarge),
            ("ADMIN_UNAVAILABLE", .adminUnavailable),
            ("ADMIN_BUSY", .adminBusy),
            ("TIMEOUT", .timeout),
            ("IMPORT_FAILED", .importFailed),
        ]
        for (raw, code) in expected {
            let receipt = ProviderImportReceiptParser.parse(stdout: "PI_HOST_FAILED {\"code\":\"\(raw)\"}", exitCode: 1)
            guard case let .failure(failure) = receipt else {
                return XCTFail("应解析为失败回执：\(raw)")
            }
            XCTAssertEqual(failure.code, code)
            XCTAssertEqual(failure.rawCode, raw)
            XCTAssertFalse(failure.displayMessage.isEmpty)
        }
    }

    func testAC04_6_preservesUnknownFailureCode() {
        guard case let .failure(failure) = ProviderImportReceiptParser.parse(stdout: "PI_HOST_FAILED {\"code\":\"SOMETHING_NEW\"}", exitCode: 1) else {
            return XCTFail("应解析为失败回执")
        }
        XCTAssertEqual(failure.code, .unknown("SOMETHING_NEW"))
        XCTAssertEqual(failure.rawCode, "SOMETHING_NEW")
        XCTAssertTrue(failure.displayMessage.contains("SOMETHING_NEW"), "未知码必须原样展示")
    }

    func testAC04_6_explainsEachSkippedReasonWithoutAutoRetry() {
        let cases: [(String, ProviderImportSkipReason, String)] = [
            ("import_incomplete", .importIncomplete, "Host 侧状态"),
            ("remote_changed", .remoteChanged, "不会覆盖"),
            ("remote_missing", .remoteMissing, "重新导入"),
        ]
        for (raw, reason, keyword) in cases {
            let stdout = "PI_HOST_PROVIDERS {\"imported\":[],\"skipped\":[{\"sourceId\":\"s\",\"reason\":\"\(raw)\"}],\"defaultSet\":false}"
            guard case let .success(body) = ProviderImportReceiptParser.parse(stdout: stdout) else {
                return XCTFail("应解析为成功回执：\(raw)")
            }
            XCTAssertEqual(body.skipped.first?.reason, reason)
            XCTAssertTrue(body.skipped.first?.reason.clientGuidance.contains(keyword) ?? false)
            XCTAssertFalse(body.skipped.first?.reason.allowsAutomaticRetry ?? true)
        }
        XCTAssertTrue(ProviderImportSkipReason.remoteMissing.canReimport)
        XCTAssertFalse(ProviderImportSkipReason.importIncomplete.canReimport)
        XCTAssertFalse(ProviderImportSkipReason.remoteChanged.canReimport)
    }

    func testAC04_6_preservesUnknownSkippedReason() {
        let stdout = "PI_HOST_PROVIDERS {\"imported\":[],\"skipped\":[{\"sourceId\":\"s\",\"reason\":\"brand_new\"}],\"defaultSet\":false}"
        guard case let .success(body) = ProviderImportReceiptParser.parse(stdout: stdout) else {
            return XCTFail("应解析为成功回执")
        }
        XCTAssertEqual(body.skipped.first?.reason, .unknown("brand_new"))
    }

    func testAC04_6_reportsUnparseableOutput() {
        guard case let .unparseable(reason) = ProviderImportReceiptParser.parse(stdout: "boom\nnothing here", exitCode: 1) else {
            return XCTFail("无标记输出不应被当作成功")
        }
        XCTAssertTrue(reason.contains("PI_HOST_PROVIDERS"))

        guard case .unparseable = ProviderImportReceiptParser.parse(stdout: "PI_HOST_PROVIDERS not-json") else {
            return XCTFail("坏 JSON 不应被当作成功")
        }
        guard case .unparseable = ProviderImportReceiptParser.parse(stdout: "PI_HOST_FAILED {\"code\":") else {
            return XCTFail("坏 JSON 不应被当作失败码")
        }
    }

    // MARK: - 审查返工（fix 7 / 8 / 9 / 10）

    func testFix7_nonZeroExitCodeWithOnlySuccessMarkerIsNotSuccess() {
        let stdout = "PI_HOST_PROVIDERS {\"imported\":[{\"sourceId\":\"s1\",\"providerId\":\"prv_1\"}],\"skipped\":[],\"defaultSet\":true}"
        guard case let .unparseable(reason) = ProviderImportReceiptParser.parse(stdout: stdout, exitCode: 1) else {
            return XCTFail("非零退出码 + 只有成功行不得判成功")
        }
        XCTAssertTrue(reason.contains("1"), "原因里要带上退出码：\(reason)")
        XCTAssertTrue(reason.contains("PI_HOST_PROVIDERS"))

        // 退出码 0 时仍是成功回执。
        guard case .success = ProviderImportReceiptParser.parse(stdout: stdout, exitCode: 0) else {
            return XCTFail("退出码 0 时应解析为成功")
        }
    }

    func testFix8_successReceiptToleratesMissingOptionalFields() {
        let stdout = "PI_HOST_PROVIDERS {\"imported\":[{\"sourceId\":\"s1\",\"providerId\":\"prv_1\"}]}"
        guard case let .success(body) = ProviderImportReceiptParser.parse(stdout: stdout, exitCode: 0) else {
            return XCTFail("缺 skipped / defaultSet 不应把成功回执判成 unparseable")
        }
        XCTAssertEqual(body.skipped, [])
        XCTAssertFalse(body.defaultSet)
        XCTAssertEqual(body.outcome(forSourceId: "s1"), .imported(providerId: "prv_1"))

        // 主体里没有任何已知字段时不是「零条目的成功」：Host 若只打标记而主体不合契约，
        // 客户端必须按回执异常处理，不能让调用方以为导入成功。
        guard case let .unparseable(reason) = ProviderImportReceiptParser.parse(stdout: "PI_HOST_PROVIDERS {}", exitCode: 0) else {
            return XCTFail("空主体必须按回执异常处理，而不是零条目的成功")
        }
        XCTAssertTrue(reason.contains("已知字段"), "失败原因要能说清是主体不合契约：\(reason)")
    }

    func testFix9_sourceIdDistinguishesCommaContainingModelIds() {
        let single = ProviderSourceID.make(vendorKey: "custom", baseUrl: nil, modelIds: ["a,b"])
        let two = ProviderSourceID.make(vendorKey: "custom", baseUrl: nil, modelIds: ["a", "b"])
        XCTAssertNotEqual(single, two, "[\"a,b\"] 与 [\"a\",\"b\"] 不能撞成同一 sourceId")

        // 字段边界也不能靠换行区分：长度前缀让 a\nb 作为 model id 与作为 baseUrl 不同。
        let newlineModel = ProviderSourceID.make(vendorKey: "custom", baseUrl: nil, modelIds: ["a\nb"])
        let newlineBase = ProviderSourceID.make(vendorKey: "custom", baseUrl: "a\nb", modelIds: [])
        XCTAssertNotEqual(newlineModel, newlineBase)
    }

    func testFix10_rejectsPayloadAboveOneMiB() {
        // 512 个模型、每个 alias 约 2 KB → 载荷超过 1 MiB（未触碰其它字段上限）。
        var input = Self.validInput()
        input.models = (0..<ProviderVendorSchema.maxModels).map { index in
            ProviderModelSpec(
                id: "model/\(index)",
                contextWindow: 1_000,
                maxTokens: 1_000,
                thinkingLevels: [],
                alias: String(repeating: "a", count: 2_200)
            )
        }
        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))

        guard let issue = issues.first(where: { $0.kind == .payloadTooLarge }) else {
            return XCTFail("超过 1 MiB 的载荷必须被拦下：\(issues.prefix(3))")
        }
        XCTAssertEqual(issue.path, "providers")
        XCTAssertTrue(issue.message.contains("1 MiB"), "原因要说明 1 MiB 上限：\(issue.message)")
        XCTAssertTrue(issue.message.contains("字节"))

        // 正常载荷不受影响。
        XCTAssertEqual(ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [Self.validInput()])), [])
    }

    // MARK: - 工具

    static func validInput() -> ProviderCreateInput {
        ProviderCreateInput(
            name: "Custom",
            vendorKey: "custom",
            type: "openai_compatible",
            protocol: "openai_compatible",
            authKind: "api_key_and_base_url",
            baseUrl: "https://models.example/v1",
            models: [
                ProviderModelSpec(
                    id: "model/a",
                    contextWindow: 120_000,
                    maxTokens: 8_000,
                    thinkingLevels: ["off", "high"],
                    defaultThinkingLevel: "high"
                )
            ],
            secretValue: "{{API_KEY}}",
            temperature: 0
        )
    }

    static func jsonValue(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func rawJSON(_ text: String) -> JSONValue {
        (try? jsonValue(text)) ?? .null
    }
}
