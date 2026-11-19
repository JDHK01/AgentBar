import Foundation
import Security

public enum BalanceSourceType: String, Codable, CaseIterable, Sendable {
    case jsonAPI
    case webExtract
    case command

    public var title: String {
        switch self {
        case .jsonAPI: return "JSON API"
        case .webExtract: return "网页提取（SSO）"
        case .command: return "自定义命令"
        }
    }
}

public struct BalanceSourceConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var type: BalanceSourceType
    public var urlOrCommand: String
    public var extractorOrJSONPath: String
    public var currencySymbol: String
    public var lowBalanceThreshold: Double?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: BalanceSourceType,
        urlOrCommand: String,
        extractorOrJSONPath: String,
        currencySymbol: String = "$",
        lowBalanceThreshold: Double? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.urlOrCommand = urlOrCommand
        self.extractorOrJSONPath = extractorOrJSONPath
        self.currencySymbol = currencySymbol
        self.lowBalanceThreshold = lowBalanceThreshold
        self.isEnabled = isEnabled
    }

    public static var deepSeekPreset: BalanceSourceConfig {
        BalanceSourceConfig(
            name: "DeepSeek API",
            type: .jsonAPI,
            urlOrCommand: "https://api.deepseek.com/user/balance",
            extractorOrJSONPath: "balance_infos.0.total_balance",
            currencySymbol: "¥",
            lowBalanceThreshold: 50
        )
    }
}

public struct BalanceReading: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { sourceID }
    public var sourceID: UUID
    public var name: String
    public var sourceType: BalanceSourceType
    public var dashboardURL: String?
    public var formattedValue: String
    public var numericValue: Double?
    public var usedFraction: Double?
    public var footnote: String
    public var isLow: Bool
    public var needsLogin: Bool
    public var updatedAt: Date

    public init(
        sourceID: UUID,
        name: String,
        sourceType: BalanceSourceType = .webExtract,
        dashboardURL: String? = nil,
        formattedValue: String,
        numericValue: Double? = nil,
        usedFraction: Double? = nil,
        footnote: String,
        isLow: Bool = false,
        needsLogin: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.sourceID = sourceID
        self.name = name
        self.sourceType = sourceType
        self.dashboardURL = dashboardURL
        self.formattedValue = formattedValue
        self.numericValue = numericValue
        self.usedFraction = usedFraction
        self.footnote = footnote
        self.isLow = isLow
        self.needsLogin = needsLogin
        self.updatedAt = updatedAt
    }
}

public enum KeychainStore {
    private static let service = "com.agentbar.desktop.balance"

    public static func saveToken(_ token: String, for id: UUID) {
        let account = id.uuidString
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func loadToken(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum BalanceService {
    public static func parseWebPayload(
        rawJSONOrString: String,
        source: BalanceSourceConfig
    ) -> BalanceReading {
        let dashboardURL = source.type == .webExtract ? source.urlOrCommand : nil
        if let data = rawJSONOrString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["_agentbarSmart"] as? Bool == true {
            if obj["needsLogin"] as? Bool == true {
                return BalanceReading(
                    sourceID: source.id,
                    name: source.name,
                    sourceType: source.type,
                    dashboardURL: dashboardURL,
                    formattedValue: "点击登录 SSO",
                    footnote: "登录后自动同步余额与额度",
                    isLow: false,
                    needsLogin: true
                )
            }
            let primary = (obj["primary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let secondary = (obj["secondary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let frac = (obj["usedFraction"] as? NSNumber)?.doubleValue
            let num = extractFirstDouble(from: primary)
            let isLow = (num != nil && source.lowBalanceThreshold != nil) ? (num! < source.lowBalanceThreshold!) : false

            let displayValue: String
            if !primary.isEmpty {
                displayValue = primary
            } else if let num {
                displayValue = String(format: "%@%.2f", source.currencySymbol, num)
            } else {
                displayValue = "已连接看板"
            }

            let foot: String
            if !secondary.isEmpty {
                foot = String(secondary.prefix(34))
            } else if isLow {
                foot = "低于阈值 \(source.currencySymbol)\(Int(source.lowBalanceThreshold ?? 0))"
            } else {
                foot = "点击打开完整看板 · 刚刚"
            }

            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: dashboardURL,
                formattedValue: String(displayValue.prefix(20)),
                numericValue: num,
                usedFraction: frac,
                footnote: foot,
                isLow: isLow,
                needsLogin: false
            )
        }

        guard let number = extractFirstDouble(from: rawJSONOrString) else {
            let trimmed = rawJSONOrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: dashboardURL,
                formattedValue: trimmed.isEmpty ? "点击查看看板" : String(trimmed.prefix(16)),
                footnote: source.type == .webExtract ? "点击打开 SSO 看板同步" : "刚刚更新",
                isLow: false,
                needsLogin: trimmed.isEmpty && source.type == .webExtract
            )
        }
        let isLow = source.lowBalanceThreshold.map { number < $0 } ?? false
        let formatted = String(format: "%@%.2f", source.currencySymbol, number)
        let foot = isLow
            ? "低于阈值 \(source.currencySymbol)\(Int(source.lowBalanceThreshold ?? 0))"
            : "\(source.type.title) · 刚刚"
        return BalanceReading(
            sourceID: source.id,
            name: source.name,
            sourceType: source.type,
            dashboardURL: dashboardURL,
            formattedValue: formatted,
            numericValue: number,
            usedFraction: isLow ? 0.85 : nil,
            footnote: foot,
            isLow: isLow
        )
    }

    public static func fetchReading(
        for source: BalanceSourceConfig,
        webEvaluator: (@Sendable (URL, String) async throws -> String)? = nil
    ) async -> BalanceReading {
        let dashboardURL = source.type == .webExtract ? source.urlOrCommand : nil
        do {
            let rawString: String
            switch source.type {
            case .jsonAPI:
                rawString = try await fetchJSONAPI(source: source)
            case .command:
                rawString = try await runBalanceCommand(source.urlOrCommand)
            case .webExtract:
                guard let url = URL(string: source.urlOrCommand), let webEvaluator else {
                    throw NSError(domain: "BalanceService", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
                }
                let trimmedExpr = source.extractorOrJSONPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let expr = trimmedExpr.isEmpty ? "auto" : trimmedExpr
                rawString = try await webEvaluator(url, expr)
            }

            return parseWebPayload(rawJSONOrString: rawString, source: source)
        } catch {
            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: dashboardURL,
                formattedValue: "获取失败",
                footnote: String(error.localizedDescription.prefix(24)),
                isLow: false,
                needsLogin: source.type == .webExtract
            )
        }
    }

    private static func fetchJSONAPI(source: BalanceSourceConfig) async throws -> String {
        guard let url = URL(string: source.urlOrCommand) else {
            throw NSError(domain: "BalanceService", code: 2, userInfo: [NSLocalizedDescriptionKey: "API URL 无效"])
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = KeychainStore.loadToken(for: source.id), !token.isEmpty {
            if token.lowercased().hasPrefix("bearer ") {
                req.setValue(token, forHTTPHeaderField: "Authorization")
            } else {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "BalanceService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let json = try JSONSerialization.jsonObject(with: data)
        let resolved = resolveDotPath(json: json, path: source.extractorOrJSONPath)
        if let s = resolved as? String { return s }
        if let n = resolved as? NSNumber { return n.stringValue }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func resolveDotPath(json: Any, path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        var cur: Any? = json
        for part in parts {
            if let dict = cur as? [String: Any] {
                cur = dict[part]
            } else if let arr = cur as? [Any], let idx = Int(part), arr.indices.contains(idx) {
                cur = arr[idx]
            } else {
                return nil
            }
        }
        return cur
    }

    private static func runBalanceCommand(_ cmd: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", cmd]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public static func extractFirstDouble(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let pattern = #"-?\d+(?:\.\d+)?"#
        guard let range = cleaned.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(cleaned[range])
    }
}
