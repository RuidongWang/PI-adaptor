// Run with: swiftc PI-IOS/Model/StateFile.swift tests/StateFileRegression.swift -o /tmp/pi-state-test && /tmp/pi-state-test
import Foundation

// StateFile only needs Codable state; keep this executable independent of UIKit.
struct PersistedState: Codable, Equatable {
    let marker: String
    static let empty = PersistedState(marker: "empty")
}

@main
struct StateFileRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state-v1.json")
        let missing = StateFile.load(from: file)
        precondition(missing.canSave && missing.warning == nil && missing.state == .empty)

        try Data(#"{"marker":"saved"}"#.utf8).write(to: file)
        let valid = StateFile.load(from: file)
        precondition(valid.canSave && valid.state.marker == "saved")

        try Data("broken".utf8).write(to: file)
        let corrupt = StateFile.load(from: file)
        precondition(corrupt.canSave && corrupt.warning != nil)
        precondition(!FileManager.default.fileExists(atPath: file.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(backups.contains { $0.hasPrefix("state-v1.corrupt-") })

        try Data("broken again".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let failedBackup = StateFile.load(from: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        precondition(!failedBackup.canSave && failedBackup.warning != nil)
        let retained = try Data(contentsOf: file)
        precondition(retained == Data("broken again".utf8))
        try FileManager.default.removeItem(at: file)

        // Reading a directory as a file fails without moving or overwriting it.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let unreadable = StateFile.load(from: file)
        precondition(!unreadable.canSave && unreadable.warning != nil)
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        print("StateFile regression checks passed")
    }
}
