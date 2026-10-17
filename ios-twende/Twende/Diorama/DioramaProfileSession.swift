import Foundation
import QuartzCore
import UIKit

/// Main-thread frame-gap probe: counts display frames and hitches (gaps over 25 ms).
@MainActor
private final class DioramaHitchProbe: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames: Int = 0
    private var hitches: Int = 0
    private var worst: Double = 0

    func start() {
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l; last = 0
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 {
            let gap = (l.timestamp - last) * 1000
            frames += 1
            if gap > 25 { hitches += 1 }
            worst = max(worst, gap)
        }
        last = l.timestamp
    }
    func drain() -> (frames: Int, hitches: Int, worst: Double) {
        defer { frames = 0; hitches = 0; worst = 0 }
        return (frames, hitches, worst)
    }
}

/// Records a full performance log while the user zooms into the city, and can run a scripted
/// ablation (switch one effect or layer off at a time on a still camera) to measure what each costs.
@MainActor
@Observable
final class DioramaProfileSession {
    static let shared = DioramaProfileSession()

    private(set) var isRecording: Bool = false
    private(set) var phase: String = "Idle"
    private(set) var files: [URL] = []
    private(set) var liveLine: String = ""
    /// When true, the test runs once as soon as the camera holds still above zoom 15.5.
    var ablationPending: Bool = true

    private struct Tick {
        var t: Double; var zoom: Double; var pitch: Double
        var gpuFPS: Double; var gpuP50: Double?; var gpuP95: Double?; var cpuP50: Double?; var cpuP95: Double?
        var triangles: Int; var draws: Int; var shadowTriangles: Int; var labels: Int; var lights: Int; var hosts: Int
        var categories: [(String, Int)]
        var thermal: String; var thermalRaw: Int; var lowPower: Bool
        var memoryMB: Double; var processCPU: Double
        var mainFPS: Int; var hitches: Int; var worstGapMS: Double
    }
    private struct AblationResult {
        var name: String; var frames: Int; var gpuP50: Double?; var gpuP95: Double?; var cpuP50: Double?; var cameraMoved: Bool
    }
    private struct Event { var t: Double; var text: String }

    private var ticks: [Tick] = []
    private var events: [Event] = []
    private var ablation: [AblationResult] = []
    private var started: CFTimeInterval = 0
    private var runTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let hitchProbe = DioramaHitchProbe()
    private var lastPassText: String = ""
    private var ablationDone: Bool = false
    private static let maxSeconds: Double = 900

    private var elapsed: Double { CACurrentMediaTime() - started }

    // MARK: Control

    func start() {
        guard !isRecording else { return }
        DioramaProfiler.shared.begin()
        ticks.removeAll(); events.removeAll(); ablation.removeAll(); files.removeAll()
        started = CACurrentMediaTime(); ablationDone = !ablationPending; lastPassText = ""
        isRecording = true
        phase = ablationPending ? "Recording. Go to the map, zoom into the city centre, then hold still." : "Recording. Zoom into the city centre."
        hitchProbe.start()
        let info = ProcessInfo.processInfo
        events.append(Event(t: 0, text: "Start · thermal \(DioramaProfiler.thermalName(info.thermalState)) · low power \(info.isLowPowerModeEnabled) · \(info.processorCount) cores · \(String(format: "%.1f", Double(info.physicalMemory) / 1_073_741_824)) GB RAM · iOS \(UIDevice.current.systemVersion) · screen \(Int(UIScreen.main.bounds.width * UIScreen.main.scale))x\(Int(UIScreen.main.bounds.height * UIScreen.main.scale)) @\(Int(UIScreen.main.maximumFramesPerSecond)) Hz max"))
        let names: [(Notification.Name, String)] = [
            (ProcessInfo.thermalStateDidChangeNotification, "Thermal state changed"),
            (.NSProcessInfoPowerStateDidChange, "Low Power Mode changed"),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING"),
        ]
        for (name, text) in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    let p = ProcessInfo.processInfo
                    self.events.append(Event(t: self.elapsed, text: "\(text) · thermal \(DioramaProfiler.thermalName(p.thermalState)) · low power \(p.isLowPowerModeEnabled)"))
                }
            })
        }
        runTask = Task { await loop() }
    }

    func stop() {
        guard isRecording else { return }
        runTask?.cancel(); runTask = nil
        hitchProbe.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        let frames = DioramaProfiler.shared.end()
        isRecording = false
        phase = "Writing report"
        files = write(frames: frames)
        phase = files.isEmpty ? "Report could not be written" : "Done. Share the report below."
    }

    // MARK: Loop

    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            tick()
            if !ablationDone, cameraIsStill() {
                ablationDone = true; ablationPending = false
                await runAblation()
            }
            if elapsed > Self.maxSeconds { stop(); return }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let recent = DioramaProfiler.shared.frames(from: now - 1)
        let gpu = recent.compactMap(\.gpuMS), cpu = recent.map(\.cpuMS)
        var perHost: [Int: Int] = [:]
        for f in recent { perHost[f.host, default: 0] += 1 }
        let hosts = DioramaDebugSwitches.shared.liveHosts()
        var byCategory: [DioramaCategory: Int] = [:]
        for h in hosts { for (c, n) in h.triangles { byCategory[c, default: 0] += n } }
        let info = ProcessInfo.processInfo
        let probe = hitchProbe.drain()
        let last = DioramaProfiler.shared.lastFrame
        let t = Tick(t: elapsed, zoom: last?.zoom ?? 0, pitch: last?.pitch ?? 0,
            gpuFPS: Double(perHost.values.max() ?? 0),
            gpuP50: gpu.isEmpty ? nil : DioramaProfiler.percentile(gpu, 0.5), gpuP95: gpu.isEmpty ? nil : DioramaProfiler.percentile(gpu, 0.95),
            cpuP50: cpu.isEmpty ? nil : DioramaProfiler.percentile(cpu, 0.5), cpuP95: cpu.isEmpty ? nil : DioramaProfiler.percentile(cpu, 0.95),
            triangles: byCategory.values.reduce(0, +), draws: hosts.reduce(0) { $0 + $1.drawCalls },
            shadowTriangles: hosts.reduce(0) { $0 + $1.shadowTriangles }, labels: hosts.reduce(0) { $0 + $1.labels },
            lights: hosts.reduce(0) { $0 + $1.lights }, hosts: hosts.count,
            categories: byCategory.sorted { $0.value > $1.value }.map { ($0.key.rawValue, $0.value) },
            thermal: DioramaProfiler.thermalName(info.thermalState), thermalRaw: info.thermalState.rawValue, lowPower: info.isLowPowerModeEnabled,
            memoryMB: DioramaProfiler.memoryMB(), processCPU: DioramaProfiler.processCPUPercent(),
            mainFPS: probe.frames, hitches: probe.hitches, worstGapMS: probe.worst)
        ticks.append(t)
        let passes = DioramaState.shared.passReport
        if passes != lastPassText, !passes.hasPrefix("Per-pass GPU timings appear") {
            lastPassText = passes
            events.append(Event(t: t.t, text: "Pass timings (zoom \(String(format: "%.2f", t.zoom)))\n" + passes.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n")))
        }
        liveLine = String(format: "z%.2f · GPU %@ ms · %d tris · %@ · %.0f MB", t.zoom, t.gpuP50.map { String(format: "%.1f", $0) } ?? "–", t.triangles, t.thermal, t.memoryMB)
        print("[ZuriProfile] " + liveLine)
    }

    /// Camera unchanged over the last three seconds, zoomed into the city.
    private func cameraIsStill() -> Bool {
        let now = CACurrentMediaTime()
        guard let last = DioramaProfiler.shared.lastFrame, last.zoom >= 15.5, elapsed > 5 else { return false }
        let window = DioramaProfiler.shared.frames(from: now - 3)
        if window.isEmpty { return now - last.t > 3 }
        let zooms = window.map(\.zoom), lats = window.map(\.latitude), lons = window.map(\.longitude)
        return (zooms.max()! - zooms.min()!) < 0.01 && (lats.max()! - lats.min()!) < 3e-6 && (lons.max()! - lons.min()!) < 3e-6
    }

    // MARK: Scripted ablation

    private func runAblation() async {
        let state = DioramaState.shared
        let originalFlags = DioramaDebugSwitches.shared.flags
        let originalLayers = state.visibleCategories
        defer {
            DioramaDebugSwitches.shared.flags = originalFlags
            state.visibleCategories = originalLayers
            NotificationCenter.default.post(name: DioramaState.renderSettingsChanged, object: state)
        }
        typealias Change = (inout DioramaDebugSwitches.Flags, inout Set<DioramaCategory>) -> Void
        let layers: [(String, DioramaCategory)] = [("Buildings", .buildings), ("Roads", .roads), ("Objects", .props), ("Trees", .vegetation),
                                                   ("Walls", .walls), ("Ground", .ground), ("Water", .water)]
        var steps: [(String, Change)] = [
            ("Everything on (baseline)", { _, _ in }),
            ("Sun shadows off", { f, _ in f.shadows = false }),
            ("Glow / bloom off", { f, _ in f.bloom = false }),
            ("Point lights off", { f, _ in f.pointLights = false }),
            ("Ground painting off", { f, _ in f.groundPaint = false }),
            ("Facade shader off", { f, _ in f.facadeShader = false }),
            ("3D labels off", { f, _ in f.labels = false }),
            ("All effects off", { f, _ in f.shadows = false; f.bloom = false; f.pointLights = false; f.groundPaint = false; f.facadeShader = false; f.labels = false }),
        ]
        for (name, category) in layers {
            steps.append(("\(name) layer off", { _, c in c.remove(category) }))
        }
        steps.append(("All 3D scenery off (native map floor)", { _, c in c.removeAll() }))
        steps.append(("Everything on (repeat, drift check)", { _, _ in }))

        events.append(Event(t: elapsed, text: "Ablation test started at zoom \(String(format: "%.2f", DioramaProfiler.shared.lastFrame?.zoom ?? 0)) (forced 60 Hz redraws; keep the camera still)"))
        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled else { return }
            phase = "Test \(index + 1)/\(steps.count): \(step.0). Hold still."
            var flags = originalFlags, cats = originalLayers
            step.1(&flags, &cats)
            DioramaDebugSwitches.shared.flags = flags
            state.visibleCategories = cats
            NotificationCenter.default.post(name: DioramaState.renderSettingsChanged, object: state)
            let begin = CACurrentMediaTime()
            let repaint = Task { @MainActor in
                while !Task.isCancelled {
                    DioramaProfiler.shared.requestRepaint()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            try? await Task.sleep(for: .seconds(3))
            repaint.cancel()
            let frames = DioramaProfiler.shared.frames(from: begin + 1)
            let gpu = frames.compactMap(\.gpuMS)
            let zooms = frames.map(\.zoom), lats = frames.map(\.latitude)
            let moved = !zooms.isEmpty && ((zooms.max()! - zooms.min()!) > 0.02 || (lats.max()! - lats.min()!) > 6e-6)
            ablation.append(AblationResult(name: step.0, frames: frames.count,
                gpuP50: gpu.isEmpty ? nil : DioramaProfiler.percentile(gpu, 0.5), gpuP95: gpu.isEmpty ? nil : DioramaProfiler.percentile(gpu, 0.95),
                cpuP50: frames.isEmpty ? nil : DioramaProfiler.percentile(frames.map(\.cpuMS), 0.5), cameraMoved: moved))
        }
        events.append(Event(t: elapsed, text: "Ablation test finished; settings restored"))
        phase = "Test finished. Keep zooming, or stop and share."
    }

    // MARK: Report

    private func write(frames: [DioramaProfiler.Frame]) -> [URL] {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let directory = URL.documentsDirectory.appending(path: "Profiles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appending(path: "zuri-profile-\(stamp).txt")
        let csvURL = directory.appending(path: "zuri-profile-\(stamp)-frames.csv")
        var csv = "t,host,zoom,pitch,bearing,lat,lon,cpu_encode_ms,gpu_ms\n"
        let t0 = frames.first?.t ?? 0
        for f in frames {
            csv += String(format: "%.3f,%d,%.3f,%.1f,%.1f,%.6f,%.6f,%.2f,%@\n", f.t - t0, f.host & 0xffff, f.zoom, f.pitch, f.bearing, f.latitude, f.longitude, f.cpuMS, f.gpuMS.map { String(format: "%.2f", $0) } ?? "")
        }
        var written: [URL] = []
        if (try? buildReport(frames: frames).write(to: reportURL, atomically: true, encoding: .utf8)) != nil { written.append(reportURL) }
        if (try? csv.write(to: csvURL, atomically: true, encoding: .utf8)) != nil { written.append(csvURL) }
        return written
    }

    private func buildReport(frames: [DioramaProfiler.Frame]) -> String {
        func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
        func avg(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        var out: [String] = []
        out.append("ZURI PERFORMANCE LOG  \(Date().formatted())")
        out.append("Duration \(Int(ticks.last?.t ?? 0)) s · \(frames.count) frames recorded · \(ticks.count) one-second samples")
        out.append("GPU ms is the shared Mapbox command buffer (basemap + diorama). CPU ms is diorama encode time on the render thread.")
        out.append("120 fps needs GPU < 8.3 ms and CPU < 8 ms. 60 fps needs < 16.7 ms.")
        out.append("")

        out.append("== DIAGNOSIS ==")
        out.append(contentsOf: diagnosis(f: f))
        out.append("")

        if !ablation.isEmpty {
            out.append("== ABLATION (camera still, one change at a time; GPU ms median) ==")
            let base = ablation.first?.gpuP50
            let floorMS = ablation.first { $0.name.hasPrefix("All 3D scenery off") }?.gpuP50
            out.append(col("step", 40, left: true) + col("GPU50", 8) + col("GPU95", 8) + col("saved ms", 10) + col("share", 8) + col("frames", 8))
            for r in ablation {
                let saved = (base != nil && r.gpuP50 != nil) ? base! - r.gpuP50! : nil
                let share = (saved != nil && base! > 0) ? saved! / base! * 100 : nil
                out.append(col(r.name, 40, left: true) + col(f(r.gpuP50), 8) + col(f(r.gpuP95), 8) + col(f(saved, 2), 10)
                           + col(share.map { String(format: "%.0f%%", $0) } ?? "–", 8) + col("\(r.frames)", 8) + (r.cameraMoved ? "  (camera moved, unreliable)" : ""))
            }
            if let base, let floorMS {
                out.append(String(format: "Diorama share of GPU frame: %.1f of %.1f ms (%.0f%%). The rest is the native map.", base - floorMS, base, base > 0 ? (base - floorMS) / base * 100 : 0))
            }
            out.append("")
        } else {
            out.append("== ABLATION ==\nNot run (the camera never held still above zoom 15.5).\n")
        }

        out.append("== BY ZOOM LEVEL (0.5 steps) ==")
        out.append([col("zoom", 6), col("secs", 5), col("fps", 5), col("GPU50", 7), col("GPU95", 7), col("CPU95", 7), col("tris", 9),
                    col("draws", 6), col("shadowTr", 9), col("cpu%", 6), col("memMB", 7), col("hitch", 6), " thermal"].joined())
        let buckets = Dictionary(grouping: ticks.filter { $0.zoom > 0 }) { floor($0.zoom * 2) / 2 }
        for key in buckets.keys.sorted() {
            let b = buckets[key]!
            out.append([col(String(format: "%.1f", key), 6), col("\(b.count)", 5), col(f(avg(b.map(\.gpuFPS)), 0), 5),
                        col(f(avg(b.compactMap(\.gpuP50))), 7), col(f(b.compactMap(\.gpuP95).max()), 7), col(f(b.compactMap(\.cpuP95).max()), 7),
                        col("\(Int(avg(b.map { Double($0.triangles) }) ?? 0))", 9), col("\(Int(avg(b.map { Double($0.draws) }) ?? 0))", 6),
                        col("\(Int(avg(b.map { Double($0.shadowTriangles) }) ?? 0))", 9), col(f(avg(b.map(\.processCPU)), 0), 6),
                        col(f(avg(b.map(\.memoryMB)), 0), 7), col("\(b.reduce(0) { $0 + $1.hitches })", 6),
                        " " + (b.max { $0.thermalRaw < $1.thermalRaw }?.thermal ?? "")].joined())
        }
        out.append("")

        out.append("== EVENTS ==")
        for e in events { out.append(String(format: "[%6.1fs] ", e.t) + e.text) }
        out.append("")

        out.append("== TIMELINE (one line per second) ==")
        out.append([col("t(s)", 6), col("zoom", 6), col("pitch", 6), col("fps", 5), col("GPU50", 7), col("GPU95", 7), col("CPU50", 7), col("CPU95", 7),
                    col("tris", 9), col("draws", 6), col("shadowTr", 9), col("lbl", 5), col("lights", 7), col("hosts", 6), col("cpu%", 6), col("memMB", 7),
                    col("main/hitch/worst", 18), " thermal / top categories"].joined())
        for t in ticks {
            let top = t.categories.prefix(3).map { "\($0.0) \($0.1 / 1000)k" }.joined(separator: ", ")
            out.append([col(String(format: "%.0f", t.t), 6), col(String(format: "%.2f", t.zoom), 6), col(String(format: "%.1f", t.pitch), 6), col(String(format: "%.0f", t.gpuFPS), 5),
                        col(f(t.gpuP50), 7), col(f(t.gpuP95), 7), col(f(t.cpuP50), 7), col(f(t.cpuP95), 7),
                        col("\(t.triangles)", 9), col("\(t.draws)", 6), col("\(t.shadowTriangles)", 9), col("\(t.labels)", 5), col("\(t.lights)", 7), col("\(t.hosts)", 6),
                        col(String(format: "%.0f", t.processCPU), 6), col(String(format: "%.0f", t.memoryMB), 7),
                        col("\(t.mainFPS)/\(t.hitches)/\(Int(t.worstGapMS))ms", 18),
                        " " + t.thermal + (t.lowPower ? "+LPM" : "") + "  " + top].joined())
        }
        out.append("")
        out.append("Raw per-frame data: the matching -frames.csv file.")
        return out.joined(separator: "\n")
    }

    private func diagnosis(f: (Double?, Int) -> String) -> [String] {
        var lines: [String] = []
        let measured = ticks.filter { $0.gpuP50 != nil && $0.zoom >= 15.5 }
        guard !measured.isEmpty else { return ["No frames were drawn above zoom 15.5, so nothing could be measured."] }
        let gpu50 = DioramaProfiler.percentile(measured.compactMap(\.gpuP50), 0.5)
        let gpu95 = DioramaProfiler.percentile(measured.compactMap(\.gpuP95), 0.95)
        let cpu95 = DioramaProfiler.percentile(measured.compactMap(\.cpuP95), 0.95)
        let hitches = measured.reduce(0) { $0 + $1.hitches }
        lines.append(String(format: "City zoom (15.5+): GPU median %.1f ms, worst-second p95 %.1f ms, CPU encode p95 %.1f ms, %d main-thread hitches.", gpu50, gpu95, cpu95, hitches))
        if gpu50 > 8.3 { lines.append(String(format: "- Too slow for 120 fps: GPU takes %.1f ms per frame (budget 8.3 ms).", gpu50)) }
        if gpu50 > 16.7 { lines.append("- Too slow even for 60 fps.") }
        if gpu50 > cpu95 * 1.5 { lines.append("- GPU-bound: the GPU takes far longer than the CPU encode. Cut pixel or triangle work, not code.") }
        else if cpu95 > 8 { lines.append("- CPU-bound: encode time is high. Look at draw calls and per-frame planning.") }
        if hitches > 10 { lines.append("- Main thread stalls: the app's own work (not the GPU) is dropping frames. Check the camera passes and label updates.") }
        if let first = ticks.first(where: { $0.thermalRaw >= 1 }) {
            lines.append(String(format: "- Heat: thermal state reached %@ at %.0f s (zoom %.2f). CPU averaged %.0f%% of a core.", first.thermal, first.t, first.zoom, measured.map(\.processCPU).reduce(0, +) / Double(measured.count)))
        } else {
            lines.append("- Heat: thermal state stayed nominal during this run (run longer than two minutes to judge heating).")
        }
        let memStart = ticks.first?.memoryMB ?? 0, memEnd = ticks.last?.memoryMB ?? 0
        lines.append(String(format: "- Memory: %.0f MB at start, %.0f MB at end (%+.0f MB).", memStart, memEnd, memEnd - memStart))
        if let slowest = Dictionary(grouping: measured) { floor($0.zoom * 2) / 2 }.max(by: { (avgGPU($0.value)) < (avgGPU($1.value)) }) {
            lines.append(String(format: "- Slowest zoom band: %.1f to %.1f at %.1f ms GPU median.", slowest.key, slowest.key + 0.5, avgGPU(slowest.value)))
        }
        let base = ablation.first?.gpuP50
        if let base, base > 0 {
            let ranked = ablation.dropFirst().filter { r in !r.name.hasPrefix("All ") && !r.name.hasPrefix("Everything") }
                .compactMap { r -> (String, Double)? in r.gpuP50.map { (r.name, base - $0) } }
                .sorted { $0.1 > $1.1 }
            lines.append("- Biggest single costs (GPU ms saved when switched off, of \(f(base, 1)) ms):")
            for (name, saved) in ranked.prefix(5) {
                lines.append("    " + col(name, 34, left: true) + String(format: "%5.2f ms  (%.0f%%)", saved, saved / base * 100))
            }
            if let floorMS = ablation.first(where: { $0.name.hasPrefix("All 3D scenery off") })?.gpuP50 {
                lines.append(String(format: "- Native map alone: %.1f ms. Diorama adds %.1f ms.", floorMS, max(0, base - floorMS)))
            }
        }
        return lines
    }

    private func col(_ text: String, _ width: Int, left: Bool = false) -> String {
        let pad = String(repeating: " ", count: max(0, width - text.count))
        return left ? text + pad : pad + text
    }

    private func avgGPU(_ ticks: [Tick]) -> Double {
        let v = ticks.compactMap(\.gpuP50)
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
}
