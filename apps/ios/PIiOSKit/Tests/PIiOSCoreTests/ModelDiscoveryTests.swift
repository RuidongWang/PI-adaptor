import XCTest
@testable import PIiOSCore

final class ModelDiscoveryTests: XCTestCase {
    func testHTTPFailuresUseFixedMessagesAndNeverEchoResponseBody() {
        let canary = "PRIVATE_CANARY_\(UUID().uuidString)"
        let cases: [(Int, String)] = [
            (401, "认证失败"),
            (402, "余额不足"),
            (403, "拒绝访问"),
            (404, "地址不存在"),
            (408, "超时"),
            (429, "请求受限"),
            (503, "暂时不可用"),
        ]
        for (status, expected) in cases {
            let error = ModelListError.remote(status: status, message: canary)
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains(expected), "HTTP \(status): \(message)")
            XCTAssertFalse(message.contains(canary), "HTTP \(status) 不得回显服务端正文")
        }
    }

    func testSuccessfulHTTPWithHTMLBodyUsesFixedInvalidResponseMessage() {
        XCTAssertThrowsError(
            try ModelListParser.parse(data: Data("<html>proxy login</html>".utf8))
        ) { error in
            XCTAssertEqual(error as? ModelListError, .invalidResponse)
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "模型列表不是可识别的 JSON"
            )
        }
    }

    func testNetworkFailuresAreClassifiedWithoutEchoingTransportDetail() {
        let canary = "PRIVATE_CANARY_\(UUID().uuidString)"
        let cases: [(String, String)] = [
            ("URLError: nodename nor servname provided", "域名"),
            ("SSLError: certificate verify failed", "TLS"),
            ("TimeoutError: timed out", "超时"),
            ("ConnectionRefusedError: [Errno 111] refused \(canary)", "拒绝连接"),
        ]
        for (detail, expected) in cases {
            let line = #"PI_MODELS_RESULT {"status":0,"url":"https://example.invalid","body":"","error":"\#(detail)"}"#
            XCTAssertThrowsError(try RemoteModelListEnvelope.parse(stdout: line)) { error in
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains(expected), "\(detail): \(message)")
                XCTAssertFalse(message.contains(canary), "不得回显底层错误详情")
            }
        }
    }

    func testModelsURLAndResponseShapes() throws {
        XCTAssertEqual(
            try ModelListParser.modelsURL(baseURL: "http://203.0.113.10:8080/antigravity/"),
            "http://203.0.113.10:8080/antigravity/models"
        )
        XCTAssertEqual(
            try ModelListParser.modelsURL(baseURL: "https://api.example/v1/chat/completions"),
            "https://api.example/v1/models"
        )

        let openAI = Data(#"{"data":[{"id":"m-b","context_window":32000},{"id":"m-a","display_name":"Alpha","max_tokens":2048}]}"#.utf8)
        let models = try ModelListParser.parse(data: openAI)
        XCTAssertEqual(models.map(\.modelId), ["m-a", "m-b"])
        XCTAssertEqual(models[0].displayName, "Alpha")
        XCTAssertEqual(models[0].maxTokens, 2048)

        let google = Data(#"{"models":[{"name":"models/gemini-3-pro","displayName":"Gemini 3 Pro","inputTokenLimit":1000000,"outputTokenLimit":65536}]}"#.utf8)
        let googleModels = try ModelListParser.parse(data: google)
        XCTAssertEqual(googleModels.first?.modelId, "gemini-3-pro")
        XCTAssertEqual(googleModels.first?.contextWindow, 1_000_000)
        XCTAssertEqual(googleModels.first?.maxTokens, 65_536)
    }

    func testEndpointCapacitiesOverrideCatalogAndCatalogSuppliesCapabilities() throws {
        let catalog = try ModelsDevCatalog(data: Data(Self.catalogFixture.utf8))
        let discovered = DiscoveredModel(
            modelId: "antigravity-gemini-3-pro",
            displayName: "Gemini via Antigravity",
            contextWindow: 200_000,
            maxTokens: nil
        )
        let resolved = try XCTUnwrap(ModelConfigurationResolver.resolve([discovered], catalog: catalog).first)

        XCTAssertEqual(resolved.spec.id, "antigravity-gemini-3-pro")
        XCTAssertEqual(resolved.spec.contextWindow, 200_000, "服务端上报的容量优先")
        XCTAssertEqual(resolved.spec.maxTokens, 65_536, "服务端缺省时使用 models.dev")
        XCTAssertEqual(resolved.spec.thinkingLevels, ["off", "high"])
        XCTAssertEqual(resolved.spec.supportsImages, true)
        XCTAssertEqual(resolved.spec.supportsDocuments, true)
        XCTAssertEqual(resolved.metadataSource, .modelsDev(provider: "google"))
    }

    func testEndpointEffortLadderOverridesGenericCatalogLevels() throws {
        let data = Data(
            #"{"data":[{"id":"deepseek-flash","name":"DeepSeek-V4.1-Flash","context_window":1048576,"max_output_tokens":393216,"input_modalities":["text","image"],"effort":{"supported_levels":["low","high","max"],"default_level":"high"}}]}"#.utf8
        )
        let models = try ModelListParser.parse(data: data)
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(models, catalog: .shared).first
        )

        XCTAssertEqual(resolved.spec.thinkingLevels, ["off", "low", "high", "max"])
        XCTAssertEqual(resolved.spec.defaultThinkingLevel, "high")
        XCTAssertFalse(resolved.spec.thinkingLevels.contains("medium"))
        XCTAssertEqual(resolved.spec.contextWindow, 1_048_576)
        XCTAssertEqual(resolved.spec.maxTokens, 393_216)
        XCTAssertEqual(resolved.spec.supportsImages, true)
        XCTAssertEqual(resolved.metadataSource, .modelsDev(provider: "deepseek"))
    }

    func testExplicitEmptySupportedLevelsDoesNotFallBackToCatalog() throws {
        let data = Data(
            #"{"data":[{"id":"deepseek-flash","effort":{"supported_levels":[]}}]}"#.utf8
        )
        let models = try ModelListParser.parse(data: data)

        XCTAssertEqual(models.first?.thinkingLevels, [])
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(models, catalog: .shared).first
        )
        XCTAssertEqual(resolved.spec.thinkingLevels, [])
        XCTAssertNil(resolved.spec.defaultThinkingLevel)
    }

    func testMissingEffortStillUsesCatalog() throws {
        let data = Data(#"{"data":[{"id":"deepseek-flash"}]}"#.utf8)
        let models = try ModelListParser.parse(data: data)

        XCTAssertNil(models.first?.thinkingLevels)
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(models, catalog: .shared).first
        )
        XCTAssertFalse(resolved.spec.thinkingLevels.isEmpty)
    }

    func testInvalidDefaultDoesNotExtendEndpointSupportedLevels() throws {
        let data = Data(
            #"{"data":[{"id":"private","effort":{"supported_levels":["low","high"],"default_level":"max"}}]}"#.utf8
        )
        let models = try ModelListParser.parse(data: data)
        let emptyCatalog = try ModelsDevCatalog(data: Data("{}".utf8))
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(models, catalog: emptyCatalog).first
        )

        XCTAssertEqual(resolved.spec.thinkingLevels, ["low", "high"])
        XCTAssertEqual(resolved.spec.defaultThinkingLevel, "low")
    }

    func testEmptySupportedLevelsTakesPriorityOverDefaultLevel() throws {
        let data = Data(
            #"{"data":[{"id":"private","effort":{"supported_levels":[],"default_level":"high"}}]}"#.utf8
        )
        let models = try ModelListParser.parse(data: data)
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(models, catalog: .shared).first
        )

        XCTAssertEqual(resolved.spec.thinkingLevels, [])
        XCTAssertNil(resolved.spec.defaultThinkingLevel)
    }

    func testParserPreservesDuplicateIdsForFormDiagnostics() throws {
        let data = Data(
            #"{"data":[{"id":"dup","display_name":"First"},{"id":"dup","display_name":"Second"}]}"#.utf8
        )
        let models = try ModelListParser.parse(data: data)

        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.map(\.modelId), ["dup", "dup"])
    }

    func testUnmatchedModelUsesGenericDefaults() throws {
        let catalog = try ModelsDevCatalog(data: Data(Self.catalogFixture.utf8))
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(
                [DiscoveredModel(modelId: "private-unknown-model", displayName: "Private")],
                catalog: catalog
            ).first
        )
        XCTAssertEqual(resolved.spec.contextWindow, ModelsDevCatalog.defaultContextWindow)
        XCTAssertEqual(resolved.spec.maxTokens, ModelsDevCatalog.defaultMaxTokens)
        XCTAssertTrue(resolved.spec.thinkingLevels.isEmpty)
        XCTAssertEqual(resolved.metadataSource, .generic)
    }

    func testResolvedAliasMatchesUpstreamTextRules() throws {
        let discovered = DiscoveredModel(
            modelId: "private-unknown-model",
            displayName: "  Private\tModel\n" + String(repeating: "x", count: 80)
        )
        let resolved = try XCTUnwrap(
            ModelConfigurationResolver.resolve(
                [discovered],
                catalog: try ModelsDevCatalog(data: Data("{}".utf8))
            )
                .first
        )
        let alias = try XCTUnwrap(resolved.spec.alias)

        XCTAssertLessThanOrEqual(alias.utf16.count, ProviderVendorSchema.maxAliasLength)
        XCTAssertEqual(alias.trimmingCharacters(in: .whitespacesAndNewlines), alias)
        XCTAssertFalse(alias.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }))
        XCTAssertEqual(
            ProviderImportValidation.issues(
                in: ProviderImportPayload.make(inputs: [
                    ProviderCreateInput(
                        name: "Gateway",
                        vendorKey: "custom",
                        type: "openai_compatible",
                        protocol: "openai_compatible",
                        authKind: "api_key_and_base_url",
                        baseUrl: "https://models.example/v1",
                        models: [resolved.spec],
                        secretValue: "secret"
                    ),
                ])
            ),
            []
        )
    }

    func testProviderModelSpecEncodesNullDefaultThinkingLevel() throws {
        let input = ProviderCreateInput(
            name: "Gateway",
            vendorKey: "custom",
            type: "openai_compatible",
            protocol: "openai_compatible",
            authKind: "api_key_and_base_url",
            baseUrl: "https://models.example/v1",
            models: [
                ProviderModelSpec(
                    id: "plain-model",
                    contextWindow: 128_000,
                    maxTokens: 8_192,
                    thinkingLevels: []
                ),
            ],
            secretValue: "fixture-key"
        )
        let payload = ProviderImportPayload.make(inputs: [input])
        XCTAssertEqual(ProviderImportValidation.issues(in: payload), [])

        let encoded = try ProviderImportEncoder.encodeToString(payload)
        XCTAssertTrue(encoded.contains("\"defaultThinkingLevel\":null"))

        let decoded = try JSONDecoder().decode(
            ProviderImportPayload.self,
            from: Data(encoded.utf8)
        )
        XCTAssertNil(decoded.providers[0].input.models[0].defaultThinkingLevel)
    }

    func testBundledCatalogContributesMetadata() throws {
        let match = try XCTUnwrap(ModelsDevCatalog.shared.match(modelId: "claude-sonnet-4-5"))
        XCTAssertEqual(match.providerKey, "anthropic")
        XCTAssertGreaterThan(match.profile.contextWindow ?? 0, 0)
        XCTAssertTrue(match.profile.supportsImages)
    }

    private static let catalogFixture = """
    {
      "google": {
        "name": "Google",
        "api": "https://generativelanguage.googleapis.com/v1beta",
        "models": {
          "gemini-3-pro": {
            "id": "gemini-3-pro",
            "name": "Gemini 3 Pro",
            "reasoning": true,
            "reasoning_options": [{"type": "effort", "values": ["none", "high"]}],
            "limit": {"context": 1048576, "output": 65536},
            "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]}
          }
        }
      }
    }
    """
}
