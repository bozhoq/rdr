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
        let standard = trace()
        let detected = run(standard)
        check(detected.count == 1, "Expected one unloading and return")
        check(abs(detected[0].unloadingSeconds - 0.5) < 1e-9, "Duration is from sensor timestamps")
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
        check(run((0..<500).map { sample(Double($0) / 100, $0 >= 50 && $0 < 400 ? 0.1 : ($0 == 400 ? 3 : 1)) }).isEmpty, "Reject excessively long unloading")

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
