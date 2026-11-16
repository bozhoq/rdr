import Foundation

struct JumpCandidate: Codable, Identifiable, Sendable {
    var id = UUID()
    let startSeconds: Double
    let endSeconds: Double
    let minimumLoadG: Double
    let returnPeakG: Double
    let maximumRotationRadiansPerSecond: Double

    // Interval between unloading and return thresholds.
    var unloadingSeconds: Double { endSeconds - startSeconds }
    var strongImpact: Bool { returnPeakG >= 8 }
    var fastRotation: Bool { maximumRotationRadiansPerSecond >= 12 }

    /// Approximate rise from release to apex for a hand-labeled toss with
    /// release and catch at the same height, using unloading as a time proxy.
    func approximateTossHeightMeters(label: JumpLabel) -> Double? {
        let duration = unloadingSeconds
        guard label == .phoneToss, duration.isFinite, duration >= 0.22, duration <= 3 else { return nil }
        return 9.80665 * duration * duration / 8
    }
}

struct JumpAnalysis: Codable, Sendable {
    var detectorVersion = JumpDetector.version
    var candidates: [JumpCandidate] = []
    var discontinuities = 0
}

/// Experimental ground-test heuristic. Kite lift can prevent near-weightlessness;
/// no inference about kite airtime or height is made from these events.
struct JumpDetector {
    static let version = "ground-1"
    private(set) var discontinuities = 0
    private var previousTime: Double?
    private var loadedSince: Double?
    private var armed = false
    private var flight: Flight?
    private var landing: Landing?

    private struct Flight {
        let start: Double
        var minimumLoad: Double
        var maximumRotation: Double
    }
    private struct Landing {
        let flight: Flight
        let end: Double
        var peak: Double
    }

    mutating func breakContinuity() {
        discontinuities += 1
        previousTime = nil
        clearEpisode()
    }

    private mutating func clearEpisode() {
        loadedSince = nil
        armed = false
        flight = nil
        landing = nil
    }

    mutating func process(_ sample: MotionSample) -> JumpCandidate? {
        let a = sample.accelerationG
        let g = sample.gravityG
        let r = sample.rotationRadiansPerSecond
        // Core Motion: total acceleration = userAcceleration + gravity.
        // A vector magnitude does not depend on the phone's orientation.
        let load = sqrt(pow(a.x + g.x, 2) + pow(a.y + g.y, 2) + pow(a.z + g.z, 2))
        let spin = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        let time = sample.elapsedSinceFirstSampleSeconds
        guard time.isFinite, time >= 0, load.isFinite, spin.isFinite else {
            breakContinuity()
            return nil
        }
        if let previousTime, time <= previousTime || time - previousTime > 0.05 {
            breakContinuity()
        }
        previousTime = time

        // Observe the return for 200 ms. This also prevents counting the
        // immediate rebound after catching a tossed phone as a separate jump.
        if var pending = landing {
            if time - pending.end <= 0.20 { pending.peak = max(pending.peak, load) }
            if time - pending.end >= 0.20 {
                clearEpisode()
                guard pending.peak >= 1.5 else { return nil }
                return JumpCandidate(
                    startSeconds: pending.flight.start,
                    endSeconds: pending.end,
                    minimumLoadG: pending.flight.minimumLoad,
                    returnPeakG: pending.peak,
                    maximumRotationRadiansPerSecond: pending.flight.maximumRotation
                )
            }
            landing = pending
            return nil
        }

        if var current = flight {
            let duration = time - current.start
            guard duration <= 3 else { clearEpisode(); return nil }
            if load < 0.65 {
                current.minimumLoad = min(current.minimumLoad, load)
                current.maximumRotation = max(current.maximumRotation, spin)
                flight = current
            } else {
                clearEpisode()
                if duration >= 0.22 {
                    landing = Landing(flight: current, end: time, peak: load)
                }
            }
            return nil
        }

        if load < 0.4 {
            if armed {
                flight = Flight(start: time, minimumLoad: load, maximumRotation: spin)
            }
            armed = false
            loadedSince = nil
        } else if load >= 0.8 {
            if loadedSince == nil { loadedSince = time }
            if time - (loadedSince ?? time) >= 0.20 { armed = true }
        } else if !armed {
            loadedSince = nil
        }
        return nil
    }
}

/// Streaming replay uses the exact same detector as live recording. Raw logs,
/// including pre-detector logs, remain unchanged; results are stored separately.
enum JumpReplay {
    private struct Header: Decodable { let type: String }
    private struct MotionEntry: Decodable { let data: MotionSample }

    static func analyze(url: URL) throws -> JumpAnalysis {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var detector = JumpDetector()
        var result = JumpAnalysis()
        var buffer = Data()
        let decoder = JSONDecoder()

        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            do {
                let header = try decoder.decode(Header.self, from: line)
                if header.type == "motion" {
                    let entry = try decoder.decode(MotionEntry.self, from: line)
                    if let candidate = detector.process(entry.data) {
                        result.candidates.append(candidate)
                    }
                }
            } catch {
                // A partial line after a reboot must never join two episodes.
                detector.breakContinuity()
            }
        }

        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                consume(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 1_048_576 {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if !buffer.isEmpty { consume(buffer) }
        result.discontinuities = detector.discontinuities
        return result
    }
}
