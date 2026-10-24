// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Body text for the reader. SwiftUI's `Text` cannot justify paragraphs on all
/// platforms, so the reader uses the native text control underneath. On iOS the
/// control also reports which word was tapped so narration can start there.
struct JustifiedText: View {
    enum Weight: String {
        case regular, medium, semibold
    }

    var text: String
    var size: CGFloat
    var weight: Weight = .regular
    var useSerif: Bool = true
    var color: Color
    var lineSpacing: CGFloat
    var justified: Bool = true
    var sentenceHighlight: NSRange?
    var sentenceHighlightColor: Color?
    var wordHighlight: NSRange?
    var wordHighlightColor: Color?
    var onWordTap: ((NSRange) -> Void)?

    #if os(macOS)
    var body: some View {
        MacJustifiedText(
            text: text, size: size, weight: weight, useSerif: useSerif,
            color: NSColor(color), lineSpacing: lineSpacing, justified: justified,
            sentenceHighlight: sentenceHighlight,
            sentenceHighlightColor: sentenceHighlightColor.map { NSColor($0) },
            wordHighlight: wordHighlight,
            wordHighlightColor: wordHighlightColor.map { NSColor($0) }
        )
    }
    #else
    var body: some View {
        IOSJustifiedText(
            text: text, size: size, weight: weight, useSerif: useSerif,
            color: UIColor(color), lineSpacing: lineSpacing, justified: justified,
            sentenceHighlight: sentenceHighlight,
            sentenceHighlightColor: sentenceHighlightColor.map { UIColor($0) },
            wordHighlight: wordHighlight,
            wordHighlightColor: wordHighlightColor.map { UIColor($0) },
            onWordTap: onWordTap
        )
    }
    #endif
}

#if os(macOS)
private struct MacJustifiedText: NSViewRepresentable {
    var text: String
    var size: CGFloat
    var weight: JustifiedText.Weight
    var useSerif: Bool
    var color: NSColor
    var lineSpacing: CGFloat
    var justified: Bool
    var sentenceHighlight: NSRange?
    var sentenceHighlightColor: NSColor?
    var wordHighlight: NSRange?
    var wordHighlightColor: NSColor?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: width, height: ceil(bounds.height) + 2)
    }

    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = justified ? .justified : .natural
        paragraph.lineSpacing = lineSpacing
        paragraph.hyphenationFactor = 1
        paragraph.paragraphSpacing = 10
        var font = NSFont.systemFont(ofSize: size, weight: nsWeight)
        if useSerif, let descriptor = font.fontDescriptor.withDesign(.serif) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let length = (text as NSString).length
        if let sentenceHighlight, let sentenceHighlightColor,
           sentenceHighlight.location >= 0, sentenceHighlight.location + sentenceHighlight.length <= length {
            attributed.addAttribute(.backgroundColor, value: sentenceHighlightColor, range: sentenceHighlight)
        }
        if let wordHighlight, let wordHighlightColor,
           wordHighlight.location >= 0, wordHighlight.location + wordHighlight.length <= length {
            attributed.addAttribute(.backgroundColor, value: wordHighlightColor, range: wordHighlight)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: wordHighlight)
            attributed.addAttribute(.underlineColor, value: wordHighlightColor, range: wordHighlight)
        }
        return attributed
    }

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}
#else
private struct IOSJustifiedText: UIViewRepresentable {
    var text: String
    var size: CGFloat
    var weight: JustifiedText.Weight
    var useSerif: Bool
    var color: UIColor
    var lineSpacing: CGFloat
    var justified: Bool
    var sentenceHighlight: NSRange?
    var sentenceHighlightColor: UIColor?
    var wordHighlight: NSRange?
    var wordHighlightColor: UIColor?
    var onWordTap: ((NSRange) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.contentInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.textView = view
        context.coordinator.onWordTap = onWordTap
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.textView = view
        context.coordinator.onWordTap = onWordTap
        view.attributedText = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height) + 2)
    }

    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = justified ? .justified : .natural
        paragraph.lineSpacing = lineSpacing
        paragraph.hyphenationFactor = 1
        paragraph.paragraphSpacing = 10
        var font = UIFont.systemFont(ofSize: size, weight: uiWeight)
        if useSerif, let descriptor = font.fontDescriptor.withDesign(.serif) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let length = (text as NSString).length
        if let sentenceHighlight, let sentenceHighlightColor,
           sentenceHighlight.location >= 0, sentenceHighlight.location + sentenceHighlight.length <= length {
            attributed.addAttribute(.backgroundColor, value: sentenceHighlightColor, range: sentenceHighlight)
        }
        if let wordHighlight, let wordHighlightColor,
           wordHighlight.location >= 0, wordHighlight.location + wordHighlight.length <= length {
            attributed.addAttribute(.backgroundColor, value: wordHighlightColor, range: wordHighlight)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: wordHighlight)
            attributed.addAttribute(.underlineColor, value: wordHighlightColor, range: wordHighlight)
        }
        return attributed
    }

    private var uiWeight: UIFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    final class Coordinator: NSObject {
        weak var textView: UITextView?
        var onWordTap: ((NSRange) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView, let text = textView.text, !text.isEmpty else { return }
            let point = gesture.location(in: textView)
            guard let position = textView.closestPosition(to: point) else { return }
            let index = textView.offset(from: textView.beginningOfDocument, to: position)
            let nsText = text as NSString
            guard nsText.length > 0 else { return }

            var start = min(max(index, 0), nsText.length)
            var end = start
            let whitespace = CharacterSet.whitespacesAndNewlines
            while start > 0 {
                if let scalar = UnicodeScalar(nsText.character(at: start - 1)), whitespace.contains(scalar) { break }
                start -= 1
            }
            while end < nsText.length {
                if let scalar = UnicodeScalar(nsText.character(at: end)), whitespace.contains(scalar) { break }
                end += 1
            }
            guard end > start else { return }
            onWordTap?(NSRange(location: start, length: end - start))
        }
    }
}
#endif
