import XCTest

@testable import PIiOSCore

final class ProviderImportComposerTests: XCTestCase {
    func testECMAScriptTrimUsesHostWhitespaceSetIncludingBOM() {
        let whitespace = "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}"
            + "\u{1680}\u{2000}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
        XCTAssertEqual(ECMAScriptString.trim(whitespace + "model/a" + whitespace), "model/a")

        // Foundation trims these, but JavaScript String.prototype.trim() does not.
        XCTAssertEqual(ECMAScriptString.trim("\u{0085}model\u{200B}"), "\u{0085}model\u{200B}")
        XCTAssertTrue(ECMAScriptString.isTrimmed("model/a"))
        XCTAssertFalse(ECMAScriptString.isTrimmed("\u{FEFF}model/a"))
    }

    func testRawPayloadWithBOMTextFailsLocalValidation() {
        var input = Self.validInput()
        input.secretValue = "\u{FEFF}secret"
        input.models[0].id = "\u{FEFF}model/a"
        input.models[0].alias = "Alias\u{FEFF}"
        input.defaultModelId = input.models[0].id

        let issues = ProviderImportValidation.issues(in: ProviderImportPayload.make(inputs: [input]))

        XCTAssertTrue(issues.contains { $0.path.hasSuffix(".secretValue") })
        XCTAssertTrue(issues.contains { $0.path.hasSuffix(".models[0].id") })
        XCTAssertTrue(issues.contains { $0.path.hasSuffix(".models[0].alias") })
    }

    func testComposerNormalizesBOMFromSafeFieldsAndModelText() throws {
        let base = ProviderModelSpec(
            id: "unused",
            contextWindow: 1,
            maxTokens: 1,
            thinkingLevels: [],
            supportsImages: true
        )
        let spec = ProviderImportComposer.modelSpec(from: ProviderModelDraftInput(
            base: base,
            modelId: "\u{FEFF}gemini-3.8-flash-high\u{FEFF}",
            displayName: "\u{FEFF}Gemini 3.8 Flash High\u{FEFF}",
            contextWindow: "\u{FEFF}128000\u{FEFF}",
            maxTokens: "\u{FEFF}8192\u{FEFF}",
            thinkingLevels: "\u{FEFF}off\u{FEFF}, \u{FEFF}high\u{FEFF}",
            defaultThinkingLevel: "\u{FEFF}high\u{FEFF}"
        ))

        XCTAssertEqual(spec.id, "gemini-3.8-flash-high")
        XCTAssertEqual(spec.alias, "Gemini 3.8 Flash High")
        XCTAssertEqual(spec.contextWindow, 128_000)
        XCTAssertEqual(spec.maxTokens, 8_192)
        XCTAssertEqual(spec.thinkingLevels, ["off", "high"])
        XCTAssertEqual(spec.defaultThinkingLevel, "high")
        XCTAssertEqual(spec.supportsImages, true)

        let composition = ProviderImportComposer.compose(
            serviceName: "\u{FEFF}Antigravity\u{FEFF}",
            baseURL: "\u{FEFF}http://203.0.113.10:8080/antigravity\u{FEFF}",
            apiKey: "\u{FEFF}sk-test\u{FEFF}",
            models: [spec],
            setDefaultModel: true
        )

        XCTAssertEqual(composition.input.name, "Antigravity")
        XCTAssertEqual(composition.input.vendorKey, "custom")
        XCTAssertEqual(composition.input.baseUrl, "http://203.0.113.10:8080/antigravity")
        XCTAssertEqual(composition.input.secretValue, "sk-test")
        XCTAssertTrue(composition.issues.isEmpty, "\(composition.issues)")
        let encoded = try ProviderImportEncoder.encodeToString(composition.payload)
        XCTAssertFalse(encoded.contains("\u{FEFF}"))
    }

    func testComposerPreservesEmptyThinkingLevelsAndNullDefault() throws {
        let spec = ProviderImportComposer.modelSpec(from: ProviderModelDraftInput(
            base: Self.plainSpec,
            modelId: " gemini-3.8-flash-high ",
            displayName: "",
            contextWindow: "128000",
            maxTokens: "8192",
            thinkingLevels: "  ",
            defaultThinkingLevel: " "
        ))

        XCTAssertEqual(spec.thinkingLevels, [])
        XCTAssertNil(spec.defaultThinkingLevel)
        let composition = ProviderImportComposer.compose(
            serviceName: "Antigravity",
            baseURL: "http://203.0.113.10:8080/antigravity",
            apiKey: "sk-test",
            models: [spec],
            setDefaultModel: true
        )
        XCTAssertTrue(composition.issues.isEmpty, "\(composition.issues)")
        let encoded = try ProviderImportEncoder.encodeToString(composition.payload)
        XCTAssertTrue(encoded.contains("\"defaultThinkingLevel\":null"))
    }

    func testComposerAliasIsUsedOnlyWhenItDiffersFromModelID() {
        let cases: [(modelId: String, displayName: String, expected: String?)] = [
            ("model/a", "  Model A  ", "Model A"),
            ("model/a", " model/a ", nil),
            ("model/a", "   ", nil),
            ("model/a", "\u{FEFF}model/a\u{FEFF}", nil),
        ]

        for item in cases {
            let spec = ProviderImportComposer.modelSpec(from: ProviderModelDraftInput(
                base: Self.plainSpec,
                modelId: item.modelId,
                displayName: item.displayName,
                contextWindow: "128000",
                maxTokens: "8192",
                thinkingLevels: "",
                defaultThinkingLevel: ""
            ))
            XCTAssertEqual(spec.alias, item.expected, "modelId=\(item.modelId) displayName=\(item.displayName)")
        }
    }

    func testComposerSetsFirstModelAsDefaultOnlyForFirstProvider() throws {
        let first = Self.model(id: "first")
        let second = Self.model(id: "second")

        let firstProvider = ProviderImportComposer.compose(
            serviceName: "Antigravity",
            baseURL: "http://203.0.113.10:8080/antigravity",
            apiKey: "sk-test",
            models: [first, second],
            setDefaultModel: true
        )
        XCTAssertEqual(firstProvider.input.defaultModelId, "first")
        XCTAssertEqual(firstProvider.payload.defaultModel?.modelId, "first")
        XCTAssertEqual(firstProvider.payload.defaultModel?.sourceId, firstProvider.payload.providers[0].sourceId)
        XCTAssertTrue(firstProvider.issues.isEmpty, "\(firstProvider.issues)")

        let laterProvider = ProviderImportComposer.compose(
            serviceName: "Antigravity",
            baseURL: "http://203.0.113.10:8080/antigravity",
            apiKey: "sk-test",
            models: [first, second],
            setDefaultModel: false
        )
        XCTAssertNil(laterProvider.input.defaultModelId)
        XCTAssertNil(laterProvider.payload.defaultModel)
        XCTAssertEqual(laterProvider.input.models.map(\.id), ["first", "second"])
        XCTAssertTrue(laterProvider.issues.isEmpty, "\(laterProvider.issues)")
    }

    func testBOMModelIDNormalizedBeforeResolutionPreservesCatalogCapabilities() throws {
        let catalog = try ModelsDevCatalog(data: Data(#"{"google":{"name":"Google","models":{"gemini-3-pro":{"id":"gemini-3-pro","name":"Gemini","reasoning":true,"limit":{"context":1048576,"output":65536},"modalities":{"input":["text","image","pdf"]}}}}}"#.utf8))
        let models = [DiscoveredModel(modelId: "\u{FEFF}gemini-3-pro\u{FEFF}", displayName: "Gemini")]
            .map { discovered in
                var model = discovered
                model.modelId = ECMAScriptString.trim(model.modelId)
                return model
            }
        let candidate = try XCTUnwrap(ModelConfigurationResolver.resolve(models, catalog: catalog).first)
        XCTAssertEqual(candidate.spec.id, "gemini-3-pro")
        XCTAssertEqual(candidate.metadataSource, .modelsDev(provider: "google"))
        XCTAssertEqual(candidate.spec.contextWindow, 1_048_576)
        XCTAssertEqual(candidate.spec.maxTokens, 65_536)
        XCTAssertFalse(candidate.spec.thinkingLevels.isEmpty)
        XCTAssertEqual(candidate.spec.supportsImages, true)
        XCTAssertEqual(candidate.spec.supportsDocuments, true)

        let composition = ProviderImportComposer.compose(
            serviceName: "Google", baseURL: "https://models.example/v1", apiKey: "fixture-key",
            models: [candidate.spec], setDefaultModel: true
        )
        XCTAssertTrue(composition.isValid, "\(composition.issues)")
        XCTAssertEqual(composition.payload.defaultModel?.modelId, "gemini-3-pro")
    }

    func testDeepSeekPresetPreservesOfficialVendorKey() throws {
        let spec = ProviderModelSpec(
            id: "deepseek-flash",
            contextWindow: 1_048_576,
            maxTokens: 393_216,
            thinkingLevels: ["off", "low", "medium", "high", "max"],
            defaultThinkingLevel: "medium",
            supportsReasoningEffort: true,
            supportsImages: true
        )

        let composition = ProviderImportComposer.compose(
            serviceName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            apiKey: "test-key",
            models: [spec],
            setDefaultModel: true,
            vendorKey: "deepseek"
        )

        XCTAssertEqual(composition.input.vendorKey, "deepseek")
        XCTAssertEqual(composition.input.baseUrl, "https://api.deepseek.com")
        XCTAssertTrue(composition.isValid, "\(composition.issues)")
        let encoded = try ProviderImportEncoder.encodeToString(composition.payload)
        XCTAssertTrue(encoded.contains("\"vendorKey\":\"deepseek\""))
    }

    private static var plainSpec: ProviderModelSpec {
        ProviderModelSpec(
            id: "placeholder",
            contextWindow: 1,
            maxTokens: 1,
            thinkingLevels: []
        )
    }

    private static func model(id: String) -> ProviderModelSpec {
        ProviderModelSpec(
            id: id,
            contextWindow: 128_000,
            maxTokens: 8_192,
            thinkingLevels: []
        )
    }

    private static func validInput() -> ProviderCreateInput {
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
            secretValue: "sk-test",
            temperature: 0
        )
    }
}
