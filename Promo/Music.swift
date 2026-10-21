import Foundation

/// The soundtrack: a West-Coast-flavoured beat at 100 BPM in F minor, with the app's own sound
/// effects laid on top at their cue times. Everything is synthesized.
enum Score {
    static let rate = 44_100.0
    static let beat = 0.6
    static let step = beat / 4
    static let bar = beat * 4

    static let drop = 3.6
    static let stop = 33.0
    static let endCard = 35.4
    static let montage = (start: 16.8, end: 24.0)

    private static var seed: UInt32 = 2024

    private static func noise() -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Double(seed) / Double(UInt32.max) * 2 - 1
    }

    private static func add(_ part: [Double], at time: Double, gain: Double, into buffer: inout [Double]) {
        let start = Int(time * rate)
        guard start < buffer.count else { return }
        for i in 0..<min(part.count, buffer.count - start) { buffer[start + i] += part[i] * gain }
    }

    private static func make(_ seconds: Double, _ f: (Double) -> Double) -> [Double] {
        (0..<Int(seconds * rate)).map { f(Double($0) / rate) }
    }

    // MARK: Instruments

    static func kick() -> [Double] {
        var phase = 0.0
        return make(0.5) { t in
            phase += 2 * .pi * (44 + 100 * exp(-t * 32)) / rate
            return sin(phase) * exp(-t * 6.5) + noise() * exp(-t * 900) * 0.25
        }
    }

    static func snare() -> [Double] {
        var low = 0.0
        return make(0.32) { t in
            low += 0.25 * (noise() - low)
            let crack = (noise() - low)
            let claps = [0.0, 0.011, 0.023].reduce(0.0) { sum, at in
                t >= at ? sum + exp(-(t - at) * 95) * 0.6 : sum
            }
            return crack * (exp(-t * 15) * 0.75 + claps) + sin(2 * .pi * 185 * t) * exp(-t * 24) * 0.35
        }
    }

    static func hat(open: Bool) -> [Double] {
        var low = 0.0
        return make(open ? 0.3 : 0.07) { t in
            low += 0.55 * (noise() - low)
            return (noise() - low) * exp(-t * (open ? 11 : 52)) * 0.5
        }
    }

    static func crash() -> [Double] {
        var low = 0.0
        return make(2.2) { t in
            low += 0.4 * (noise() - low)
            return (noise() - low) * exp(-t * 2.2) * 0.45
        }
    }

    static func bass(_ freq: Double, length: Double) -> [Double] {
        make(length) { t in
            let env = min(1, t / 0.004) * (0.55 + 0.45 * exp(-t * 7)) * min(1, (length - t) / 0.04)
            let x = sin(2 * .pi * freq * t) + 0.35 * sin(2 * .pi * freq * 2 * t)
            return tanh(x * 1.4) * env
        }
    }

    /// Soft detuned-saw chord pad with a gentle low-pass.
    static func pad(_ notes: [Double], length: Double) -> [Double] {
        var lp = 0.0
        return make(length) { t in
            let raw = notes.reduce(0.0) { sum, f in
                sum + [0.996, 1.004].reduce(0.0) { s2, d in
                    let x = t * f * d
                    return s2 + 2 * (x - floor(x + 0.5))
                }
            }
            lp += 0.11 * (raw - lp)
            let env = min(1, t / 0.35) * min(1, (length - t) / 0.3)
            return lp * env
        }
    }

    /// G-funk style sine "whistle" lead with glide and vibrato.
    static func lead(_ notes: [(beat: Double, beats: Double, freq: Double)]) -> [Double] {
        let total = (notes.last.map { $0.beat + $0.beats } ?? 0) * beat + 0.3
        var phase = 0.0
        var freq = notes.first?.freq ?? 440
        return make(total) { t in
            let b = t / beat
            guard let note = notes.last(where: { $0.beat <= b }) else { return 0 }
            let local = t - note.beat * beat
            let length = note.beats * beat
            freq += (note.freq - freq) * 0.012
            let vibrato = 1 + 0.006 * sin(2 * .pi * 5.5 * local) * min(1, local / 0.15)
            phase += 2 * .pi * freq * vibrato / rate
            let env = min(1, local / 0.015) * (local < length - 0.06 ? 1 : max(0, (length - local) / 0.06))
            let tone = sin(phase) + 0.12 * sin(phase * 2) + 0.05 * sin(phase * 3)
            return tone * (local < length ? env : 0)
        }
    }

    static func riser(_ length: Double) -> [Double] {
        var low = 0.0, band = 0.0
        var phase = 0.0
        return make(length) { t in
            let k = t / length
            let cutoff = 400 + 5200 * k * k
            let f = 2 * sin(.pi * cutoff / rate)
            low += f * band
            band += f * (noise() - low - 0.7 * band)
            phase += 2 * .pi * (220 + 660 * k) / rate
            return (band * 0.55 + sin(phase) * 0.12) * pow(k, 2.2)
        }
    }

    // MARK: Arrangement

    static func render(duration: Double, cues: [Cue], withMusic: Bool = true) -> [Float] {
        let count = Int(duration * rate)
        var music = [Double](repeating: 0, count: count)
        var effects = [Double](repeating: 0, count: count)

        if withMusic {
            let chords: [(root: Double, voicing: [Double])] = [
                (87.31, [174.61, 207.65, 261.63]),   // Fm
                (69.30, [138.59, 174.61, 207.65]),   // Db
                (103.83, [207.65, 261.63, 311.13]),  // Ab
                (77.78, [155.56, 196.00, 233.08]),   // Eb
            ]
            let kickHit = kick(), snareHit = snare(), closed = hat(open: false), open = hat(open: true), cymbal = crash()

            // Pad under everything except the WASTED silence; a held chord on the end card.
            var t = 0.0
            var barIndex = 0
            while t < stop {
                let chord = chords[barIndex % 4]
                add(pad(chord.voicing, length: min(bar + 0.3, stop - t + 0.05)), at: t, gain: 0.05, into: &music)
                t += bar
                barIndex += 1
            }
            add(pad([174.61, 207.65, 261.63, 392.00], length: duration - endCard), at: endCard, gain: 0.06, into: &music)
            add(riser(drop - 2.2), at: 2.2, gain: 0.8, into: &music)

            // Drums and bass from the drop until WASTED cuts everything.
            var s = 0
            while true {
                let time = drop + Double(s) * step
                guard time < stop else { break }
                let inBar = s % 16
                let chord = chords[Int(time / bar) % 4]
                if [0, 7, 10].contains(inBar) {
                    add(kickHit, at: time, gain: 0.95, into: &music)
                    add(bass(inBar == 10 ? chord.root * 2 : chord.root, length: inBar == 7 ? 0.28 : 0.42), at: time, gain: 0.42, into: &music)
                }
                if inBar == 4 || inBar == 12 { add(snareHit, at: time, gain: 0.7, into: &music) }
                if inBar % 2 == 0 { add(closed, at: time, gain: inBar % 4 == 0 ? 0.55 : 0.4, into: &music) }
                if inBar == 14 { add(open, at: time, gain: 0.4, into: &music) }
                // Hat roll into every fourth bar.
                if (s / 16) % 4 == 3, inBar >= 13 { add(closed, at: time + step / 2, gain: 0.3, into: &music) }
                s += 1
            }
            for impact in [drop, montage.start, endCard] { add(cymbal, at: impact, gain: 0.9, into: &music) }
            add(kickHit, at: endCard, gain: 1, into: &music)

            // The whistle melody over the montage.
            let tune: [(beat: Double, beats: Double, freq: Double)] = [
                (0, 1, 523.25), (1, 0.5, 622.25), (1.5, 0.5, 698.46), (2, 2, 830.61), (4, 1, 783.99), (5, 1, 698.46),
                (6, 2, 622.25), (8, 1, 698.46), (9, 1, 830.61), (10, 2, 1046.5),
            ]
            add(lead(tune), at: montage.start, gain: 0.17, into: &music)
        }

        for cue in cues {
            add(SFX.shared.render(cue.kind).map(Double.init), at: cue.time, gain: Double(cue.gain), into: &effects)
        }

        var mixed = [Float](repeating: 0, count: count)
        var peak = 0.0
        var level = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            // Music sits lower under the demo so the clicks and racks read clearly.
            let musicGain = (t >= 7.2 && t < 16.8) ? 0.5 : 0.72
            let fadeOut = min(1, max(0, (duration - t) / 1.2))
            let v = tanh((music[i] * musicGain + effects[i] * 0.95) * 1.15) * fadeOut
            level[i] = v
            peak = max(peak, abs(v))
        }
        // -2 dBFS leaves room for the AAC encoder's overshoot.
        let norm = peak > 0 ? 0.79 / peak : 1
        for i in 0..<count { mixed[i] = Float(level[i] * norm) }
        return mixed
    }

    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate) * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        data.reserveCapacity(data.count + samples.count * 4)
        for sample in samples {
            let v = UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_000))
            u16(v); u16(v)
        }
        return data
    }
}
