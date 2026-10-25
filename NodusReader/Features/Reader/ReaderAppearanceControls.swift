// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import SwiftUI

/// Theme, typography and reading-mode controls shared by the reader's
/// appearance popover (compact), the full appearance sheet and Settings ›
/// Reading & Typography (full). Edits go to the book's own appearance when it
/// has one ("This book only"), otherwise to the global preferences.
struct ReaderAppearanceControls: View {
    enum Style {
        case compact
        case full
    }

    @Environment(ThemeManager.self) private var themeManager
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(LibraryService.self) private var library
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nodusPalette) private var palette

    let target: AppearanceTarget
    var style: Style = .full
    var showsTheme = true
    var onMoreSettings: (() -> Void)?

    private var book: Book? { target.book }
    private var isBookSpecific: Bool { book?.appearance != nil }

    private var typography: ReaderTypography {
        ReaderAppearanceResolver.typography(for: book, preferences: preferences)
    }

    private var selection: String {
        ReaderAppearanceResolver.themeSelection(for: book, themeManager: themeManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 14 : 16) {
            if showsTheme {
                themeSection
            }
            typographySection
            readingModeSection
            if book != nil {
                bookOnlySection
            }
            if style == .full {
                preview
                Button("Reset typography") {
                    updateTypography { $0 = ReaderTypography() }
                }
                .font(.footnote)
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 4)
            }
            if let onMoreSettings {
                Button {
                    onMoreSettings()
                } label: {
                    Label("More settings…", systemImage: "slider.horizontal.3")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Writing

    private func updateTypography(_ change: (inout ReaderTypography) -> Void) {
        var value = typography
        change(&value)
        if let book, var appearance = book.appearance {
            appearance.typography = value
            library.setAppearance(appearance, for: book)
        } else {
            preferences.typography = value
        }
    }

    private func selectTheme(_ newSelection: String) {
        if let book, var appearance = book.appearance {
            appearance.readerThemeSelection = newSelection
            library.setAppearance(appearance, for: book)
        } else if newSelection.hasPrefix("custom:"),
                  let custom = themeManager.customThemes.first(where: { "custom:\($0.id.uuidString)" == newSelection }) {
            themeManager.selectCustomTheme(custom)
        } else if let id = ReaderThemeID(rawValue: newSelection) {
            themeManager.selectReaderTheme(id)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReaderTypography, Value>) -> Binding<Value> {
        Binding(
            get: { typography[keyPath: keyPath] },
            set: { newValue in updateTypography { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: Theme

    @ViewBuilder
    private var themeSection: some View {
        Eyebrow("Theme")
        // Every theme stays visible (no hidden horizontal row), so the
        // selected one is always on screen.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: style == .compact ? 10 : 12),
                                 count: 3),
                  spacing: style == .compact ? 10 : 14) {
            themeTiles(width: nil)
        }
        if style == .full, !isBookSpecific {
            Toggle("Match app theme", isOn: Binding(
                get: { themeManager.readerFollowsApp },
                set: { isOn in
                    if isOn {
                        themeManager.followAppTheme()
                    } else if let id = themeManager.selectedReaderThemeID {
                        themeManager.selectReaderTheme(id)
                    }
                }
            ))
            .font(.footnote)
            .tint(palette.accent)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func themeTiles(width: CGFloat?) -> some View {
        ForEach(ReaderThemeID.allCases) { id in
            let reader = ReaderTheme.resolve(id, colorScheme: colorScheme)
            let app = id.appTheme
            ThemeSwatchTile(
                name: app.title,
                background: id == .system ? nil : reader.background,
                text: id == .system ? nil : reader.text,
                splitSwatch: id == .system ? app.swatch : nil,
                border: id == .highContrast ? .black : nil,
                isSelected: selection == id.rawValue
            ) {
                selectTheme(id.rawValue)
            }
            .frame(width: width)
        }
        ForEach(themeManager.customThemes) { custom in
            ThemeSwatchTile(
                name: custom.name,
                background: Color(hex: custom.backgroundHex),
                text: Color(hex: custom.textHex),
                splitSwatch: nil,
                border: nil,
                isSelected: selection == "custom:\(custom.id.uuidString)"
            ) {
                selectTheme("custom:\(custom.id.uuidString)")
            }
            .frame(width: width)
        }
    }

    // MARK: Typography

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Typography")
            if style == .compact {
                textSizeStepper
            } else {
                labeledSlider("Text size", value: binding(\.fontScale),
                              range: ReaderTypography.fontScaleRange, step: 0.05,
                              display: "\(Int(typography.baseFontSize.rounded())) pt")
            }
            labeledSlider("Line spacing", value: binding(\.lineHeight),
                          range: ReaderTypography.lineHeightRange, step: 0.05,
                          display: String(format: "%.2f", typography.lineHeight))
            labeledSlider("Margins", value: binding(\.margin),
                          range: ReaderTypography.marginRange, step: 2,
                          display: "\(Int(typography.margin.rounded())) pt")
            Picker("Typeface", selection: binding(\.useSerif)) {
                Text("Serif").tag(true)
                Text("Sans").tag(false)
            }
            .pickerStyle(.segmented)
            if style == .full {
                Picker("Weight", selection: binding(\.weightIndex)) {
                    Text("Regular").tag(0)
                    Text("Medium").tag(1)
                    Text("Semibold").tag(2)
                }
                .pickerStyle(.segmented)
            }
            Toggle("Justify text", isOn: binding(\.justify))
                .font(.footnote)
                .tint(palette.accent)
        }
        .padding(style == .compact ? 0 : 14)
        .modifier(CardIfFull(style: style))
    }

    private var textSizeStepper: some View {
        HStack(spacing: 10) {
            sizeButton(smaller: true)
            Text("\(Int(typography.baseFontSize.rounded())) pt")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Text size \(Int(typography.baseFontSize.rounded())) points")
            sizeButton(smaller: false)
        }
    }

    private func sizeButton(smaller: Bool) -> some View {
        let range = ReaderTypography.fontScaleRange
        let next = typography.fontScale + (smaller ? -0.05 : 0.05)
        return Button {
            updateTypography { $0.fontScale = min(max(next, range.lowerBound), range.upperBound) }
        } label: {
            Text("A")
                .font(.system(size: smaller ? 14 : 22, design: .serif))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(palette.panel, in: Capsule())
                .overlay(Capsule().stroke(palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.text)
        .disabled(smaller ? typography.fontScale <= range.lowerBound + 0.001
                          : typography.fontScale >= range.upperBound - 0.001)
        .accessibilityLabel(smaller ? "Smaller text" : "Larger text")
    }

    private func labeledSlider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>,
                               step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundStyle(palette.muted)
                    .monospacedDigit()
            }
            .font(.footnote)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    // MARK: Reading mode

    private var readingModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Reading mode")
            Picker("Reading mode", selection: binding(\.flow)) {
                ForEach(ReadingFlow.allCases) { flow in
                    Text(flow.label)
                        .accessibilityLabel(flow.accessibilityLabel)
                        .tag(flow)
                }
            }
            .pickerStyle(.segmented)
            #if os(iOS)
            if typography.flow == .paged {
                Picker("Page turn", selection: binding(\.pageTurn)) {
                    ForEach(PageTurnStyle.allCases) { turn in
                        Text(turn.label).tag(turn)
                    }
                }
                .pickerStyle(.segmented)
            }
            #endif
            Text(modeFootnote)
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeFootnote: String {
        switch typography.flow {
        case .paged:
            #if os(iOS)
            String(localized: "With Reduce Motion on, Page curl is shown as Slide.")
            #else
            String(localized: "Two facing pages, like an open book.")
            #endif
        case .scrollVertical:
            String(localized: "Scroll freely through the book in one column.")
        case .scrollHorizontal:
            String(localized: "Scroll sideways along a strip of columns.")
        }
    }

    // MARK: This book only

    private var bookOnlySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("This book only", isOn: Binding(
                get: { isBookSpecific },
                set: { isOn in
                    guard let book else { return }
                    library.setAppearance(
                        isOn ? ReaderAppearanceResolver.snapshot(themeManager: themeManager,
                                                                 preferences: preferences) : nil,
                        for: book
                    )
                }
            ))
            .font(.footnote.weight(.semibold))
            .tint(palette.accent)
            Text(isBookSpecific
                 ? "Changes apply only to this book. Turn off to use your general settings again."
                 : "Changes apply to every book. Turn on to keep separate settings for this one.")
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Preview

    private var preview: some View {
        let theme = ReaderAppearanceResolver.theme(for: book, themeManager: themeManager, colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 8) {
            Text("CHAPTER 1")
                .font(.system(size: 9, weight: .semibold))
                .tracking(2)
                .foregroundStyle(theme.muted)
            Text("Loomings")
                .font(.system(size: 22, design: .serif))
                .italic()
                .foregroundStyle(theme.text)
            JustifiedText(
                text: String(localized: "Call me Ishmael. Some years ago—never mind how long precisely—I thought I would sail about a little and see the watery part of the world."),
                size: typography.baseFontSize,
                weight: weight,
                useSerif: typography.useSerif,
                color: theme.text,
                lineSpacing: typography.lineSpacing,
                justified: typography.justify
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview")
    }

    private var weight: JustifiedText.Weight {
        switch typography.weightIndex {
        case 2: .semibold
        case 1: .medium
        default: .regular
        }
    }
}

private struct CardIfFull: ViewModifier {
    let style: ReaderAppearanceControls.Style

    func body(content: Content) -> some View {
        if style == .full {
            content.panelCard(radius: 18)
        } else {
            content
        }
    }
}

/// The reader's "Aa" popover: quick theme, typography and reading-mode
/// changes without leaving the page.
///
/// The reader forces its own light or dark colour scheme on everything it
/// presents, so the popover takes the matching app palette too. Otherwise a
/// dark app panel would show system controls drawn for a light page (dark
/// labels on a dark background).
struct ReaderAppearancePopover: View {
    let book: Book
    let readerIsDark: Bool
    var onMoreSettings: () -> Void

    private var palette: NodusPalette {
        readerIsDark ? .dark : .light
    }

    var body: some View {
        ScrollView {
            ReaderAppearanceControls(target: .book(book), style: .compact, onMoreSettings: onMoreSettings)
                .padding(16)
        }
        .scrollIndicators(.hidden)
        // Tall enough to show every control on iPad and Mac without scrolling;
        // on iPhone the system limits it to the screen and the content scrolls.
        .frame(idealWidth: 340, maxWidth: 380, idealHeight: 860, maxHeight: 920)
        .background(palette.panelRaised)
        .readerPresentation(isDark: readerIsDark)
    }
}
