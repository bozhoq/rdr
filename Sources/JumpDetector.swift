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
    static let phoneTossVersion = "phone-toss-2"
    private let confirmsPhoneCatch: Bool
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

    init(confirmsPhoneCatch: Bool = false) {
        self.confirmsPhoneCatch = confirmsPhoneCatch
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
            if confirmsPhoneCatch && load < 0.65 {
                guard time - pending.flight.start <= 3 else { clearEpisode(); return nil }
                flight = pending.flight
                landing = nil
                return nil
            }
            if time - pending.end <= 0.20 { pending.peak = max(pending.peak, load) }
            if time - pending.end >= 0.20 {
                clearEpisode()
                guard pending.peak >= (confirmsPhoneCatch ? 1.25 : 1.5) else { return nil }
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

/// Detects a push, ascent, descent and braking as separate phases. A kite jump
/// can stay loaded in the air, so it never needs a free-fall interval.
struct RidingJumpDetector {
    static let version = "ride-1"

    struct Point {
        let time: Double
        let height: Double
    }

    struct Flight {
        let event: JumpCandidate
        let trajectory: [Point]
        let settledHeight: Double
        let residualVelocity: Double
    }

    private struct Motion {
        let time: Double
        let vertical: Double
        let load: Double
        let spin: Double
    }

    private struct Arc {
        let began: Double
        let launchSpeed: Double
        var takeoff: Double?
        var landing: Double?
        var landingVelocity = 0.0
        var velocity = 0.0
        var height = 0.0
        var peak = 0.0
        var descent = 0.0
        var minimumLoad: Double
        var landingPeak = 0.0
        var maximumRotation: Double
        var trajectory: [Point] = []
    }

    private(set) var discontinuities = 0
    private var previous: Motion?
    private var settledSince: Double?
    private var arc: Arc?

    mutating func process(_ sample: MotionSample, calibration: MotionCalibration?, moving: Bool) -> Flight? {
        let time = sample.elapsedSinceFirstSampleSeconds
        let a = sample.accelerationG, g = sample.gravityG, r = sample.rotationRadiansPerSecond
        let load = (pow(a.x + g.x, 2) + pow(a.y + g.y, 2) + pow(a.z + g.z, 2)).squareRoot()
        let spin = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        let raw = calibration?.correctedVertical(sample.verticalAccelerationMetersPerSecondSquared, at: time)
            ?? sample.verticalAccelerationMetersPerSecondSquared
        guard time.isFinite, time >= 0, raw.isFinite, load.isFinite, spin.isFinite else {
            breakContinuity()
            return nil
        }
        let interval = previous.map { time - $0.time } ?? 0.01
        if interval <= 0 || interval > 0.05 { breakContinuity() }
        let alpha = interval > 0 ? interval / (0.04 + interval) : 1
        let filtered = previous.map { $0.vertical + alpha * (raw - $0.vertical) } ?? raw
        let motion = Motion(time: time, vertical: filtered, load: load, spin: spin)
        defer { previous = motion }
        guard let last = previous else { return nil }

        if let current = arc {
            arc = nil
            return advance(current, from: last, to: motion)
        }
        if abs(filtered) <= 1.0 {
            if settledSince == nil { settledSince = time }
        } else if filtered >= 1.7, time - (settledSince ?? time) >= 0.25 {
            arc = Arc(began: last.time, launchSpeed: moving ? 1.15 : 1.35, minimumLoad: load, maximumRotation: spin)
            settledSince = nil
        } else if filtered < -1.0 {
            settledSince = nil
        }
        return nil
    }

    private mutating func breakContinuity() {
        if previous != nil { discontinuities += 1 }
        previous = nil
        settledSince = nil
        arc = nil
    }

    private mutating func advance(_ current: Arc, from last: Motion, to now: Motion) -> Flight? {
        var track = current
        let dt = now.time - last.time
        let initialVelocity = track.velocity
        track.velocity += (last.vertical + now.vertical) * 0.5 * dt
        track.height += (initialVelocity + track.velocity) * 0.5 * dt
        track.maximumRotation = max(track.maximumRotation, now.spin)

        guard let takeoff = track.takeoff else {
            if now.time - track.began > 0.75 || track.velocity < -0.1 {
                arc = nil
                return nil
            }
            if now.vertical < 0.7, track.velocity >= track.launchSpeed {
                track.takeoff = now.time
                track.height = 0
                track.trajectory = [Point(time: now.time, height: 0)]
            }
            arc = track
            return nil
        }

        guard now.time - takeoff <= 15.5 else {
            arc = nil
            return nil
        }
        track.trajectory.append(Point(time: now.time, height: track.height))
        track.peak = max(track.peak, track.height)
        track.minimumLoad = min(track.minimumLoad, now.load)
        if let landing = track.landing {
            track.landingPeak = max(track.landingPeak, now.load)
            if track.velocity < initialVelocity - 0.10 && now.vertical < -1.0 {
                track.landing = nil
                track.landingPeak = 0
                arc = track
                return nil
            }
            let braking = track.velocity - track.landingVelocity
            if now.time - landing >= 0.22, braking >= max(0.8, -track.landingVelocity * 0.55),
               abs(now.vertical) <= 2.2, abs(track.velocity) <= max(1.3, -track.landingVelocity * 0.5) {
                let event = JumpCandidate(startSeconds: takeoff, endSeconds: landing, minimumLoadG: track.minimumLoad,
                                          returnPeakG: track.landingPeak, maximumRotationRadiansPerSecond: track.maximumRotation)
                arc = nil
                return Flight(event: event, trajectory: track.trajectory, settledHeight: track.height, residualVelocity: track.velocity)
            }
            if now.time - landing >= 0.50 {
                track.landing = nil
                track.landingPeak = 0
            }
        } else if now.time - takeoff >= 0.35, track.peak >= 0.20,
                  track.descent <= -0.65, initialVelocity <= -0.50, now.vertical >= 2.3 {
            track.landing = now.time
            track.landingVelocity = initialVelocity
            track.landingPeak = now.load
        } else {
            track.descent = min(track.descent, track.velocity)
        }
        arc = track
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
