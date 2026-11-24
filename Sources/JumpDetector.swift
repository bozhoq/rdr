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
    static let phoneTossVersion = "phone-toss-3"
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
        var nearFreeFallSeconds = 0.0
    }
    private struct Landing {
        let flight: Flight
        let end: Double
        var peak: Double
        var supportedSeconds = 0.0
        var lowSince: Double?
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
        let interval = previousTime.map { time - $0 } ?? 0
        previousTime = time

        // Observe the return for 200 ms. This also prevents counting the
        // immediate rebound after catching a tossed phone as a separate jump.
        if var pending = landing {
            if confirmsPhoneCatch {
                if load >= 0.50 {
                    pending.supportedSeconds += interval
                    pending.lowSince = nil
                } else {
                    if pending.lowSince == nil { pending.lowSince = time }
                    if let lowSince = pending.lowSince, time - lowSince >= 0.04, pending.supportedSeconds < 0.10 {
                        guard time - pending.flight.start <= 3 else { clearEpisode(); return nil }
                        flight = pending.flight
                        landing = nil
                        return nil
                    }
                }
            }
            if time - pending.end <= 0.20 { pending.peak = max(pending.peak, load) }
            if time - pending.end >= 0.20 {
                clearEpisode()
                guard pending.peak >= (confirmsPhoneCatch ? 1.25 : 1.5) else { return nil }
                if confirmsPhoneCatch {
                    let duration = pending.end - pending.flight.start
                    guard pending.supportedSeconds >= 0.11,
                          pending.flight.nearFreeFallSeconds >= duration * 0.60 else { return nil }
                }
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
            if load < (confirmsPhoneCatch ? 0.50 : 0.65) {
                current.minimumLoad = min(current.minimumLoad, load)
                current.maximumRotation = max(current.maximumRotation, spin)
                if load < 0.30 { current.nearFreeFallSeconds += interval }
                flight = current
            } else {
                clearEpisode()
                if duration >= 0.22 {
                    landing = Landing(flight: current, end: time, peak: load, supportedSeconds: interval)
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
    static let version = "ride-9"

    struct Point {
        let time: Double
        let height: Double
    }

    struct Flight {
        let event: JumpCandidate
        let trajectory: [Point]
        let settledHeight: Double
        let residualVelocity: Double
        var levelLandingHeight: Double? = nil
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
        var recoverySince: Double?
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

    private struct ShortFlight {
        let start: Double
        var minimumLoad: Double
        var maximumSpin: Double
        var landing: Double?
        var landingLoad = 0.0
        var landingAcceleration = 0.0
        var samples: [Motion]

        func estimateHeight() -> Double? {
            guard let landing, samples.count >= 15 else { return nil }
            let duration = landing - start
            var velocity = 0.0
            var displacement = 0.0
            var lowLoadTime = 0.0
            var positions: [Point] = []
            for (before, after) in zip(samples, samples.dropFirst()) {
                let dt = after.time - before.time
                let nextVelocity = velocity + (before.vertical + after.vertical) * 0.5 * dt
                displacement += (velocity + nextVelocity) * 0.5 * dt
                if before.load < 0.70 { lowLoadTime += dt }
                positions.append(Point(time: after.time, height: displacement))
                velocity = nextVelocity
            }
            // Estimate only in a predominantly unloaded short flight. Use
            // equal takeoff and landing heights to solve for vertical velocity
            // at takeoff. Horizontal motion does not enter this calculation.
            guard lowLoadTime >= duration * 0.75,
                  (-13.0 ... -6.0).contains(velocity / duration) else { return nil }
            let takeoffVelocity = -displacement / duration
            guard takeoffVelocity > 0.5, takeoffVelocity + velocity < -0.5 else { return nil }
            let apex = positions.max {
                $0.height + takeoffVelocity * ($0.time - start) < $1.height + takeoffVelocity * ($1.time - start)
            }
            guard let apex, (0.2...0.8).contains((apex.time - start) / duration) else { return nil }
            let height = apex.height + takeoffVelocity * (apex.time - start)
            return (0.08...0.95).contains(height) ? height : nil
        }
    }

    private(set) var discontinuities = 0
    private(set) var lastRejection: String?
    private var previous: Motion?
    private var settledSince: Double?
    private var preparation: [Motion] = []
    private var preparedUntil = -Double.infinity
    private var arc: Arc?
    private var lastPush = -Double.infinity
    // A rotating pouch can stay laterally loaded while its vertical axis is already in flight.
    private var verticalUnloading: [Motion] = []
    private var shortFlight: ShortFlight?
    private var pendingShortFlight: Flight?
    private var lastLanding = -Double.infinity

    mutating func process(_ sample: MotionSample, calibration: MotionCalibration?, moving: Bool) -> Flight? {
        lastRejection = nil
        let time = sample.elapsedSinceFirstSampleSeconds
        let a = sample.accelerationG, g = sample.gravityG, r = sample.rotationRadiansPerSecond
        let load = (pow(a.x + g.x, 2) + pow(a.y + g.y, 2) + pow(a.z + g.z, 2)).squareRoot()
        let spin = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        let corrected = calibration?.correctedVertical(sample.verticalAccelerationMetersPerSecondSquared, at: time)
        let raw = corrected.map { -$0 } ?? sample.upwardAcceleration
        guard time.isFinite, time >= 0, raw.isFinite, load.isFinite, spin.isFinite else {
            breakContinuity()
            return nil
        }
        let interval = previous.map { time - $0.time } ?? 0.01
        if interval <= 0 || interval > 0.05 {
            breakContinuity()
            previous = Motion(time: time, vertical: raw, load: load, spin: spin)
            return nil
        }
        let alpha = interval > 0 ? interval / (0.04 + interval) : 1
        let filtered = previous.map { $0.vertical + alpha * (raw - $0.vertical) } ?? raw
        let motion = Motion(time: time, vertical: filtered, load: load, spin: spin)
        defer { previous = motion }
        guard let last = previous else { return nil }

        if let detected = detectShortFlight(Motion(time: time, vertical: raw, load: load, spin: spin)) {
            pendingShortFlight = detected
        }
        if let flight = detectRidingFlight(from: last, to: motion, moving: moving) {
            if let pendingShortFlight, pendingShortFlight.event.startSeconds <= flight.event.endSeconds,
               pendingShortFlight.event.endSeconds >= flight.event.startSeconds {
                self.pendingShortFlight = nil
                self.shortFlight = nil
                lastLanding = pendingShortFlight.event.endSeconds
                // The height and airtime must describe the same interval.
                // Copying just the short estimate onto a wider event mixes
                // two different trajectories.
                return pendingShortFlight
            }
            if let shortFlight, shortFlight.start <= flight.event.endSeconds {
                self.shortFlight = nil
            }
            lastLanding = flight.event.endSeconds
            return flight
        }
        guard let short = pendingShortFlight,
              arc == nil || time >= short.event.endSeconds + 0.45 else { return nil }
        pendingShortFlight = nil
        lastLanding = short.event.endSeconds
        arc = nil
        return short
    }

    private mutating func detectRidingFlight(from last: Motion, to motion: Motion, moving: Bool) -> Flight? {
        if let current = arc {
            arc = nil
            return advance(current, from: last, to: motion)
        }
        let time = motion.time
        let filtered = motion.vertical
        // A rider may be edging through chop, not standing still. A bounded
        // one-second window with near-zero mean vertical acceleration supplies
        // context without GPS. It never supplies height or proves takeoff.
        preparation.append(motion)
        preparation.removeAll { time - $0.time > 1.0 }
        if let first = preparation.first, time - first.time >= 0.6 {
            let mean = preparation.reduce(0.0) { $0 + $1.vertical } / Double(preparation.count)
            let supported = preparation.filter { $0.load >= 0.5 && $0.load <= 2.5 }.count
            if abs(mean) < 0.7, Double(supported) / Double(preparation.count) >= 0.85 {
                preparedUntil = time + 0.35
            }
        }
        if abs(filtered) <= 1.0 {
            if settledSince == nil { settledSince = time }
        } else if filtered >= 1.7, (time - (settledSince ?? time) >= 0.25 || time <= preparedUntil) {
            arc = Arc(began: last.time, launchSpeed: moving ? 1.15 : 1.35,
                      minimumLoad: motion.load, maximumRotation: motion.spin)
            settledSince = nil
        } else if filtered < -1.0 {
            settledSince = nil
        }
        return nil
    }

    private mutating func detectShortFlight(_ motion: Motion) -> Flight? {
        let time = motion.time, vertical = motion.vertical, load = motion.load, spin = motion.spin
        let followsPush = time - lastPush <= 0.55
        if load >= 1.55 && vertical >= 5 { lastPush = time }
        guard var flight = shortFlight else {
            if followsPush, time - lastLanding >= 0.35, (-14.0 ... -6.8).contains(vertical), load <= 1.6 {
                verticalUnloading.append(motion)
                verticalUnloading.removeAll { time - $0.time > 0.25 }
            } else { verticalUnloading.removeAll(keepingCapacity: true) }
            if load <= 0.52, followsPush, time - lastLanding >= 0.35 {
                let lead = time - (verticalUnloading.first?.time ?? time)
                let samples = lead >= 0.04 ? verticalUnloading : [motion]
                shortFlight = ShortFlight(start: samples[0].time, minimumLoad: load,
                                          maximumSpin: samples.map(\.spin).max() ?? spin, samples: samples)
                verticalUnloading.removeAll(keepingCapacity: true)
            }
            return nil
        }
        flight.maximumSpin = max(flight.maximumSpin, spin)
        if let landing = flight.landing {
            let recovery = time - landing
            guard recovery <= 0.18, load >= 0.50 else {
                shortFlight = nil
                return nil
            }
            flight.landingLoad = max(flight.landingLoad, load)
            flight.landingAcceleration = max(flight.landingAcceleration, vertical)
            if recovery >= 0.10, flight.landingLoad >= 1.65, flight.landingAcceleration >= 4 {
                shortFlight = nil
                lastPush = -.infinity
                guard landing - flight.start >= 0.22, flight.minimumLoad <= 0.22 else { return nil }
                let event = JumpCandidate(startSeconds: flight.start, endSeconds: landing,
                                          minimumLoadG: flight.minimumLoad, returnPeakG: flight.landingLoad,
                                          maximumRotationRadiansPerSecond: flight.maximumSpin)
                return Flight(event: event, trajectory: [], settledHeight: 0, residualVelocity: 0,
                              levelLandingHeight: flight.estimateHeight())
            }
        } else {
            guard time - flight.start <= 0.75 else {
                shortFlight = nil
                return nil
            }
            flight.samples.append(motion)
            flight.minimumLoad = min(flight.minimumLoad, load)
            // The pouch can swing laterally in flight. A large total load alone
            // must not cut off the ascent while the vertical axis is still unloading.
            if load >= 0.80 && vertical >= -3.0 {
                flight.landing = time
                flight.landingLoad = load
                flight.landingAcceleration = vertical
            }
        }
        shortFlight = flight
        return nil
    }

    private mutating func breakContinuity() {
        if previous != nil { discontinuities += 1 }
        previous = nil
        settledSince = nil
        arc = nil
        lastPush = -.infinity
        shortFlight = nil
        pendingShortFlight = nil
        lastLanding = -.infinity
        preparation.removeAll()
        verticalUnloading.removeAll(keepingCapacity: true)
        preparedUntil = -Double.infinity
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
        guard track.height >= -max(0.65, track.peak * 0.20) else {
            lastRejection = "trajectoryBelowTakeoff"
            arc = nil
            return nil
        }
        if let landing = track.landing {
            track.landingPeak = max(track.landingPeak, now.load)
            if track.velocity < initialVelocity - 0.10 && now.vertical < -1.0 {
                track.landing = nil
                track.recoverySince = nil
                track.landingPeak = 0
                arc = track
                return nil
            }
            let braking = track.velocity - track.landingVelocity
            let sinceContact = now.time - landing
            let fastRecovery = (0.22...0.50).contains(sinceContact) &&
                braking >= max(0.8, -track.landingVelocity * 0.55) &&
                abs(now.vertical) <= 2.2 && abs(track.velocity) <= max(1.3, -track.landingVelocity * 0.5)
            // A gradual landing can brake for longer. Require a sustained
            // return to supported, vertically settled motion near takeoff level.
            let settled = abs(track.velocity) <= 0.55 && abs(now.vertical) <= 1.8 &&
                (0.65...1.45).contains(now.load) && abs(track.height) <= max(0.4, 0.20 * track.peak)
            if settled {
                if track.recoverySince == nil { track.recoverySince = now.time }
            } else { track.recoverySince = nil }
            let softRecovery = braking >= max(0.65, -track.landingVelocity * 0.70) &&
                track.recoverySince.map { now.time - $0 >= 0.14 } == true
            if fastRecovery || softRecovery {
                let event = JumpCandidate(startSeconds: takeoff, endSeconds: landing, minimumLoadG: track.minimumLoad,
                                          returnPeakG: track.landingPeak, maximumRotationRadiansPerSecond: track.maximumRotation)
                arc = nil
                return Flight(event: event, trajectory: track.trajectory, settledHeight: track.height, residualVelocity: track.velocity)
            }
            if sinceContact >= 1.15 {
                // Reusing this arc joins later gestures to an old takeoff and
                // can turn a few movements into a multi-second false flight.
                lastRejection = "unconfirmedLanding"
                arc = nil
                return nil
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
