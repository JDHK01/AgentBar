import Foundation

public struct ModelPriceRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String { modelPrefix }
    public var modelPrefix: String
    public var inputPerMillionUSD: Double
    public var outputPerMillionUSD: Double
    public var cacheReadPerMillionUSD: Double
    public var cacheWritePerMillionUSD: Double
    public var defaultContextWindow: Int

    public init(
        modelPrefix: String,
        inputPerMillionUSD: Double,
        outputPerMillionUSD: Double,
        cacheReadPerMillionUSD: Double,
        cacheWritePerMillionUSD: Double,
        defaultContextWindow: Int
    ) {
        self.modelPrefix = modelPrefix
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.cacheReadPerMillionUSD = cacheReadPerMillionUSD
        self.cacheWritePerMillionUSD = cacheWritePerMillionUSD
        self.defaultContextWindow = defaultContextWindow
    }
}

public enum PricingCatalog {
    public static let defaults: [ModelPriceRule] = [
        ModelPriceRule(
            modelPrefix: "claude-opus",
            inputPerMillionUSD: 15.0,
            outputPerMillionUSD: 75.0,
            cacheReadPerMillionUSD: 1.5,
            cacheWritePerMillionUSD: 18.75,
            defaultContextWindow: 200_000
        ),
        ModelPriceRule(
            modelPrefix: "claude-sonnet",
            inputPerMillionUSD: 3.0,
            outputPerMillionUSD: 15.0,
            cacheReadPerMillionUSD: 0.3,
            cacheWritePerMillionUSD: 3.75,
            defaultContextWindow: 200_000
        ),
        ModelPriceRule(
            modelPrefix: "claude-haiku",
            inputPerMillionUSD: 0.8,
            outputPerMillionUSD: 4.0,
            cacheReadPerMillionUSD: 0.08,
            cacheWritePerMillionUSD: 1.0,
            defaultContextWindow: 200_000
        ),
        ModelPriceRule(
            modelPrefix: "gpt-5",
            inputPerMillionUSD: 1.25,
            outputPerMillionUSD: 10.0,
            cacheReadPerMillionUSD: 0.125,
            cacheWritePerMillionUSD: 1.25,
            defaultContextWindow: 272_000
        ),
        ModelPriceRule(
            modelPrefix: "codex",
            inputPerMillionUSD: 1.5,
            outputPerMillionUSD: 6.0,
            cacheReadPerMillionUSD: 0.375,
            cacheWritePerMillionUSD: 1.5,
            defaultContextWindow: 258_400
        ),
        ModelPriceRule(
            modelPrefix: "deepseek",
            inputPerMillionUSD: 0.27,
            outputPerMillionUSD: 1.10,
            cacheReadPerMillionUSD: 0.07,
            cacheWritePerMillionUSD: 0.27,
            defaultContextWindow: 128_000
        ),
        ModelPriceRule(
            modelPrefix: "doubao",
            inputPerMillionUSD: 0.15,
            outputPerMillionUSD: 0.60,
            cacheReadPerMillionUSD: 0.03,
            cacheWritePerMillionUSD: 0.15,
            defaultContextWindow: 128_000
        ),
        ModelPriceRule(
            modelPrefix: "grok",
            inputPerMillionUSD: 3.0,
            outputPerMillionUSD: 15.0,
            cacheReadPerMillionUSD: 0.75,
            cacheWritePerMillionUSD: 3.0,
            defaultContextWindow: 256_000
        )
    ]

    public static func rule(for model: String?, customRules: [ModelPriceRule] = defaults) -> ModelPriceRule? {
        guard let lower = model?.lowercased(), !lower.isEmpty else { return nil }
        return customRules.first { lower.contains($0.modelPrefix.lowercased()) }
    }

    public static func estimatedCostUSD(
        usage: TokenUsage,
        model: String?,
        rules: [ModelPriceRule] = defaults
    ) -> Double? {
        guard usage.totalTokens > 0 else { return nil }
        let matched = rule(for: model, customRules: rules) ?? ModelPriceRule(
            modelPrefix: "default",
            inputPerMillionUSD: 2.0,
            outputPerMillionUSD: 8.0,
            cacheReadPerMillionUSD: 0.2,
            cacheWritePerMillionUSD: 2.5,
            defaultContextWindow: 200_000
        )
        let m = 1_000_000.0
        let inputCost = (Double(usage.input) / m) * matched.inputPerMillionUSD
        let outputCost = (Double(usage.output) / m) * matched.outputPerMillionUSD
        let cacheReadCost = (Double(usage.cacheRead) / m) * matched.cacheReadPerMillionUSD
        let cacheWriteCost = (Double(usage.cacheWrite) / m) * matched.cacheWritePerMillionUSD
        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }

    public static func defaultContextWindow(for model: String?) -> Int {
        rule(for: model)?.defaultContextWindow ?? 200_000
    }
}

public enum FormattingHelpers {
    public static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            let val = Double(count) / 1_000.0
            return val >= 100 ? String(format: "%.0fk", val) : String(format: "%.1fk", val)
        } else {
            return "\(count)"
        }
    }

    public static func memoryString(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
    }

    public static func relativeDuration(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds) 秒前"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        if hours < 24 {
            return remMin > 0 ? "\(hours) 小时 \(remMin) 分" : "\(hours) 小时前"
        }
        return "\(hours / 24) 天前"
    }

    public static func elapsedString(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds) 秒"
        }
        let minutes = seconds / 60
        let remSec = seconds % 60
        if minutes < 60 {
            return "\(minutes) 分 \(String(format: "%02d", remSec)) 秒"
        }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public static func providerDisplay(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("anthropic") { return "Anthropic" }
        if lower.contains("openai") { return "OpenAI" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("volces") || lower.contains("ark") || lower.contains("doubao") { return "火山方舟" }
        if lower.contains("bedrock") || lower.contains("amazonaws") { return "AWS Bedrock" }
        if lower.contains("vertex") || lower.contains("aiplatform.googleapis") { return "Vertex AI" }
        if lower.contains("x.ai") || lower.contains("grok") { return "xAI" }
        return raw
    }
}
