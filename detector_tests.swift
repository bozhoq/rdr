import Foundation

@main
enum DetectorTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }

    static func sample(_ time: Double, _ load: Double, angle: Double = 0) -> MotionSample {
        let g = Vector3(x: sin(angle), y: 0, z: -cos(angle))
        return MotionSample(
            elapsedSinceFirstSampleSeconds: time,
            accelerationG: Vector3(x: (load - 1) * g.x, y: 0, z: (load - 1) * g.z),
            gravityG: g,
            rotationRadiansPerSecond: Vector3(x: 0, y: angle == 0 ? 0 : 15, z: 0),
            attitude: Quaternion(x: 0, y: 0, z: 0, w: 1),
            verticalAccelerationMetersPerSecondSquared: (1 - load) * -9.80665
        )
    }

    static func run(_ samples: [MotionSample]) -> [JumpCandidate] {
        var detector = JumpDetector()
        return samples.compactMap { detector.process($0) }
    }

    static func trace(lowStart: Int = 100, lowEnd: Int = 150, rotating: Bool = false, peak: Double = 3) -> [MotionSample] {
        (0..<250).map { i in
            let load = i >= lowStart && i < lowEnd ? 0.1 : (i == lowEnd ? peak : 1)
            return sample(Double(i) / 100, load, angle: rotating ? Double(i) * 0.15 : 0)
        }
    }

    static func main() throws {
        var altitude = AltitudeMetrics(supported: true)
        let first = AltitudeSample(elapsedSinceFirstSampleSeconds: 1, pressureKilopascals: 100, relativeAltitudeMeters: 0)
        let upper = AltitudeSample(elapsedSinceFirstSampleSeconds: 3, pressureKilopascals: 99.96, relativeAltitudeMeters: 3.4)
        let lower = AltitudeSample(elapsedSinceFirstSampleSeconds: 4, pressureKilopascals: 100.01, relativeAltitudeMeters: -0.2)
        check(altitude.add(first) && altitude.add(upper) && altitude.add(lower), "Record signed altitude samples on the motion timeline")
        check(!altitude.add(upper), "Reject altitude timestamps that move backwards")
        check(!altitude.add(AltitudeSample(elapsedSinceFirstSampleSeconds: 5, pressureKilopascals: .nan, relativeAltitudeMeters: 0)), "Drop invalid pressure")
        let altitudeData = try JSONEncoder().encode(altitude)
        let restoredAltitude = try JSONDecoder().decode(AltitudeMetrics.self, from: altitudeData)
        check(restoredAltitude.count == 3 && restoredAltitude.lowestMeters == -0.2 && restoredAltitude.highestMeters == 3.4 && restoredAltitude.longestIntervalSeconds == 2, "Restore barometer range and interval from checkpoint")

        let still = (0...500).map { sample(Double($0) / 100, 1.02) }
        let calibration = try MotionCalibration.measure(still)
        let original = still[0].verticalAccelerationMetersPerSecondSquared
        check(abs(calibration.frequencyHz - 100) < 0.001 && abs(calibration.correctedVertical(original, at: 6)) < 1e-9, "Calibrate a stable nonzero baseline")
        check(calibration.correctedVertical(original, at: 5) == original, "Calibration respects the sample boundary")
        var shaking = still
        shaking[100] = sample(1, 1.02, angle: 0.5)
        do { _ = try MotionCalibration.measure(shaking); check(false, "Motion must invalidate calibration") }
        catch MotionCalibration.Failure.movement { check(true, "Reject rotation during the baseline") }
        var calibrationGap = still
        calibrationGap.removeSubrange(100..<110)
        do { _ = try MotionCalibration.measure(calibrationGap); check(false, "A clock gap must invalidate calibration") }
        catch MotionCalibration.Failure.timing { check(true, "Reject gaps even when average sensor rate is high") }

        let standard = trace()
        let detected = run(standard)
        check(detected.count == 1, "Expected one unloading and return")
        check(abs(detected[0].unloadingSeconds - 0.5) < 1e-9, "Duration is from sensor timestamps")
        let toss = detected[0]
        check(abs((toss.approximateTossHeightMeters(label: .phoneToss) ?? 0) - 0.3064578125) < 1e-9, "Toss estimate uses same-height ballistic model")
        for label in [JumpLabel.unreviewed, .bodyJump, .otherMovement] {
            check(toss.approximateTossHeightMeters(label: label) == nil, "Estimate is restricted to labeled phone tosses")
        }
        let badToss = JumpCandidate(startSeconds: 2, endSeconds: 1, minimumLoadG: 0.1, returnPeakG: 3, maximumRotationRadiansPerSecond: 0)
        check(badToss.approximateTossHeightMeters(label: .phoneToss) == nil, "Invalid time cannot produce height")
        let rotated = run(trace(rotating: true))
        check(rotated.count == 1 && abs(rotated[0].unloadingSeconds - 0.5) < 1e-9, "Rotation invariance")
        check(rotated[0].fastRotation, "Rotation is flagged, not automatically rejected")
        check(run((0..<300).map { sample(Double($0) / 100, 1, angle: Double($0) * 0.1) }).isEmpty, "Rotating gravity alone is not a jump")
        check(run(trace(lowEnd: 112)).isEmpty, "Reject brief unloading")
        check(run(trace(lowEnd: 121)).isEmpty, "Reject sub-220ms event")
        check(run(trace(peak: 1)).isEmpty, "Require a return impulse")
        check(run(trace(lowStart: 0)).isEmpty, "Do not infer takeoff before recording")
        check(run(Array(standard.prefix(145))).isEmpty, "Do not invent landing at EOF")
        check(run((0..<250).map { sample(Double($0) / 100, $0 == 100 ? 15 : 1) }).isEmpty, "Impact alone is not a jump")
        let longUnloading: [MotionSample] = (0..<500).map { i in
            let load: Double
            if i >= 50 && i < 400 { load = 0.1 }
            else if i == 400 { load = 3 }
            else { load = 1 }
            return sample(Double(i) / 100, load)
        }
        check(run(longUnloading).isEmpty, "Reject excessively long unloading")

        var gap = standard
        gap.removeSubrange(120..<140)
        check(run(gap).isEmpty, "Never bridge a sensor gap")
        var invalid = standard
        invalid[120] = sample(1.2, .nan)
        check(run(invalid).isEmpty, "Invalid sample breaks the episode")
        var reversed = standard
        reversed[120] = sample(1.0, 0.1)
        check(run(reversed).isEmpty, "Reversed time breaks the episode")
        var duplicate = standard
        duplicate.insert(standard[120], at: 121)
        check(run(duplicate).isEmpty, "Duplicate time breaks the episode")

        let two = standard + standard.map { original in
            sample(original.elapsedSinceFirstSampleSeconds + 2.5,
                   sqrt(pow(original.accelerationG.z + original.gravityG.z, 2)))
        }
        check(run(two).count == 2, "Rearm after recovery")
        var rebound = standard
        for i in 155..<190 { rebound[i] = sample(Double(i) / 100, 0.1) }
        rebound[190] = sample(1.9, 3)
        check(run(rebound).count == 1, "Suppress immediate rebound")
        var jitter = standard
        jitter[120] = sample(1.2, 0.5)
        check(run(jitter).count == 1, "Hysteresis tolerates threshold noise")

        // Summary migration: old metadata remains readable, and new results survive JSON roundtrip.
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","startedAt":1000,"gpsEnabledAtStart":false,"status":"finished","durationSeconds":2.5,"motion":{"count":250,"gapsOver100ms":0},"locationCount":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var summary = try decoder.decode(SessionSummary.self, from: Data(legacy.utf8))
        check(summary.jumpAnalysis == nil, "Old sessions decode without detector fields")
        summary.jumpAnalysis = JumpAnalysis(candidates: detected)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(SessionSummary.self, from: encoder.encode(summary))
        check(restored.id == summary.id && restored.jumpAnalysis?.candidates.count == 1, "Preserve session identity and results")
        check(restored.review == nil && restored.markers == nil, "Old summaries load without review or markers")

        // Replaying generates fresh event UUIDs: user labels must follow the
        // sensor interval, and never silently transfer to a changed algorithm.
        var review = SessionReview(title: "Тест прогулки", notes: "Телефон свободно в чехле")
        review.setLabel(.phoneToss, for: detected[0], version: JumpDetector.version)
        let replayedCandidate = run(standard)[0]
        check(replayedCandidate.id != detected[0].id, "Replay generates new event UUID")
        check(review.label(for: replayedCandidate, version: JumpDetector.version) == .phoneToss, "Label survives replay")
        check(review.label(for: replayedCandidate, version: "future-version") == .unreviewed, "No label transfer to a new detector")
        review.setLabel(.unreviewed, for: replayedCandidate, version: JumpDetector.version)
        check(review.labels.isEmpty, "User can clear a label")

        // Disk integration verifies that edits/replay don't overwrite one another
        // or mutate the original log, and that results are exported from current metadata.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rider-store-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        summary.markers = [SessionMarker(elapsedSeconds: 1.1, kind: .phoneToss)]
        let writer = try store.makeLog(for: summary)
        try writer.writeStart(summary, systemVersion: "synthetic-test")
        writer.close()
        let rawBefore = try Data(contentsOf: store.logURL(for: summary.id))
        try store.saveNotes(title: "  Тест прогулки  ", notes: "Телефон свободно в чехле", for: summary.id)
        try store.saveLabel(.phoneToss, candidateID: detected[0].id, for: summary.id)
        try store.saveAnalysis(JumpAnalysis(candidates: [replayedCandidate]), for: summary.id)
        let stored = try store.history()[0]
        check(stored.review?.title == "Тест прогулки", "Title is trimmed and preserved through replay")
        check(stored.review?.notes == "Телефон свободно в чехле", "Notes preserved through label and replay edits")
        check(stored.review?.label(for: replayedCandidate, version: JumpDetector.version) == .phoneToss, "Stored label survives replay")
        check(stored.markers?.count == 1 && stored.markers?[0].elapsedSeconds == 1.1, "Marker persists through edits")
        check(stored.matches("ПРОГУЛКИ") && stored.matches("чехле"), "Search matches titles and notes case-insensitively")
        check(stored.matches("  ") && !stored.matches("несуществующее"), "Empty search and no-match search")
        let rawAfter = try Data(contentsOf: store.logURL(for: summary.id))
        check(rawBefore == rawAfter, "Review and replay never rewrite raw log")
        let reportData = try SessionReport.data(for: stored)
        let report = try JSONSerialization.jsonObject(with: reportData) as! [String: Any]
        check(report["kind"] as? String == "rider-session-result", "Export has identifiable schema")
        let exported = report["session"] as! [String: Any]
        let exportedReview = exported["review"] as! [String: Any]
        check(exportedReview["title"] as? String == "Тест прогулки", "Export contains latest review")
        check((exported["markers"] as? [[String: Any]])?.count == 1, "Export includes markers")
        check(exported["latitude"] == nil && exported["longitude"] == nil && exported["locations"] == nil, "Report has no raw GPS coordinates")
        let exportedAnalysis = exported["jumpAnalysis"] as! [String: Any]
        check((exportedAnalysis["candidates"] as? [[String: Any]])?.count == 1, "Export contains replay results")
        try store.saveNotes(title: String(repeating: "а", count: 120), notes: String(repeating: "б", count: 4200), for: summary.id)
        let limited = try store.history()[0]
        check(limited.review?.title.count == 100 && limited.review?.notes.count == 4000, "Bound note sizes in storage as well as UI")
        check(limited.review?.label(for: replayedCandidate, version: JumpDetector.version) == .phoneToss, "Changing notes preserves labels")
        do {
            try store.saveLabel(.bodyJump, candidateID: UUID(), for: summary.id)
            fatalError("Unknown candidate must not be silently annotated")
        } catch { checks += 1 }
        let reportURL = try SessionReport.write(stored)
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let savedReport = try Data(contentsOf: reportURL)
        check(savedReport == reportData, "Share file matches the current report snapshot")

        struct Row: Encodable { let type = "motion"; let data: MotionSample }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rider-tests-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data()
        for s in standard {
            bytes.append(try encoder.encode(Row(data: s)))
            bytes.append(10)
        }
        try bytes.write(to: url)
        let replay = try JumpReplay.analyze(url: url)
        check(replay.candidates.count == detected.count, "Live and file replay agree")
        check(replay.candidates[0].startSeconds == detected[0].startSeconds, "Replay timestamps agree")
        bytes.append(Data("{\"type\":\"motion\",\"data\":".utf8))
        try bytes.write(to: url)
        let truncated = try JumpReplay.analyze(url: url)
        check(truncated.candidates.count == 1 && truncated.discontinuities == 1, "Reboot-truncated tail preserves completed events")

        // The fixtures are generated exclusively from synthetic motion by Python.
        // Real user logs and GPS never leave the user's machine.
        struct Expected: Decodable {
            let startSeconds: Double
            let endSeconds: Double
            let minimumLoadG: Double
            let returnPeakG: Double
            let maximumRotationRadiansPerSecond: Double
        }
        struct Fixture: Decodable {
            let samples: [MotionSample]
            let expected: [Expected]
            let discontinuities: Int
        }
        if CommandLine.arguments.count > 1 {
            let fixtures = try decoder.decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            for (index, fixture) in fixtures.enumerated() {
                var detector = JumpDetector()
                let actual = fixture.samples.compactMap { detector.process($0) }
                check(actual.count == fixture.expected.count, "Python/Swift event count, case \(index)")
                check(detector.discontinuities == fixture.discontinuities, "Python/Swift discontinuities, case \(index)")
                for (a, e) in zip(actual, fixture.expected) {
                    check(abs(a.startSeconds - e.startSeconds) < 1e-9 && abs(a.endSeconds - e.endSeconds) < 1e-9, "Python/Swift timing")
                    check(abs(a.minimumLoadG - e.minimumLoadG) < 1e-9 && abs(a.returnPeakG - e.returnPeakG) < 1e-9, "Python/Swift load")
                    check(abs(a.maximumRotationRadiansPerSecond - e.maximumRotationRadiansPerSecond) < 1e-9, "Python/Swift rotation")
                }
            }
        }
        print("PASS: \(checks) detector checks")
    }
}
