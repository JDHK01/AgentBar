import AgentBarCore
import AppKit
import SwiftUI

struct PanelView: View {
    static let panelWidth: CGFloat = 448

    @Bindable var model: AppModel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                headerBar
                if model.isSearchVisible {
                    searchBar
                }
                summaryChipsRow
                if !model.balanceReadings.isEmpty {
                    balancesRow
                }
                filterPicker
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                if newHeight > 60 && abs(model.measuredTopChromeHeight - newHeight) > 0.5 {
                    model.measuredTopChromeHeight = newHeight
                    model.onPreferredHeightChanged?()
                }
            }

            sessionScrollList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutPriority(0)

            footerBar
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                    if newHeight > 20 && abs(model.measuredFooterHeight - newHeight) > 0.5 {
                        model.measuredFooterHeight = newHeight
                        model.onPreferredHeightChanged?()
                    }
                }
        }
        .frame(width: Self.panelWidth)
        .sheet(item: $model.confirmingHighRiskSession) { target in
            highRiskConfirmationSheet(target)
        }
        .sheet(item: $model.denyingSession) { target in
            denyReasonSheet(target)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("AgentBar")
                .font(.system(size: 15, weight: .bold))

            Button {
                model.demoModeEnabled.toggle()
            } label: {
                Text(model.demoModeEnabled ? "演示数据" : "实时数据")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .controlSize(.mini)
            .buttonStyle(.glass)
            .help("一键切换真实本机数据与完整原型演示数据")

            Spacer()

            if model.menuBarCounts.completedUnseen > 0 || model.menuBarCounts.failed > 0 {
                Button("全部已读") {
                    model.markAllCompletedSeen()
                }
                .controlSize(.mini)
                .buttonStyle(.glass)
            }

            GlassEffectContainer {
                HStack(spacing: 5) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.isSearchVisible.toggle()
                            if !model.isSearchVisible {
                                model.searchQuery = ""
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("搜索会话或目录")

                    Button {
                        Task { await model.refreshAll(includeBalances: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                            .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("立即刷新")

                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("设置")
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索标题、工作目录、工具或模型…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var summaryChipsRow: some View {
        let counts = model.menuBarCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                MetricChipView(text: "\(model.sessions.count) 个会话")
                if counts.failed > 0 {
                    MetricChipView(dotColor: StatusPalette.color(for: .failed), text: "\(counts.failed) 失败")
                }
                if counts.awaitingApproval > 0 {
                    MetricChipView(dotColor: StatusPalette.color(for: .awaitingApproval), text: "\(counts.awaitingApproval) 待审批")
                }
                if counts.completedUnseen > 0 {
                    MetricChipView(dotColor: StatusPalette.color(for: .completed), text: "\(counts.completedUnseen) 已完成")
                }
                if counts.activeGenerating > 0 {
                    MetricChipView(dotColor: StatusPalette.color(for: .generating), text: "\(counts.activeGenerating) 进行中")
                }
            }
            .padding(.horizontal, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 9)
    }

    private var balancesRow: some View {
        let cols = min(3, max(1, model.balanceReadings.count))
        return GlassEffectContainer {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: cols),
                spacing: 7
            ) {
                ForEach(model.balanceReadings) { reading in
                    BalanceCardView(reading: reading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    private var filterPicker: some View {
        Picker("", selection: $model.filterMode) {
            ForEach(SessionFilterMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 13)
        .padding(.bottom, 6)
    }

    private var sessionScrollList: some View {
        let hostGroups = model.filteredHostGroups
        return ScrollView(.vertical, showsIndicators: true) {
            Group {
                if hostGroups.isEmpty || hostGroups.allSatisfy({ $0.directories.isEmpty }) {
                    emptyPlaceholder
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hostGroups) { hostGroup in
                            hostSection(hostGroup)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                if newHeight > 20 && abs(model.measuredScrollContentHeight - newHeight) > 0.5 {
                    model.measuredScrollContentHeight = newHeight
                    model.onPreferredHeightChanged?()
                }
            }
        }
        .contentMargins(.zero, for: .scrollContent)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.filterMode == .all ? "暂无匹配的 Agent 会话" : "当前筛选下没有会话")
                .font(.system(size: 13, weight: .semibold))
            Text("在终端或桌面启动 Claude Code、Codex、DeepSeek Harness 或 Cursor 后会自动显示在这里，也可点击顶部“实时数据”切换到演示数据预览全部交互。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func hostSection(_ hostGroup: HostSessionGroup) -> some View {
        let isOffline = !hostGroup.connection.isOnline
        let collapsed = model.isGroupCollapsed(hostGroup.id, defaultOffline: isOffline)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 11)

                Image(systemName: hostGroup.host.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))

                Text(hostGroup.host.displayTitle)
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                hostRightStatus(hostGroup)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.toggleGroupCollapsed(hostGroup.id, isOfflineHost: isOffline)
                }
            }

            if !collapsed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hostGroup.directories) { dirGroup in
                        directorySection(dirGroup)
                    }
                }
                .opacity(isOffline ? 0.58 : 1.0)
            }
        }
    }

    @ViewBuilder
    private func hostRightStatus(_ hostGroup: HostSessionGroup) -> some View {
        if hostGroup.host.isLocal {
            Text("\(hostGroup.totalSessionCount) 个会话")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if hostGroup.connection.isOnline {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                if let ms = hostGroup.connection.latencyMs {
                    Text("SSH · \(ms) ms")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("SSH · 在线")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1.2)
                    .frame(width: 6, height: 6)
                Text("离线 · \(hostGroup.connection.errorMessage ?? "不可达")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("重连") {
                    Task { await model.refreshSSHHosts() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func directorySection(_ dirGroup: DirectorySessionGroup) -> some View {
        let collapsed = model.isGroupCollapsed(dirGroup.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                if dirGroup.directory != nil {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.25, green: 0.62, blue: 0.96))
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Text(dirGroup.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(dirGroup.abbreviatedPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                directoryMiniCounts(dirGroup.sessions)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.toggleGroupCollapsed(dirGroup.id)
                }
            }

            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(dirGroup.sessions) { session in
                        SessionRowView(
                            session: session,
                            isExpanded: model.expandedSessionIDs.contains(session.id),
                            model: model
                        )
                    }
                }
                .padding(.leading, 22)
                .padding(.trailing, 8)
            }
        }
    }

    private func directoryMiniCounts(_ list: [AgentSession]) -> some View {
        let failCount = list.filter { $0.status == .failed }.count
        let appCount = list.filter { $0.status == .awaitingApproval }.count
        let doneCount = list.filter { $0.status == .completed }.count
        let genCount = list.filter { $0.status.isActiveWork && $0.status != .awaitingApproval }.count
        let restCount = list.count - failCount - appCount - doneCount - genCount

        return HStack(spacing: 5) {
            if failCount > 0 { miniDotCount(.failed, count: failCount) }
            if appCount > 0 { miniDotCount(.awaitingApproval, count: appCount) }
            if doneCount > 0 { miniDotCount(.completed, count: doneCount) }
            if genCount > 0 { miniDotCount(.generating, count: genCount) }
            if restCount > 0 && failCount == 0 && appCount == 0 && doneCount == 0 && genCount == 0 {
                miniDotCount(list.first?.status ?? .waitingForInput, count: restCount)
            }
        }
    }

    private func miniDotCount(_ status: SessionStatus, count: Int) -> some View {
        HStack(spacing: 2.5) {
            StatusDotView(status: status, size: 6)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footerBar: some View {
        HStack {
            Text(model.todaySummaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("设置") {
                onOpenSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    private func highRiskConfirmationSheet(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 20))
                Text("确认批准高风险操作？")
                    .font(.system(size: 14, weight: .bold))
            }
            Text("命中规则：\(session.pendingApproval?.highRiskMatchedRule ?? "")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(session.pendingApproval?.commandOrSummary ?? session.overview)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack {
                Spacer()
                Button("取消") {
                    model.confirmingHighRiskSession = nil
                }
                .buttonStyle(.glass)
                Button("确认批准一次") {
                    model.requestApprove(session, bypassHighRiskCheck: true)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func denyReasonSheet(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("拒绝并向 Agent 说明原因")
                .font(.system(size: 14, weight: .bold))
            TextField("可选：例如“不要删除 .build，直接增量编译”", text: $model.denyReasonDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") {
                    model.denyingSession = nil
                }
                .buttonStyle(.glass)
                Button("发送拒绝") {
                    let reason = model.denyReasonDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.requestDeny(session, reason: reason.isEmpty ? nil : reason)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}
