import Foundation

public struct DeepSeekWalletEntry: Codable, Hashable, Sendable {
    public var currency: String
    public var normalBalance: Decimal
    public var bonusBalance: Decimal
    public var totalCost: Decimal

    public init(
        currency: String,
        normalBalance: Decimal,
        bonusBalance: Decimal = 0,
        totalCost: Decimal = 0
    ) {
        self.currency = currency.uppercased()
        self.normalBalance = normalBalance
        self.bonusBalance = bonusBalance
        self.totalCost = totalCost
    }

    public var totalBalance: Decimal {
        normalBalance + bonusBalance
    }

    public var symbol: String {
        switch currency {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        default: return "\(currency) "
        }
    }
}

public enum DeepSeekAccountStatus: Codable, Hashable, Sendable {
    case ready
    case expired
    case signedOut
    case failed(String)
}

public struct DeepSeekAccountSnapshot: Codable, Hashable, Sendable {
    public var status: DeepSeekAccountStatus
    public var authSource: String
    public var wallets: [DeepSeekWalletEntry]
    public var usageURL: String
    public var topUpURL: String
    public var updatedAt: Date

    public init(
        status: DeepSeekAccountStatus,
        authSource: String = "DeepSeek 账号",
        wallets: [DeepSeekWalletEntry] = [],
        usageURL: String = "https://platform.deepseek.com/usage",
        topUpURL: String = "https://platform.deepseek.com/top_up",
        updatedAt: Date = Date()
    ) {
        self.status = status
        self.authSource = authSource
        self.wallets = wallets
        self.usageURL = usageURL
        self.topUpURL = topUpURL
        self.updatedAt = updatedAt
    }

    public var primaryWallet: DeepSeekWalletEntry? {
        if let funded = wallets.first(where: { $0.totalBalance != 0 }) {
            return funded
        }
        if let withSpend = wallets.first(where: { $0.totalCost > 0 }) {
            return withSpend
        }
        if let cny = wallets.first(where: { $0.currency == "CNY" }) {
            return cny
        }
        return wallets.first
    }

    public var primaryFormattedBalance: String {
        let nonZero = wallets.filter { $0.totalBalance != 0 }
        if !nonZero.isEmpty {
            return nonZero
                .map { DeepSeekAccountUsageService.formatBalance($0.totalBalance, symbol: $0.symbol) }
                .joined(separator: " + ")
        }
        if let primary = primaryWallet {
            return DeepSeekAccountUsageService.formatBalance(primary.totalBalance, symbol: primary.symbol)
        }
        return "¥0.00"
    }

    public var primaryNumericBalance: Double? {
        guard status == .ready, let primary = primaryWallet else { return nil }
        return NSDecimalNumber(decimal: primary.totalBalance).doubleValue
    }

    public var primaryUsedFraction: Double? {
        guard status == .ready, let primary = primaryWallet else { return nil }
        if primary.totalBalance <= 0 && primary.totalCost > 0 {
            return 1.0
        }
        guard primary.totalCost > 0 else { return nil }
        let totalCredits = primary.totalBalance + primary.totalCost
        guard totalCredits > 0 else { return nil }
        let frac = NSDecimalNumber(decimal: primary.totalCost / totalCredits).doubleValue
        return min(1.0, max(0.0, frac))
    }

    public var isZeroOrNegativeBalance: Bool {
        guard status == .ready else { return false }
        guard !wallets.isEmpty else { return false }
        return !wallets.contains(where: { $0.totalBalance > 0 })
    }

    public func toBalanceReading(source: BalanceSourceConfig) -> BalanceReading {
        switch status {
        case .ready:
            let primary = primaryWallet ?? DeepSeekWalletEntry(currency: "CNY", normalBalance: 0)
            let numVal = NSDecimalNumber(decimal: primary.totalBalance).doubleValue
            let belowThreshold = source.lowBalanceThreshold.map { numVal < $0 } ?? false
            let zeroBalance = isZeroOrNegativeBalance
            let isLow = zeroBalance || belowThreshold
            let targetURL = zeroBalance ? topUpURL : usageURL

            let footnote: String
            if zeroBalance {
                footnote = "当前无可用余额 · 点击去充值"
            } else if belowThreshold, let threshold = source.lowBalanceThreshold {
                footnote = "低于阈值 \(primary.symbol)\(Int(threshold)) · 点击充值"
            } else if primary.bonusBalance > 0 && primary.totalCost > 0 {
                let bonusStr = DeepSeekAccountUsageService.formatBalance(primary.bonusBalance, symbol: primary.symbol)
                let costStr = DeepSeekAccountUsageService.formatBalance(primary.totalCost, symbol: primary.symbol)
                footnote = "含赠金 \(bonusStr) · 已用 \(costStr)"
            } else if primary.bonusBalance > 0 {
                let normStr = DeepSeekAccountUsageService.formatBalance(primary.normalBalance, symbol: primary.symbol)
                let bonusStr = DeepSeekAccountUsageService.formatBalance(primary.bonusBalance, symbol: primary.symbol)
                footnote = "充值 \(normStr) · 赠金 \(bonusStr)"
            } else if primary.totalCost > 0 {
                let costStr = DeepSeekAccountUsageService.formatBalance(primary.totalCost, symbol: primary.symbol)
                footnote = "充值余额 · 累计已用 \(costStr)"
            } else {
                footnote = "\(authSource) · 点击查看用量"
            }

            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: targetURL,
                formattedValue: primaryFormattedBalance,
                numericValue: numVal,
                usedFraction: primaryUsedFraction,
                footnote: footnote,
                isLow: isLow,
                needsLogin: false,
                updatedAt: updatedAt
            )

        case .expired:
            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: usageURL,
                formattedValue: "登录已过期",
                footnote: "点击打开 DeepSeek Harness 重新登录",
                isLow: false,
                needsLogin: true,
                updatedAt: updatedAt
            )

        case .signedOut:
            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: usageURL,
                formattedValue: "点击登录账号",
                footnote: "在 DeepSeek Harness 登录后自动同步",
                isLow: false,
                needsLogin: true,
                updatedAt: updatedAt
            )

        case .failed(let reason):
            return BalanceReading(
                sourceID: source.id,
                name: source.name,
                sourceType: source.type,
                dashboardURL: usageURL,
                formattedValue: "获取失败",
                footnote: String(reason.prefix(26)),
                isLow: false,
                needsLogin: false,
                updatedAt: updatedAt
            )
        }
    }
}

public struct DeepSeekStoredGrant: Sendable, Equatable {
    public var token: String
    public var issuerOrigin: String

    public init(token: String, issuerOrigin: String) {
        self.token = token
        self.issuerOrigin = issuerOrigin
    }
}

public enum DeepSeekAccountUsageService {
    public static let defaultPlatformOrigin = "https://platform.deepseek.com"

    public static func resolveDSHHome(homeDirectory: String = NSHomeDirectory()) -> String {
        if let envHome = ProcessInfo.processInfo.environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envHome.isEmpty {
            return (envHome as NSString).expandingTildeInPath
        }
        return (homeDirectory as NSString).appendingPathComponent(".dsh")
    }

    public static func hasStoredCredentials(
        homeDirectory: String = NSHomeDirectory(),
        fallbackKeychainID: UUID? = nil
    ) -> Bool {
        let dshHome = resolveDSHHome(homeDirectory: homeDirectory)
        let credPath = (dshHome as NSString).appendingPathComponent(".credentials.yaml")
        if let yaml = try? String(contentsOfFile: credPath, encoding: .utf8),
           parseCredentialsGrant(yaml: yaml) != nil {
            return true
        }
        if loadFallbackAPIKey(dshHome: dshHome, keychainID: fallbackKeychainID) != nil {
            return true
        }
        return false
    }

    public static func fetchReading(
        for source: BalanceSourceConfig,
        homeDirectory: String = NSHomeDirectory()
    ) async -> BalanceReading {
        let snapshot = await fetchSnapshot(homeDirectory: homeDirectory, fallbackKeychainID: source.id)
        return snapshot.toBalanceReading(source: source)
    }

    public static func fetchSnapshot(
        homeDirectory: String = NSHomeDirectory(),
        fallbackKeychainID: UUID? = BalanceSourceConfig.deepSeekHarnessDefaultID
    ) async -> DeepSeekAccountSnapshot {
        let dshHome = resolveDSHHome(homeDirectory: homeDirectory)
        let credPath = (dshHome as NSString).appendingPathComponent(".credentials.yaml")
        if let yaml = try? String(contentsOfFile: credPath, encoding: .utf8),
           let grant = parseCredentialsGrant(yaml: yaml) {
            let desktopVersion = readDesktopVersion(dshHome: dshHome)
            return await queryPlatformSummary(grant: grant, desktopVersion: desktopVersion)
        }

        if let apiKey = loadFallbackAPIKey(dshHome: dshHome, keychainID: fallbackKeychainID) {
            return await queryOfficialAPIBalance(apiKey: apiKey)
        }

        return DeepSeekAccountSnapshot(status: .signedOut)
    }

    public static func parseCredentialsGrant(yaml: String) -> DeepSeekStoredGrant? {
        var inTargetSection = false
        var sectionIndent = -1
        var kindValue: String?
        var tokenValue: String?
        var issuerValue: String?

        for rawLine in yaml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let indent = leadingIndentationCount(line)
            if !inTargetSection {
                if let (key, _) = splitYAMLKeyValue(trimmed),
                   key == "deepseek-account-platform/default" {
                    inTargetSection = true
                    sectionIndent = indent
                }
                continue
            }

            if indent <= sectionIndent {
                break
            }

            guard let (key, val) = splitYAMLKeyValue(trimmed) else { continue }
            switch key {
            case "kind":
                if !val.isEmpty { kindValue = val }
            case "token":
                if !val.isEmpty { tokenValue = val }
            case "issuer":
                if !val.isEmpty { issuerValue = val }
            default:
                break
            }
        }

        if let kindValue, kindValue != "grant" {
            return nil
        }
        guard let token = tokenValue, !token.isEmpty else {
            return nil
        }
        let origin = normalizeOrigin(issuerValue ?? defaultPlatformOrigin) ?? defaultPlatformOrigin
        return DeepSeekStoredGrant(token: token, issuerOrigin: origin)
    }

    public static func parseUserSummaryResponse(
        data: Data,
        statusCode: Int,
        issuerOrigin: String = defaultPlatformOrigin
    ) -> DeepSeekAccountSnapshot {
        let origin = normalizeOrigin(issuerOrigin) ?? defaultPlatformOrigin
        let usageURL = "\(origin)/usage"
        let topUpURL = "\(origin)/top_up"

        if statusCode == 401 {
            return DeepSeekAccountSnapshot(
                status: .expired,
                usageURL: usageURL,
                topUpURL: topUpURL
            )
        }
        guard (200..<300).contains(statusCode) else {
            return DeepSeekAccountSnapshot(
                status: .failed("HTTP \(statusCode)"),
                usageURL: usageURL,
                topUpURL: topUpURL
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (root["code"] as? NSNumber)?.intValue else {
            return DeepSeekAccountSnapshot(
                status: .failed("响应格式异常"),
                usageURL: usageURL,
                topUpURL: topUpURL
            )
        }

        if code == 40003 {
            return DeepSeekAccountSnapshot(
                status: .expired,
                usageURL: usageURL,
                topUpURL: topUpURL
            )
        }

        guard code == 0,
              let payload = root["data"] as? [String: Any],
              (payload["biz_code"] as? NSNumber)?.intValue == 0,
              let bizData = payload["biz_data"] as? [String: Any] else {
            let bizCode = ((root["data"] as? [String: Any])?["biz_code"] as? NSNumber)?.intValue
            let label = bizCode.map { "业务错误 \($0)" } ?? "接口返回 code=\(code)"
            return DeepSeekAccountSnapshot(
                status: .failed(label),
                usageURL: usageURL,
                topUpURL: topUpURL
            )
        }

        var buckets: [String: (normal: Decimal, bonus: Decimal, cost: Decimal)] = [:]

        if let normalWallets = bizData["normal_wallets"] as? [[String: Any]] {
            for item in normalWallets {
                guard let currency = (item["currency"] as? String)?.uppercased(),
                      let amount = parseDecimal(item["balance"]) else { continue }
                var entry = buckets[currency] ?? (0, 0, 0)
                entry.normal += amount
                buckets[currency] = entry
            }
        }

        if let bonusWallets = bizData["bonus_wallets"] as? [[String: Any]] {
            for item in bonusWallets {
                guard let currency = (item["currency"] as? String)?.uppercased(),
                      let amount = parseDecimal(item["balance"]) else { continue }
                var entry = buckets[currency] ?? (0, 0, 0)
                entry.bonus += amount
                buckets[currency] = entry
            }
        }

        if let totalCosts = bizData["total_costs"] as? [[String: Any]] {
            for item in totalCosts {
                guard let currency = (item["currency"] as? String)?.uppercased(),
                      let amount = parseDecimal(item["amount"] ?? item["balance"]) else { continue }
                var entry = buckets[currency] ?? (0, 0, 0)
                entry.cost += amount
                buckets[currency] = entry
            }
        }

        let wallets = sortedCurrencies(Array(buckets.keys)).map { cur in
            let val = buckets[cur] ?? (0, 0, 0)
            return DeepSeekWalletEntry(
                currency: cur,
                normalBalance: val.normal,
                bonusBalance: val.bonus,
                totalCost: val.cost
            )
        }

        return DeepSeekAccountSnapshot(
            status: .ready,
            authSource: "DeepSeek 账号",
            wallets: wallets,
            usageURL: usageURL,
            topUpURL: topUpURL
        )
    }

    public static func parseOfficialAPIBalanceResponse(
        data: Data,
        statusCode: Int
    ) -> DeepSeekAccountSnapshot {
        if statusCode == 401 {
            return DeepSeekAccountSnapshot(status: .expired, authSource: "API Key")
        }
        guard (200..<300).contains(statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]] else {
            return DeepSeekAccountSnapshot(
                status: .failed("HTTP \(statusCode)"),
                authSource: "API Key"
            )
        }

        var buckets: [String: (normal: Decimal, bonus: Decimal)] = [:]
        for info in infos {
            guard let currency = (info["currency"] as? String)?.uppercased() else { continue }
            let topped = parseDecimal(info["topped_up_balance"])
            let granted = parseDecimal(info["granted_balance"])
            let total = parseDecimal(info["total_balance"])
            let normalVal = topped ?? (total ?? 0)
            let bonusVal = topped != nil ? (granted ?? 0) : 0
            var entry = buckets[currency] ?? (0, 0)
            entry.normal += normalVal
            entry.bonus += bonusVal
            buckets[currency] = entry
        }

        let wallets = sortedCurrencies(Array(buckets.keys)).map { cur in
            let val = buckets[cur] ?? (0, 0)
            return DeepSeekWalletEntry(currency: cur, normalBalance: val.normal, bonusBalance: val.bonus)
        }
        return DeepSeekAccountSnapshot(
            status: .ready,
            authSource: "API Key",
            wallets: wallets
        )
    }

    /// Matches DeepSeek Harness `formatBalance.ts` (two-decimal floor + `<¥0.01` sub-cent indicator).
    public static func formatBalance(_ amount: Decimal, symbol: String) -> String {
        let subCent = Decimal(string: "0.01") ?? 0.01
        if amount == 0 {
            return "\(symbol)0.00"
        }
        if amount < 0 {
            let absVal = -amount
            if absVal < subCent {
                return "-\(symbol)0.01"
            }
            return "-\(symbol)\(formatGroupedTwoDecimals(absVal, roundingMode: .plain))"
        }
        if amount < subCent {
            return "<\(symbol)0.01"
        }
        return "\(symbol)\(formatGroupedTwoDecimals(amount, roundingMode: .down))"
    }

    private static func queryPlatformSummary(
        grant: DeepSeekStoredGrant,
        desktopVersion: String
    ) async -> DeepSeekAccountSnapshot {
        let origin = normalizeOrigin(grant.issuerOrigin) ?? defaultPlatformOrigin
        guard let url = URL(string: "\(origin)/api/v0/users/get_user_summary") else {
            return DeepSeekAccountSnapshot(status: .failed("平台地址无效"))
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(grant.token, forHTTPHeaderField: "x-dsh-auth-token")
        req.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        req.setValue("desktop-mac", forHTTPHeaderField: "x-client-platform")
        req.setValue(desktopVersion, forHTTPHeaderField: "x-client-version")
        req.setValue("zh_CN", forHTTPHeaderField: "x-client-locale")
        req.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "x-client-timezone-offset")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) DeepSeekHarness/\(desktopVersion) Chrome/134.0.0.0 Electron/35.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return parseUserSummaryResponse(data: data, statusCode: status, issuerOrigin: origin)
        } catch {
            return DeepSeekAccountSnapshot(
                status: .failed("网络连接失败"),
                usageURL: "\(origin)/usage",
                topUpURL: "\(origin)/top_up"
            )
        }
    }

    private static func queryOfficialAPIBalance(apiKey: String) async -> DeepSeekAccountSnapshot {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return DeepSeekAccountSnapshot(status: .failed("API 地址无效"), authSource: "API Key")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if apiKey.lowercased().hasPrefix("bearer ") {
            req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        } else {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return parseOfficialAPIBalanceResponse(data: data, statusCode: status)
        } catch {
            return DeepSeekAccountSnapshot(status: .failed("网络连接失败"), authSource: "API Key")
        }
    }

    private static func readDesktopVersion(dshHome: String) -> String {
        let runtimePath = (dshHome as NSString).appendingPathComponent("dsh-runtimes/dsh-primary-runtime/runtime.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: runtimePath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ver = (obj["desktopVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ver.isEmpty {
            return ver
        }
        return "0.2.2"
    }

    private static func loadFallbackAPIKey(dshHome: String, keychainID: UUID?) -> String? {
        if let keychainID,
           let token = KeychainStore.loadToken(for: keychainID)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        if let envKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return envKey
        }
        let dotEnvPath = (dshHome as NSString).appendingPathComponent(".env")
        if let content = try? String(contentsOfFile: dotEnvPath, encoding: .utf8) {
            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let eq = line.firstIndex(of: "=") else { continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = unquoteYAMLValue(String(line[line.index(after: eq)...]))
                if k == "DEEPSEEK_API_KEY", !v.isEmpty {
                    return v
                }
            }
        }
        return nil
    }

    private static func leadingIndentationCount(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " {
                count += 1
            } else if ch == "\t" {
                count += 2
            } else {
                break
            }
        }
        return count
    }

    private static func splitYAMLKeyValue(_ trimmedLine: String) -> (key: String, value: String)? {
        guard let colonIdx = trimmedLine.firstIndex(of: ":") else { return nil }
        let rawKey = String(trimmedLine[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let rawVal = String(trimmedLine[trimmedLine.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        return (unquoteYAMLValue(rawKey), unquoteYAMLValue(rawVal))
    }

    private static func unquoteYAMLValue(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func normalizeOrigin(_ raw: String) -> String? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host,
              !host.isEmpty else {
            return nil
        }
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            return nil
        }
        if let port = comps.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func parseDecimal(_ raw: Any?) -> Decimal? {
        if let s = raw as? String {
            return Decimal(string: s.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
        }
        if let n = raw as? NSNumber {
            return n.decimalValue
        }
        return nil
    }

    private static func sortedCurrencies(_ currencies: [String]) -> [String] {
        currencies.sorted { lhs, rhs in
            let rank: (String) -> Int = { cur in
                switch cur {
                case "CNY": return 0
                case "USD": return 1
                default: return 2
                }
            }
            let rL = rank(lhs)
            let rR = rank(rhs)
            if rL != rR { return rL < rR }
            return lhs < rhs
        }
    }

    private static func formatGroupedTwoDecimals(
        _ value: Decimal,
        roundingMode: NSDecimalNumber.RoundingMode
    ) -> String {
        var src = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &src, 2, roundingMode)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? String(format: "%.2f", NSDecimalNumber(decimal: rounded).doubleValue)
    }
}
