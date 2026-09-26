import AVFoundation
import SwiftUI

/// Full-screen flow: live camera scan → review. `onFinish(true)` once details are confirmed.
/// Details only ever come from the scan; there is no typed entry.
struct IDScanFlow: View {
    let onFinish: (Bool) -> Void
    @State private var model: IDScanViewModel = IDScanViewModel()

    var body: some View {
        Group {
            if let result = model.result {
                IdentityReviewView(
                    result: result,
                    faceImage: model.faceImage,
                    onRescan: { model.restart() },
                    onConfirmed: { onFinish(true) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                IDScanView(model: model) {
                    model.stop()
                    onFinish(false)
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4), value: model.result)
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}

/// Camera fills the screen; the app's white sheet sits over the bottom like every other panel.
/// There is no fixed frame to line up with: the scanner finds the card wherever it is and pins
/// gold corner brackets to its real corners. The sheet fills in each detail the moment it's read.
struct IDScanView: View {
    let model: IDScanViewModel
    let onClose: () -> Void

    private static let sheetHeight: CGFloat = 318

    var body: some View {
        Group {
            switch model.phase {
            case .preparing:
                ZStack {
                    TwendeColor.ink.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            case .denied:
                blocked(title: L(.idCameraDeniedTitle), body: L(.idCameraDeniedBody), showsSettings: true)
            case .unavailable:
                blocked(title: L(.idNoCameraTitle), body: L(.idNoCameraBody), showsSettings: false)
            case .scanning, .captured:
                scanner
            }
        }
        .overlay(alignment: .topLeading) { closeButton }
    }

    private var closeButton: some View {
        MapCircleButton(
            systemImage: "xmark",
            accessibilityLabel: L(.close),
            tint: model.phase == .scanning || model.phase == .captured ? .white : TwendeColor.ink,
            usesLiquidGlass: true,
            action: onClose
        )
        .accessibilityIdentifier("id.scan.close")
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    // MARK: Scanner

    private var scanner: some View {
        GeometryReader { outer in
            let bottomInset = outer.safeAreaInsets.bottom
            let topInset = outer.safeAreaInsets.top
            GeometryReader { proxy in
                let size = proxy.size
                let sheet = Self.sheetHeight + bottomInset
                let cameraArea = CGRect(x: 0, y: topInset + 56, width: size.width, height: size.height - sheet - topInset - 56)
                ZStack(alignment: .bottom) {
                    CameraPreview(session: model.camera.session)
                        .frame(width: size.width, height: size.height)
                        .overlay(TwendeColor.ink.opacity(model.quad == nil ? 0.18 : 0))
                        .animation(.easeOut(duration: 0.25), value: model.quad == nil)

                    tracker(in: size, cameraArea: cameraArea)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)

                    IDScanSheet(model: model)
                        .padding(.bottom, bottomInset)
                        .frame(width: size.width, height: sheet, alignment: .top)
                        .background(TwendeColor.surface)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                }
                .frame(width: size.width, height: size.height)
            }
            .ignoresSafeArea()
        }
        .background(TwendeColor.ink)
    }

    /// Brackets on the detected card; a quiet ID-shaped guide in the open camera area when none is seen.
    @ViewBuilder
    private func tracker(in size: CGSize, cameraArea: CGRect) -> some View {
        let captured = model.phase == .captured
        if let quad = model.quad, let corners = Self.project(quad, image: model.imageSize, view: size) {
            ZStack {
                CardQuad(corners: corners)
                    .fill(captured ? Color.white.opacity(0.28) : TwendeColor.primary.opacity(0.14))
                CardBrackets(corners: corners)
                    .stroke(captured ? TwendeColor.surface : TwendeColor.primary,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: corners)
            .animation(.easeOut(duration: 0.2), value: captured)
            .transition(.opacity)
        } else {
            let width = min(cameraArea.width - 64, 420)
            let height = width / 1.586
            let rect = CGRect(x: cameraArea.midX - width / 2, y: cameraArea.midY - height / 2, width: width, height: height)
            CardBrackets(corners: QuadCorners(rect: rect))
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .transition(.opacity)
        }
    }

    /// Maps normalised upright-image points into the aspect-filled preview.
    static func project(_ quad: IDQuad, image: CGSize, view: CGSize) -> QuadCorners? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = max(view.width / image.width, view.height / image.height)
        let offset = CGPoint(x: (image.width * scale - view.width) / 2, y: (image.height * scale - view.height) / 2)
        let map = { (p: CGPoint) in CGPoint(x: p.x * image.width * scale - offset.x, y: p.y * image.height * scale - offset.y) }
        return QuadCorners(a: map(quad.topLeft), b: map(quad.topRight), c: map(quad.bottomRight), d: map(quad.bottomLeft))
    }

    // MARK: Blocked states

    private func blocked(title: String, body: String, showsSettings: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Icon3DView(icon: .lock, size: 112)
                .padding(.bottom, 8)
            Text(title)
                .font(TwendeFont.title)
                .foregroundStyle(TwendeColor.ink)
                .multilineTextAlignment(.center)
            Text(body)
                .font(TwendeFont.body)
                .foregroundStyle(TwendeColor.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showsSettings {
                Button(L(.idOpenSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.twendePrimary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TwendeColor.surface.ignoresSafeArea())
    }
}

/// White sheet: title, live instruction, a gold progress rule and the three key details filling in.
private struct IDScanSheet: View {
    let model: IDScanViewModel

    private var live: IDScanResult { model.live }
    private var name: String? {
        let joined = [live.givenNames, live.surname].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined.localizedCapitalized
    }
    private var progress: Double {
        guard model.phase != .captured else { return 1 }
        let found = [name != nil, live.documentNumber != nil, live.dateOfBirth != nil].filter { $0 }.count
        return Double(found) / 3 * 0.92 + (model.quad == nil ? 0 : 0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(TwendeColor.border)
                    Rectangle()
                        .fill(LinearGradient(colors: [TwendeColor.goldDeep, TwendeColor.goldLight, TwendeColor.goldMid], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 3)
            .clipShape(.rect(cornerRadius: 1.5))
            .padding(.top, 14)
            .animation(.spring(duration: 0.5), value: progress)

            HStack(alignment: .firstTextBaseline) {
                Text(L(.idScanTitle))
                    .font(TwendeFont.title)
                    .foregroundStyle(TwendeColor.ink)
                Spacer(minLength: 8)
                if live.kind != .other {
                    Text(IdentityCopy.kindName(live.kind))
                        .font(TwendeFont.captionMedium)
                        .foregroundStyle(TwendeColor.accentText)
                        .transition(.opacity)
                }
            }
            .padding(.top, 18)
            .animation(.easeOut(duration: 0.2), value: live.kind)

            Text(hintText)
                .font(TwendeFont.bodyMedium)
                .foregroundStyle(model.hint == .glare ? TwendeColor.amberText : TwendeColor.inkSecondary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: hintText)
                .padding(.top, 4)
                .accessibilityIdentifier("id.scan.hint")

            VStack(spacing: 0) {
                RowDivider(leading: 0).padding(.top, 14)
                LiveFieldRow(title: L(.fullName), value: name, isActive: model.quad != nil)
                LiveFieldRow(title: L(.idDocumentNumber), value: live.documentNumber, isActive: model.quad != nil, monospaced: true)
                LiveFieldRow(title: L(.idDateOfBirth), value: live.dateOfBirth.map(Self.format), isActive: model.quad != nil, showsDivider: false)
            }

            Spacer(minLength: 0)
            Text(L(.idPrimerBullet2))
                .font(TwendeFont.label)
                .foregroundStyle(TwendeColor.inkTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
    }

    private var hintText: String {
        if model.phase == .captured { return L(.idScanCaptured) }
        switch model.hint {
        case .find: return L(.idScanHintAlign)
        case .closer: return L(.idScanHintCloser)
        case .steady: return L(.idScanHintSteady)
        case .reading: return L(.idScanHintReading)
        case .glare: return L(.idScanHintGlare)
        }
    }

    static func format(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current))
    }
}

/// One detail: a shimmering placeholder while the card is in view, the value once read.
private struct LiveFieldRow: View {
    let title: String
    let value: String?
    var isActive: Bool
    var monospaced: Bool = false
    var showsDivider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(monospaced ? TwendeFont.bodySemibold.monospacedDigit() : TwendeFont.bodySemibold)
                        .foregroundStyle(TwendeColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        .id(value)
                } else if isActive {
                    ShimmerBar(height: 8)
                        .frame(width: 96, height: 8)
                        .transition(.opacity)
                } else {
                    Capsule().fill(TwendeColor.surfaceAlt).frame(width: 96, height: 8)
                }
            }
            .frame(height: 48)
            .clipped()
            .animation(.spring(duration: 0.35), value: value)
            if showsDivider { RowDivider(leading: 0) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shapes

/// Four screen-space corners, clockwise from top-left, animatable as a whole.
struct QuadCorners: Equatable {
    var a: CGPoint, b: CGPoint, c: CGPoint, d: CGPoint

    init(a: CGPoint, b: CGPoint, c: CGPoint, d: CGPoint) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    init(rect: CGRect) {
        self.init(a: CGPoint(x: rect.minX, y: rect.minY), b: CGPoint(x: rect.maxX, y: rect.minY),
                  c: CGPoint(x: rect.maxX, y: rect.maxY), d: CGPoint(x: rect.minX, y: rect.maxY))
    }

    typealias Data = AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>, AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>>

    var data: Data {
        get { AnimatablePair(AnimatablePair(a.animatableData, b.animatableData), AnimatablePair(c.animatableData, d.animatableData)) }
        set {
            a.animatableData = newValue.first.first
            b.animatableData = newValue.first.second
            c.animatableData = newValue.second.first
            d.animatableData = newValue.second.second
        }
    }

    var points: [CGPoint] { [a, b, c, d] }
}

private struct CardQuad: Shape {
    var corners: QuadCorners
    var animatableData: QuadCorners.Data {
        get { corners.data }
        set { corners.data = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines(corners.points)
            path.closeSubpath()
        }
    }
}

/// Short L-shaped brackets hugging each corner, sized to the card's edges.
private struct CardBrackets: Shape {
    var corners: QuadCorners
    var animatableData: QuadCorners.Data {
        get { corners.data }
        set { corners.data = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let points = corners.points
        return Path { path in
            for index in 0..<4 {
                let corner = points[index]
                let previous = points[(index + 3) % 4]
                let next = points[(index + 1) % 4]
                path.move(to: Self.toward(corner, previous, 0.16))
                path.addLine(to: corner)
                path.addLine(to: Self.toward(corner, next, 0.12))
            }
        }
    }

    private static func toward(_ from: CGPoint, _ to: CGPoint, _ share: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share)
    }
}

/// Hosts the capture session's preview layer.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
