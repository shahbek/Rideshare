import Foundation
import QuartzCore
import UIKit

/// Finite, GPU-paced tile sweeps shared by coarse arrivals, departures and full-detail retirement.
nonisolated enum DioramaTileTransition {
    @MainActor
    static func run(host: DioramaRenderLayer, from: Float, to: Float, lifecycle: Bool = true,
                    step: @MainActor (SIMD4<Float>, Float) -> Void) async -> Bool {
        var elapsed: Double = 0
        var previous = CACurrentMediaTime()
        var requested = previous
        var current = SIMD4<Float>(0, 0, from, 1)
        var endpoint: Bool = false
        func apply(_ field: SIMD4<Float>, progress: Float) {
            if lifecycle { host.setLifecycleReveal(field) } else { host.setReveal(field) }
            step(field, progress)
        }
        apply(current, progress: 0)
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            let finish = UIAccessibility.isReduceMotionEnabled || UIApplication.shared.applicationState != .active
                || ProcessInfo.processInfo.thermalState == .critical
            if host.diagnostic.contains("failed") || host.diagnostic.contains("missing") || now - requested > 20 { return false }
            let completed = lifecycle ? host.hasCompletedLifecycle(current) : host.hasCompleted(reveal: current)
            if finish {
                apply(SIMD4(0, 0, to, 1), progress: 1)
                return true
            }
            if completed {
                if endpoint { return true }
                elapsed += min(1.0 / 30, max(0, now - previous))
                let progress = Float(min(1, elapsed / 1.8))
                let eased = progress * progress * (3 - 2 * progress)
                current.z = from + (to - from) * eased
                apply(current, progress: eased)
                requested = now
                endpoint = progress >= 1
            }
            previous = now
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return false }
        }
        return false
    }
}
