import XCTest
@testable import PIiOSCore

final class ProjectRegistrationTests: XCTestCase {
    func testBrowseEntriesTreatMissingKindAsDirectory() throws {
        let entries = ProjectDirectoryRules.entries(
            from: [
                .object([
                    "name": .string("alpha"),
                    "path": .string("/home/ubuntu/alpha"),
                ]),
                .object([
                    "name": .string("beta"),
                    "path": .string("/home/ubuntu/beta"),
                    "type": .string("directory"),
                ]),
                .object([
                    "name": .string("notes.txt"),
                    "path": .string("/home/ubuntu/notes.txt"),
                    "isDirectory": .bool(false),
                ]),
            ],
            currentPath: "/home/ubuntu"
        )

        XCTAssertEqual(entries.map(\.name), ["alpha", "beta", "notes.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false])
    }

    func testBrowseEntriesRejectEscapingAndMalformedPaths() {
        let entries = ProjectDirectoryRules.entries(
            from: [
                .object(["name": .string("ok"), "path": .string("/srv/ok")]),
                .object(["name": .string("../escape"), "path": .string("/srv/../escape")]),
                .object(["name": .string("other"), "path": .string("/other")]),
                .object(["name": .string("bad\nname"), "path": .string("/srv/bad\nname")]),
            ],
            currentPath: "/srv/"
        )
        XCTAssertEqual(entries.map(\.name), ["ok"])
    }

    func testParentAndDefaultNameHandleRootAndTrailingSlash() {
        XCTAssertEqual(ProjectDirectoryRules.parent(of: "/home/ubuntu/"), "/home")
        XCTAssertEqual(ProjectDirectoryRules.parent(of: "/home"), "/")
        XCTAssertNil(ProjectDirectoryRules.parent(of: "/"))
        XCTAssertEqual(ProjectDirectoryRules.defaultProjectName(for: "/home/ubuntu/"), "ubuntu")
        XCTAssertEqual(ProjectDirectoryRules.defaultProjectName(for: "/"), "root")
    }

    func testProjectNameDraftSeedsAndRefreshesOnlyUntouchedSuggestions() {
        var draft = ProjectNameDraft()

        draft.suggestIfNeeded(for: "/srv/desktop/")
        XCTAssertEqual(draft.text, "desktop")
        XCTAssertEqual(draft.suggestedPath, "/srv/desktop")
        XCTAssertFalse(draft.isUserEdited)

        draft.suggestIfNeeded(for: "/srv/mobile")
        XCTAssertEqual(draft.text, "mobile")
    }

    func testProjectNameDraftPreservesTypedNameAcrossDirectoryNavigation() {
        var draft = ProjectNameDraft()
        draft.suggestIfNeeded(for: "/srv/desktop")
        draft.edit("Team workspace")

        draft.suggestIfNeeded(for: "/srv/mobile")
        draft.suggestIfNeeded(for: "/")

        XCTAssertEqual(draft.text, "Team workspace")
        XCTAssertTrue(draft.isUserEdited)
    }

    func testProjectNameDraftPreservesAnIntentionallyClearedName() {
        var draft = ProjectNameDraft()
        draft.suggestIfNeeded(for: "/srv/desktop")
        draft.edit("  ")

        draft.suggestIfNeeded(for: "/srv/mobile")

        XCTAssertEqual(draft.text, "  ")
        XCTAssertEqual(
            ProjectRegistrationRules.validate(
                name: draft.text,
                path: "/srv/mobile",
                existing: []
            ),
            .emptyName
        )
    }

    func testProjectNameDraftDoesNotReseedTheSameCanonicalPath() {
        var draft = ProjectNameDraft()
        draft.suggestIfNeeded(for: "/srv/desktop")
        draft.edit("Custom")

        draft.suggestIfNeeded(for: "/srv/desktop/")

        XCTAssertEqual(draft.text, "Custom")
        XCTAssertEqual(draft.suggestedPath, "/srv/desktop")
    }

    func testBrowseResponseUsesHostParentAndOmitsItAtRoot() throws {
        let nested = try JSONDecoder().decode(
            RACPProjectBrowseResult.self,
            from: Data(
                #"{"path":"/home/ubuntu/projects","parent":"/home/ubuntu","entries":[]}"#.utf8
            )
        )
        let root = try JSONDecoder().decode(
            RACPProjectBrowseResult.self,
            from: Data(#"{"path":"/home/ubuntu","entries":[]}"#.utf8)
        )

        XCTAssertEqual(nested.parent, "/home/ubuntu")
        XCTAssertNil(root.parent)
    }

    func testProjectNameValidationAllowsKnownPathAndRejectsOtherDuplicate() {
        let existing = [
            ProjectRegistrationTarget(
                projectId: "1",
                displayName: "Desktop",
                path: "/srv/desktop"
            ),
            ProjectRegistrationTarget(projectId: "2", displayName: "Mobile"),
        ]

        XCTAssertNil(
            ProjectRegistrationRules.validate(
                name: " Desktop ",
                path: "/srv/desktop/",
                existing: existing
            )
        )
        XCTAssertEqual(
            ProjectRegistrationRules.validate(
                name: "Desktop",
                path: "/srv/other",
                existing: existing
            ),
            .duplicateName
        )
        XCTAssertEqual(
            ProjectRegistrationRules.validate(name: "  ", path: "/srv/new", existing: existing),
            .emptyName
        )
        XCTAssertEqual(
            ProjectRegistrationRules.validate(
                name: "Desktop",
                path: "/srv/other",
                existing: existing,
                allowUnresolvedNameConflicts: true
            ),
            .duplicateName
        )
        XCTAssertEqual(
            ProjectRegistrationRules.validate(
                name: "Desktop",
                path: "/srv/bad\npath",
                existing: existing
            ),
            .invalidPath
        )
        XCTAssertEqual(
            ProjectRegistrationRules.validate(
                name: "Desktop",
                path: "/" + String(repeating: "a", count: 4_096),
                existing: existing
            ),
            .invalidPath
        )
    }

    func testUnresolvedPathNameConflictCanBeVerifiedByServerReceipt() {
        let existing = [
            ProjectRegistrationTarget(
                projectId: "1",
                displayName: "Desktop",
                path: nil
            ),
        ]

        XCTAssertNil(
            ProjectRegistrationRules.validate(
                name: "Desktop",
                path: "/srv/desktop",
                existing: existing,
                allowUnresolvedNameConflicts: true
            )
        )
        XCTAssertTrue(
            ProjectRegistrationRules.hasUnresolvedNameConflict(
                name: "Desktop",
                existing: existing
            )
        )
        XCTAssertEqual(
            ProjectRegistrationRules.uniqueName(base: "Desktop", existing: existing),
            "Desktop (2)"
        )
        XCTAssertEqual(
            ProjectRegistrationRules.uniqueName(
                base: "Desktop",
                existing: existing + [
                    ProjectRegistrationTarget(
                        projectId: "2",
                        displayName: "Desktop (2)",
                        path: "/srv/desktop-2"
                    ),
                ]
            ),
            "Desktop (3)"
        )
    }

    func testProjectRegisterReceiptAppendsWithoutReorderingExistingProjects() {
        let existing = [
            RACPProjectSummary(id: "one", label: "One", archived: false),
            RACPProjectSummary(id: "two", label: "Two", archived: false),
        ]
        let created = RACPProjectSummary(id: "three", label: "Three", archived: false)

        XCTAssertEqual(
            ProjectCatalogRules.upsert(created, in: existing),
            existing + [created]
        )
    }

    func testProjectRegisterReceiptReplacesTheMatchingRowInPlace() {
        let existing = [
            RACPProjectSummary(id: "one", label: "Old", archived: false),
            RACPProjectSummary(id: "two", label: "Two", archived: false),
        ]
        let refreshed = RACPProjectSummary(id: "one", label: "Updated", archived: true)

        XCTAssertEqual(
            ProjectCatalogRules.upsert(refreshed, in: existing),
            [refreshed, existing[1]]
        )
    }

    func testProjectSessionCountIncludesEveryServerSessionAndKeepsZero() {
        let sessions = [
            RACPSessionSummary(id: "one", title: "One", projectId: "p1"),
            RACPSessionSummary(id: "two", title: "Two", projectId: "p1"),
            RACPSessionSummary(id: "other", title: "Other", projectId: "p2"),
        ]

        XCTAssertEqual(
            ProjectSessionRules.totalSessionCount(sessions, projectID: "p1"),
            2
        )
        XCTAssertEqual(
            ProjectSessionRules.totalSessionCount(
                sessions,
                projectID: "p1",
                excludingSessionIDs: ["two"]
            ),
            1
        )
        XCTAssertEqual(
            ProjectSessionRules.totalSessionCount(sessions, projectID: "empty"),
            0
        )
    }
}
