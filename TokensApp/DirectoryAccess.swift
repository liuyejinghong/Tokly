import Foundation
import Darwin

struct SourceDirectoryRole: Identifiable {
    let id: String
    let client: String
    let label: String
    let relativePath: String
    static let all: [SourceDirectoryRole] = [
        .init(id: "codex-sessions", client: "codex", label: "会话目录", relativePath: ".codex/sessions"),
        .init(id: "codex-archives", client: "codex", label: "归档目录（可选）", relativePath: ".codex/archived_sessions"),
        .init(id: "claude-projects", client: "claude", label: "项目日志目录", relativePath: ".claude/projects"),
        .init(id: "claude-transcripts", client: "claude", label: "转录目录（可选）", relativePath: ".claude/transcripts"),
        .init(id: "opencode-data", client: "opencode", label: "OpenCode 数据目录", relativePath: ".local/share/opencode")
    ]
    static let clients = Set(all.map(\.client))
}

enum DirectoryAccessError: Error, LocalizedError {
    case unknownRole
    case overlyBroadDirectory
    case missingGrant(String)
    case expiredGrant(String)
    case invalidMapping

    var errorDescription: String? {
        switch self {
        case .unknownRole: return "此来源目录尚未支持"
        case .overlyBroadDirectory: return "请选择具体客户端的数据目录，不要选择磁盘根目录或整个用户目录"
        case .missingGrant(let name): return "请先授权 \(name) 的日志目录"
        case .expiredGrant(let name): return "\(name) 的目录授权已失效，请重新选择"
        case .invalidMapping: return "目录映射异常，请重新选择来源目录"
        }
    }
}

final class SourceDirectoryLease {
    let home: URL
    let revision: String
    private var urls: [URL]
    init(home: URL, revision: String, urls: [URL]) {
        self.home = home; self.revision = revision; self.urls = urls
    }
    func close() {
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
        urls.removeAll()
    }
    deinit { close() }
}

final class DirectoryAccessStore {
    private struct Grant: Codable {
        var bookmark: Data
        var displayPath: String
    }
    private struct State: Codable {
        var revision: String
        var grants: [String: Grant]
    }
    private let file: URL
    private var state: State
    var revision: String { state.revision }

    init(file: URL) throws {
        self.file = file
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard UUID(uuidString: state.revision) != nil else { throw DirectoryAccessError.invalidMapping }
            guard Set(state.grants.keys).isSubset(of: Set(SourceDirectoryRole.all.map(\.id))) else {
                throw DirectoryAccessError.unknownRole
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            state = State(revision: UUID().uuidString, grants: [:])
        }
    }

    func hasGrant(client: String) -> Bool {
        SourceDirectoryRole.all.contains { $0.client == client && state.grants[$0.id] != nil }
    }
    func path(role: String) -> String? { state.grants[role]?.displayPath }

    static var userHome: URL {
        getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func validateSelection(_ url: URL, userHome: URL) throws {
        let path = url.standardizedFileURL.path
        let home = userHome.standardizedFileURL.path
        let isVolumeRoot = path.hasPrefix("/Volumes/") && url.standardizedFileURL.pathComponents.count == 3
        if !url.isFileURL || path == "/" || path == home || home.hasPrefix(path + "/") || isVolumeRoot {
            throw DirectoryAccessError.overlyBroadDirectory
        }
    }

    func authorize(role: String, url: URL) throws {
        guard SourceDirectoryRole.all.contains(where: { $0.id == role }) else { throw DirectoryAccessError.unknownRole }
        try Self.validateSelection(url, userHome: Self.userHome)
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        var next = state
        next.revision = UUID().uuidString
        next.grants[role] = Grant(bookmark: data, displayPath: url.path)
        try persist(next)
    }

    func remove(role: String) throws {
        var next = state
        next.revision = UUID().uuidString
        next.grants.removeValue(forKey: role)
        try persist(next)
    }

    private func persist(_ next: State) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        state = next
    }

    // A stable revision namespace preserves warm caches, while changed grants
    // cannot collide with cached files from a different physical directory.
    func acquire(clients: Set<String>, root: URL) throws -> SourceDirectoryLease {
        for client in clients where !hasGrant(client: client) {
            throw DirectoryAccessError.missingGrant(client)
        }
        let home = root.appendingPathComponent(state.revision, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var active: [URL] = []
        do {
            for role in SourceDirectoryRole.all where clients.contains(role.client) {
                guard let grant = state.grants[role.id] else { continue }
                var stale = false
                let url = try URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw DirectoryAccessError.expiredGrant(role.label) }
                active.append(url)
                if stale {
                    var next = state
                    next.grants[role.id] = Grant(bookmark: try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil), displayPath: url.path)
                    try persist(next)
                }
                let link = home.appendingPathComponent(role.relativePath)
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let previous = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
                    if previous == url.path { continue }
                    try FileManager.default.removeItem(at: link)
                } else if FileManager.default.fileExists(atPath: link.path) {
                    throw DirectoryAccessError.invalidMapping
                }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            }
            return SourceDirectoryLease(home: home, revision: state.revision, urls: active)
        } catch {
            active.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
}
