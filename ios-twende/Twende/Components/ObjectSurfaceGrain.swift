import SwiftUI

/// Static, deterministic micro-grain for enamel and painted flap leaves; never a per-frame noise shader.
struct ObjectSurfaceGrain: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<420 {
                let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                let y = CGFloat((index * 137 + 47) % 991) / 991 * size.height
                let rect = CGRect(x: x, y: y, width: 0.6, height: 0.6)
                context.fill(Path(ellipseIn: rect), with: .color(index.isMultiple(of: 2) ? .white.opacity(0.16) : .black.opacity(0.075)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
