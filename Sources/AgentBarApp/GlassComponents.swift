import AgentBarCore
import AppKit
import SwiftUI

struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, currentX + size.width)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + horizontalSpacing
        }
        return CGSize(width: min(maxWidth, usedWidth), height: currentY + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + horizontalSpacing
        }
    }
}

enum StatusPalette {
    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .failed:
            return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .awaitingApproval:
            return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .completed:
            return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .generating, .runningTool:
            return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .waitingForInput:
            return Color.secondary
        case .runningProcessOnly, .idle, .offline:
            return Color.secondary.opacity(0.75)
        }
    }

    static func textColor(for status: SessionStatus) -> Color {
        switch status {
        case .failed:
            return Color(red: 0.78, green: 0.05, blue: 0.08)
        case .awaitingApproval:
            return Color(red: 0.64, green: 0.34, blue: 0.0)
        case .completed:
            return Color(red: 0.09, green: 0.48, blue: 0.20)
        case .generating, .runningTool:
            return Color(red: 0.0, green: 0.35, blue: 0.80)
        case .waitingForInput, .runningProcessOnly, .idle, .offline:
            return Color.secondary
        }
    }
}

struct StatusDotView: View {
    let status: SessionStatus
    var size: CGFloat = 6.5

    var body: some View {
        switch status {
        case .runningProcessOnly, .offline:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.75), lineWidth: 1.4)
                .frame(width: size, height: size)
        default:
            Circle()
                .fill(StatusPalette.color(for: status))
                .frame(width: size, height: size)
        }
    }
}

struct StatusPillView: View {
    let status: SessionStatus
    var isInferred: Bool = false

    var body: some View {
        HStack(spacing: 4.5) {
            StatusDotView(status: status, size: 6)
            Text(isInferred ? "\(status.label)?" : status.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StatusPalette.textColor(for: status))
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3)
        .modifier(StatusPillBackground(status: status))
    }
}

private struct StatusPillBackground: ViewModifier {
    let status: SessionStatus

    func body(content: Content) -> some View {
        if status == .offline {
            content.overlay(
                Capsule()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.45))
            )
        } else {
            content
                .glassEffect(
                    .regular.tint(StatusPalette.color(for: status).opacity(0.18)),
                    in: .capsule
                )
        }
    }
}

struct MetricChipView: View {
    var dotColor: Color? = nil
    let text: String

    var body: some View {
        HStack(spacing: 4.5) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(
            Capsule()
                .fill(.white.opacity(0.32))
                .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
        )
    }
}

struct StatusFilterPillView: View {
    let category: StatusCategoryFilter
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let color = StatusPalette.color(for: category.representativeStatus)
        let textColor = StatusPalette.textColor(for: category.representativeStatus)
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(category.title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? textColor : .primary.opacity(0.86))
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 || isSelected ? textColor : .secondary)
            }
            .fixedSize()
            .padding(.horizontal, 7.5)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? color.opacity(0.24) : .white.opacity(0.32))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isSelected ? color.opacity(0.88) : .white.opacity(0.58),
                                lineWidth: isSelected ? 1.3 : 0.6
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isSelected ? "再次点击取消过滤" : "点击仅查看“\(category.title)”状态的会话")
    }
}

struct BalanceCardView: View {
    let reading: BalanceReading
    var isRefreshing: Bool = false
    var onOpenDashboard: (() -> Void)? = nil

    var body: some View {
        let timeTag = reading.needsLogin ? "" : " · \(FormattingHelpers.relativeDuration(since: reading.updatedAt))"
        let cleanFoot = reading.footnote
            .replacingOccurrences(of: " · 刚刚", with: "")
            .replacingOccurrences(of: "刚刚更新", with: "自动同步")
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(reading.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isRefreshing {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if reading.sourceType == .webExtract, onOpenDashboard != nil {
                    Image(systemName: reading.needsLogin ? "person.badge.key.fill" : "arrow.up.right.square")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(reading.needsLogin ? Color.orange : Color.accentColor)
                }
            }

            Text(reading.formattedValue)
                .font(.system(size: 15.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    reading.isLow
                        ? Color(red: 0.84, green: 0.05, blue: 0.09)
                        : (reading.needsLogin ? Color.accentColor : .primary)
                )
                .lineLimit(1)

            if let frac = reading.usedFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(reading.isLow ? Color.red : Color.accentColor)
                            .frame(width: max(4, geo.size.width * min(1, max(0, frac))))
                    }
                }
                .frame(height: 4.5)
                .padding(.vertical, 1)
            }

            Text(cleanFoot + timeTag)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if reading.sourceType == .webExtract {
                onOpenDashboard?()
            }
        }
        .help(reading.sourceType == .webExtract ? "点击打开 Dashboard 页面或完成 SSO 登录同步" : reading.name)
    }
}

@MainActor
final class StandaloneMarkdownWindowManager {
    static let shared = StandaloneMarkdownWindowManager()
    private var windows: [String: NSWindow] = [:]

    func open(session: AgentSession) {
        guard let md = session.lastOutputMarkdown, !md.isEmpty else { return }
        if let existing = windows[session.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    AgentLogoView(kind: session.kind, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(session.kind.displayName) · \(session.model ?? "")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("复制 Markdown") {
                        JumpService.copyToPasteboard(md)
                    }
                    .buttonStyle(.glass)
                }
                Divider()
                MarkdownDocumentView(markdown: md, fontSize: 13)
            }
            .padding(18)
        }
        .frame(minWidth: 560, minHeight: 420)

        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "\(session.title) · 输出预览"
        win.setContentSize(NSSize(width: 660, height: 540))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[session.id] = win
    }
}
