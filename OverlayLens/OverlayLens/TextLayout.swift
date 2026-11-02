import CoreGraphics

/// One piece of recognized text in view coordinates (points, bottom-left origin).
struct TextPiece {
    let rect: CGRect
    let text: String
}

/// Pieces that sit on the same baseline, left to right.
struct TextRow {
    var rect: CGRect
    var pieces: [TextPiece]
    var height: CGFloat { rect.height }
}

/// Rows stacked into one paragraph: this is what the hover frame outlines.
struct TextBlock {
    var rect: CGRect
    var rows: [TextRow]
}

/// Vision hands back one observation per run of text, and it splits a visual
/// line wherever the script or spacing changes (Thai/English mixes, wide
/// gaps). Stitch those back into rows and rows into paragraphs so a hover
/// outlines the whole sentence, not a fragment of it.
enum TextLayout {
    static func rows(from pieces: [TextPiece]) -> [TextRow] {
        var rows: [TextRow] = []
        for piece in pieces.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            let index = rows.lastIndex { row in
                let overlap = min(row.rect.maxY, piece.rect.maxY) - max(row.rect.minY, piece.rect.minY)
                let gap = max(piece.rect.minX - row.rect.maxX, row.rect.minX - piece.rect.maxX)
                return overlap >= 0.5 * min(row.height, piece.rect.height) && gap < 1.2 * min(row.height, piece.rect.height)
            }
            if let index {
                rows[index].rect = rows[index].rect.union(piece.rect)
                rows[index].pieces.append(piece)
            } else {
                rows.append(TextRow(rect: piece.rect, pieces: [piece]))
            }
        }
        for i in rows.indices { rows[i].pieces.sort { $0.rect.minX < $1.rect.minX } }
        return rows.sorted { $0.rect.midY > $1.rect.midY }
    }

    static func blocks(from rows: [TextRow], maxHeight: CGFloat) -> [TextBlock] {
        var blocks: [TextBlock] = []
        for row in rows {
            let index = blocks.lastIndex { block in
                guard let last = block.rows.last else { return false }
                let gap = block.rect.minY - row.rect.maxY
                let ratio = row.height / last.height
                return gap > -0.3 * row.height && gap < 0.9 * row.height
                    && row.rect.minX < block.rect.maxX && row.rect.maxX > block.rect.minX
                    && ratio > 0.55 && ratio < 1.8
                    && block.rect.union(row.rect).height <= maxHeight
            }
            if let index {
                blocks[index].rect = blocks[index].rect.union(row.rect)
                blocks[index].rows.append(row)
            } else {
                blocks.append(TextBlock(rect: row.rect, rows: [row]))
            }
        }
        return blocks
    }

    /// Lines are kept as lines unless they are clearly one sentence wrapped
    /// across rows. A list (sidebar items, menus, bullets) keeps every row on
    /// its own line, so the translator never fuses separate items into one
    /// nonsense sentence. Rows of a paragraph fill the width; a row that
    /// stops short — or ends a sentence — ends its line.
    private static let connectors: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "for", "and", "or",
        "with", "by", "from", "at", "as", "is", "are", "was", "were", "be", "your", "our", "my", "this", "that"]

    static func text(of rows: [TextRow]) -> String {
        guard let first = rows.first else { return "" }
        let lines = rows.map { $0.pieces.map(\.text).joined(separator: " ") }
        let right = rows.map(\.rect.maxX).max() ?? first.rect.maxX
        /// Room left at the end of a row, in multiples of the row height.
        func slack(_ row: TextRow) -> CGFloat { (right - row.rect.maxX) / max(row.height, 1) }
        // A paragraph: most rows (except the last) run close to the right edge.
        let inner = rows.dropLast()
        let fullRows = inner.filter { slack($0) < 2.5 }.count
        let isParagraph = !inner.isEmpty && fullRows * 2 > inner.count

        var out = lines[0]
        for i in 1..<max(rows.count, 1) where i < rows.count {
            let previous = rows[i - 1], row = rows[i]
            let gap = previous.rect.minY - row.rect.maxY
            let prevLine = lines[i - 1], line = lines[i]
            let endsSentence = prevLine.last.map { ".!?:;。！？：".contains($0) } ?? false
            let startsItem = line.first.map { "•·-–—*▪●○◦".contains($0) || $0.isNumber } ?? false
            // Wrapped English rarely starts a row with a capital unless the row
            // above ends mid-phrase; list items almost always do.
            let lastWord = prevLine.split(separator: " ").last.map { $0.lowercased() } ?? ""
            let prevEndsLatin = prevLine.last.map { $0.isASCII && $0.isLetter } ?? false
            let startsCapital = prevEndsLatin && (line.first?.isUppercase ?? false) && !Self.connectors.contains(lastWord)
                && !(prevLine.last.map { ",-–(".contains($0) } ?? false)
            let wraps = isParagraph && gap < 0.9 * row.height && slack(previous) < 2.5
                && !endsSentence && !startsItem && !startsCapital
            if !wraps {
                out += gap >= 0.9 * row.height ? "\n\n" : "\n"
            } else if let last = out.last, last != "-", !(last.isThaiOrCJK && (line.first?.isThaiOrCJK ?? false)) {
                out += " "
            }
            out += line
        }
        return out
    }
}

extension Character {
    var isThaiOrCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0E7F, 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
