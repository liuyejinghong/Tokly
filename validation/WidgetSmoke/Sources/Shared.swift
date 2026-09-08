import Foundation

/// Synthetic-only preflight snapshot, shared by the app and widget targets.
struct PrepSnapshot: Codable {
    var schemaVersion: Int = 1
    var tokens: Int64
    var updatedAt: Date
    var revision: Int
}

enum PrepStoreError: Error, LocalizedError {
    case missingGroupIdentifier
    case unresolvedGroup(String)
    case missingSnapshot
    case schemaMismatch(Int)
    case negativeTokens

    var errorDescription: String? {
        switch self {
        case .missingGroupIdentifier:
            return "缺少 PrepAppGroupIdentifier（Info.plist 未配置共享 App Group）"
        case .unresolvedGroup(let id):
            return "无法解析 App Group 容器：\(id)"
        case .missingSnapshot:
            return "尚未写入快照（snapshot.json 不存在）"
        case .schemaMismatch(let v):
            return "快照数据异常：schemaVersion=\(v)，期望 1"
        case .negativeTokens:
            return "快照数据异常：tokens 为负数"
        }
    }
}

enum PrepStore {
    static let widgetKind = "TokensPrepWidget"
    static let fileName = "snapshot.json"
    static let groupDefaultsKey = "PrepAppGroupIdentifier"

    static func groupContainerURL() throws -> URL {
        guard let id = Bundle.main.object(forInfoDictionaryKey: groupDefaultsKey) as? String,
              !id.isEmpty,
              !id.contains("$(")
        else {
            throw PrepStoreError.missingGroupIdentifier
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else {
            throw PrepStoreError.unresolvedGroup(id)
        }
        return url
    }

    static func snapshotURL() throws -> URL {
        try groupContainerURL().appendingPathComponent(fileName)
    }

    /// Decode and validate snapshots shared by the app and widget.
    static func decode(_ data: Data) throws -> PrepSnapshot {
        let snapshot = try JSONDecoder().decode(PrepSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else {
            throw PrepStoreError.schemaMismatch(snapshot.schemaVersion)
        }
        guard snapshot.tokens >= 0 else {
            throw PrepStoreError.negativeTokens
        }
        return snapshot
    }

    /// Read and validate. Only no-such-file maps to missingSnapshot; all other errors propagate.
    static func read() throws -> PrepSnapshot {
        let url = try snapshotURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if isNoSuchFile(error) {
                throw PrepStoreError.missingSnapshot
            }
            throw error
        }
        return try decode(data)
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    static func write(_ snapshot: PrepSnapshot) throws {
        let url = try snapshotURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
