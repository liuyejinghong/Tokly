import Foundation

/// Client registry mirror for display + selection.
///
/// IDs align with the upstream `ClientId` set plus the collector-accepted
/// `synthetic` / `9router` aliases. Display only — no account/API sync is
/// implied; statistics come from on-device records.
public struct SourceRegistryEntry: Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var pathHint: String

    public init(id: String, displayName: String, pathHint: String) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
    }
}

public enum SourceRegistry {
    public static let all: [SourceRegistryEntry] = [
        .init(id: "codex", displayName: "Codex", pathHint: "~/.codex/sessions"),
        .init(id: "claude", displayName: "Claude Code", pathHint: "~/.claude/projects"),
        .init(id: "opencode", displayName: "OpenCode", pathHint: "~/.local/share/opencode"),
        .init(id: "cursor", displayName: "Cursor", pathHint: "~/.config/tokens/cursor-cache"),
        .init(id: "gemini", displayName: "Gemini CLI", pathHint: "~/.gemini/tmp"),
        .init(id: "amp", displayName: "Amp", pathHint: "~/.local/share/amp/threads"),
        .init(id: "droid", displayName: "Droid", pathHint: "~/.factory/sessions"),
        .init(id: "openclaw", displayName: "OpenClaw", pathHint: "~/.openclaw/agents"),
        .init(id: "pi", displayName: "Pi", pathHint: "~/.pi/agent/sessions"),
        .init(id: "kimi", displayName: "Kimi", pathHint: "~/.kimi/sessions"),
        .init(id: "qwen", displayName: "Qwen", pathHint: "~/.qwen/projects"),
        .init(id: "roocode", displayName: "Roo Code", pathHint: "~/.config/Code … roo-cline/tasks"),
        .init(id: "kilocode", displayName: "Kilo Code", pathHint: "~/.config/Code … kilo-code/tasks"),
        .init(id: "mux", displayName: "Mux", pathHint: "~/.mux/sessions"),
        .init(id: "kilo", displayName: "Kilo", pathHint: "~/.local/share/kilo/kilo.db"),
        .init(id: "crush", displayName: "Crush", pathHint: "~/.local/share/crush/projects.json"),
        .init(id: "hermes", displayName: "Hermes", pathHint: "~/.hermes/state.db"),
        .init(id: "copilot", displayName: "Copilot", pathHint: "~/.copilot/otel"),
        .init(id: "goose", displayName: "Goose", pathHint: "~/.local/share/goose/sessions"),
        .init(id: "codebuff", displayName: "Codebuff", pathHint: "~/.config/manicode/projects"),
        .init(id: "antigravity", displayName: "Antigravity", pathHint: "~/.config/tokens/antigravity-cache"),
        .init(id: "zed", displayName: "Zed", pathHint: "~/.local/share/zed/threads"),
        .init(id: "kiro", displayName: "Kiro", pathHint: "~/.kiro/sessions/cli"),
        .init(id: "trae", displayName: "Trae", pathHint: "~/.config/tokens/trae-cache"),
        .init(id: "warp", displayName: "Warp", pathHint: "~/.config/tokens/warp-cache"),
        .init(id: "cline", displayName: "Cline", pathHint: "~/.config/Code … claude-dev/tasks"),
        .init(id: "gjc", displayName: "GJC · 9Router", pathHint: "~/.gjc/agent/sessions"),
        .init(id: "grok", displayName: "Grok", pathHint: "~/.grok/sessions"),
        .init(id: "jcode", displayName: "JCode", pathHint: "~/.jcode/sessions"),
        .init(id: "commandcode", displayName: "CommandCode", pathHint: "~/.commandcode/projects"),
        .init(id: "micode", displayName: "MiMo Code", pathHint: "~/.local/share/mimocode"),
        .init(id: "antigravity-cli", displayName: "Antigravity CLI", pathHint: "~/.gemini/antigravity-cli"),
        .init(id: "junie", displayName: "Junie", pathHint: "~/.junie/sessions"),
        .init(id: "zcode", displayName: "ZCode", pathHint: "~/.zcode/projects"),
        .init(id: "opencodereview", displayName: "OpenCodeReview", pathHint: "~/.opencodereview/sessions"),
        .init(id: "codebuddy", displayName: "CodeBuddy", pathHint: "~/.codebuddy/projects"),
        .init(id: "workbuddy", displayName: "WorkBuddy", pathHint: "~/.workbuddy"),
        .init(id: "devin-cli", displayName: "Devin CLI", pathHint: "~/.local/share/devin/cli"),
        .init(id: "devin-desktop", displayName: "Devin Desktop", pathHint: "~/Library/Application Support/Devin"),
        .init(id: "reasonix", displayName: "Reasonix", pathHint: "~/.reasonix/stats"),
        .init(id: "freebuff", displayName: "Freebuff", pathHint: "~/.config/manicode/projects"),
        .init(id: "fx", displayName: "Fx", pathHint: "~/.fx/sessions"),
        .init(id: "synthetic", displayName: "Synthetic", pathHint: "synthetic test source"),
    ]

    public static let primaryIDs: Set<String> = ["codex", "claude", "opencode"]

    public static func displayName(for id: String) -> String {
        all.first(where: { $0.id == id })?.displayName ?? id
    }

    public static func pathHint(for id: String) -> String {
        all.first(where: { $0.id == id })?.pathHint ?? "—"
    }

    public static var orderedForOnboarding: [SourceRegistryEntry] {
        let primary = all.filter { primaryIDs.contains($0.id) }
        let rest = all.filter { !primaryIDs.contains($0.id) && $0.id != "synthetic" }
        return primary + rest
    }
}
