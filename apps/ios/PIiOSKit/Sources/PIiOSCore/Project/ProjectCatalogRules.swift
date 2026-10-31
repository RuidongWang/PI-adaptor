import Foundation

/// Local reconciliation for project-list write receipts.
public enum ProjectCatalogRules {
    /// Apply a `project/register` result immediately, before a list refresh can fail.
    public static func upsert(
        _ project: RACPProjectSummary,
        in projects: [RACPProjectSummary]
    ) -> [RACPProjectSummary] {
        var updated = projects
        if let index = updated.firstIndex(where: { $0.id == project.id }) {
            updated[index] = project
        } else {
            updated.append(project)
        }
        return updated
    }
}

public enum ProjectSessionRules {
    /// Project rows report every server session, including locally archived ones.
    public static func totalSessionCount(
        _ sessions: [RACPSessionSummary],
        projectID: String,
        excludingSessionIDs: Set<String> = []
    ) -> Int {
        sessions.lazy.filter {
            $0.projectId == projectID && !excludingSessionIDs.contains($0.id)
        }.count
    }
}
