import AgentBarCore
import AppKit
import SwiftUI

@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()
    private var cache: [AgentKind: NSImage] = [:]

    func baseIcon(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] {
            return cached
        }
        let ws = NSWorkspace.shared
        for bundleID in kind.preferredBundleIdentifiers {
            if let url = ws.urlForApplication(withBundleIdentifier: bundleID) {
                let img = ws.icon(forFile: url.path)
                cache[kind] = img
                return img
            }
        }
        for path in kind.fallbackAppPaths where FileManager.default.fileExists(atPath: path) {
            let img = ws.icon(forFile: path)
            cache[kind] = img
            return img
        }
        return nil
    }
}

struct AgentLogoView: View {
    let kind: AgentKind
    var size: CGFloat = 32

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let nsImage = AppIconProvider.shared.baseIcon(for: kind) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.14), radius: 1.5, x: 0, y: 1)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.62), Color(white: 0.38)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size * 0.84, height: size * 0.84)
                    .overlay(
                        Text(kind.fallbackMonogram)
                            .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    )
                    .frame(width: size, height: size)
            }

            if kind.isCLI {
                Text(">_")
                    .font(.system(size: max(7, size * 0.22), weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2.5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(.white.opacity(0.95), lineWidth: 1.2)
                    )
                    .offset(x: 1, y: 1)
            } else if kind.isChatOnly {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: max(7, size * 0.23), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.46, height: size * 0.46)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.2))
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

@MainActor
enum MenuBarBadgeRenderer {
    struct Segment {
        let color: NSColor
        let text: String
    }

    static func renderStatusImage(
        counts: MenuBarCounts,
        totalSessionCount: Int,
        style: MenuBarIconStyle,
        isDarkMenuBar: Bool
    ) -> NSImage {
        let fgColor = isDarkMenuBar ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 0.95)
        let segments: [Segment] = buildSegments(counts: counts, totalSessionCount: totalSessionCount, style: style)

        let height: CGFloat = 22
        let glyphWidth: CGFloat = 16
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor
        ]

        var totalWidth: CGFloat = 4 + glyphWidth + 4
        var measuredTexts: [(Segment, NSSize)] = []
        if !segments.isEmpty {
            totalWidth += 3
            for (idx, seg) in segments.enumerated() {
                let sz = (seg.text as NSString).size(withAttributes: textAttrs)
                measuredTexts.append((seg, sz))
                totalWidth += 7.0 + (seg.text.isEmpty ? 0 : (2.5 + ceil(sz.width)))
                if idx < segments.count - 1 {
                    totalWidth += 5.5
                }
            }
            totalWidth += 2
        }

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height), flipped: false) { _ in
            // Draw crisp terminal glyph [>_]
            let glyphRect = NSRect(x: 3, y: 4.5, width: 14, height: 13)
            let border = NSBezierPath(roundedRect: glyphRect, xRadius: 3.0, yRadius: 3.0)
            border.lineWidth = 1.45
            fgColor.setStroke()
            border.stroke()

            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: glyphRect.minX + 3.2, y: glyphRect.maxY - 4.0))
            chevron.line(to: NSPoint(x: glyphRect.minX + 5.8, y: glyphRect.midY))
            chevron.line(to: NSPoint(x: glyphRect.minX + 3.2, y: glyphRect.minY + 4.0))
            chevron.lineWidth = 1.4
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()

            let underscore = NSBezierPath()
            underscore.move(to: NSPoint(x: glyphRect.minX + 7.4, y: glyphRect.minY + 3.8))
            underscore.line(to: NSPoint(x: glyphRect.maxX - 3.0, y: glyphRect.minY + 3.8))
            underscore.lineWidth = 1.4
            underscore.lineCapStyle = .round
            underscore.stroke()

            var cursorX: CGFloat = glyphRect.maxX + 6.0
            for (seg, sz) in measuredTexts {
                let dotSize: CGFloat = 6.8
                let dotRect = NSRect(x: cursorX, y: (height - dotSize) / 2.0, width: dotSize, height: dotSize)
                let dotPath = NSBezierPath(ovalIn: dotRect)
                seg.color.setFill()
                dotPath.fill()
                NSColor.black.withAlphaComponent(0.22).setStroke()
                dotPath.lineWidth = 0.5
                dotPath.stroke()
                cursorX += dotSize

                if !seg.text.isEmpty {
                    cursorX += 2.5
                    let textRect = NSRect(
                        x: cursorX,
                        y: (height - sz.height) / 2.0 - 0.3,
                        width: ceil(sz.width),
                        height: sz.height
                    )
                    (seg.text as NSString).draw(in: textRect, withAttributes: textAttrs)
                    cursorX += ceil(sz.width)
                }
                cursorX += 5.5
            }
            return true
        }
        image.isTemplate = segments.isEmpty
        return image
    }

    private static func buildSegments(
        counts: MenuBarCounts,
        totalSessionCount: Int,
        style: MenuBarIconStyle
    ) -> [Segment] {
        let red = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
        let yellow = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
        let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
        let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)

        func cap(_ n: Int) -> String { n > 9 ? "9+" : "\(n)" }

        switch style {
        case .multiDot:
            var list: [Segment] = []
            if counts.failed > 0 { list.append(Segment(color: red, text: cap(counts.failed))) }
            if counts.awaitingApproval > 0 { list.append(Segment(color: yellow, text: cap(counts.awaitingApproval))) }
            if counts.completedUnseen > 0 { list.append(Segment(color: green, text: cap(counts.completedUnseen))) }
            if counts.activeGenerating > 0 { list.append(Segment(color: blue, text: cap(counts.activeGenerating))) }
            return list
        case .singlePriority:
            let topColor: NSColor?
            if counts.failed > 0 { topColor = red }
            else if counts.awaitingApproval > 0 { topColor = yellow }
            else if counts.completedUnseen > 0 { topColor = green }
            else if counts.activeGenerating > 0 { topColor = blue }
            else { topColor = nil }
            guard let topColor else { return [] }
            return [Segment(color: topColor, text: cap(max(counts.totalHighlighted, totalSessionCount)))]
        }
    }
}
