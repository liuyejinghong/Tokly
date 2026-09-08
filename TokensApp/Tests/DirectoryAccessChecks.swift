import Foundation

@main struct DirectoryAccessChecks {
    static func main() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        for url in [home, URL(fileURLWithPath: "/", isDirectory: true), URL(fileURLWithPath: "/Users", isDirectory: true), URL(fileURLWithPath: "/Volumes/External", isDirectory: true)] {
            do {
                try DirectoryAccessStore.validateSelection(url, userHome: home)
                fatalError("Broad folder was accepted")
            } catch DirectoryAccessError.overlyBroadDirectory {}
        }
        try DirectoryAccessStore.validateSelection(home.appendingPathComponent(".codex/sessions"), userHome: home)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("grants.json")
        let empty = try DirectoryAccessStore(file: file)
        precondition(!empty.hasGrant(client: "codex"))
        try Data("broken".utf8).write(to: file)
        do { _ = try DirectoryAccessStore(file: file); fatalError("Corrupt grants became empty grants") } catch {}
        try Data(#"{"revision":"../escape","grants":{}}"#.utf8).write(to: file)
        do { _ = try DirectoryAccessStore(file: file); fatalError("Path traversal revision accepted") } catch {}
        let sample = try ScanSnapshot.decodeValidated(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let encoded = try SnapshotStore.encodePrivate(sample, sourceRevision: "a")
        let restored = try SnapshotStore.decodePrivate(encoded, sourceRevision: "a")
        precondition(restored == sample)
        do { _ = try SnapshotStore.decodePrivate(encoded, sourceRevision: "b"); fatalError("Wrong source revision accepted") } catch {}
        let direct = try SnapshotStore.encodePrivate(sample, sourceRevision: nil)
        let directRestored = try ScanSnapshot.decodeValidated(from: direct)
        precondition(directRestored == sample)
        do { _ = try SnapshotStore.decodePrivate(direct, sourceRevision: "a"); fatalError("Missing revision accepted") } catch {}
        print("PASS directory boundaries, corrupt grants, and snapshot revision checks")
    }
}
