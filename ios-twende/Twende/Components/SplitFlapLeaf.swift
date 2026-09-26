import SwiftUI

/// Interpolates the *face switch* as well as the rotation. The outgoing top becomes the incoming
/// bottom exactly edge-on at 90 degrees, rather than switching characters at the animation's start.
struct SplitFlapLeaf: View, Animatable {
    let outgoing: Character
    let incoming: Character
    let size: CGSize
    var angle: CGFloat

    var animatableData: CGFloat {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let isFront = angle < 90
        let lightLoss = 0.24 * sin(Double(min(180, max(0, angle))) * .pi / 180)
        SplitFlapFace(
            character: isFront ? outgoing : incoming,
            size: size, top: isFront, lightLoss: lightLoss
        )
            .rotation3DEffect(
                .degrees(isFront ? -angle : 180 - angle),
                axis: (x: 1, y: 0, z: 0),
                anchor: isFront ? .bottom : .top,
                perspective: 0.20
            )
            .frame(height: size.height, alignment: isFront ? .top : .bottom)
            .allowsHitTesting(false)
    }
}
