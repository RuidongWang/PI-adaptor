import Foundation
import XCTest

@testable import PIiOSCore

final class BootstrapStagedCredentialTests: XCTestCase {
    func testRecoveryEnumeratesOnlyAttemptScopedPDT2RecordsForHost() throws {
        let hostID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherHostID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let staged = try XCTUnwrap(
            BootstrapStagedCredential(
                hostID: hostID,
                attemptId: "ios-attempt-1",
                targetPort: 43_871,
                deviceId: "dev_staged",
                deviceToken: "pdt2." + "test",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        let account = BootstrapStagedCredential.account(
            hostID: hostID,
            attemptId: staged.attemptId
        )
        let data = try JSONEncoder().encode(staged)

        let other = try XCTUnwrap(
            BootstrapStagedCredential(
                hostID: otherHostID,
                attemptId: "ios-attempt-2",
                targetPort: 43_872,
                deviceId: "dev_other",
                deviceToken: "pdt2." + "test"
            )
        )
        let otherAccount = BootstrapStagedCredential.account(
            hostID: otherHostID,
            attemptId: other.attemptId
        )
        let otherData = try JSONEncoder().encode(other)

        let recovered = BootstrapStagedCredential.recoverable(
            from: [
                (account: account, data: data),
                (account: otherAccount, data: otherData),
                (account: "host-token:\(hostID.uuidString.lowercased())", data: data),
                (account: account + "-tampered", data: data),
            ],
            expectedHostID: hostID
        )
        XCTAssertEqual(recovered, [staged])
        XCTAssertEqual(recovered.first?.targetPort, 43_871)
        XCTAssertEqual(recovered.first?.attemptId, "ios-attempt-1")
    }

    func testStagingRejectsLegacyTokenAndUnsafeAttempt() {
        let hostID = UUID()
        XCTAssertNil(
            BootstrapStagedCredential(
                hostID: hostID,
                attemptId: "safe",
                targetPort: 42_000,
                deviceId: "dev",
                deviceToken: "pdt1." + "legacy"
            )
        )
        XCTAssertNil(
            BootstrapStagedCredential(
                hostID: hostID,
                attemptId: "../escape",
                targetPort: 42_000,
                deviceId: "dev",
                deviceToken: "pdt2." + "test"
            )
        )
    }

    func testPromotedStagingIsClearedWithoutRevokeAcrossRecoveryAttempts() async throws {
        let staged = try XCTUnwrap(
            BootstrapStagedCredential(
                hostID: UUID(),
                attemptId: "promoted-attempt",
                targetPort: 43_871,
                deviceId: "dev_promoted",
                deviceToken: "pdt2." + "promoted"
            )
        )
        await assertPromotedRecoveryKeepsTokenAlive(staged)
    }

    private func assertPromotedRecoveryKeepsTokenAlive(
        _ staged: BootstrapStagedCredential
    ) async {
        let calls = RecoveryCalls(clearFailuresRemaining: 1)
        let firstRemaining = await BootstrapStagingRecoveryCoordinator.recover(
            staging: [staged],
            activeDeviceId: staged.deviceId,
            activeDeviceToken: staged.deviceToken,
            revoke: { _ in await calls.recordRevoke() },
            clear: { _ in await calls.recordClear() }
        )
        XCTAssertEqual(firstRemaining, [staged])
        let firstRevokeCount = await calls.revokeCount
        let firstClearCount = await calls.clearCount
        XCTAssertEqual(firstRevokeCount, 0)
        XCTAssertEqual(firstClearCount, 1)

        let secondRemaining = await BootstrapStagingRecoveryCoordinator.recover(
            staging: firstRemaining,
            activeDeviceId: staged.deviceId,
            activeDeviceToken: staged.deviceToken,
            revoke: { _ in await calls.recordRevoke() },
            clear: { _ in await calls.recordClear() }
        )
        XCTAssertTrue(secondRemaining.isEmpty)
        let secondRevokeCount = await calls.revokeCount
        let secondClearCount = await calls.clearCount
        XCTAssertEqual(secondRevokeCount, 0)
        XCTAssertEqual(secondClearCount, 2)
    }

    func testDifferentOrMissingPrimaryRevokesStagedCredential() throws {
        let staged = try XCTUnwrap(
            BootstrapStagedCredential(
                hostID: UUID(),
                attemptId: "unpromoted-attempt",
                targetPort: 43_871,
                deviceId: "dev_staged",
                deviceToken: "pdt2." + "staged"
            )
        )
        XCTAssertEqual(
            staged.recoveryAction(
                activeDeviceId: "dev_active",
                activeDeviceToken: "pdt2." + "active"
            ),
            .revokeThenClear
        )
        XCTAssertEqual(
            staged.recoveryAction(
                activeDeviceId: nil,
                activeDeviceToken: nil
            ),
            .revokeThenClear
        )
    }
}

private actor RecoveryCalls {
    private(set) var revokeCount = 0
    private(set) var clearCount = 0
    private var clearFailuresRemaining: Int

    init(clearFailuresRemaining: Int) {
        self.clearFailuresRemaining = clearFailuresRemaining
    }

    func recordRevoke() {
        revokeCount += 1
    }

    func recordClear() -> Bool {
        clearCount += 1
        if clearFailuresRemaining > 0 {
            clearFailuresRemaining -= 1
            return false
        }
        return true
    }
}
