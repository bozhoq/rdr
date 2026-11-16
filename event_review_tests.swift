import Foundation

@main enum EventReviewTests {
    static var checks = 0
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !ok() { fatalError(message) }
    }
    static func sample(_ time: Double, load: Double = 1, angle: Double = 0, spin: Double = 2) -> MotionSample {
        let g = Vector3(x: sin(angle), y: 0, z: -cos(angle))
        return MotionSample(elapsedSinceFirstSampleSeconds: time,
            accelerationG: Vector3(x: (load - 1)*g.x, y: 0, z: (load - 1)*g.z),
            gravityG: g, rotationRadiansPerSecond: Vector3(x: 0, y: spin, z: 0),
            attitude: Quaternion(x: 0, y: 0, z: 0, w: 1), verticalAccelerationMetersPerSecondSquared: 0)
    }
    static func candidate(_ start: Double = 3, _ end: Double = 3.5) -> JumpCandidate {
        JumpCandidate(startSeconds: start, endSeconds: end, minimumLoadG: 0.1, returnPeakG: 3, maximumRotationRadiansPerSecond: 2)
    }
    static func main() throws {
        let event = candidate()
        var collector = try MotionWindowCollector(candidate: event)
        for i in 0..<700 { try collector.consume(sample(Double(i)/100, load: i >= 300 && i < 350 ? 0.1 : 1)) }
        let window = collector.result
        check(window.lower == 1 && window.upper == 5.5, "Two seconds of context on either side")
        check(window.points.count == 451, "Only inclusive event window retained")
        check(window.points.first?.seconds == 1 && window.points.last?.seconds == 5.5, "Exact sensor timestamps")
        check(window.gaps == 0, "Continuous 100 Hz signal has no gaps")
        check(window.points.filter { $0.loadG < 0.4 }.count == 50, "No smoothing of short low-load interval")
        for angle in [0.0, 0.5, 1.0, 2.0, 3.14, 6.28] {
            var rotated = try MotionWindowCollector(candidate: event)
            try rotated.consume(sample(3, load: 0.3, angle: angle, spin: -4))
            check(abs(rotated.result.points[0].loadG - 0.3) < 1e-10, "Load independent of device coordinates")
            check(rotated.result.points[0].rotation == 4, "Magnitude of rotation")
        }
        var broken = try MotionWindowCollector(candidate: event)
        try broken.consume(sample(3))
        try broken.consume(sample(3.1))
        check(broken.result.gaps == 1 && broken.result.points[0].segment != broken.result.points[1].segment, "Missing samples split chart")
        try broken.consume(sample(3.1))
        try broken.consume(sample(3.05))
        try broken.consume(sample(3.11, load: .nan))
        try broken.consume(sample(3.12))
        check(broken.result.rejected == 3 && broken.result.points.count == 3, "Bad load and duplicate/reversed time rejected")
        check(broken.result.points[2].segment != broken.result.points[1].segment, "Do not bridge invalid data")
        let edge = try MotionWindowCollector(candidate: candidate(0.1, 0.4))
        check(edge.lower == 0, "No negative window at recording start")
        for invalid in [candidate(-1, 1), candidate(4, 3), candidate(1, 100), candidate(.nan, 4)] {
            do { _ = try MotionWindowCollector(candidate: invalid); fatalError("Bad event must fail") }
            catch { checks += 1 }
        }
        var oversized = try MotionWindowCollector(candidate: candidate(3, 3.5))
        do {
            for i in 0..<6001 { try oversized.consume(sample(1 + Double(i)*0.0001)) }
            fatalError("Unbounded sample count")
        } catch { checks += 1 }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rider-event-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("old.jsonl")
        struct Entry: Encodable { let type = "motion"; let data: MotionSample }
        let encoder = JSONEncoder()
        var data = Data()
        for i in 0..<700 {
            if i == 320 { data.append(Data("{broken line}\n".utf8)); continue }
            data.append(try encoder.encode(Entry(data: sample(Double(i)/100))))
            data.append(10)
            if i == 330 { data.append(Data("{\"type\":\"marker\",\"data\":{}}\n".utf8)) }
        }
        data.append(Data("{\"type\":".utf8))
        try data.write(to: url)
        let replay = try EventReplay.load(url: url, candidate: event)
        check(replay.points.count == 450, "Old JSONL replay reads only window")
        check(replay.gaps == 1, "Malformed line splits chart; unrelated marker does not; EOF outside window ignored")
        let reread = try Data(contentsOf: url)
        check(reread == data, "Review never mutates raw data")
        try Data().write(to: url)
        let empty = try EventReplay.load(url: url, candidate: event)
        check(empty.points.isEmpty, "Empty log gives empty window")

        var session = SessionSummary(startedAt: Date(timeIntervalSince1970: 100), gpsEnabledAtStart: true, batteryAtStartPercent: nil)
        session.durationSeconds = 100
        session.status = .finished
        session.setup = SessionSetup(sport: .groundTest, spot: "PRIVATE_SPOT", kite: "PRIVATE_GEAR")
        session.review = SessionReview(title: "PRIVATE_TITLE", notes: "PRIVATE_NOTES")
        session.jumpAnalysis = JumpAnalysis(candidates: [event, candidate(5, 5.5)])
        session.review?.setLabel(.bodyJump, for: event, version: JumpDetector.version)
        session.review?.setLabel(.phoneToss, for: session.jumpAnalysis!.candidates[1], version: JumpDetector.version)
        session.distanceMeters = 1000
        session.maxSpeedMetersPerSecond = 8
        let card = SessionCardData(session: session)
        check(card.markedJumps == 1 && card.candidateCount == 2, "Card distinguishes user marks from candidates")
        check(card.sport == "Тест на земле" && card.duration == 100, "Card clearly states test sport")
        let json = String(decoding: try encoder.encode(card), as: UTF8.self)
        for secret in ["PRIVATE_SPOT", "PRIVATE_GEAR", "PRIVATE_TITLE", "PRIVATE_NOTES", "latitude", "longitude", session.id.uuidString] {
            check(!json.contains(secret), "Card omits private fields")
        }
        session.gpsMetrics = RouteMetrics()
        let missingGPS = SessionCardData(session: session)
        check(missingGPS.distanceMeters == nil && missingGPS.speedMetersPerSecond == nil, "No obsolete GPS fallback")
        session.jumpAnalysis = nil
        check(SessionCardData(session: session).markedJumps == 0, "No stale jump count without current analysis")

        var old = session
        old.setup = SessionSetup(spot: "  Spot One ", kite: "Nine", board: "Board A")
        var newer = SessionSummary(startedAt: Date(timeIntervalSince1970: 200), gpsEnabledAtStart: false, batteryAtStartPercent: nil)
        newer.setup = SessionSetup(spot: "spot one", kite: "Twelve", board: "board a")
        let suggestions = SetupSuggestions(history: [old, newer])
        check(suggestions.spots == ["spot one"], "Recent casing wins and whitespace trimmed")
        check(suggestions.kites == ["Twelve", "Nine"], "Recent-first gear")
        check(suggestions.boards == ["board a"], "Board deduplication")
        var many: [SessionSummary] = []
        for i in 0..<30 {
            var s = SessionSummary(startedAt: Date(timeIntervalSince1970: Double(i)), gpsEnabledAtStart: false, batteryAtStartPercent: nil)
            s.setup = SessionSetup(spot: " \(i) ", kite: "", board: "   ")
            many.append(s)
        }
        let limited = SetupSuggestions(history: many)
        check(limited.spots.count == 12 && limited.spots.first == "29", "Recent suggestions capped")
        check(limited.kites.isEmpty && limited.boards.isEmpty, "Empty values excluded")
        check(SetupSuggestions(history: []).spots.isEmpty, "Empty history")
        print("PASS: \(checks) event review, public card and recent gear checks")
    }
}
