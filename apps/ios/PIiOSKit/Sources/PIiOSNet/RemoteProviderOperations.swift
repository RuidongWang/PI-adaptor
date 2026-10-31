import Foundation
import PIiOSCore

/// Operations that must run on the SSH host so API credentials never travel
/// directly from the phone to a plain-HTTP model gateway.
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
        transport: SSHTransport,
        payload: Data,
        dataDir: String? = nil,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderImportReceipt {
        var command = "node \"$HOME/.pi-desktop/pi-host/current/pi-host.js\" provider-import"
        if let dataDir {
            command += " --data-dir \(shellQuoted(dataDir))"
        }
        let result = try await transport.exec(command, stdin: payload, timeout: timeout)
        return ProviderImportReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    public static func removeProvider(
        transport: SSHTransport,
        payload: Data,
        dataDir: String? = nil,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderRemoveReceipt {
        var command = "node \"$HOME/.pi-desktop/pi-host/current/pi-host.js\" provider-remove"
        if let dataDir {
            command += " --data-dir \(shellQuoted(dataDir))"
        }
        let result = try await transport.exec(command, stdin: payload, timeout: timeout)
        return ProviderRemoveReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    public static func bindingStatus(
        transport: SSHTransport,
        sessionId: String,
        dataDir: String? = nil,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderBindingReceipt {
        var command = "node \"$HOME/.pi-desktop/pi-host/current/pi-host.js\" provider-binding-status"
        if let dataDir {
            command += " --data-dir \(shellQuoted(dataDir))"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(BindingStatusInput(sessionId: sessionId))
        let result = try await transport.exec(command, stdin: payload, timeout: timeout)
        return ProviderBindingReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    private struct DiscoveryInput: Codable {
        var url: String
        var apiKey: String
        var timeout: Int
    }

    private struct BindingStatusInput: Codable {
        var version = 1
        var sessionId: String
    }

    private static func modelDiscoveryCommand() -> String {
        let encoded = Data(discoveryScript.utf8).base64EncodedString()
        return "python3 -c \"import base64;exec(base64.b64decode('\(encoded)'))\""
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
