// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Nodus Reader app mark: the original Nodus N over two open-book page curves.
/// Direction C (Pages) from design/DESIGN.md.
public struct ReaderMark: View {
    public var pageColor: Color

    public init(pageColor: Color = Color(hex: 0xA78BFA)) {
        self.pageColor = pageColor
    }

    public var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 64
            let ox = (size.width - 64 * s) / 2
            let oy = (size.height - 64 * s) / 2 - 2 * s
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

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

            func n(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                p(32 + (x - 32) * 0.72, 27 + (y - 32) * 0.72)
            }
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
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .color(Color(hex: hex)))
            }
        }
        .accessibilityHidden(true)
    }
}
