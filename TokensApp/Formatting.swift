import Foundation

public enum Format {
    public static func compact(_ value: Int64) -> String {
        TokenFormat.compact(value)
    }

    public static func money(_ v: Double) -> String {
        "$" + String(format: "%.2f", v)
    }

    public static func costText(tokensTotal: Int64, cost: EstimatedCost) -> String {
        switch Aggregation.classify(tokensTotal: tokensTotal, cost: cost) {
        case .legitimateZero:
            return "$0.00"
        case .fullyPriced(let a):
            return money(a)
        case .partialKnown(let a, _):
            return money(a) + " *"
        case .allUnpriced:
            return "暂无单价"
        }
    }

    public static func costFootnote(tokensTotal: Int64, cost: EstimatedCost) -> String {
        switch Aggregation.classify(tokensTotal: tokensTotal, cost: cost) {
        case .legitimateZero:
            return "暂无用量"
        case .fullyPriced:
            return "按模型单价估算 · USD"
        case .partialKnown(_, let u):
            return "部分 Token 暂无单价（\(compact(u)) 未定价）"
        case .allUnpriced(let u):
            return "\(compact(u)) Token 暂无可用单价"
        }
    }

    public static func updatedText(_ date: Date?) -> String {
        guard let date else { return "尚未更新" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    public static func dayLabel(_ ymd: String) -> String {
        // "2026-09-08" -> "9/8"
        let parts = ymd.split(separator: "-")
        guard parts.count == 3,
              let m = Int(parts[1]), let d = Int(parts[2]) else { return ymd }
        return "\(m)/\(d)"
    }
}
