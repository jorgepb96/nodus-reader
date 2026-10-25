// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Everything the paginator needs to lay out one page. The values come from the
/// reader theme and the user's typography preferences; the native text stack
/// receives a matching attributed string.
struct ReaderPageStyle: Equatable {
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var margin: CGFloat
    var justified: Bool
    var useSerif: Bool
    var weightIndex: Int
    var text: PlatformColor
    var muted: PlatformColor
    var background: PlatformColor
    var isDark: Bool

    init(theme: ReaderTheme, preferences: ReaderPreferences) {
        self.init(theme: theme, typography: preferences.typography)
    }

    init(theme: ReaderTheme, typography: ReaderTypography) {
        fontSize = typography.baseFontSize
        lineSpacing = typography.lineSpacing
        margin = typography.margin
        justified = typography.justify
        useSerif = typography.useSerif
        weightIndex = typography.weightIndex
        text = PlatformColor(theme.text)
        muted = PlatformColor(theme.muted)
        background = PlatformColor(theme.background)
        isDark = theme.isDark
    }

    var bodyFont: PlatformFont {
        let weight: PlatformFont.Weight
        #if os(macOS)
        weight = switch weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
        #else
        weight = switch weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
        #endif
        let base = PlatformFont.systemFont(ofSize: fontSize, weight: weight)
        guard useSerif, let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return PlatformFont(descriptor: descriptor, size: fontSize) ?? base
    }

    /// Book typesetting: paragraphs follow each other without extra space and
    /// open with a first-line indent.
    var bodyParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = justified ? .justified : .natural
        paragraph.lineSpacing = lineSpacing
        paragraph.hyphenationFactor = 1
        paragraph.paragraphSpacing = 0
        paragraph.firstLineHeadIndent = (fontSize * 1.5).rounded()
        return paragraph
    }

    /// A chapter's first paragraph, headings and the paragraph after a
    /// heading start flush, as in printed books.
    var flushParagraphStyle: NSParagraphStyle {
        let paragraph = (bodyParagraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        return paragraph
    }

    /// Extracted text separates paragraphs with a blank line ("\n\n"). The
    /// second line break is kept, so chapter offsets (annotations, narration,
    /// bookmarks) never move, but drawn with no height.
    private var collapsedBreakAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 0.01
        paragraph.maximumLineHeight = 0.01
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        return [
            .font: PlatformFont.systemFont(ofSize: 0.01),
            .foregroundColor: text,
            .paragraphStyle: paragraph
        ]
    }

    /// Chapter text with book paragraph layout: blank lines between
    /// paragraphs collapsed, first-line indents, flush openings and headings.
    func bodyText(_ text: String) -> NSAttributedString {
        let body = NSMutableAttributedString(string: text, attributes: bodyAttributes)
        let ns = text as NSString
        guard ns.length > 1 else { return body }
        let collapsed = collapsedBreakAttributes
        for index in 1..<ns.length where ns.character(at: index) == 10 && ns.character(at: index - 1) == 10 {
            body.setAttributes(collapsed, range: NSRange(location: index, length: 1))
        }
        let flush = flushParagraphStyle
        var isFirst = true
        var previousWasHeading = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { paragraph, range, _, _ in
            guard let paragraph, !paragraph.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let heading = Self.looksLikeHeading(paragraph)
            if isFirst || heading || previousWasHeading {
                body.addAttribute(.paragraphStyle, value: flush, range: range)
            }
            isFirst = false
            previousWasHeading = heading
        }
        return body
    }

    /// A short line that does not end like a sentence ("Resumen", "PART ONE",
    /// "II") is a heading inside the chapter text.
    static func looksLikeHeading(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80, let last = trimmed.last else { return false }
        return !".,;:!?…\"”’»)—–".contains(last)
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: text,
            .paragraphStyle: bodyParagraphStyle
        ]
    }
}

struct EditorialChapterHeader {
    var eyebrow: String
    var title: String
    var style: ReaderPageStyle

    var string: String {
        "\(eyebrow)\n\(title)\n\n"
    }

    var length: Int {
        (string as NSString).length
    }

    var attributed: NSAttributedString {
        let result = NSMutableAttributedString()
        let eyebrowFont = PlatformFont.systemFont(ofSize: 10, weight: .semibold)
        let eyebrowAttributes: [NSAttributedString.Key: Any] = [
            .font: eyebrowFont,
            .foregroundColor: style.muted,
            .kern: 2.0
        ]
        result.append(NSAttributedString(string: "\(eyebrow)\n", attributes: eyebrowAttributes))

        var titleFont = PlatformFont.systemFont(ofSize: max(26, style.fontSize * 1.65))
        if let descriptor = titleFont.fontDescriptor.withDesign(.serif) {
            titleFont = PlatformFont(descriptor: descriptor, size: max(26, style.fontSize * 1.65)) ?? titleFont
        }
        #if os(macOS)
        let italicDescriptor: NSFontDescriptor? = titleFont.fontDescriptor.withSymbolicTraits(.italic)
        #else
        let italicDescriptor: UIFontDescriptor? = titleFont.fontDescriptor.withSymbolicTraits(.traitItalic)
        #endif
        if let italicDescriptor {
            #if os(macOS)
            if let font = NSFont(descriptor: italicDescriptor, size: titleFont.pointSize) {
                titleFont = font
            }
            #else
            titleFont = UIFont(descriptor: italicDescriptor, size: titleFont.pointSize)
            #endif
        }
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        titleParagraph.paragraphSpacing = 18
        result.append(NSAttributedString(string: "\(title)\n\n", attributes: [
            .font: titleFont,
            .foregroundColor: style.text,
            .paragraphStyle: titleParagraph
        ]))
        return result
    }
}
