import Foundation
import PIiOSCore

public protocol RACPV2Requesting: Sendable {
    func v2Request<R: Decodable & Sendable>(
        method: String,
        params: JSONValue,
        timeout: TimeInterval
    ) async throws -> R
}

extension RACPClient: RACPV2Requesting {}

/// Host operations for RACP v2 provider management plus the SSH-isolated
/// `/models` discovery probe. Provider writes never invoke a provider CLI.
public enum RemoteProviderOperations {
    public static let userVisibleTimeout: TimeInterval = 10

    public static func discoverModels(
        transport: SSHTransport,
        requestURL: String,
        apiKey: String,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> [DiscoveredModel] {
        let modelsURL = try ModelListParser.modelsURL(baseURL: requestURL)
        let input = DiscoveryInput(url: modelsURL, apiKey: apiKey, timeout: 7)
        let data = try JSONEncoder().encode(input)
        let result = try await transport.exec(
            modelDiscoveryCommand(),
            stdin: data,
            timeout: timeout
        )
        return try RemoteModelListEnvelope.parse(
            stdout: result.stdoutText,
            exitStatus: Int32(clamping: result.exitStatus)
        )
    }

    public static func importProviders(
        client: any RACPV2Requesting,
        payload: ProviderImportPayload,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderImportReceipt {
        guard payload.version == ProviderImportPayload.supportedVersion else {
            return .failure(.init(code: .invalidRequest))
        }
        let budget = ProviderOperationBudget(timeout: timeout)
        var imported: [ProviderImportImported] = []
        var defaultSet = false
        for entry in payload.providers {
            do {
                let result: ProviderEnvelope = try await client.v2Request(
                    method: RACPV2Method.providerCreate.rawValue,
                    params: .object([
                        "provider": providerCreateValue(for: entry),
                        "context": writeContext(
                            prefix: "provider_import",
                            stableSuffix: entry.sourceId
                        ),
                    ]),
                    timeout: try budget.remaining()
                )
                imported.append(
                    ProviderImportImported(
                        sourceId: entry.sourceId,
                        providerId: result.provider.id
                    )
                )
                if payload.defaultModel?.sourceId == entry.sourceId {
                    defaultSet = result.provider.isDefault
                        && result.provider.models.contains {
                            $0.id == payload.defaultModel?.modelId
                        }
                }
            } catch is ProviderOperationDeadlineExceeded {
                return .failure(ProviderImportFailure(code: .timeout))
            } catch let error as RACPV2Error {
                return .failure(ProviderImportFailure(code: importFailure(for: error)))
            }
        }
        return .success(
            ProviderImportSuccess(
                imported: imported,
                skipped: [],
                defaultSet: defaultSet
            )
        )
    }

    public static func removeProvider(
        client: any RACPV2Requesting,
        providerId: String,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderRemoveReceipt {
        guard !providerId.isEmpty else {
            return .failure(.invalidRequest)
        }
        let budget = ProviderOperationBudget(timeout: timeout)
        do {
            let result: DeleteEnvelope = try await client.v2Request(
                method: RACPV2Method.providerDelete.rawValue,
                params: .object([
                    "providerId": .string(providerId),
                    "confirmProviderId": .string(providerId),
                    "context": writeContext(
                        prefix: "provider_delete",
                        stableSuffix: providerId
                    ),
                ]),
                timeout: try budget.remaining()
            )
            let remaining: Int
            if let remainingTimeout = try? budget.remaining() {
                remaining = (try? await providerList(
                    client: client,
                    timeout: remainingTimeout
                ).count) ?? -1
            } else {
                remaining = -1
            }
            return .success(
                ProviderRemoveSummary(
                    providerId: providerId,
                    effect: result.deleted ? .deleted : .absent,
                    secretCleared: true,
                    defaultMoved: nil,
                    remaining: remaining,
                    remainingEligible: remaining
                )
            )
        } catch is ProviderOperationDeadlineExceeded {
            return .failure(.timeout)
        } catch let error as RACPV2Error {
            if case .server(let code, _) = error, code == "NOT_FOUND" {
                return .success(
                    ProviderRemoveSummary(
                        providerId: providerId,
                        effect: .absent,
                        secretCleared: true,
                        defaultMoved: nil,
                        remaining: 0,
                        remainingEligible: 0
                    )
                )
            }
            return .failure(removeFailure(for: error))
        }
    }

    public static func bindingStatus(
        client: any RACPV2Requesting,
        sessionId: String,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderBindingReceipt {
        guard !sessionId.isEmpty else {
            return .failure(.invalidRequest)
        }
        let budget = ProviderOperationBudget(timeout: timeout)
        do {
            let session: SessionEnvelope = try await client.v2Request(
                method: RACPV2Method.sessionGet.rawValue,
                params: .object(["sessionId": .string(sessionId)]),
                timeout: try budget.remaining()
            )
            let providers = try await providerList(
                client: client,
                timeout: try budget.remaining()
            )
            let providerId = session.session.providerId
            let modelId = session.session.modelId
            let observedAt = ISO8601DateFormatter().string(from: Date())
            func status(
                available: Bool?,
                reason: String?,
                effective: Bool
            ) -> ProviderBindingStatus {
                ProviderBindingStatus(
                    sessionId: sessionId,
                    pinnedProviderId: providerId,
                    pinnedModelId: modelId,
                    pinnedThinkingLevel: session.session.thinkingLevel,
                    effectiveProviderId: effective ? providerId : nil,
                    effectiveModelId: effective ? modelId : nil,
                    available: available,
                    unavailableReason: reason,
                    unknownInputs: [],
                    observedAt: observedAt
                )
            }
            guard let providerId, !providerId.isEmpty,
                  let modelId, !modelId.isEmpty
            else {
                return .success(status(available: false, reason: "no_candidate", effective: false))
            }
            guard let provider = providers.first(where: { $0.id == providerId }) else {
                return .success(status(available: false, reason: "provider_missing", effective: false))
            }
            guard !provider.models.isEmpty else {
                return .success(status(available: false, reason: "models_empty", effective: false))
            }
            guard provider.models.contains(where: { $0.id == modelId }) else {
                return .success(status(available: false, reason: "model_removed", effective: false))
            }
            if provider.authKind != "none", !provider.hasApiKey {
                return .success(status(available: false, reason: "secret_missing", effective: false))
            }
            return .success(status(available: true, reason: nil, effective: true))
        } catch is ProviderOperationDeadlineExceeded {
            return .failure(.timeout)
        } catch let error as RACPV2Error {
            return .failure(importFailure(for: error))
        }
    }

    private struct ProviderEnvelope: Decodable, Sendable {
        var provider: RACPV2Provider
    }

    private struct ProviderListEnvelope: Decodable, Sendable {
        var providers: [RACPV2Provider]
    }

    private struct DeleteEnvelope: Decodable, Sendable {
        var deleted: Bool
    }

    private struct SessionEnvelope: Decodable, Sendable {
        struct Session: Decodable, Sendable {
            var providerId: String?
            var modelId: String?
            var thinkingLevel: String?
        }
        var session: Session
    }

    private struct ProviderOperationDeadlineExceeded: Error {}

    private struct ProviderOperationBudget {
        private let deadline: ContinuousClock.Instant

        init(timeout: TimeInterval) {
            deadline = ContinuousClock.now.advanced(
                by: .seconds(max(0, timeout))
            )
        }

        func remaining() throws -> TimeInterval {
            let components = ContinuousClock.now
                .duration(to: deadline)
                .components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            guard seconds > 0 else {
                throw ProviderOperationDeadlineExceeded()
            }
            return seconds
        }
    }

    private static func providerList(
        client: any RACPV2Requesting,
        timeout: TimeInterval
    ) async throws -> [RACPV2Provider] {
        let result: ProviderListEnvelope = try await client.v2Request(
            method: RACPV2Method.providerList.rawValue,
            params: .object([:]),
            timeout: timeout
        )
        return result.providers
    }

    private static func providerCreateValue(
        for entry: ProviderImportEntry
    ) -> JSONValue {
        let input = entry.input
        var fields: [String: JSONValue] = [
            "name": .string(input.name),
            "vendorKey": .string(providerVendorKey(for: entry)),
            "type": .string(input.type),
            "protocol": .string(input.protocol),
            "baseUrl": .string(input.baseUrl ?? ""),
            "authKind": .string(
                input.authKind == "none" ? "none" : "api_key"
            ),
            "models": .array(input.models.map(providerModelValue)),
        ]
        if input.authKind != "none",
           let secret = input.secretValue,
           !secret.isEmpty {
            fields["apiKey"] = .string(secret)
        }
        return .object(fields)
    }

    private static func providerVendorKey(
        for entry: ProviderImportEntry
    ) -> String {
        "pi-ios-\(entry.sourceId)"
    }

    private static func providerModelValue(
        _ model: ProviderModelSpec
    ) -> JSONValue {
        .object([
            "id": .string(model.id),
            "displayName": .string(model.alias ?? model.id),
            "contextWindow": .number(Double(model.contextWindow)),
            "maxTokens": .number(Double(model.maxTokens)),
            "thinkingLevels": .array(model.thinkingLevels.map(JSONValue.string)),
            "defaultThinkingLevel": model.defaultThinkingLevel.map(JSONValue.string) ?? .null,
            "supportsImages": .bool(model.supportsImages ?? false),
        ])
    }

    private static func writeContext(
        prefix: String,
        stableSuffix: String
    ) -> JSONValue {
        .object([
            "requestId": .string("req_\(UUID().uuidString)"),
            "idempotencyKey": .string("\(prefix)_\(stableSuffix)"),
        ])
    }

    private static func importFailure(for error: RACPV2Error) -> ProviderImportFailureCode {
        guard case .server(let code, _) = error else { return .importFailed }
        switch code {
        case "INVALID_ARGUMENT", "INVALID_REQUEST": return .invalidRequest
        case "PAYLOAD_TOO_LARGE": return .payloadTooLarge
        case "TIMEOUT", "DEADLINE_EXCEEDED": return .timeout
        case "CONFLICT": return .conflict
        default: return .importFailed
        }
    }

    private static func removeFailure(for error: RACPV2Error) -> ProviderRemoveFailureCode {
        guard case .server(let code, _) = error else { return .removeFailed }
        switch code {
        case "INVALID_ARGUMENT", "INVALID_REQUEST": return .invalidRequest
        case "PAYLOAD_TOO_LARGE": return .payloadTooLarge
        case "TIMEOUT", "DEADLINE_EXCEEDED": return .timeout
        default: return .removeFailed
        }
    }

    private struct DiscoveryInput: Codable {
        var url: String
        var apiKey: String
        var timeout: Int
    }

    private static func modelDiscoveryCommand() -> String {
        let encoded = Data(discoveryScript.utf8).base64EncodedString()
        return "python3 -c \"import base64;exec(base64.b64decode('\(encoded)'))\""
    }

    private static let discoveryScript = """
import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

payload = json.loads(sys.stdin.read())
url = payload["url"]
api_key = payload.get("apiKey", "")
timeout = float(payload.get("timeout", 12))

class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old = urllib.parse.urlsplit(req.full_url)
        new = urllib.parse.urlsplit(newurl)
        if (old.scheme, old.netloc) != (new.scheme, new.netloc):
            raise RuntimeError("cross-origin redirect refused")
        return super().redirect_request(req, fp, code, msg, headers, newurl)

try:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": "Bearer " + api_key,
            "Accept": "application/json",
            "User-Agent": "PI-IOS/0.1",
        },
    )
    opener = urllib.request.build_opener(SameOriginRedirect())
    with opener.open(request, timeout=timeout) as response:
        raw = response.read(2 * 1024 * 1024)
        result = {
            "status": response.status,
            "url": response.geturl(),
            "body": raw.decode("utf-8", "replace"),
        }
except urllib.error.HTTPError as error:
    raw = error.read(64 * 1024)
    result = {
        "status": error.code,
        "url": url,
        "body": raw.decode("utf-8", "replace"),
    }
except Exception as error:
    result = {
        "status": 0,
        "url": url,
        "body": "",
        "error": type(error).__name__ + ": " + str(error),
    }

print("PI_MODELS_RESULT " + json.dumps(result, ensure_ascii=False, separators=(",", ":")))
"""
}

/// Explicit compatibility path for pre-PI-adaptor `pi-host` installations.
/// PI-adaptor installs and normal provider operations must never call this CLI.
public enum LegacyRemoteProviderOperations {
    public static func importProviders(
        transport: SSHTransport,
        payload: Data,
        dataDir: String? = nil,
        timeout: TimeInterval = RemoteProviderOperations.userVisibleTimeout
    ) async throws -> ProviderImportReceipt {
        let result = try await transport.exec(
            command("provider-import", dataDir: dataDir),
            stdin: payload,
            timeout: timeout
        )
        return ProviderImportReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    public static func removeProvider(
        transport: SSHTransport,
        payload: Data,
        dataDir: String? = nil,
        timeout: TimeInterval = RemoteProviderOperations.userVisibleTimeout
    ) async throws -> ProviderRemoveReceipt {
        let result = try await transport.exec(
            command("provider-remove", dataDir: dataDir),
            stdin: payload,
            timeout: timeout
        )
        return ProviderRemoveReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    public static func bindingStatus(
        transport: SSHTransport,
        sessionId: String,
        dataDir: String? = nil,
        timeout: TimeInterval = RemoteProviderOperations.userVisibleTimeout
    ) async throws -> ProviderBindingReceipt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(BindingStatusInput(sessionId: sessionId))
        let result = try await transport.exec(
            command("provider-binding-status", dataDir: dataDir),
            stdin: payload,
            timeout: timeout
        )
        return ProviderBindingReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    private struct BindingStatusInput: Codable {
        var version = 1
        var sessionId: String
    }

    private static func command(_ subcommand: String, dataDir: String?) -> String {
        var command =
            "node \"$HOME/.pi-desktop/pi-host/current/pi-host.js\" \(subcommand)"
        if let dataDir {
            let quoted = "'" + dataDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
            command += " --data-dir \(quoted)"
        }
        return command
    }
}
