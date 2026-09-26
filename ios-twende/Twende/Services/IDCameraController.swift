import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// The four corners of a detected document, normalised (0…1, top-left origin) in the upright camera image.
nonisolated struct IDQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Horizontal share of the frame the card covers; drives the "move closer" hint.
    var width: CGFloat {
        max(topRight.x, bottomRight.x) - min(topLeft.x, bottomLeft.x)
    }

    /// Largest corner movement between two detections.
    func distance(to other: IDQuad) -> CGFloat {
        zip([topLeft, topRight, bottomRight, bottomLeft], [other.topLeft, other.topRight, other.bottomRight, other.bottomLeft])
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? 1
    }
}

/// Text read from the flattened card, plus the flattened card itself for the face crop.
nonisolated struct IDFrameReading: @unchecked Sendable {
    let lines: [String]
    let image: CGImage?
}

/// Finds the ID anywhere in the camera image, flattens it with a perspective correction and reads the
/// straightened close-up. Detection runs ~12×/s for a live outline; recognition runs on its own queue
/// only while the card is still. Frames never leave this class and are never written anywhere.
nonisolated final class IDCameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Availability: Sendable { case ready, denied, unavailable }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "zuri.id-camera")
    private let ocrQueue = DispatchQueue(label: "zuri.id-ocr", qos: .userInitiated)
    private let context = CIContext()
    private var orientation: CGImagePropertyOrientation = .right
    private var isConfigured = false

    private var onQuad: (@Sendable (IDQuad?, CGSize) -> Void)?
    private var onReading: (@Sendable (IDFrameReading) -> Void)?

    private var lastDetect: CFAbsoluteTime = 0
    private var lastOCR: CFAbsoluteTime = 0
    private var lastQuadAt: CFAbsoluteTime = 0
    private var previousQuad: IDQuad?
    private var isReading = false
    /// Alternates flattened-card and whole-frame reads, so a wrong outline (e.g. the photo box on the
    /// card) can never stop the scan from reading the text.
    private var readCount = 0

    /// Asks for permission and wires the best back camera (or the simulator's injected external camera).
    func prepare() async -> Availability {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default:
            return .denied
        }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera, .external]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.position == .back }) ?? discovery.devices.first else { return .unavailable }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.configure(device) ? .ready : .unavailable)
            }
        }
    }

    private func configure(_ device: AVCaptureDevice) -> Bool {
        guard !isConfigured else { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInput(input)
        // 4K where available: the flattened card then has enough pixels for small print.
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
        // The injected simulator webcam delivers upright frames; phone sensors are landscape.
        orientation = device.deviceType == .external ? .up : .right
        isConfigured = true
        return true
    }

    func start(onQuad: @escaping @Sendable (IDQuad?, CGSize) -> Void, onReading: @escaping @Sendable (IDFrameReading) -> Void) {
        queue.async {
            self.onQuad = onQuad
            self.onReading = onReading
            self.previousQuad = nil
            self.readCount = 0
            self.isReading = false
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            self.onQuad = nil
            self.onReading = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDetect > 0.08, let onQuad, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetect = now

        let rotated = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let image = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        let size = image.extent.size

        let detection = Self.detectCard(in: image, size: size)
        onQuad(detection?.display, size)

        guard !isReading else {
            if let detection { previousQuad = detection.display; lastQuadAt = now }
            return
        }
        if let detection {
            lastQuadAt = now
            // Skip only frames where the card is visibly moving (motion blur); normal hand shake is fine.
            let moving = previousQuad.map { $0.distance(to: detection.display) > 0.06 } ?? false
            previousQuad = detection.display
            guard !moving, now - lastOCR > 0.3 else { return }
            readCount += 1
            if readCount % 3 != 0, let flat = flatten(image, corners: detection.corners) {
                read(flat, source: "card", at: now)
            } else {
                readWholeFrame(image, size: size, at: now)
            }
        } else {
            previousQuad = nil
            // Held very close the card fills the frame and has no visible edges: read the whole frame.
            guard now - lastOCR > 0.6 else { return }
            readWholeFrame(image, size: size, at: now)
        }
    }

    private func readWholeFrame(_ image: CIImage, size: CGSize, at now: CFAbsoluteTime) {
        let scale = min(1, 2200 / max(size.width, size.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let frame = context.createCGImage(scaled, from: scaled.extent) else { return }
        read(frame, source: "frame", at: now)
    }

    private func read(_ image: CGImage, source: String, at now: CFAbsoluteTime) {
        isReading = true
        lastOCR = now
        ocrQueue.async {
            var lines = Self.recognise(image, orientation: .up)
            // A card turned the other way reads as garbage; try it upside down / sideways before giving up.
            if lines.count < 4 {
                for orientation in [CGImagePropertyOrientation.down, .right, .left] {
                    let retry = Self.recognise(image, orientation: orientation)
                    if retry.count > lines.count { lines = retry }
                    if lines.count >= 4 { break }
                }
            }
            print("[IDScan] read source=\(source) rows=\(lines.count)")
            self.queue.async {
                self.isReading = false
                self.onReading?(IDFrameReading(lines: lines, image: lines.count >= 3 ? image : nil))
            }
        }
    }

    /// Document segmentation with an ID-shaped filter (short/long side 0.5–0.85 covers ID-1 cards and
    /// passport pages), so doors, screens and windows in the background are ignored.
    private static func detectCard(in image: CIImage, size: CGSize) -> (display: IDQuad, corners: VNRectangleObservation)? {
        let request = VNDetectDocumentSegmentationRequest()
        do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([request]) } catch { return nil }
        guard let observation = request.results?.first, observation.confidence > 0.5 else { return nil }
        let px = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let top = hypot(px(observation.topRight).x - px(observation.topLeft).x, px(observation.topRight).y - px(observation.topLeft).y)
        let side = hypot(px(observation.bottomLeft).x - px(observation.topLeft).x, px(observation.bottomLeft).y - px(observation.topLeft).y)
        guard top > 0, side > 0 else { return nil }
        let ratio = min(top, side) / max(top, side)
        guard (0.5...0.85).contains(ratio), min(top, side) > min(size.width, size.height) * 0.15 else { return nil }
        let flip = { (p: CGPoint) in CGPoint(x: p.x, y: 1 - p.y) }
        let quad = IDQuad(
            topLeft: flip(observation.topLeft), topRight: flip(observation.topRight),
            bottomRight: flip(observation.bottomRight), bottomLeft: flip(observation.bottomLeft)
        )
        return (quad, observation)
    }

    /// Perspective-corrects the card to a flat, landscape, ~1800px-wide image.
    private func flatten(_ image: CIImage, corners: VNRectangleObservation) -> CGImage? {
        let size = image.extent.size
        let px = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = px(corners.topLeft)
        filter.topRight = px(corners.topRight)
        filter.bottomRight = px(corners.bottomRight)
        filter.bottomLeft = px(corners.bottomLeft)
        guard var output = filter.outputImage else { return nil }
        if output.extent.height > output.extent.width { output = output.oriented(.right) }
        output = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
        let scale = 1800 / max(output.extent.width, 1)
        output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(output, from: output.extent)
    }

    private static func recognise(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.008
        do { try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request]) } catch { return [] }
        return rows(from: request.results ?? [])
    }

    /// Vision returns text boxes in no guaranteed order and often splits one printed row (a label and
    /// its value, or a machine-readable line) into several boxes. Group boxes by row, top to bottom,
    /// and join each row left to right so the parsers see the card as it is printed.
    static func rows(from observations: [VNRecognizedTextObservation]) -> [String] {
        let items = observations.compactMap { observation -> (box: CGRect, text: String)? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return (observation.boundingBox, text)
        }
        .sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for item in items {
            if let last = rows.last?.first, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
    }

    /// Crops the largest face on the card with breathing room, for an optional profile photo.
    static func faceCrop(from image: CGImage) -> UIImage? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var rect = CGRect(
            x: face.boundingBox.minX * width,
            y: (1 - face.boundingBox.maxY) * height,
            width: face.boundingBox.width * width,
            height: face.boundingBox.height * height
        )
        let side = max(rect.width, rect.height) * 1.7
        rect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = image.cropping(to: rect.integral) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
