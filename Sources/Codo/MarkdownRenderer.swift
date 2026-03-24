import AppKit

/// Lightweight Markdown → NSAttributedString renderer for banner notifications.
/// Supported: `# heading`, `**bold**`, `` `inline code` ``, `- list items`
enum MarkdownRenderer {

    static func render(_ markdown: String, maxLines: Int) -> NSAttributedString {
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: Banner.bodyFont,
            .foregroundColor: Banner.bodyColor
        ]
        let boldAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Banner.bodyColor
        ]
        let headingAttrs: [NSAttributedString.Key: Any] = [
            .font: Banner.headingFont,
            .foregroundColor: Banner.titleColor
        ]
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: Banner.codeFont,
            .foregroundColor: Banner.codeColor,
            .backgroundColor: Banner.codeBgColor
        ]
        let listBullet = "  •  "

        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        let effectiveLines = Array(lines.prefix(maxLines))

        for (index, rawLine) in effectiveLines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .init(charactersIn: "\r"))

            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
            }

            // # Heading
            if let headingMatch = line.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                let content = String(line[headingMatch.upperBound...])
                result.append(NSAttributedString(string: content, attributes: headingAttrs))
                continue
            }

            // - List item / * List item
            var lineText = line
            var prefix = ""
            if let listMatch = line.range(of: #"^[\-\*]\s+"#, options: .regularExpression) {
                lineText = String(line[listMatch.upperBound...])
                prefix = listBullet
            }

            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: bodyAttrs))
            }

            // Inline formatting: **bold** and `code`
            result.append(renderInline(lineText, body: bodyAttrs, bold: boldAttrs, code: codeAttrs))
        }

        return result
    }

    // MARK: - Private

    private static func renderInline(
        _ text: String,
        body: [NSAttributedString.Key: Any],
        bold: [NSAttributedString.Key: Any],
        code: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let pattern = #"(\*\*(.+?)\*\*|`([^`]+)`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: text, attributes: body)
        }

        let nsText = text as NSString
        var lastEnd = 0

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            if match.range.location > lastEnd {
                let before = nsText.substring(
                    with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                result.append(NSAttributedString(string: before, attributes: body))
            }

            if match.range(at: 2).location != NSNotFound {
                let content = nsText.substring(with: match.range(at: 2))
                result.append(NSAttributedString(string: content, attributes: bold))
            } else if match.range(at: 3).location != NSNotFound {
                let content = nsText.substring(with: match.range(at: 3))
                result.append(NSAttributedString(string: " \(content) ", attributes: code))
            }

            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsText.length {
            let remaining = nsText.substring(from: lastEnd)
            result.append(NSAttributedString(string: remaining, attributes: body))
        }

        return result
    }
}
