import AppKit

/// Synthesized sounds (no audio files shipped): wheel whoosh and ticks, a weapon-handling sound
/// per weapon class for a finished job, the "mission passed" sting, police blips and "wasted".
final class SFX {
    static let shared = SFX()

    enum Kind: CaseIterable {
        case open, tick, page, passed, wasted, denied, wanted, evaded
        case rackPistol, rackRifle, rackBolt, rackPump, rackHeavy, pinPull, bladeDraw, meleeSwing
    }

    private let rate = 44_100.0
    private var clips: [Kind: Data] = [:]
    private var pool: [Kind: [NSSound]] = [:]
    private var seed: UInt32 = 0x9E37_79B9

    private init() {
        for kind in Kind.allCases { clips[kind] = wav(render(kind)) }
    }

    func play(_ kind: Kind) {
        guard Settings.shared.sound, let clip = clips[kind] else { return }
        var sounds = pool[kind] ?? []
        if let idle = sounds.first(where: { !$0.isPlaying }) {
            idle.currentTime = 0
            idle.play()
            return
        }
        guard sounds.count < 4, let sound = NSSound(data: clip) else { return }
        sound.volume = volume(kind)
        sounds.append(sound)
        pool[kind] = sounds
        sound.play()
    }

    func play(_ kind: Kind, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.play(kind) }
    }

    private func volume(_ kind: Kind) -> Float {
        switch kind {
        case .tick: return 0.35
        case .page: return 0.4
        case .open: return 0.5
        case .passed: return 0.45
        case .wasted: return 0.75
        case .denied: return 0.35
        case .wanted: return 0.32
        case .evaded: return 0.4
        case .rackPistol, .rackRifle, .rackBolt, .rackPump, .rackHeavy, .pinPull, .bladeDraw, .meleeSwing: return 0.65
        }
    }

    // MARK: - Synthesis kit

    private func noise() -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Double(seed) / Double(UInt32.max) * 2 - 1
    }

    /// State-variable band-pass: shapes noise into metal friction, swooshes and spray.
    private struct BandPass {
        var low = 0.0, band = 0.0
        mutating func run(_ x: Double, cutoff: Double, damping: Double, rate: Double) -> Double {
            let f = 2 * sin(.pi * min(cutoff, rate / 6.5) / rate)
            low += f * band
            let high = x - low - damping * band
            band += f * high
            return band
        }
    }

    private func samples(_ seconds: Double, _ f: (Double) -> Double) -> [Double] {
        (0..<max(1, Int(seconds * rate))).map { f(Double($0) / rate) }
    }

    private func clip(_ seconds: Double, _ f: (Double) -> Double) -> [Float] {
        samples(seconds, f).map(Float.init)
    }

    /// Lays parts down at their start times.
    private func mix(_ seconds: Double, _ parts: [(at: Double, part: [Double])]) -> [Float] {
        var out = [Double](repeating: 0, count: Int(seconds * rate))
        for (at, part) in parts {
            let offset = Int(at * rate)
            for (i, v) in part.enumerated() where offset + i < out.count { out[offset + i] += v }
        }
        return out.map { Float(tanh($0 * 1.1) / 1.1) }
    }

    private func click(_ t: Double, pitch: Double) -> Double {
        guard t >= 0 else { return 0 }
        let body = exp(-t * 170) * (0.6 * sin(2 * .pi * pitch * t) + 0.22 * sin(2 * .pi * pitch * 2.01 * t))
        return body + noise() * exp(-t * 1100) * 0.3
    }

    /// A metal-on-metal clack: band-passed transient plus inharmonic ringing.
    private func clack(_ tone: Double, _ gain: Double) -> [Double] {
        var bp = BandPass()
        return samples(0.16) { (u: Double) -> Double in
            let w: Double = 2 * .pi * tone * u
            let hit: Double = bp.run(self.noise(), cutoff: 3300, damping: 0.6, rate: self.rate) * exp(-u * 380) * 1.3
            let p1: Double = sin(w)
            let p2: Double = 0.5 * exp(-u * 30) * sin(w * 2.76)
            let p3: Double = 0.25 * exp(-u * 60) * sin(w * 5.4)
            let ring: Double = (p1 + p2 + p3) * exp(-u * 55) * 0.32
            let tick: Double = self.noise() * exp(-u * 2500) * 0.45
            return (hit + ring + tick) * gain
        }
    }

    /// Low body knock with a quick pitch drop.
    private func thump(_ freq: Double, decay: Double, _ gain: Double) -> [Double] {
        var phase = 0.0
        return samples(min(2.6, 6 / decay)) { u in
            phase += 2 * .pi * freq * (1 + 0.8 * exp(-u * 50)) / self.rate
            return sin(phase) * exp(-u * decay) * gain
        }
    }

    /// Sliding friction (a slide or bolt travelling), noise swept between two pitches.
    private func scrape(_ duration: Double, from f0: Double, to f1: Double, _ gain: Double, damping: Double = 0.9) -> [Double] {
        var bp = BandPass()
        return samples(duration) { u in
            let k = u / duration
            let env = pow(sin(.pi * k), 0.7)
            return bp.run(self.noise(), cutoff: f0 + (f1 - f0) * k, damping: damping, rate: self.rate) * env * gain
        }
    }

    /// A bell-like metal ring (blade, pin, spoon).
    private func ring(_ freq: Double, decay: Double, _ gain: Double) -> [Double] {
        let partials: [(Double, Double, Double)] = [(1, 1, 1), (2.41, 0.5, 1.4), (3.93, 0.3, 2), (5.6, 0.18, 3)]
        return samples(min(2, 7 / decay)) { u in
            partials.reduce(0.0) { sum, p in sum + sin(2 * .pi * freq * p.0 * u) * p.1 * exp(-u * decay * p.2) } * min(1, u / 0.002) * gain
        }
    }

    private func whoosh(_ duration: Double, from f0: Double, to f1: Double, _ gain: Double) -> [Double] {
        var bp = BandPass()
        return samples(duration) { u in
            let k = u / duration
            return bp.run(self.noise(), cutoff: f0 + (f1 - f0) * k, damping: 1.2, rate: self.rate) * pow(sin(.pi * k), 1.5) * gain
        }
    }

    // MARK: - Sounds

    func render(_ kind: Kind) -> [Float] {
        switch kind {
        case .tick:
            return clip(0.04) { click($0, pitch: 2300) }

        case .page:
            return clip(0.1) { click($0, pitch: 2700) + click($0 - 0.045, pitch: 2000) }

        case .denied:
            return clip(0.12) { t in
                let square = sin(2 * .pi * 140 * t) > 0 ? 1.0 : -1.0
                return square * 0.25 * exp(-t * 22)
            }

        case .open:
            // Band-passed noise sweeping upward, over a soft low thump.
            var bp = BandPass()
            let duration = 0.24
            return clip(duration) { t in
                let swoosh = bp.run(self.noise(), cutoff: 450 + 2600 * (t / duration), damping: 0.5, rate: self.rate)
                let envelope = min(1, t / 0.05) * exp(-max(0, t - 0.05) * 14)
                let low = sin(2 * .pi * (120 - 160 * t) * t) * exp(-t * 18) * 0.5
                return swoosh * envelope * 0.55 + low
            }

        case .passed:
            let notes: [(start: Double, freq: Double)] = [(0, 659.25), (0.12, 987.77), (0.12, 1318.5)]
            return clip(1.0) { t in
                notes.reduce(0.0) { sum, note in
                    let u = t - note.start
                    guard u >= 0 else { return sum }
                    let env = min(1, u / 0.006) * exp(-u * 3.2)
                    let voice = sin(2 * .pi * note.freq * u) + 0.3 * sin(2 * .pi * note.freq * 2 * u) + 0.1 * sin(2 * .pi * note.freq * 3 * u)
                    return sum + voice * env * 0.28
                }
            }

        case .wanted:
            // Two quick police "wee-woo" blips.
            return clip(0.5) { t in
                let high = Int(t / 0.125) % 2 == 0
                let f = high ? 1180.0 : 860.0
                let tone = sin(2 * .pi * f * t) + 0.35 * sin(2 * .pi * f * 3 * t)
                let gate = min(1, (t.truncatingRemainder(dividingBy: 0.125)) / 0.01)
                return tone * gate * exp(-t * 2.4) * 0.3
            }

        case .evaded:
            let notes: [(start: Double, freq: Double)] = [(0, 987.77), (0.1, 783.99), (0.2, 587.33)]
            return clip(0.75) { t in
                notes.reduce(0.0) { sum, note in
                    let u = t - note.start
                    guard u >= 0 else { return sum }
                    return sum + sin(2 * .pi * note.freq * u) * min(1, u / 0.005) * exp(-u * 6) * 0.3
                }
            }

        case .wasted:
            // Time slows: a reversed swell and a sinking tone, then a huge reverberant boom.
            let hitAt = 0.42
            var lp = 0.0
            var swellPhase = 0.0
            let swell = samples(hitAt) { u in
                let k = u / hitAt
                lp += (0.02 + 0.12 * k) * (self.noise() - lp)
                swellPhase += 2 * .pi * (330 - 220 * k) / self.rate
                return (lp * 1.6 + sin(swellPhase) * 0.22) * pow(k, 3)
            }
            var impact = thump(46, decay: 2.1, 1.25)
            var rumble = 0.0
            for i in 0..<impact.count {
                let u = Double(i) / rate
                rumble += 0.03 * (noise() - rumble)
                impact[i] += rumble * exp(-u * 4.5) * 2.2 + sin(2 * .pi * (70 - 30 * min(u, 1)) * u) * exp(-u * 1.6) * 0.45
            }
            var parts: [(at: Double, part: [Double])] = [(0, swell), (hitAt, impact)]
            for (delay, gain) in [(0.09, 0.34), (0.17, 0.25), (0.26, 0.18), (0.37, 0.12), (0.5, 0.08)] {
                parts.append((hitAt + delay, impact.map { $0 * gain }))
            }
            return mix(3.0, parts)

        case .rackPistol:
            return mix(0.45, [(0, clack(2400, 0.7)), (0.015, scrape(0.07, from: 1800, to: 2600, 0.45)),
                              (0.12, clack(1900, 1.0)), (0.12, thump(130, decay: 30, 0.6))])

        case .rackRifle:
            return mix(0.55, [(0, scrape(0.09, from: 1200, to: 2000, 0.5)), (0, clack(2100, 0.6)),
                              (0.2, clack(1500, 1.1)), (0.2, thump(95, decay: 22, 0.8)), (0.2, ring(1800, decay: 14, 0.22))])

        case .rackBolt:
            return mix(0.75, [(0, clack(3000, 0.5)), (0.07, scrape(0.1, from: 1500, to: 2400, 0.45)), (0.18, clack(2200, 0.6)),
                              (0.3, scrape(0.08, from: 2400, to: 1500, 0.45)), (0.4, clack(1700, 1.0)), (0.4, thump(110, decay: 28, 0.5))])

        case .rackPump:
            // The classic "chk-chk".
            return mix(0.6, [(0, scrape(0.06, from: 900, to: 1600, 0.8, damping: 0.7)), (0.05, clack(1300, 0.9)), (0.05, thump(90, decay: 25, 0.7)),
                             (0.2, scrape(0.05, from: 1600, to: 900, 0.8, damping: 0.7)), (0.24, clack(1100, 1.25)), (0.24, thump(80, decay: 22, 0.9))])

        case .rackHeavy:
            var phase = 0.0
            let whir = samples(0.75) { u in
                phase += 2 * .pi * (180 + 340 * min(u / 0.6, 1)) / self.rate
                let motor = 0.6 + 0.4 * sin(2 * .pi * 38 * u)
                return (sin(phase) + 0.3 * sin(phase * 2)) * motor * min(1, u / 0.1) * exp(-max(0, u - 0.55) * 12) * 0.16
            }
            return mix(0.95, [(0, thump(65, decay: 10, 1.0)), (0, clack(900, 1.0)), (0, ring(600, decay: 8, 0.28)), (0.12, whir)])

        case .pinPull:
            return mix(0.7, [(0, clack(4200, 0.3)), (0.02, ring(3400, decay: 9, 0.45)), (0.22, ring(5200, decay: 18, 0.25)),
                             (0.22, clack(2600, 0.25))])

        case .bladeDraw:
            return mix(0.75, [(0, scrape(0.28, from: 2500, to: 7500, 0.9, damping: 0.5)), (0.22, ring(4100, decay: 6, 0.33)),
                              (0.22, ring(6200, decay: 9, 0.18))])

        case .meleeSwing:
            return mix(0.5, [(0, whoosh(0.22, from: 500, to: 2200, 0.9)), (0.22, thump(110, decay: 26, 0.7)), (0.22, clack(800, 0.4))])
        }
    }

    private func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for sample in samples {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_000)))
        }
        return data
    }

    /// Writes every sound to a folder as .wav (used to audition them).
    func export(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for kind in Kind.allCases {
            try wav(render(kind)).write(to: folder.appendingPathComponent("\(kind).wav"))
        }
    }
}
