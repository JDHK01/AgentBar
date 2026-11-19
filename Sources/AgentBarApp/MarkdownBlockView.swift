import AppKit
import SwiftUI

enum MarkdownBlock: Identifiable {
    case heading(id: Int, level: Int, text: String)
    case paragraph(id: Int, text: String)
    case bulletList(id: Int, items: [String])
    case codeBlock(id: Int, language: String?, code: String)
    case table(id: Int, headers: [String], rows: [[String]])
    case quote(id: Int, text: String)

    var id: Int {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .bulletList(let id, _),
             .codeBlock(let id, _, _),
             .table(let id, _, _),
             .quote(let id, _):
            return id
        }
    }
}

enum LightweightMarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var nextID = 1
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(id: nextID, language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
                nextID += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let rest = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty && hashes.count <= 6 {
                    blocks.append(.heading(id: nextID, level: hashes.count, text: rest))
                    nextID += 1
                    index += 1
                    continue
                }
            }

            // GFM pipe table
            if trimmed.contains("|"),
               index + 1 < lines.count,
               isTableSeparatorLine(lines[index + 1]) {
                let headers = splitTableCells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|") && !rowLine.isEmpty else { break }
                    rows.append(splitTableCells(rowLine))
                    index += 1
                }
                blocks.append(.table(id: nextID, headers: headers, rows: rows))
                nextID += 1
                continue
            }

            // List items
            if isListItem(trimmed) {
                var items: [String] = []
                while index < lines.count {
                    let cur = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isListItem(cur) else { break }
                    items.append(stripListMarker(cur))
                    index += 1
                }
                blocks.append(.bulletList(id: nextID, items: items))
                nextID += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let cur = lines[index].trimmingCharacters(in: .whitespaces)
                    guard cur.hasPrefix(">") else { break }
                    quoteLines.append(cur.dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(id: nextID, text: quoteLines.joined(separator: "\n")))
                nextID += 1
                continue
            }

            // Paragraph
            var paraLines: [String] = []
            while index < lines.count {
                let cur = lines[index]
                let curTrim = cur.trimmingCharacters(in: .whitespaces)
                if curTrim.isEmpty || curTrim.hasPrefix("```") || curTrim.hasPrefix("#") || isListItem(curTrim) || curTrim.hasPrefix(">") {
                    break
                }
                paraLines.append(curTrim)
                index += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(id: nextID, text: paraLines.joined(separator: " ")))
                nextID += 1
            }
        }
        return blocks
    }

    private static func isListItem(_ s: String) -> Bool {
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { return true }
        if let dotIdx = s.firstIndex(of: "."),
           s[..<dotIdx].allSatisfy(\.isNumber),
           s.index(after: dotIdx) < s.endIndex,
           s[s.index(after: dotIdx)] == " " {
            return true
        }
        return false
    }

    private static func stripListMarker(_ s: String) -> String {
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            return String(s.dropFirst(2))
        }
        if let dotIdx = s.firstIndex(of: ".") {
            let next = s.index(after: dotIdx)
            if next < s.endIndex {
                return String(s[next...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct MarkdownDocumentView: View {
    let markdown: String
    var fontSize: CGFloat = 12

    var body: some View {
        let blocks = LightweightMarkdownParser.parse(markdown)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    inlineText(text)
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .padding(.top, level <= 2 ? 2 : 0)

                case .paragraph(_, let text):
                    inlineText(text)
                        .font(.system(size: fontSize))
                        .fixedSize(horizontal: false, vertical: true)

                case .bulletList(_, let items):
                    VStack(alignment: .leading, spacing: 3.5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                    .font(.system(size: fontSize, weight: .bold))
                                    .foregroundStyle(.secondary)
                                inlineText(item)
                                    .font(.system(size: fontSize))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                case .codeBlock(_, let lang, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lang ?? "code")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Button {
                                JumpService.copyToPasteboard(code)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                            .help("复制代码")
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color(white: 0.95))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
                    )

                case .table(_, let headers, let rows):
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                                Text(h)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(0..<headers.count, id: \.self) { col in
                                    inlineText(col < row.count ? row[col] : "")
                                        .font(.system(size: 11))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)

                case .quote(_, let text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                        inlineText(text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 3
        case 2: return fontSize + 2
        case 3: return fontSize + 1
        default: return fontSize + 0.5
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(raw)
    }
}
