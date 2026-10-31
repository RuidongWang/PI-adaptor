import XCTest
@testable import PIiOSCore

final class ProviderOperationContextTests: XCTestCase {
    private let hostID = UUID()

    func testMatchingHostAndGenerationsAllowReceipt() {
        XCTAssertTrue(context().canApply(to: context()))
    }

    func testDeletedHostRejectsReceipt() {
        XCTAssertFalse(context().canApply(to: nil))
    }

    func testSwitchedHostRejectsReceiptEvenAtSameAddress() {
        XCTAssertFalse(context().canApply(to: context(host: UUID())))
    }

    func testSwitchAwayAndBackRejectsReceiptWithSameUUIDAndIdentity() {
        XCTAssertFalse(context().canApply(to: context(hostGeneration: 3)))
    }

    func testReconnectOnSameHostRejectsOldReceipt() {
        XCTAssertFalse(context().canApply(to: context(connectionGeneration: 3)))
    }

    func testIdentityChangesRejectLateImportAndDelete() {
        let original = context()
        for edited in [
            context(address: "other.example"), context(sshPort: 2222),
            context(username: "other"), context(hostPort: 45124),
            context(authKind: "password"),
        ] {
            XCTAssertFalse(original.canApply(to: edited))
        }
    }

    func testEditingIdentityThenRestoringItStillRejectsOldGeneration() {
        XCTAssertFalse(context().canApply(to: context(identityGeneration: 4)))
    }

    private func context(
        host: UUID? = nil, address: String = "server.example", sshPort: Int = 22,
        username: String = "ubuntu", hostPort: Int? = 45123, authKind: String = "private_key",
        hostGeneration: Int = 1, identityGeneration: Int = 1, connectionGeneration: Int = 1
    ) -> ProviderOperationContext {
        ProviderOperationContext(
            hostID: host ?? hostID, address: address, sshPort: sshPort, username: username,
            hostPort: hostPort, authKind: authKind, hostGeneration: hostGeneration,
            identityGeneration: identityGeneration,
            connectionGeneration: connectionGeneration
        )
    }
}
