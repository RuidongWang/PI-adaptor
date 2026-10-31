import Foundation
import XCTest
@testable import PIiOSCore

final class SessionRequestKeyStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("requests.json") }
    private var store: SessionRequestKeyStore { SessionRequestKeyStore(fileURL: fileURL) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func identity(
        host: String = "host-fixture", session: String = "session-fixture", item: String? = nil,
        action: SessionRequestAction = .turn(text: "fixture message")
    ) -> SessionRequestIdentity {
        SessionRequestIdentity(hostID: host, sessionID: session, itemID: item, action: action)
    }

    func testTimeoutAndRestartReusePendingKeyForEveryAction() throws {
        let actions: [SessionRequestAction] = [
            .turn(text: "fixture message"), .approval(decision: .allowOnce, permissionMode: nil),
            .contract(decision: .approve, permissionMode: .ask), .input(answers: [["fixture answer"], nil]),
        ]
        for action in actions {
            let request = identity(item: "item-fixture", action: action)
            let first = try store.prepare(request)
            // Losing the response leaves the attempt pending; a fresh store represents relaunch.
            XCTAssertEqual(try store.prepare(request), first)
            XCTAssertEqual(try SessionRequestKeyStore(fileURL: fileURL).prepare(request), first)
        }
    }

    func testHostSessionAndItemAreIsolated() throws {
        let requests = [identity(), identity(host: "other-host"), identity(session: "other-session"),
                        identity(item: "item-one"), identity(item: "item-two")]
        let keys = try requests.map { try store.prepare($0).idempotencyKey }
        XCTAssertEqual(Set(keys).count, requests.count)
    }

    func testStructuredIdentityCannotCollideThroughSeparators() throws {
        let first = identity(session: "s#i", item: "j")
        let second = identity(session: "s", item: "i#j")
        XCTAssertNotEqual(try store.prepare(first).idempotencyKey, try store.prepare(second).idempotencyKey)
    }

    func testChangedTextGetsNewKeyAndOriginalPendingTextStillRetries() throws {
        let original = try store.prepare(identity())
        let edited = try store.prepare(identity(action: .turn(text: "different fixture message")))
        XCTAssertNotEqual(original.idempotencyKey, edited.idempotencyKey)
        XCTAssertEqual(try store.prepare(identity()), original)
    }

    func testChangedDecisionContractOrPermissionGetsNewKey() throws {
        let actions: [SessionRequestAction] = [
            .approval(decision: .allowOnce, permissionMode: nil),
            .approval(decision: .deny, permissionMode: nil),
            .approval(decision: .allowSession, permissionMode: .ask),
            .approval(decision: .allowSession, permissionMode: .auto),
            .contract(decision: .approve, permissionMode: .ask),
            .contract(decision: .approve, permissionMode: .auto),
            .contract(decision: .reject, permissionMode: .ask),
        ]
        let keys = try actions.map { try store.prepare(identity(item: "same-item", action: $0)).idempotencyKey }
        XCTAssertEqual(Set(keys).count, actions.count)
    }

    func testChangedAnswersIncludingSkipsOrderAndArrayBoundariesGetNewKeys() throws {
        let variants: [[[String]?]] = [
            [["a"], nil], [["b"], nil], [nil, ["a"]], [["a"], []],
            [["a", "b"]], [["a"], ["b"]], [["a,b"]],
        ]
        let keys = try variants.map {
            try store.prepare(identity(item: "input-fixture", action: .input(answers: $0))).idempotencyKey
        }
        XCTAssertEqual(Set(keys).count, variants.count)
    }

    func testAcknowledgementRetiresKeysForEveryActionAcrossRestart() throws {
        let actions: [SessionRequestAction] = [.turn(text: "fixture"), .input(answers: [nil]),
                                               .contract(decision: .approve, permissionMode: .ask), .approval(decision: .deny, permissionMode: nil)]
        for action in actions {
            let request = identity(item: "item", action: action)
            let first = try store.prepare(request)
            try store.acknowledge(first)
            XCTAssertNotEqual(try store.prepare(request).idempotencyKey, first.idempotencyKey)
        }
    }

    func testLateDuplicateAcknowledgementCannotRetireNewAttempt() throws {
        let first = try store.prepare(identity())
        try store.acknowledge(first)
        let next = try store.prepare(identity())
        try store.acknowledge(first)
        XCTAssertEqual(try store.prepare(identity()), next)
    }

    func testAcknowledgementDoesNotClearOtherHostsOrActions() throws {
        let original = try store.prepare(identity())
        let otherHost = try store.prepare(identity(host: "other"))
        let otherAction = try store.prepare(identity(action: .turn(text: "other")))
        try store.acknowledge(original)
        XCTAssertEqual(try store.prepare(identity(host: "other")), otherHost)
        XCTAssertEqual(try store.prepare(identity(action: .turn(text: "other"))), otherAction)
    }

    func testRetryPreservesOriginalAdmissionEvenAfterRestartAndRunningStateChanges() throws {
        let first = try store.prepare(identity(), admission: nil)
        XCTAssertEqual(try store.prepare(identity(), admission: .queue), first)
        try store.acknowledge(first)
        let queued = try store.prepare(identity(), admission: .queue)
        XCTAssertEqual(try store.prepare(identity(), admission: nil), queued)
        XCTAssertEqual(queued.admission, .queue)
    }

    func testMissingStorageFailsBeforeAnyKeyCanBeReturned() {
        XCTAssertThrowsError(try SessionRequestKeyStore(fileURL: nil).prepare(identity()))
        let invalidURL = directory.appendingPathComponent("missing/requests.json")
        XCTAssertThrowsError(try SessionRequestKeyStore(fileURL: invalidURL).prepare(identity()))
    }

    func testCorruptFileFailsClosedAndIsNotOverwritten() throws {
        let corrupt = Data("not-json-fixture".utf8)
        try corrupt.write(to: fileURL)
        XCTAssertThrowsError(try store.prepare(identity()))
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testUnknownSchemaVersionFailsClosed() throws {
        try assertBadFileIsPreserved(Data(#"{"version":99,"pending":{}}"#.utf8))
    }

    func testCorruptRecordsFailClosedIncludingUnrelatedRecords() throws {
        let digest = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let invalid: [[String: [String: String]]] = [
            [digest: ["fingerprint": other, "idempotencyKey": "request_one"]],
            [digest: ["fingerprint": digest, "idempotencyKey": ""]],
            [digest: ["fingerprint": digest, "idempotencyKey": " \n\t"]],
            ["invalid": ["fingerprint": "invalid", "idempotencyKey": "request_one"]],
            [digest: ["fingerprint": digest, "idempotencyKey": "request_same"],
             other: ["fingerprint": other, "idempotencyKey": "request_same"]],
        ]
        for pending in invalid {
            try assertBadFileIsPreserved(JSONSerialization.data(withJSONObject: ["version": 1, "pending": pending]))
        }
    }

    func testDuplicateJSONKeysIncludingEscapedAliasesFailClosed() throws {
        let digest = String(repeating: "a", count: 64)
        let escaped = "\\u0061" + String(digest.dropFirst())
        let record = #"{"fingerprint":"\#(digest)","idempotencyKey":"request_one"}"#
        for raw in [
            #"{"version":1,"version":1,"pending":{}}"#,
            #"{"version":1,"pending":{"\#(digest)":\#(record),"\#(escaped)":\#(record)}}"#,
            #"{"version":1,"pending":{"\#(digest)":{"fingerprint":"\#(digest)","idempotencyKey":"one","idempotencyKey":"two"}}}"#,
        ] { try assertBadFileIsPreserved(Data(raw.utf8)) }
    }

    private func assertBadFileIsPreserved(_ data: Data) throws {
        try data.write(to: fileURL)
        XCTAssertThrowsError(try store.prepare(identity()))
        XCTAssertThrowsError(try store.acknowledge(SessionRequestAttempt(fingerprint: "unused", idempotencyKey: "unused", admission: nil)))
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    func testPreparationAttributeFailureBlocksBothNewAndPersistedKey() throws {
        let failing = SessionRequestKeyStore(fileURL: fileURL, setResourceValues: { _ in throw AttributeFailure.fixture })
        XCTAssertThrowsError(try failing.prepare(identity()))
        let persisted = try Data(contentsOf: fileURL)
        XCTAssertThrowsError(try failing.prepare(identity(), admission: .queue))
        XCTAssertEqual(try Data(contentsOf: fileURL), persisted)
        let recovered = try store.prepare(identity())
        XCTAssertNil(recovered.admission)
        XCTAssertEqual(try store.prepare(identity()), recovered)
    }

    func testCommittedAcknowledgementIgnoresAttributeFailure() throws {
        let attempt = try store.prepare(identity())
        let failing = SessionRequestKeyStore(fileURL: fileURL, setResourceValues: { _ in throw AttributeFailure.fixture })
        XCTAssertNoThrow(try failing.acknowledge(attempt))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual((object["pending"] as? [String: Any])?.count, 0)
        let next = try store.prepare(identity())
        XCTAssertNotEqual(next.idempotencyKey, attempt.idempotencyKey)
        try failing.acknowledge(attempt)
        XCTAssertEqual(try store.prepare(identity()), next)
    }

    func testAcknowledgementFailureIsNotReportedAsSuccessfulRetirement() throws {
        let attempt = try store.prepare(identity())
        let original = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.acknowledge(attempt))
        try FileManager.default.removeItem(at: fileURL)
        try original.write(to: fileURL)
        XCTAssertEqual(try store.prepare(identity()), attempt)
    }

    func testConcurrentStoresAllocateOnlyOneKeyForSamePendingAction() throws {
        let requests = ConcurrentAttempts()
        let url = fileURL
        let request = identity()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            requests.add(Result { try SessionRequestKeyStore(fileURL: url).prepare(request).idempotencyKey })
        }
        XCTAssertEqual(requests.results.count, 16)
        let keys = try requests.results.map { try $0.get() }
        XCTAssertEqual(Set(keys).count, 1)
    }

    func testEmptyHostOrSessionCannotAllocateUnscopedKey() {
        XCTAssertThrowsError(try store.prepare(identity(host: "")))
        XCTAssertThrowsError(try store.prepare(identity(session: "")))
    }

    func testDiskContainsOnlyDigestsRandomKeysAndAdmission() throws {
        _ = try store.prepare(identity(item: "item-fixture", action: .input(answers: [["fixture answer"]])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "pending"])
        let pending = try XCTUnwrap(object["pending"] as? [String: [String: Any]])
        XCTAssertEqual(pending.count, 1)
        let digest = try XCTUnwrap(pending.keys.first)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
        let fields = try XCTUnwrap(pending[digest])
        XCTAssertEqual(Set(fields.keys), ["fingerprint", "idempotencyKey"])
        XCTAssertEqual(fields["fingerprint"] as? String, digest)
        XCTAssertTrue((fields["idempotencyKey"] as? String)?.hasPrefix("request_") == true)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        for fixture in ["host-fixture", "session-fixture", "item-fixture", "fixture answer"] {
            XCTAssertFalse(text.contains(fixture))
        }
    }

    func testSnapshotRebuildDoesNotDiscardPendingRequestIdentity() throws {
        let request = identity(item: "item-fixture", action: .input(answers: [["fixture"]]))
        let attempt = try store.prepare(request)
        let model = SessionViewModel()
        model.beginDraft(idempotencyKey: "draft-fixture", text: "fixture")
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "new", sequence: 1), revision: 20), replayComplete: false)
        XCTAssertNil(model.draft)
        XCTAssertEqual(try store.prepare(request), attempt)
    }
}

private enum AttributeFailure: Error { case fixture }

private final class ConcurrentAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [Result<String, Error>] = []

    func add(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
    }
}
