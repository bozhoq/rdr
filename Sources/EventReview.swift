import Foundation

struct MotionWindowPoint: Identifiable, Sendable {
    let id: Int
    let seconds: Double
    let loadG: Double
    let rotation: Double
    let segment: Int
}

struct MotionWindow: Sendable {
    let lower: Double
    let upper: Double
    let points: [MotionWindowPoint]
    let gaps: Int
    let rejected: Int
}

struct MotionWindowCollector {
    let lower: Double
    let upper: Double
    private(set) var points: [MotionWindowPoint] = []
    private(set) var gaps = 0
    private(set) var rejected = 0
    private var segment = 0
    private var previous: Double?
    private var latestSeen: Double?
    private var passedWindow = false

    init(candidate: JumpCandidate) throws {
        guard candidate.startSeconds.isFinite, candidate.endSeconds.isFinite,
              candidate.startSeconds >= 0, candidate.endSeconds >= candidate.startSeconds,
              candidate.unloadingSeconds <= 30 else { throw CocoaError(.fileReadCorruptFile) }
        lower = max(0, candidate.startSeconds - 2)
        upper = candidate.endSeconds + 2
    }

    mutating func breakContinuity() {
        if !points.isEmpty && !passedWindow { gaps += 1 }
        previous = nil
        segment += 1
    }

    mutating func consume(_ sample: MotionSample) throws {
        let time = sample.elapsedSinceFirstSampleSeconds
        guard time.isFinite else { breakContinuity(); return }
        if time > upper { passedWindow = true; previous = nil; return }
        guard time >= lower, !passedWindow else { return }
        guard latestSeen.map({ time > $0 }) ?? true else {
            rejected += 1; breakContinuity(); return
        }
        latestSeen = time
        let a = sample.accelerationG, g = sample.gravityG, r = sample.rotationRadiansPerSecond
        let components = [a.x, a.y, a.z, g.x, g.y, g.z, r.x, r.y, r.z]
        let load = sqrt(pow(a.x + g.x, 2) + pow(a.y + g.y, 2) + pow(a.z + g.z, 2))
        let rotation = sqrt(r.x*r.x + r.y*r.y + r.z*r.z)
        guard components.allSatisfy(\.isFinite), load.isFinite, rotation.isFinite,
              g.x*g.x + g.y*g.y + g.z*g.z > 0 else {
            rejected += 1; breakContinuity(); return
        }
        if let previous, time - previous > 0.05 { breakContinuity() }
        // Preserve every accepted 100 Hz sample around the event, not a smooth
        // interpolation. A bad/gapped sample always starts a separate series.
        guard points.count < 6000 else { throw CocoaError(.fileReadTooLarge) }
        points.append(MotionWindowPoint(id: points.count, seconds: time, loadG: load, rotation: rotation, segment: segment))
        previous = time
    }

    var result: MotionWindow { MotionWindow(lower: lower, upper: upper, points: points, gaps: gaps, rejected: rejected) }
}

enum EventReplay {
    private struct Header: Decodable { let type: String }
    private struct Entry: Decodable { let data: MotionSample }

    static func load(url: URL, candidate: JumpCandidate) throws -> MotionWindow {
        var collector = try MotionWindowCollector(candidate: candidate)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var buffer = Data()
        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            let sample: MotionSample
            do {
                let type = try decoder.decode(Header.self, from: line).type
                guard type == "motion" else { return }
                sample = try decoder.decode(Entry.self, from: line).data
            } catch { collector.breakContinuity(); return }
            try collector.consume(sample)
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                try consume(Data(buffer[..<end]))
                buffer.removeSubrange(...end)
            }
            if buffer.count > 1_048_576 { throw CocoaError(.fileReadCorruptFile) }
        }
        if !buffer.isEmpty { try consume(buffer) }
        return collector.result
    }
}

/// Explicit public-card fields: no raw log, route, session ID, title, notes,
/// equipment or spot. The preview shows exactly what will leave the phone.
struct SessionCardData: Encodable {
    let date: Date
    let sport: String
    let duration: Double
    let distanceMeters: Double?
    let speedMetersPerSecond: Double?
    let candidateCount: Int
    let markedJumps: Int

    init(session: SessionSummary) {
        date = session.startedAt
        sport = session.setup?.sport.title ?? "Сессия"
        duration = session.durationSeconds
        if let gps = session.gpsMetrics {
            distanceMeters = gps.accepted > 0 ? gps.distanceMeters : nil
            speedMetersPerSecond = gps.maxSpeedMetersPerSecond
        } else {
            distanceMeters = session.distanceMeters
            speedMetersPerSecond = session.maxSpeedMetersPerSecond
        }
        candidateCount = session.jumpAnalysis?.candidates.count ?? 0
        if let analysis = session.jumpAnalysis, let review = session.review {
            markedJumps = analysis.candidates.filter { review.label(for: $0, version: analysis.detectorVersion) == .bodyJump }.count
        } else { markedJumps = 0 }
    }
}

struct SetupSuggestions {
    let spots: [String]
    let kites: [String]
    let boards: [String]
    init(history: [SessionSummary]) {
        let setups = history.sorted { $0.startedAt > $1.startedAt }.compactMap(\.setup)
        func unique(_ key: KeyPath<SessionSetup, String>) -> [String] {
            var seen = Set<String>()
            var values: [String] = []
            for setup in setups {
                let value = setup.cleaned[keyPath: key]
                let normalized = value.folding(options: [.caseInsensitive], locale: Locale(identifier: "ru_RU"))
                if !value.isEmpty && seen.insert(normalized).inserted { values.append(value) }
                if values.count == 12 { break }
            }
            return values
        }
        spots = unique(\.spot)
        kites = unique(\.kite)
        boards = unique(\.board)
    }
}
