//
// Net Report - a macOS application for running a local amateur radio net.
// Copyright (C) 2026  kidvelvet (W7SKW)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import CoreGraphics
import CoreText

/// Renders the net report PDFs: the check-in table and the hand-drawn ARRL
/// radiogram / NTS form, each as its own document. Faithful port of
/// `create_pdf_report` and `draw_radiogram_form` from `ham_lookup.py`, split so
/// the check-in list and the radiogram are saved as separate files.
///
/// Both ReportLab's canvas and Core Graphics' PDF context use a bottom-left
/// origin with y increasing upward, so the original drawing math carries over
/// almost verbatim. Text is drawn with Core Text so we can place glyphs by
/// baseline, matching ReportLab's `drawString` / `drawCentredString`.
public enum RadiogramPDF {

    // US Letter, 72 dpi points.
    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 36

    public enum PDFError: Error { case contextCreationFailed }

    /// PDF of the check-in table only (title + generation stamp + table).
    public static func writeCheckinList(
        to url: URL,
        tableRows: [[String]],
        generatedAt: Date = Date()
    ) throws {
        try render(to: url) { ctx in
            drawString("Ham Radio Check-in Report", x: margin, y: pageHeight - margin,
                       font: bold(16), in: ctx)
            drawString("Generated: \(generationStamp(generatedAt))",
                       x: margin, y: pageHeight - margin - 14, font: regular(9), in: ctx)

            // Call Sign, Name, Nickname, City, County, Notes — sums to the
            // usable width (612 - 2×36 = 540pt).
            let colWidths: [CGFloat] = [70, 110, 70, 80, 80, 130]
            let tableTop = pageHeight - margin - 35
            _ = drawTable(tableRows, colWidths: colWidths,
                          originX: margin, topY: tableTop, in: ctx)
        }
    }

    /// PDF of the ARRL radiogram / NTS form only.
    public static func writeNetReport(
        to url: URL,
        nts: NTSForm,
        generatedAt: Date = Date()
    ) throws {
        try render(to: url) { ctx in
            let usableWidth = pageWidth - (2 * margin)
            drawString("Net Report — Generated: \(generationStamp(generatedAt))",
                       x: margin, y: pageHeight - margin, font: regular(9), in: ctx)
            let formTop = pageHeight - margin - 30
            drawRadiogramForm(startX: margin, startY: formTop, width: usableWidth, nts: nts, in: ctx)
        }
    }

    /// Shared single-page PDF context setup/teardown.
    private static func render(to url: URL, _ body: (CGContext) -> Void) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        ctx.textMatrix = .identity
        ctx.setFillColor(black)
        ctx.setStrokeColor(black)
        body(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Built once — configured formatters are reusable and costly to create.
    private static let stampFormatter: DateFormatter = {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return stamp
    }()

    private static func generationStamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    // MARK: - Table

    /// Draws the table top-down from `topY` and returns its total height.
    private static func drawTable(
        _ rows: [[String]],
        colWidths: [CGFloat],
        originX: CGFloat,
        topY: CGFloat,
        in ctx: CGContext
    ) -> CGFloat {
        let fontSize: CGFloat = 9
        let padding: CGFloat = 4
        let lineHeight: CGFloat = 12
        let cellFont = regular(fontSize)
        let headerFont = bold(fontSize)
        let ascent = CTFontGetAscent(cellFont)

        // Pre-wrap every cell and compute each row's height.
        var wrapped: [[[String]]] = []
        var rowHeights: [CGFloat] = []
        for row in rows {
            var wrappedRow: [[String]] = []
            var maxLines = 1
            for (col, cell) in row.enumerated() {
                // Defensive: a row longer than the column spec would otherwise
                // index out of bounds and crash the report.
                guard col < colWidths.count else { break }
                let width = colWidths[col] - (2 * padding)
                let lines = wrap(cell, font: cellFont, maxWidth: width)
                wrappedRow.append(lines)
                maxLines = max(maxLines, lines.count)
            }
            wrapped.append(wrappedRow)
            rowHeights.append(CGFloat(maxLines) * lineHeight + (2 * padding))
        }

        ctx.setLineWidth(0.6)
        var y = topY
        for (rowIndex, wrappedRow) in wrapped.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            let rowTop = y
            let rowBottom = y - rowHeight

            var x = originX
            for (col, lines) in wrappedRow.enumerated() {
                guard col < colWidths.count else { break }
                let cellWidth = colWidths[col]

                // Header shading.
                if rowIndex == 0 {
                    ctx.setFillColor(lightGrey)
                    ctx.fill(CGRect(x: x, y: rowBottom, width: cellWidth, height: rowHeight))
                    ctx.setFillColor(black)
                }
                // Cell border.
                ctx.stroke(CGRect(x: x, y: rowBottom, width: cellWidth, height: rowHeight))

                // Cell text, top-aligned.
                let font = rowIndex == 0 ? headerFont : cellFont
                for (i, text) in lines.enumerated() {
                    let baseline = rowTop - padding - ascent - (CGFloat(i) * lineHeight)
                    drawString(text, x: x + padding, y: baseline, font: font, in: ctx)
                }
                x += cellWidth
            }
            y = rowBottom
        }
        return topY - y
    }

    // MARK: - Radiogram form (port of draw_radiogram_form)

    private static func drawRadiogramForm(
        startX: CGFloat,
        startY: CGFloat,
        width: CGFloat,
        nts: NTSForm,
        in ctx: CGContext
    ) {
        ctx.setStrokeColor(black)
        ctx.setFillColor(black)
        ctx.setLineWidth(1)

        var y = startY
        drawCentred("ARRL RADIOGRAM", centerX: startX + (width / 2), y: y, font: bold(20), in: ctx)
        y -= 24
        drawCentred("the national association for Amateur Radio",
                    centerX: startX + (width / 2), y: y, font: regular(9), in: ctx)

        // Top row of labelled cells.
        y -= 20
        let topRowHeight: CGFloat = 38
        let topCols: [(String, CGFloat, String)] = [
            ("NUMBER", 0.10, nts.messageNumber),
            ("PRECEDENCE", 0.12, nts.precedence),
            ("HX", 0.05, nts.handling),
            ("STATION OF ORIGIN", 0.17, nts.fromCall),
            ("CHECK", 0.08, nts.check),
            ("PLACE OF ORIGIN", 0.22, nts.placeOrigin),
            ("TIME FILED", 0.13, nts.timeFiled),
            ("DATE", 0.13, nts.dateFiled),
        ]
        var x = startX
        // Hoisted out of the loop: one font each instead of one per column.
        let labelFont = regular(8)
        let valueFont = bold(9)
        ctx.stroke(CGRect(x: startX, y: y - topRowHeight, width: width, height: topRowHeight))
        for (title, ratio, value) in topCols {
            let colW = width * ratio
            strokeLine(x1: x, y1: y - topRowHeight, x2: x, y2: y, in: ctx)
            drawString(title, x: x + 3, y: y - 11, font: labelFont, in: ctx)
            drawString(value, x: x + 3, y: y - 26, font: valueFont, in: ctx)
            x += colW
        }
        strokeLine(x1: startX + width, y1: y - topRowHeight, x2: startX + width, y2: y, in: ctx)

        // TO / received-at boxes.
        y -= topRowHeight + 10
        let toHeight: CGFloat = 52
        let leftW = width * 0.55
        let rightW = width - leftW
        ctx.stroke(CGRect(x: startX, y: y - toHeight, width: leftW, height: toHeight))
        ctx.stroke(CGRect(x: startX + leftW, y: y - toHeight, width: rightW, height: toHeight))
        drawString("TO", x: startX + 4, y: y - 13, font: regular(9), in: ctx)
        drawString(nts.toName, x: startX + 40, y: y - 13, font: bold(10), in: ctx)
        drawString(nts.toStreet, x: startX + 40, y: y - 28, font: regular(8), in: ctx)
        drawString(nts.toCityState, x: startX + 40, y: y - 42, font: regular(8), in: ctx)
        drawString("THIS RADIO MESSAGE WAS RECEIVED AT", x: startX + leftW + 4, y: y - 13, font: regular(8), in: ctx)
        drawString("AMATEUR STATION", x: startX + leftW + 4, y: y - 28, font: regular(8), in: ctx)
        drawString("PHONE", x: startX + leftW + 145, y: y - 28, font: regular(8), in: ctx)
        drawString("NAME", x: startX + leftW + 4, y: y - 42, font: regular(8), in: ctx)
        drawString("E-MAIL", x: startX + leftW + 145, y: y - 42, font: regular(8), in: ctx)

        // Message body: word slots across fixed underlines.
        let messageLines = 5
        let slotsPerLine = 5
        let lineGap: CGFloat = 20
        y -= toHeight + lineGap
        let slotGap: CGFloat = 14
        let slotW = (width - (slotGap * CGFloat(slotsPerLine - 1))) / CGFloat(slotsPerLine)

        var lineWords: [[String]] = [
            nts.line1.split(separator: " ").map(String.init),
            nts.line2.split(separator: " ").map(String.init),
        ]
        while lineWords.count < messageLines { lineWords.append([]) }

        let slotFont = regular(9)   // hoisted: 25 slots share one font
        for lineIndex in 0..<messageLines {
            let underlineY = y - (CGFloat(lineIndex) * lineGap)
            let words = lineWords[lineIndex].prefix(slotsPerLine)
            for slotIndex in 0..<slotsPerLine {
                let slotX = startX + (CGFloat(slotIndex) * (slotW + slotGap))
                strokeLine(x1: slotX, y1: underlineY, x2: slotX + slotW, y2: underlineY, in: ctx)
                if slotIndex < words.count {
                    drawCentred(words[words.startIndex + slotIndex],
                                centerX: slotX + (slotW / 2),
                                y: underlineY + 4, font: slotFont, in: ctx)
                }
            }
        }

        // Footer: FROM / TO.
        y -= (CGFloat(messageLines) * lineGap) + 8
        let footerH: CGFloat = 26
        ctx.stroke(CGRect(x: startX, y: y - footerH, width: width, height: footerH))
        strokeLine(x1: startX + (width * 0.5), y1: y - footerH, x2: startX + (width * 0.5), y2: y, in: ctx)
        drawString("FROM: \(nts.fromCall)", x: startX + 6, y: y - 15, font: regular(9), in: ctx)
        drawString("TO: \(nts.toStation)", x: startX + (width * 0.5) + 6, y: y - 15, font: regular(9), in: ctx)
    }

    // MARK: - Text + drawing helpers

    private static let black = CGColor(gray: 0, alpha: 1)
    private static let lightGrey = CGColor(gray: 0.827, alpha: 1)

    // Deliberately not memoised in a static dictionary: these are callable from
    // any thread, and Core Text already caches font instances internally, so a
    // hand-rolled cache would add a data race for no real gain.
    static func regular(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
    private static func bold(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    // Core Text attribute keys (this target doesn't link AppKit, so the
    // NSAttributedString.Key.font convenience isn't available). Built once —
    // only the font varies per call.
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let useContextColorKey =
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    /// Width of `text` in `font`. Internal so the wrapping equivalence test can
    /// measure exactly the way the renderer does.
    static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(makeLine(text, font: font), nil, nil, nil))
    }

    private static func makeLine(_ text: String, font: CTFont) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            fontKey: font,
            useContextColorKey: true,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attrs)
        )
    }

    /// Draw text with its left edge at `x` and baseline at `y` (≈ drawString).
    private static func drawString(_ text: String, x: CGFloat, y: CGFloat, font: CTFont, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let line = makeLine(text, font: font)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    /// Draw text centred horizontally on `centerX` with baseline at `y`.
    private static func drawCentred(_ text: String, centerX: CGFloat, y: CGFloat, font: CTFont, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let line = makeLine(text, font: font)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: centerX - (width / 2), y: y)
        CTLineDraw(line, ctx)
    }

    private static func strokeLine(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, in ctx: CGContext) {
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
        ctx.strokePath()
    }

    /// Greedy word-wrap to `maxWidth`, measuring with Core Text.
    static func wrap(_ text: String, font: CTFont, maxWidth: CGFloat) -> [String] {
        guard !text.isEmpty else { return [""] }
        // The word-split below discards whitespace, so an all-blank cell has
        // always produced a single empty line. Preserve that exactly.
        if text.allSatisfy(\.isWhitespace) { return [""] }

        func width(_ s: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(makeLine(s, font: font), nil, nil, nil))
        }

        // Fast path: most cells — call sign, city, county, state, short notes —
        // fit on one line, and if the whole string fits then the greedy loop
        // below would put it all on one line anyway. That replaces one
        // measurement per word (plus the word-splitting allocations) with a
        // single measurement.
        //
        // It only holds when rejoining the words would reproduce the string
        // exactly. Splitting on spaces and rejoining also collapses runs of
        // spaces and trims the edges, so text with irregular spacing has to go
        // the long way round or the cell would render differently.
        let spacingIsRegular = !text.hasPrefix(" ") && !text.hasSuffix(" ")
            && !text.contains("  ")
        if spacingIsRegular, width(text) <= maxWidth { return [text] }

        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [""] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if width(candidate) <= maxWidth || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }
}
