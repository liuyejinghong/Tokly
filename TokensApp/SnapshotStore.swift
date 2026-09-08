import Foundation
import WidgetKit

/// Persistence: full scan responses stay private; only the trimmed
/// Widget snapshot is published to the App Group. All writes are atomic.
/// Failures never overwrite the last successful snapshot.
public enum SnapshotStoreError: Error, LocalizedError {
    case missingGroupIdentifier
    case unresolvedGroup(String)
    case missingSnapshot
    case undecodable(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingGroupIdentifier:
            "缺少 App Group 配置（Info.plist 未配置共享 App Group）"
        case .unresolvedGroup(let id):
            "无法解析 App Group 容器：\(id)"
        case .missingSnapshot:
            "尚无统计快照"
        case .undecodable(let what):
            "快照数据异常：\(what)"
        case .writeFailed(let what):
            "本机保存失败：\(what)"
        }
    }
}

private struct StoredDirectorySnapshot: Codable {
    let revision: String
    let snapshot: ScanSnapshot
}

public enum SnapshotStore {
    public static let privateFileName = "scan.json"
    public static let widgetFileName = "widget-snapshot.json"
    public static let groupDefaultsKey = "TokensAppGroupIdentifier"
    public static let fallbackGroupID = "team.tokensmacos.app"

    public static func privateDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("local.tokensmacos.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func privateSnapshotURL() throws -> URL {
        try privateDirectory().appendingPathComponent(privateFileName)
    }

    public static func configDirectory() throws -> URL {
        // Isolated app config (price caches live under <config>/cache).
        // Never the original tokens CLI default.
        let dir = try privateDirectory().appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true)
        return dir
    }

    public static func groupIdentifier() -> String {
        if let id = Bundle.main.object(forInfoDictionaryKey: groupDefaultsKey) as? String,
           !id.isEmpty, !id.contains("$(") {
            return id
        }
        return fallbackGroupID
    }

    public static func groupContainerURL() throws -> URL {
        let id = groupIdentifier()
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: id) else {
            throw SnapshotStoreError.unresolvedGroup(id)
        }
        return url
    }

    /// Loads the last successful private snapshot, if any.
    public static func loadPrivate(sourceRevision: String? = nil) throws -> ScanSnapshot {
        let url = try privateSnapshotURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if isNoSuchFile(error) { throw SnapshotStoreError.missingSnapshot }
            throw error
        }
        do {
            return try decodePrivate(data, sourceRevision: sourceRevision)
        } catch {
            throw SnapshotStoreError.undecodable(error.localizedDescription)
        }
    }

    /// Atomically saves the single private response artifact, then
    /// publishes the trimmed Widget snapshot and asks the system to
    /// refresh timelines. Storage failures throw and are surfaced
    /// separately from scan failures; the previous artifact is retained.
    public static func saveSuccess(_ snapshot: ScanSnapshot, today: String, sourceRevision: String? = nil) throws {
        do {
            let data = try encodePrivate(snapshot, sourceRevision: sourceRevision)
            try data.write(to: try privateSnapshotURL(), options: .atomic)
        } catch {
            throw SnapshotStoreError.writeFailed(error.localizedDescription)
        }
        try publishWidget(from: snapshot, today: today)
    }

    static func decodePrivate(_ data: Data, sourceRevision: String?) throws -> ScanSnapshot {
        guard let sourceRevision else { return try ScanSnapshot.decodeValidated(from: data) }
        let stored = try JSONDecoder().decode(StoredDirectorySnapshot.self, from: data)
        guard stored.revision == sourceRevision else { throw SnapshotStoreError.missingSnapshot }
        return stored.snapshot
    }

    static func encodePrivate(_ snapshot: ScanSnapshot, sourceRevision: String?) throws -> Data {
        if let sourceRevision {
            return try JSONEncoder().encode(StoredDirectorySnapshot(revision: sourceRevision, snapshot: snapshot))
        }
        return try snapshot.encoded()
    }

    public static func publishWidget(from snapshot: ScanSnapshot, today: String) throws {
        let showCost = UserDefaults.standard.object(forKey: "widgetShowCost") as? Bool ?? true
        let widget = WidgetSnapshotBuilder.make(
            from: snapshot, today: today,
            preferences: WidgetPreferences(showCost: showCost))
        do {
            let dir = try groupContainerURL()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(widget)
            try data.write(to: dir.appendingPathComponent(widgetFileName), options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            throw SnapshotStoreError.writeFailed("小组件发布失败：\(error.localizedDescription)")
        }
    }

    public static func loadWidget() -> WidgetSnapshot? {
        do {
            let url = try groupContainerURL().appendingPathComponent(widgetFileName)
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    public static func invalidateWidget() throws {
        do {
            let url = try groupContainerURL().appendingPathComponent(widgetFileName)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if !isNoSuchFile(error) { throw error }
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            throw SnapshotStoreError.writeFailed("小组件失效失败：\(error.localizedDescription)")
        }
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           u.domain == NSPOSIXErrorDomain, u.code == Int(ENOENT) { return true }
        return false
    }
}
