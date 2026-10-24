// SPDX-License-Identifier: MIT
import SwiftUI

/// Original connected N from the Nodus ecosystem mark (64×64 grid).
/// Geometry reused verbatim from `nodus-drift-mobile/ios/NodusDrift/NodusMark.swift`.
/// See THIRD_PARTY_NOTICES.md for attribution.
public struct NodusMark: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 41, size.height / 45)
            let x = (size.width - 41 * scale) / 2 - 11.5 * scale
            let y = (size.height - 45 * scale) / 2 - 9.5 * scale
            func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
                CGPoint(x: x + px * scale, y: y + py * scale)
            }
            var path = Path()
            path.move(to: point(18, 48))
            path.addLine(to: point(18, 16))
            path.addLine(to: point(46, 48))
            path.addLine(to: point(46, 16))
            context.stroke(path, with: .linearGradient(Gradient(stops: [
                .init(color: Color(hex: 0xDDD6FE), location: 0),
                .init(color: Color(hex: 0xA78BFA), location: 0.45),
                .init(color: Color(hex: 0x7C3AED), location: 1)
            ]), startPoint: point(14, 10), endPoint: point(50, 54)),
                style: StrokeStyle(lineWidth: 6.5 * scale, lineCap: .round, lineJoin: .round))
            let nodes: [(CGFloat, CGFloat, UInt32)] = [
                (18, 16, 0xDDD6FE), (18, 48, 0xA78BFA),
                (46, 48, 0x8B5CF6), (46, 16, 0x7C3AED)
            ]
            let radius = 6.5 * scale
            for (px, py, color) in nodes {
                let centre = point(px, py)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2)), with: .color(Color(hex: color)))
            }
        }
        .accessibilityHidden(true)
    }
}
