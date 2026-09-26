import CoreGraphics
import Foundation
import Observation
import UIKit

/// Drives the live ID scan: permission, card tracking, per-frame parsing, multi-frame field voting,
/// auto-capture and hints. Every detail comes from the camera; nothing is typed.
@Observable
final class IDScanViewModel {
    enum Phase: Equatable {
        case preparing
        case denied
        case unavailable
        case scanning
        case captured
    }

    enum Hint: Equatable {
        case find, closer, steady, reading, glare
    }

    private(set) var phase: Phase = .preparing
    private(set) var hint: Hint = .find
    /// Where the card is in the upright camera image (normalised), or nil when none is in view.
    private(set) var quad: IDQuad?
    private(set) var imageSize: CGSize = .zero
    /// Best values read so far, shown live while scanning.
    private(set) var live: IDScanResult = .empty
    private(set) var result: IDScanResult?
    private(set) var faceImage: UIImage?

    let camera = IDCameraController()
    private var votes = IDFieldVotes()
    private var bestImage: CGImage?
    private var readingSince: Date?
    private var lastQuadAt: Date = .distantPast
    private var firstCompleteAt: Date?

    func start() async {
        phase = .preparing
        switch await camera.prepare() {
        case .denied: phase = .denied
        case .unavailable: phase = .unavailable
        case .ready:
            resetReading()
            phase = .scanning
            camera.start(
                onQuad: { [weak self] quad, size in
                    Task { @MainActor in self?.track(quad, size: size) }
                },
                onReading: { [weak self] reading in
                    Task { @MainActor in self?.handle(reading) }
                }
            )
        }
    }

    func stop() {
        camera.stop()
    }

    func restart() {
        result = nil
        faceImage = nil
        Task { await start() }
    }

    private func resetReading() {
        votes = IDFieldVotes()
        live = .empty
        bestImage = nil
        readingSince = nil
        firstCompleteAt = nil
        quad = nil
        hint = .find
    }

    private func track(_ quad: IDQuad?, size: CGSize) {
        guard phase == .scanning else { return }
        imageSize = size
        let now = Date()
        if let quad {
            if self.quad == nil { Haptics.selection() }
            self.quad = quad
            lastQuadAt = now
        } else if now.timeIntervalSince(lastQuadAt) > 0.4 {
            // Keep the outline briefly so a single missed detection doesn't flicker it away.
            self.quad = nil
        }
        updateHint(now: now)
    }

    private func updateHint(now: Date) {
        guard let quad else {
            hint = live.isEmptyReading ? .find : .reading
            readingSince = nil
            return
        }
        if quad.width < 0.5 {
            hint = .closer
            return
        }
        if readingSince == nil { readingSince = now }
        let elapsed = now.timeIntervalSince(readingSince ?? now)
        if elapsed > 9, live.isEmptyReading { hint = .glare }
        else { hint = live.isEmptyReading ? .steady : .reading }
    }

    private func handle(_ reading: IDFrameReading) {
        guard phase == .scanning else { return }
        guard let parsed = IDDocumentParser.parse(lines: reading.lines) else {
            print("[IDScan] no document fields in \(reading.lines.count) rows")
            return
        }
        print("[IDScan] parsed kind=\(parsed.kind) name=\(parsed.givenNames != nil || parsed.surname != nil) number=\(parsed.documentNumber != nil) dob=\(parsed.dateOfBirth != nil)")

        // A frame whose check digits all pass is authoritative on its own.
        if parsed.verifiedByChecksum && parsed.isComplete {
            finish(parsed, image: reading.image)
            return
        }
        votes.add(parsed)
        if reading.image != nil, parsed.isComplete { bestImage = reading.image }
        let merged = votes.merged()
        live = merged
        updateHint(now: Date())

        guard merged.isComplete else { return }
        let now = Date()
        if firstCompleteAt == nil { firstCompleteAt = now }
        // Capture once the key fields agree across frames, or after a short settle so a slightly noisy
        // card still completes with its most-read values.
        if votes.isStable || now.timeIntervalSince(firstCompleteAt ?? now) > 2.5 {
            finish(merged, image: bestImage ?? reading.image)
        }
    }

    private func finish(_ parsed: IDScanResult, image: CGImage?) {
        camera.stop()
        Haptics.success()
        live = parsed
        phase = .captured
        let face: UIImage? = image.flatMap(IDCameraController.faceCrop(from:))
        // Let the "captured" beat play before the review slides in.
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            faceImage = face
            result = parsed
        }
    }
}

extension IDScanResult {
    /// Nothing useful read yet.
    var isEmptyReading: Bool {
        givenNames == nil && surname == nil && documentNumber == nil && dateOfBirth == nil
    }
}

/// Tallies what each frame read for every field and keeps the most frequent value, so a single
/// misread character in one frame never wins.
private struct IDFieldVotes {
    private var kinds: [IdentityDocumentKind: Int] = [:]
    private var given: [String: Int] = [:]
    private var surname: [String: Int] = [:]
    private var number: [String: Int] = [:]
    private var nationality: [String: Int] = [:]
    private var sex: [IdentitySex: Int] = [:]
    private var birth: [Date: Int] = [:]
    private var expiry: [Date: Int] = [:]

    mutating func add(_ result: IDScanResult) {
        kinds[result.kind, default: 0] += 1
        if let value = result.givenNames?.trimmingCharacters(in: .whitespaces), value.count >= 2 { given[value, default: 0] += 1 }
        if let value = result.surname?.trimmingCharacters(in: .whitespaces), value.count >= 2 { surname[value, default: 0] += 1 }
        if let value = result.documentNumber, value.count >= 4 { number[value, default: 0] += 1 }
        if let value = result.nationality, !value.isEmpty { nationality[value, default: 0] += 1 }
        if let value = result.sex, value != .unspecified { sex[value, default: 0] += 1 }
        if let value = result.dateOfBirth { birth[value, default: 0] += 1 }
        if let value = result.expiryDate { expiry[value, default: 0] += 1 }
    }

    /// Number, birth date and a name each read the same way at least twice.
    var isStable: Bool {
        (Self.top(number)?.count ?? 0) >= 2 && (Self.top(birth)?.count ?? 0) >= 2
            && ((Self.top(given)?.count ?? 0) >= 2 || (Self.top(surname)?.count ?? 0) >= 2)
    }

    func merged() -> IDScanResult {
        var result = IDScanResult(kind: Self.top(kinds.filter { $0.key != .other })?.value ?? .other)
        result.givenNames = Self.top(given)?.value
        result.surname = Self.top(surname)?.value
        result.documentNumber = Self.top(number)?.value
        result.nationality = Self.top(nationality)?.value
        result.sex = Self.top(sex)?.value
        result.dateOfBirth = Self.top(birth)?.value
        result.expiryDate = Self.top(expiry)?.value
        // Fields read only once, or that disagreed between frames, get a "check this" note.
        let checks: [(IDField, Int, Int)] = [
            (.givenNames, Self.top(given)?.count ?? 0, given.count),
            (.surname, Self.top(surname)?.count ?? 0, surname.count),
            (.documentNumber, Self.top(number)?.count ?? 0, number.count),
            (.dateOfBirth, Self.top(birth)?.count ?? 0, birth.count),
        ]
        for (field, topCount, distinct) in checks where topCount > 0 && (topCount < 2 || distinct > 2) {
            result.uncertain.insert(field)
        }
        return result
    }

    private static func top<Key: Hashable>(_ tally: [Key: Int]) -> (value: Key, count: Int)? {
        tally.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}
