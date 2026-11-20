import Foundation

public enum DemoData {
    public static func makeShowcase() -> (
        sessions: [AgentSession],
        hostStates: [HostID: HostConnectionState],
        balances: [BalanceReading],
        subscriptions: [SubscriptionCardItem]
    ) {
        let now = Date()
        let home = ProcessInfo.processInfo.environment["AGENTBAR_GENERIC_HOSTNAME"] == "1"
            ? "/Users/dev"
            : NSHomeDirectory()
        let sshGPU = HostID.ssh(alias: "gpu-dev-01")
        let sshBuild = HostID.ssh(alias: "build-mac")

        let approval = PendingApproval(
            requestID: "demo-req-acmecore",
            sessionID: "demo:claude:acmecore",
            host: .local,
            toolName: "Bash",
            commandOrSummary: "rm -rf .build && swift build",
            cwd: "\(home)/Documents/code/AcmeCore",
            requestedAt: now.addingTimeInterval(-133),
            canRespondViaHook: true,
            highRiskMatchedRule: "rm -rf"
        )

        let s1 = AgentSession(
            id: "demo:claude:acmecore",
            rawSessionID: "demo-session-0001",
            kind: .claudeCode,
            host: .local,
            title: "修复数据流分页加载边界",
            overview: "请求执行 Bash：rm -rf .build && swift build",
            status: .awaitingApproval,
            cwd: "\(home)/Documents/code/AcmeCore/Sources",
            groupDirectory: "\(home)/Documents/code/AcmeCore",
            provider: "Anthropic",
            model: "claude-opus-5-5",
            usage: TokenUsage(input: 182_400, output: 12_900, cacheRead: 1_420_000, cacheWrite: 96_100),
            contextUsedTokens: 128_000,
            contextWindow: 200_000,
            currentTool: ToolCallRecord(
                id: "t1",
                name: "Bash",
                summary: "rm -rf .build && swift build",
                startedAt: now.addingTimeInterval(-133)
            ),
            recentTools: [
                ToolCallRecord(id: "t1", name: "Bash", summary: "rm -rf .build && swift build", startedAt: now.addingTimeInterval(-133)),
                ToolCallRecord(id: "t2", name: "Edit", summary: "Sources/AcmeCore/Loader.swift", startedAt: now.addingTimeInterval(-160), finishedAt: now.addingTimeInterval(-159.6)),
                ToolCallRecord(id: "t3", name: "Read", summary: "Sources/AcmeCore/Loader.swift", startedAt: now.addingTimeInterval(-170), finishedAt: now.addingTimeInterval(-169.9)),
                ToolCallRecord(id: "t4", name: "Bash", summary: "swift test --filter LoaderTests", startedAt: now.addingTimeInterval(-200), finishedAt: now.addingTimeInterval(-181.8), isError: true)
            ],
            totalToolCalls: 46,
            successfulToolCalls: 44,
            turnCount: 9,
            outputTokensPerSecond: 52,
            process: ProcessStats(pid: 48210, memoryBytes: 412 * 1024 * 1024, cpuPercent: 3.1, tty: "ttys004", cwd: "\(home)/Documents/code/AcmeCore"),
            pendingApproval: approval,
            startedAt: now.addingTimeInterval(-2280),
            lastActivityAt: now.addingTimeInterval(-10)
        )

        let loaderMarkdown = """
        ### 已为 Loader 补充单元测试

        新增 `LoaderTests.swift`，覆盖空批次、截断行和编码错误三类边界：

        - **6** 个新用例，全部通过
        - 顺带修复 `decodeBatch` 在空输入时崩溃的问题

        ```bash
        $ swift test --filter LoaderTests
        Test Suite 'LoaderTests' passed
             Executed 6 tests, with 0 failures
        ```

        | 文件 | 改动 |
        | --- | --- |
        | Tests/LoaderTests.swift | +142 |
        | Sources/AcmeCore/Loader.swift | +8 −3 |
        """

        let s2 = AgentSession(
            id: "demo:codex:acmecore-test",
            rawSessionID: "demo-session-0002",
            kind: .codexCLI,
            host: .local,
            title: "给 Loader 补单元测试",
            overview: "新增 6 个测试用例，全部通过",
            status: .completed,
            cwd: "\(home)/Documents/code/AcmeCore",
            groupDirectory: "\(home)/Documents/code/AcmeCore",
            provider: "OpenAI",
            model: "gpt-5-codex",
            reasoningEffort: "high",
            usage: TokenUsage(input: 64_200, output: 4_800, cacheRead: 312_000, reasoning: 1_900),
            contextUsedTokens: 58_000,
            contextWindow: 258_400,
            totalToolCalls: 14,
            successfulToolCalls: 14,
            turnCount: 3,
            outputTokensPerSecond: 68,
            process: ProcessStats(pid: 49102, memoryBytes: 164 * 1024 * 1024, cpuPercent: 0.4, tty: "ttys004", cwd: "\(home)/Documents/code/AcmeCore"),
            lastOutputMarkdown: loaderMarkdown,
            startedAt: now.addingTimeInterval(-900),
            lastActivityAt: now.addingTimeInterval(-240),
            isSeen: false
        )

        let s3 = AgentSession(
            id: "demo:codex:agentbar",
            rawSessionID: "demo-session-0003",
            kind: .codexDesktop,
            host: .local,
            title: "AgentBar 菜单栏工具构建",
            overview: "swift build -c release 正在编译液态玻璃面板…",
            status: .runningTool,
            cwd: "\(home)/Documents/code/AgentBar",
            groupDirectory: "\(home)/Documents/code/AgentBar",
            provider: "OpenAI",
            model: "gpt-5-codex",
            reasoningEffort: "high",
            usage: TokenUsage(input: 92_000, output: 14_200, cacheRead: 412_000, reasoning: 6_100),
            contextUsedTokens: 84_000,
            contextWindow: 272_000,
            currentTool: ToolCallRecord(id: "c1", name: "exec_command", summary: "swift build -c release", startedAt: now.addingTimeInterval(-4)),
            totalToolCalls: 21,
            successfulToolCalls: 21,
            turnCount: 4,
            outputTokensPerSecond: 74,
            process: ProcessStats(pid: 50112, memoryBytes: 186 * 1024 * 1024, cpuPercent: 11.2, cwd: "\(home)/Documents/code/AgentBar"),
            startedAt: now.addingTimeInterval(-1260),
            lastActivityAt: now.addingTimeInterval(-2)
        )

        let s4 = AgentSession(
            id: "demo:dsh:aurora-ui",
            rawSessionID: "demo-session-0004",
            kind: .deepseekHarness,
            host: .local,
            title: "aurora-ui 组件库多语言适配",
            overview: "正在补全 locale/zh.json 中缺失的 38 个键…",
            status: .generating,
            cwd: "\(home)/Documents/code/aurora-ui",
            groupDirectory: "\(home)/Documents/code/aurora-ui",
            provider: "DeepSeek",
            model: "deepseek-chat",
            usage: TokenUsage(input: 48_481, output: 10_587, cacheRead: 580_224),
            contextUsedTokens: 59_263,
            contextWindow: 1_048_576,
            totalToolCalls: 15,
            successfulToolCalls: 15,
            turnCount: 2,
            outputTokensPerSecond: 197,
            startedAt: now.addingTimeInterval(-360),
            lastActivityAt: now.addingTimeInterval(-5)
        )

        let s5 = AgentSession(
            id: "demo:cursor:data-pipeline",
            rawSessionID: "demo-session-0005",
            kind: .cursor,
            host: .local,
            title: "重构训练流水线配置加载",
            overview: "已修改 4 个文件，等待你确认下一步",
            status: .waitingForInput,
            cwd: "\(home)/Documents/code/data-pipeline",
            groupDirectory: "\(home)/Documents/code/data-pipeline",
            provider: "Anthropic",
            model: "claude-opus-5-5",
            turnCount: 5,
            startedAt: now.addingTimeInterval(-3200),
            lastActivityAt: now.addingTimeInterval(-540),
            isSeen: true
        )

        let s6 = AgentSession(
            id: "demo:loose:codex-note",
            rawSessionID: "demo-loose-01",
            kind: .codexDesktop,
            host: .local,
            title: "技术分享大纲与架构问答",
            overview: "已输出 5 节提纲与关键设计权衡说明",
            status: .completed,
            provider: "OpenAI",
            model: "gpt-5-codex",
            usage: TokenUsage(input: 18_400, output: 3_200, cacheRead: 64_000),
            startedAt: now.addingTimeInterval(-1800),
            lastActivityAt: now.addingTimeInterval(-120),
            isSeen: false
        )

        let s7 = AgentSession(
            id: "demo:ssh1:claude",
            rawSessionID: "remote-trainer-01",
            kind: .claudeCode,
            host: sshGPU,
            title: "分布式训练学习率扫描",
            overview: "正在分析第 3 组实验的 loss 收敛曲线…",
            status: .generating,
            cwd: "/data/vision-trainer",
            groupDirectory: "/data/vision-trainer",
            provider: "Anthropic",
            model: "claude-opus-5-5",
            usage: TokenUsage(input: 94_000, output: 8_100, cacheRead: 620_000),
            contextUsedTokens: 94_000,
            contextWindow: 200_000,
            totalToolCalls: 28,
            successfulToolCalls: 27,
            turnCount: 6,
            outputTokensPerSecond: 49,
            startedAt: now.addingTimeInterval(-3840),
            lastActivityAt: now.addingTimeInterval(-8)
        )

        let s8 = AgentSession(
            id: "demo:ssh1:codex-fail",
            rawSessionID: "remote-ckpt-99",
            kind: .codexCLI,
            host: sshGPU,
            title: "清理旧 checkpoint 脚本",
            overview: "API 429：触发速率限制，重试 3 次后放弃",
            status: .failed,
            cwd: "/data/ckpt-tools",
            groupDirectory: "/data/ckpt-tools",
            provider: "OpenAI",
            model: "gpt-5-codex",
            usage: TokenUsage(input: 21_000, output: 1_200, cacheRead: 88_000),
            errorBanner: "429 Too Many Requests：rate limit reached，已自动重试 3 次后放弃",
            startedAt: now.addingTimeInterval(-1200),
            lastActivityAt: now.addingTimeInterval(-660),
            isSeen: false
        )

        let s9 = AgentSession(
            id: "demo:ssh2:offline",
            rawSessionID: "remote-ios-02",
            kind: .codexCLI,
            host: sshBuild,
            title: "iOS 持续构建脚本",
            overview: "最后已知状态：等待输入（3 分钟前）",
            status: .offline,
            cwd: "/Users/builder/work/ios-build",
            groupDirectory: "/Users/builder/work/ios-build",
            provider: "OpenAI",
            model: "gpt-5-codex",
            startedAt: now.addingTimeInterval(-7200),
            lastActivityAt: now.addingTimeInterval(-180),
            isSeen: true
        )

        let hostStates: [HostID: HostConnectionState] = [
            .local: HostConnectionState(host: .local, isOnline: true),
            sshGPU: HostConnectionState(host: sshGPU, isOnline: true, latencyMs: 38),
            sshBuild: HostConnectionState(host: sshBuild, isOnline: false, errorMessage: "认证失败")
        ]

        let balances: [BalanceReading] = [
            BalanceReading(
                sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Team AI Dashboard",
                formattedValue: "$128.40 / $300.00",
                numericValue: 1284.50,
                usedFraction: 0.43,
                footnote: "SSO 自动同步 · 本月额度",
                isLow: false,
                updatedAt: now.addingTimeInterval(-120)
            ),
            BalanceReading(
                sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "DeepSeek Harness",
                sourceType: .deepSeekHarness,
                dashboardURL: "https://platform.deepseek.com/usage",
                formattedValue: "¥86.20",
                numericValue: 86.20,
                usedFraction: 0.42,
                footnote: "充值余额 · 累计已用 ¥63.80",
                isLow: false,
                updatedAt: now.addingTimeInterval(-45)
            ),
            BalanceReading(
                sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "火山方舟（豆包）",
                formattedValue: "¥312.40",
                numericValue: 312.40,
                usedFraction: 0.35,
                footnote: "自定义脚本同步",
                isLow: false,
                updatedAt: now.addingTimeInterval(-300)
            )
        ]

        let subscriptions: [SubscriptionCardItem] = [
            SubscriptionCardItem(
                id: "demo:sub:codex",
                kind: .codexDesktop,
                providerTitle: "OpenAI · Codex",
                planBadge: "ChatGPT Plus",
                subtitle: "有效期至 12-18 · 活跃路由",
                quotas: [
                    QuotaWindowReading(label: "5h 窗口", usedPercent: 12, resetsAt: now.addingTimeInterval(9600)),
                    QuotaWindowReading(label: "7d 周额度", usedPercent: 17, resetsAt: now.addingTimeInterval(240_000))
                ],
                todayTokens: 904_400
            ),
            SubscriptionCardItem(
                id: "demo:sub:claude",
                kind: .claudeCode,
                providerTitle: "Anthropic · Claude",
                planBadge: "Claude Max",
                subtitle: "claude-opus-5-5 · 今日高频使用",
                quotas: [
                    QuotaWindowReading(label: "5h 窗口", usedPercent: 28, resetsAt: now.addingTimeInterval(7200))
                ],
                todayTokens: 1_711_400
            ),
            SubscriptionCardItem(
                id: "demo:sub:deepseek",
                kind: .deepseekHarness,
                providerTitle: "DeepSeek · Harness",
                planBadge: "余额 ¥86.20",
                subtitle: "充值 ¥86.20 · 累计消耗 ¥63.80",
                quotas: [
                    QuotaWindowReading(label: "账户消耗", usedPercent: 42)
                ],
                todayTokens: 639_292
            )
        ]

        return ([s1, s2, s3, s4, s5, s6, s7, s8, s9], hostStates, balances, subscriptions)
    }
}
