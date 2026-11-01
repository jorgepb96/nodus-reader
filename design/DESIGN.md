# Nodus Reader — Interface Design

The approved interface direction for Nodus Reader. Build the SwiftUI app from this document.

## What is in `design/`

| Path | Contents | Use it for |
|---|---|---|
| `design/DESIGN.md` | This document: tokens, brand marks, the screen-by-screen spec and behaviors | The source of truth |
| `design/screens/*.png` | One @2x render per screen | Visual comparison: what the result should look like |
| `design/preview/*.html` | The same screens as standalone HTML; they open in any browser | Exact values: sizes, colors, spacing and copy are in the inline styles |
| `design/mockups/*.dc.html` + `canvas.json` | Original sources of the design canvas (template syntax with `{{…}}`, `<sc-for>`, `<sc-if>`; not directly runnable) | Archive. The canvas layout. Regenerating `preview/` and `screens/` |
| `design/icon/` | `ReaderMark.svg` (the mark alone) and `AppIcon-Dark`, `AppIcon-Light`, `AppIcon-Tinted` (1024 px, full-bleed, `.svg` and `.png`) | The app icon asset catalog |
| `design/tools/render-mockups.js` | Regenerates `preview/` and `screens/` from `mockups/` (Node + Playwright): `node design/tools/render-mockups.js design/mockups design/preview design/screens` | Keeping the renders in sync after a design change |
| `design/PROMPT.md` | The full implementation brief that refers to this folder | Starting or resuming a Claude Code session |

Screen file names are the same in `screens/`, `preview/` and `mockups/` (for example `iPhone-Library`). `Main` is the brand and system board. `Icon-Options` holds the icon directions; C is chosen.

Live canvas: https://claude.ai/artifact/VbhU4jNsgTdVH5zNBo3XMx (private to the owner). The folder is a snapshot of the canvas. When they differ, the folder is what to build.

**Use native controls.** Use real SwiftUI components (`TabView`, `NavigationSplitView`, `.searchable`, `Menu`, `Toggle`, `Picker`, `.inspector`, `.contextMenu`) and match the mockups' look through tokens and modifiers. Never hand-draw the system tab bar, status bar, window chrome or traffic lights. On iOS 26 the floating tab bar and the separate search button come from `TabView` with a `Tab(role: .search)`.

**Sample content is illustrative.** The book titles, counts, dates, the Mendel table and the storage sizes are placeholders. The app shows real library data. `[size]` and `[Voice name]` are still unknown.

---

## 1. Design tokens

Put these in the `DesignSystem` module as `Color` and `ShapeStyle` tokens. Do not scatter hex values through the views.

### App chrome (dark)

| Token | Value | Use |
|---|---|---|
| `ink` | `#0E0D14` | App background |
| `panel` | `#17151F` | Cards, grouped rows, search fields |
| `panelRaised` | `#1C1928` / `rgba(32,29,44,0.94)` | Mini player, floating bars, menus |
| `sidebar` | `#13111A` (iPad), `#17151F` (Mac) | Sidebars |
| `line` | `white @ 8%` | Hairlines and card borders |
| `text` | `#F2EFE8` | Primary text |
| `muted` | `#A8A3B5` | Secondary text |
| `accent` | `#C4B5FD` (lavender) | Selection, links, progress, primary buttons |
| `onAccent` | `#16121F` | Text and icons on an accent fill |
| `violet` | `#7C3AED` / `#6D28D9` | Accent on light reader themes |
| `destructive` | `#FF8F87` | Destructive menu items on dark |

The app chrome also needs a light variant for the `App` theme setting. Derive it from the Light reader theme: paper background and violet accent.

### Reader themes

| Theme | Background | Text | Muted | Narrated sentence | User highlight |
|---|---|---|---|---|---|
| System | follows Light / Dark | | | | |
| Light | `#FBF8F1` | `#1D1B22` | `#6B6577` | `#E7DEFD` | `#FBEFC0` |
| Sepia | `#F2E7D3` | `#3B2F20` | `#6F5E46` | `#E2D3F2` | `#F3DE9C` |
| Dark | `#1C1A24` | `#E6E1D6` | `#A39DAF` | violet @ 28% | gold @ 28% |
| OLED Black | `#000000` | `#CFCAC0` | `#9A95A3` | violet @ 30% | gold @ 30% |
| High Contrast | `#FFFFFF` | `#000000` | — | must still pass 7:1 | |

Highlight palette for annotations: yellow, green (`#CFE6C2`, underline `#6FA35A`), blue, pink and purple. Keep the narration highlight visually distinct from user highlights.

### Typography

- **Display and reading:** the system serif (`.serif` design, which is New York). The mockups use Newsreader as a web stand-in.
  - Large titles: 36 pt, tracking −0.9.
  - iPad: 44 pt.
  - Section headers: 22 pt.
  - Reading text default: 18–19 pt, line height ≈ 1.55–1.6.
- **Interface:** SF Pro (system).
  - Body: 15 pt.
  - Secondary: 12–13 pt.
- **Eyebrow labels:** 10–11 pt, semibold, tracking about 2, uppercase, `muted`. Examples: `CONTINUE · FROM YOUR MAC`, `ENGINES`.
- Every size maps to a Dynamic Type style. Nothing is fixed-size.

### Shape and spacing

- Corner radii:
  - Cards and grouped lists: 20–22.
  - Small cards: 16.
  - Chips and buttons: capsule.
  - Mini player: capsule, 58 pt high.
  - Covers: 3 pt at the spine, 7–8 pt on the outer edge.
- Screen side margin on iPhone is 20. Gaps between stacked sections are 14–22.
- Touch targets are at least 44 × 44. Icon-only buttons are 44 pt circles on `panel` with a hairline border.
- Covers get a soft drop shadow (y 8–10, blur 20–24, black @ 40%).

### Motion

- Use discrete, native transitions: `matchedGeometryEffect` from a cover to the reader, and sheet presentation for the player.
- Respect Reduce Motion: use a cross-fade and no page curl.

---

## 2. Brand marks

### Wordmark: `NODUS / READER`

Use it in the toolbar `.principal` slot of every navigation screen: Home, Library, Collection, Settings, Voices, Models and Sync on iPhone, plus the iPad and Mac sidebars. Leave it out of the reader, the player and the PDF reader.

Layout: `NodusMark` (19 × 21), then `NODUS` (11 pt semibold, tracking 3, `accent`), then `/ READER` (10 pt medium, tracking 2, `muted`). Combine them into one accessibility element with the label "Nodus Reader". The pattern matches `BrandToolbar` in Nodus Drift.

### `NodusMark` (ecosystem N, violet)

Reuse it **verbatim** from `nodus-drift-mobile/ios/NodusDrift/NodusMark.swift` (SPDX: MIT). Keep its license header and add the attribution to `THIRD_PARTY_NOTICES.md`. Do not modify the Nodus Drift repo.

### `ReaderMark` (app icon: the Nodus N over open pages)

**Chosen direction: C · Pages.** The original `NodusMark` keeps its exact geometry, gradient and node colors. It is scaled to 0.72 and floats just above two page curves that read as an open book seen from the front. The bottom nodes almost touch the upper page line.

Everything is drawn on a 64-unit grid with the content centered at y = 34, so the drawing frame is `0 2 64 64`. Directions A and B stay on the canvas for reference only.

```swift
// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Nodus Reader app mark: the original Nodus N (NodusMark geometry) over two open-book page curves.
struct ReaderMark: View {
    var pageColor: Color = Color(hex: 0xA78BFA)   // #8B5CF6 on light backgrounds

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 64
            let ox = (size.width - 64 * s) / 2
            let oy = (size.height - 64 * s) / 2 - 2 * s          // frame 0 2 64 64
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

            // Open-book pages: two curves meeting at the gutter (x = 32)
            func pages(_ y: CGFloat) -> Path {
                var path = Path()
                path.move(to: p(6, y))
                path.addCurve(to: p(32, y + 3), control1: p(16, y - 4), control2: p(26, y - 3))
                path.addCurve(to: p(58, y), control1: p(38, y - 3), control2: p(48, y - 4))
                return path
            }
            context.stroke(pages(53), with: .color(pageColor.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round, lineJoin: .round))
            context.stroke(pages(47), with: .color(pageColor),
                           style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round, lineJoin: .round))

            // NodusMark geometry, scaled 0.72 about (32,32) and centered at (32,27)
            func n(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(32 + (x - 32) * 0.72, 27 + (y - 32) * 0.72) }
            var nPath = Path()
            nPath.move(to: n(18, 48)); nPath.addLine(to: n(18, 16))
            nPath.addLine(to: n(46, 48)); nPath.addLine(to: n(46, 16))
            context.stroke(nPath, with: .linearGradient(Gradient(stops: [
                .init(color: Color(hex: 0xDDD6FE), location: 0),
                .init(color: Color(hex: 0xA78BFA), location: 0.45),
                .init(color: Color(hex: 0x7C3AED), location: 1)
            ]), startPoint: n(14, 10), endPoint: n(50, 54)),
                style: StrokeStyle(lineWidth: 6.5 * 0.72 * s, lineCap: .round, lineJoin: .round))
            let r = 6.5 * 0.72 * s
            for (x, y, hex) in [(18, 16, 0xDDD6FE), (18, 48, 0xA78BFA), (46, 48, 0x8B5CF6), (46, 16, 0x7C3AED)] as [(CGFloat, CGFloat, UInt32)] {
                let c = n(x, y)
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: hex)))
            }
        }
        .accessibilityHidden(true)
    }
}
```

SVG equivalent for the icon export script (`viewBox="0 2 64 64"`):

```svg
<path d="M6 53C16 49 26 50 32 56C38 50 48 49 58 53" fill="none" stroke="#A78BFA" stroke-opacity=".45" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M6 47C16 43 26 44 32 50C38 44 48 43 58 47" fill="none" stroke="#A78BFA" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>
<g transform="translate(32 27) scale(0.72) translate(-32 -32)"><!-- NodusMark: M18 48V16L46 48V16 + 4 nodes --></g>
```

App icon variants, as an icon composer or asset catalog with dark, light and tinted appearances:

- **Dark:** background a vertical gradient `#1D1929` → `#110F18`, hairline `#C4B5FD @ 18%`, pages `#A78BFA`.
- **Light:** background `#FFFFFF` → `#F1ECFD`, pages `#8B5CF6`.
- **Tinted:** a monochrome layer; the system tints it.

The mark should take up about 80% of the icon. Check it at 29 pt (Spotlight and Settings). The 1024 px masters are ready in `design/icon/` (`AppIcon-Dark`, `AppIcon-Light`, `AppIcon-Tinted`, as `.svg` and `.png`). Use them for the asset catalog, or regenerate them with a script following `nodus-drift-mobile/scripts/render_icon.swift`.

---

## 3. Navigation and screens

### iPhone: `TabView`

The tabs are **Home**, **Library**, **Collections** and **Settings**, plus a search tab (`role: .search`). The mini player sits above the tab bar:

- iOS 26: `tabViewBottomAccessory`.
- iOS 18: `safeAreaInset(edge: .bottom)`.

Tapping the mini player opens the full player as a sheet.

| Mockup | Screen | Key points |
|---|---|---|
| `iPhone-ReadingNow.dc.html` | **Home** | Editorial title "Reading now". A continue card shows the cover, an eyebrow with the source device ("CONTINUE · FROM YOUR MAC", from synced progress), title, author, chapter, progress bar, a **Read** button (filled) and a **Listen** button (outlined). Below it, an "Up next" horizontal shelf. |
| `iPhone-Library.dc.html` | **Library** | Search across titles, authors, text and notes. Filter chips: All, In progress, To read, Finished, Favorites, PDF. Sort menu. A 3-column cover grid with a thin progress bar under each cover, a `PDF` badge, and an iCloud "not downloaded" badge. Toolbar: Select, grid/list toggle, Import (+). |
| `iPhone-Collections.dc.html` | **Collection** | Breadcrumb eyebrow (`LIBRARY / HISTORY`), title and counts. Subcollection rows lead to the next level, with unlimited depth via a `NavigationStack` path. Actions: "New subcollection" and "Manual order". Book rows show multi-membership ("Also in Travel Literature") and download state. |
| `iPhone-Reader.dc.html` | **Reader (Read & Listen)** | Minimal top bar: back, title and chapter, contents, Aa. Chapter opener. The narrated sentence is highlighted. User highlights carry a note marker. Page and percent are centered at the bottom. A floating narration capsule holds previous sentence, play/pause, next sentence, the mode label with voice and speed (opens the player), and a sleep timer. Supports the theme switch (Light, Sepia, Dark, OLED). |
| `iPhone-NowPlaying.dc.html` | **Player** (sheet) | Large cover, title, and a 3-line live context of the narration with the current sentence emphasized. A scrubber shows sentence and chapter position. Transport: previous chapter, previous sentence, play (76 pt), next sentence, next chapter. A 4-up grid: Speed, Voice (with engine), Sleep timer, Mode toggle. Footer: "Voice generated on this iPhone". |
| `iPhone-Settings.dc.html` | **Settings** | A **Theme** section with an `App` / `Reader` segmented control (separate app and reader appearance), a 3 × 2 theme picker (System, Light, Dark, OLED Black, Sepia, High Contrast) as radio tiles with an "Aa" preview, and "Create custom theme". **General:** iCloud Sync, Voices & Models, Reading & Typography, Privacy, About. |
| `iPhone-Voices.dc.html` | **Voices** | A `Models` / `Voices` segmented control (Models first, so new users find the downloads), `.searchable` voice search, and filter menus for **Model** (All, Kokoro 82M, Phonon 31M, Phonon 40M Multilingual, Phonon 40M Spanish), **Language** and **Gender** (All, Female, Male: the publisher's label; voices without one, such as Phonon's character voices, appear only under All), plus Clear. When the chips do not fit the width they scroll sideways. Each row has play sample (or download if not installed), name, "BOOK DEFAULT" badge, engine and language, and a favorite star. |
| `iPhone-Models.dc.html` | **Models** | One engine list with every model, gated ones included (Kokoro 82M, Phonon 31M, Phonon 40M Multilingual, Phonon 40M Spanish), with installed, downloading (progress + pause) and available (Get) states and license info. Get on a gated model first shows a notice that it needs a Hugging Face sign-in and Gradium's accepted conditions, with Sign in (or Download when signed in), Show the guide and Cancel. Below the list: "Install from file…", the Hugging Face account (sign-in/sign-out or a token, stored in Keychain) and local storage used. **Mac only:** the list adds Ming 3.0 0.5B, and once it is installed a **Ming voices** card follows the models: each cloned voice (name, language · length · Recorded / From a file / Included · CC0) with play and delete, then *Record a voice…* and *Add audio file…*, which open a grouped-form sheet with Name, Language, the paragraph to read or the file picker, Listen, an editable *Exact words spoken* field (suggested by on-device recognition) and a consent switch; Save Voice stays disabled until the clip lasts 3–30 s, the words are long enough and consent is given. |
| `iPhone-Sync.dc.html` | **iCloud Sync** | The "Sync with iCloud" toggle, status card ("Up to date", last successful sync, offline-queue note), downloaded books (count), "Download all books", a storage bar (Books / Voices / Caches), a "stays on this device" note and troubleshooting. Never imply sync is instant. |

### iPad: `NavigationSplitView` (sidebar + content)

| Mockup | Screen | Key points |
|---|---|---|
| `iPad-Library.dc.html` | **Library** | Sidebar: wordmark, search, smart lists (Home, All Books, Favorites, To Read, Finished, Inbox), a **Collections** outline tree (disclosure, drag-to-reorder, + new), and a sync status footer. Content: breadcrumb, 44 pt title, subcollection pills, filter chips and a 5-column grid. The context menu must keep **Remove Download** ("Stays in iCloud and on other devices") separate from **Delete from Library…** (destructive, "Removes it from all your devices", confirmation required). Floating mini player at the bottom. |
| `iPad-PDFReflow.dc.html` | **Intelligent PDF** | Toolbar with an **Original PDF** / **Intelligent Reading** segmented control. Reflowed column of about 600 pt. Reconstructed tables as native tables with a "Reconstructed · compare with page" link; regions that can't be rebuilt stay as images. A right **source panel** shows the original page with region overlays (narrating, text, table, not narrated) and toggles for "Show images" and "Skip headers & page numbers". |

### Mac: `NavigationSplitView` + `.inspector`

| Mockup | Screen | Key points |
|---|---|---|
| `Mac-Library.dc.html` | **Library window** | Inset sidebar with the same tree. Toolbar: title and count, grid/list toggle, search field, Import. **List view** as a `Table` with Title (mini cover), Author, Format, Progress, Collections, Last opened and iCloud state, all sortable. The inspector edits metadata (title, author, language, published, collections chips), plus status, per-book voice and file state. A bottom player bar shows keyboard hints (Space = play/pause). |
| `Mac-Reader.dc.html` | **Reader window** | Sidebar with Contents / Bookmarks / Notes tabs and a note preview. Toolbar: Read / Listen / Read & Listen segmented control, highlight color, Aa, search, bookmark. Two-page spread with a narration highlight and a user highlight. Floating narration capsule. Add menu bar commands and shortcuts for everything in the toolbar. |

---

## 4. Behaviors the design depends on

- **Home "Continue" eyebrow** reads the device name from the last synced reading position. Hide it when the position came from this device.
- **Download states** appear everywhere a book appears: downloaded, in iCloud only (cloud badge) and downloading (progress).
- **Mode** (Read / Listen / Read & Listen) is per book, and switchable from the reader, the player and the Mac toolbar.
- **Narration highlight** is sentence-level by default. Word-level highlighting only when alignment is reliable.
- **Voices and models** never sync. The per-book voice preference does sync, but falls back gracefully when that voice isn't installed on the device: show the book default with an "Install voice" affordance.
- **Accessibility:** every icon-only button has a label. Theme tiles are radio buttons. Switches use `Toggle`. Text contrast is at least 4.5:1, including the muted grey.

## 5. Open decisions

- App icon: direction C (Pages) is final.
- Phonon model sizes and voice names are unknown until the models are verified.
