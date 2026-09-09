import Foundation
import SQLite3

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
        let databaseURL = folder.appendingPathComponent("probe.db")
        var writer: OpaquePointer?
        precondition(sqlite3_open(databaseURL.path, &writer) == SQLITE_OK)
        precondition(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE probe(value); INSERT INTO probe VALUES(1);", nil, nil, nil) == SQLITE_OK)
        let reader = try DirectoryAccessStore.openReadableDatabase(databaseURL)
        precondition(sqlite3_close(writer) == SQLITE_OK)
        precondition(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        precondition(sqlite3_exec(reader, "SELECT * FROM probe;", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_exec(reader, "INSERT INTO probe VALUES(2);", nil, nil, nil) == SQLITE_READONLY)
        sqlite3_close(reader)
        let corrupt = folder.appendingPathComponent("corrupt.db")
        try Data("not a database".utf8).write(to: corrupt)
        do { _ = try DirectoryAccessStore.openReadableDatabase(corrupt); fatalError("Unreadable database was accepted") }
        catch DirectoryAccessError.unreadableDatabase {}
        let sample = try ScanSnapshot.decodeValidated(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let encoded = try SnapshotStore.encodePrivate(sample, sourceRevision: "a")
        let restored = try SnapshotStore.decodePrivate(encoded, sourceRevision: "a")
        precondition(restored == sample)
        do { _ = try SnapshotStore.decodePrivate(encoded, sourceRevision: "b"); fatalError("Wrong source revision accepted") } catch {}
        let direct = try SnapshotStore.encodePrivate(sample, sourceRevision: nil)
        let directRestored = try ScanSnapshot.decodeValidated(from: direct)
        precondition(directRestored == sample)
        do { _ = try SnapshotStore.decodePrivate(direct, sourceRevision: "a"); fatalError("Missing revision accepted") } catch {}
        print("PASS directory boundaries, corrupt grants, snapshot revision, read-only SQLite and WAL lifetime checks")
    }
}
