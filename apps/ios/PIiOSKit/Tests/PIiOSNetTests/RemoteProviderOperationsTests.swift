import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

final class RemoteProviderOperationsTests: XCTestCase {
    func testImportUsesProviderCreateWithWriteContext() async throws {
        let client = RecordingProviderV2Client()
        let payload = ProviderImportPayload.make(
            inputs: [
                ProviderCreateInput(
                    name: "DeepSeek",
                    vendorKey: "deepseek",
                    type: "openai_compatible",
                    protocol: "openai_compatible",
                    authKind: "api_key_and_base_url",
                    baseUrl: "https://api.deepseek.com",
                    models: [
                        ProviderModelSpec(
                            id: "deepseek-chat",
                            contextWindow: 128_000,
                            maxTokens: 8_192,
                            thinkingLevels: ["off", "high"]
                        ),
                    ],
                    secretValue: "sk-test",
                    defaultModelId: "deepseek-chat"
                ),
            ],
            defaultSelection: ProviderImportDefaultSelection(
                providerIndex: 0,
                modelId: "deepseek-chat"
            )
        )

        let receipt = try await RemoteProviderOperations.importProviders(
            client: client,
            payload: payload
        )
        guard case .success(let success) = receipt else {
            return XCTFail("应导入成功：\(receipt)")
        }
        XCTAssertEqual(success.imported.first?.providerId, "prv_v2")
        XCTAssertTrue(success.defaultSet)

        let recordedCreate = await client.request(named: "provider/create")
        let request = try XCTUnwrap(recordedCreate)
        XCTAssertEqual(request.method, "provider/create")
        XCTAssertEqual(
            request.params.value(at: ["provider", "authKind"])?.stringValue,
            "api_key"
        )
        XCTAssertEqual(
            request.params.value(at: ["provider", "apiKey"])?.stringValue,
            "sk-test"
        )
        XCTAssertNotNil(
            request.params.value(at: ["context", "requestId"])?.stringValue
        )
        XCTAssertNotNil(
            request.params.value(at: ["context", "idempotencyKey"])?.stringValue
        )
    }

    func testDeleteUsesProviderDeleteAndNeverExecutesCLI() async throws {
        let client = RecordingProviderV2Client()
        let receipt = try await RemoteProviderOperations.removeProvider(
            client: client,
            providerId: "prv_v2"
        )
        guard case .success(let summary) = receipt else {
            return XCTFail("应删除成功：\(receipt)")
        }
        XCTAssertEqual(summary.effect, .deleted)

        let methods = await client.methods()
        XCTAssertEqual(methods, ["provider/delete", "provider/list"])
        let recordedDelete = await client.request(named: "provider/delete")
        let request = try XCTUnwrap(recordedDelete)
        XCTAssertEqual(
            request.params.value(at: ["confirmProviderId"])?.stringValue,
            "prv_v2"
        )
        XCTAssertNotNil(
            request.params.value(at: ["context", "requestId"])?.stringValue
        )
        XCTAssertNotNil(
            request.params.value(at: ["context", "idempotencyKey"])?.stringValue
        )
        XCTAssertFalse(methods.contains { $0.contains("main.js") })
    }

    func testBindingUsesV2SessionAndProviderList() async throws {
        let client = RecordingProviderV2Client()
        let receipt = try await RemoteProviderOperations.bindingStatus(
            client: client,
            sessionId: "session_1"
        )
        guard case .success(let status) = receipt else {
            return XCTFail("应取得绑定状态：\(receipt)")
        }
        XCTAssertEqual(status.pinnedProviderId, "prv_v2")
        XCTAssertEqual(status.pinnedModelId, "model_1")
        XCTAssertEqual(status.available, true)
        let methods = await client.methods()
        XCTAssertEqual(methods, ["session/get", "provider/list"])
    }

    func testCreateConflictNeverClaimsExistingProviderAsImported() async throws {
        let client = RecordingProviderV2Client(
            createError: .server(
                code: "CONFLICT",
                message: "provider vendorKey already exists"
            )
        )
        let input = ProviderCreateInput(
            name: "DeepSeek",
            vendorKey: "deepseek",
            type: "openai_compatible",
            protocol: "openai_compatible",
            authKind: "api_key_and_base_url",
            baseUrl: "https://api.deepseek.com",
            models: [
                ProviderModelSpec(
                    id: "deepseek-chat",
                    contextWindow: 128_000,
                    maxTokens: 8_192,
                    thinkingLevels: ["off", "high"]
                ),
            ],
            secretValue: "new-secret"
        )
        let receipt = try await RemoteProviderOperations.importProviders(
            client: client,
            payload: ProviderImportPayload.make(inputs: [input])
        )
        guard case .failure(let failure) = receipt else {
            return XCTFail("CONFLICT 无法证明远端配置一致，必须失败：\(receipt)")
        }
        XCTAssertEqual(failure.code, .conflict)
        XCTAssertTrue(failure.displayMessage.contains("编辑"))
        XCTAssertTrue(failure.displayMessage.contains("覆盖"))
        let methods = await client.methods()
        XCTAssertEqual(methods, ["provider/create"])
    }

    func testBindingSecondRPCUsesRemainingAggregateBudget() async throws {
        let client = RecordingProviderV2Client(
            delays: ["session/get": 0.12]
        )
        let receipt = try await RemoteProviderOperations.bindingStatus(
            client: client,
            sessionId: "session_1",
            timeout: 0.30
        )
        guard case .success = receipt else {
            return XCTFail("绑定查询应成功：\(receipt)")
        }
        let requests = await client.requests()
        XCTAssertEqual(requests.map(\.method), ["session/get", "provider/list"])
        let firstTimeout = try XCTUnwrap(requests.first?.timeout)
        let secondTimeout = try XCTUnwrap(requests.last?.timeout)
        XCTAssertLessThan(secondTimeout, firstTimeout)
        XCTAssertLessThan(secondTimeout, 0.25)
        XCTAssertGreaterThan(secondTimeout, 0)
    }
}

private struct RecordedV2Request: Equatable, Sendable {
    let method: String
    let params: JSONValue
    let timeout: TimeInterval
}

private actor RecordingProviderV2Client: RACPV2Requesting {
    private var records: [RecordedV2Request] = []
    private let delays: [String: TimeInterval]
    private let createError: RACPV2Error?

    init(
        delays: [String: TimeInterval] = [:],
        createError: RACPV2Error? = nil
    ) {
        self.delays = delays
        self.createError = createError
    }

    func v2Request<R: Decodable & Sendable>(
        method: String,
        params: JSONValue,
        timeout: TimeInterval
    ) async throws -> R {
        records.append(
            RecordedV2Request(
                method: method,
                params: params,
                timeout: timeout
            )
        )
        if let delay = delays[method] {
            try await Task.sleep(
                nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
            )
        }
        if method == "provider/create", let createError {
            throw createError
        }
        let requestedModelId = params.value(
            at: ["provider", "models"]
        )?.arrayValue?.first?.value(at: ["id"])?.stringValue
        let provider = makeProvider(modelID: requestedModelId ?? "model_1")
        let value: JSONValue
        switch method {
        case "provider/create", "provider/update":
            value = .object(["provider": provider])
        case "provider/list":
            value = .object(["providers": .array([provider])])
        case "provider/delete":
            value = .object(["deleted": .bool(true)])
        case "session/get":
            value = .object([
                "session": .object([
                    "providerId": .string("prv_v2"),
                    "modelId": .string("model_1"),
                    "thinkingLevel": .string("off"),
                ]),
            ])
        default:
            throw RACPV2Error.protocolViolation("unexpected method \(method)")
        }
        return try R.decoded(from: value)
    }

    private func makeProvider(modelID: String) -> JSONValue {
        .object([
            "id": .string("prv_v2"),
            "name": .string("DeepSeek"),
            "vendorKey": .string("pi-ios-source"),
            "type": .string("openai_compatible"),
            "protocol": .string("openai_compatible"),
            "baseUrl": .string("https://api.deepseek.com"),
            "authKind": .string("api_key"),
            "hasApiKey": .bool(true),
            "apiKeyMask": .string("sk-…test"),
            "isDefault": .bool(true),
            "models": .array([
                .object([
                    "id": .string(modelID),
                    "displayName": .string("Model 1"),
                    "contextWindow": .number(128_000),
                    "maxTokens": .number(8_192),
                    "thinkingLevels": .array([.string("off"), .string("high")]),
                    "defaultThinkingLevel": .string("off"),
                    "supportsImages": .bool(false),
                ]),
            ]),
            "createdAt": .string("2026-11-01T00:00:00Z"),
            "updatedAt": .string("2026-11-01T00:00:00Z"),
        ])
    }

    func methods() -> [String] {
        records.map(\.method)
    }

    func requests() -> [RecordedV2Request] {
        records
    }

    func request(named method: String) -> RecordedV2Request? {
        records.first { $0.method == method }
    }
}
