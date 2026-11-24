import Foundation

struct MotionMetrics: Codable {
    private(set) var count = 0
    private(set) var lastElapsedSeconds: Double?
    private(set) var longestIntervalSeconds: Double?
    private(set) var gapsOver100ms = 0

    var averageHz: Double? {
        guard let elapsed = lastElapsedSeconds, elapsed > 0 else { return nil }
        return Double(count - 1) / elapsed
    }

    mutating func add(_ elapsed: Double) {
        if let last = lastElapsedSeconds {
            let interval = elapsed - last
            longestIntervalSeconds = max(longestIntervalSeconds ?? 0, interval)
            if interval > 0.1 { gapsOver100ms += 1 }
        }
        lastElapsedSeconds = elapsed
        count += 1
    }
}

struct AltitudeSample: Codable {
    let elapsedSinceFirstSampleSeconds: Double
    let pressureKilopascals: Double
    let relativeAltitudeMeters: Double
}

struct AltitudeMetrics: Codable {
    let supported: Bool
    var stoppedWithError = false
    private(set) var count = 0
    private(set) var lastElapsedSeconds: Double?
    private(set) var longestIntervalSeconds: Double?
    private(set) var latestMeters: Double?
    private(set) var lowestMeters: Double?
    private(set) var highestMeters: Double?

    init(supported: Bool) {
        self.supported = supported
    }

    mutating func add(_ sample: AltitudeSample) -> Bool {
        let time = sample.elapsedSinceFirstSampleSeconds
        let meters = sample.relativeAltitudeMeters
        guard supported, !stoppedWithError, time.isFinite, time >= 0,
              sample.pressureKilopascals.isFinite, sample.pressureKilopascals > 0,
              meters.isFinite else { return false }
        if let lastElapsedSeconds {
            guard time > lastElapsedSeconds else { return false }
            longestIntervalSeconds = max(longestIntervalSeconds ?? 0, time - lastElapsedSeconds)
        }
        lastElapsedSeconds = time
        latestMeters = meters
        lowestMeters = min(lowestMeters ?? meters, meters)
        highestMeters = max(highestMeters ?? meters, meters)
        count += 1
        return true
    }
}

struct SessionSummary: Codable, Identifiable {
    enum Status: String, Codable {
        case recording, finished, interrupted
    }

    var id = UUID()
    let startedAt: Date
    let gpsEnabledAtStart: Bool
    let batteryAtStartPercent: Int?
    var status: Status = .recording
    var durationSeconds = 0.0
    var motion = MotionMetrics()
    var locationCount = 0
    var distanceMeters: Double?
    var maxSpeedMetersPerSecond: Double?
    var batteryAtCheckpointPercent: Int?
    // Optional for backwards-compatible decoding of existing session summaries.
    var jumpAnalysis: JumpAnalysis?
    var review: SessionReview?
    var markers: [SessionMarker]?
    var setup: SessionSetup?
    var gpsMetrics: RouteMetrics?
    var altitude: AltitudeMetrics?
    var motionCalibration: MotionCalibration?
    var liveJumpEstimates: [String: LiveJumpEstimate]?
    var phoneTossTest: Bool?
    var handSimulationTest: Bool?
    var reusedMotionCalibration: Bool?
    var recordingMode: RecordingMode?
    var sensors: RecordingSensors?
    var automaticConditions: Bool?
    var wind: SessionWind?

    var canReplayGroundEvents: Bool {
        handSimulationTest != true && (jumpAnalysis?.detectorVersion ?? JumpDetector.version) == JumpDetector.version
    }

    func liveEstimate(for event: JumpCandidate) -> LiveJumpEstimate? {
        guard let version = jumpAnalysis?.detectorVersion else { return nil }
        guard let estimate = liveJumpEstimates?[SessionReview.key(for: event, version: version)] else { return nil }
        let label = review?.label(for: event, version: version)
        guard label != .otherMovement else { return nil }
        if handSimulationTest == true { return estimate }
        if estimate.isPhoneToss == true { return label == .bodyJump ? nil : estimate }
        return label == .phoneToss ? nil : estimate
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [review?.title ?? "", review?.notes ?? "", setup?.spot ?? "", setup?.kiteTitle ?? "", setup?.boardTitle ?? "", setup?.activityTitle ?? ""]
            .contains { $0.localizedStandardContains(query) }
    }
}

struct SessionWind: Codable {
    var knots: Double
    var gust: Double?
    var direction: Double?
    var date: Date
    var source: String

    var title: String {
        let directionText = direction.map { " · " + SpotForecast.compass($0) } ?? ""
        return knots.formatted(.number.precision(.fractionLength(0...1))) + " уз" + directionText
    }
}

struct RecordingSensors: Codable {
    let accelerometer: Bool
    let gyroscope: Bool
    let deviceMotion: Bool
    let barometer: Bool
    let locationAllowed: Bool
    var motionResponded: Bool?
    var pressureResponded: Bool?
}

enum JumpLabel: String, Codable, CaseIterable {
    case unreviewed, bodyJump, phoneToss, otherMovement

    var title: String {
        switch self {
        case .unreviewed: return "Не отмечено"
        case .bodyJump: return "Прыжок человека"
        case .phoneToss: return "Подброс телефона"
        case .otherMovement: return "Другое движение"
        }
    }
}

struct SessionReview: Codable {
    var title = ""
    var notes = ""
    var labels: [String: JumpLabel] = [:]

    // UUIDs change on replay. Sensor times and detector version identify the
    // same event; a future changed detector cannot silently inherit its label.
    static func key(for candidate: JumpCandidate, version: String) -> String {
        let start = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), candidate.startSeconds)
        let end = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), candidate.endSeconds)
        return "\(version):\(start):\(end)"
    }

    func label(for candidate: JumpCandidate, version: String) -> JumpLabel {
        labels[Self.key(for: candidate, version: version)] ?? .unreviewed
    }

    mutating func setLabel(_ label: JumpLabel, for candidate: JumpCandidate, version: String) {
        let key = Self.key(for: candidate, version: version)
        if label == .unreviewed { labels.removeValue(forKey: key) }
        else { labels[key] = label }
    }
}

enum MarkerKind: String, Codable, CaseIterable {
    case walking, running, bodyJumps, phoneToss, caseMovement, other

    var title: String {
        switch self {
        case .walking: return "Ходьба"
        case .running: return "Бег"
        case .bodyJumps: return "Прыжки на месте"
        case .phoneToss: return "Подброс телефона"
        case .caseMovement: return "Движение чехла"
        case .other: return "Другое упражнение"
        }
    }
}

struct SessionMarker: Codable, Identifiable {
    var id = UUID()
    let elapsedSeconds: Double
    let kind: MarkerKind
}

/// Snapshot of the latest summary, including replay results and manual labels.
/// The raw log is never read here, so automatic GPS coordinates cannot leak in.
enum SessionReport {
    private struct Report: Encodable {
        let formatVersion = 1
        let kind = "rider-session-result"
        let interpretation = "Experimental candidates, not validated airtime or height. Labels are supplied by the user. Marker times refer to the first motion sample."
        let session: SessionSummary
    }

    static func data(for session: SessionSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(Report(session: session))
    }

    static func write(_ session: SessionSummary) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rider-result-\(session.id)-\(UUID()).json")
        try data(for: session).write(to: url, options: .atomic)
        return url
    }
}

struct Vector3: Codable {
    let x: Double
    let y: Double
    let z: Double
}

struct Quaternion: Codable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double
}

struct MotionSample: Codable {
    let elapsedSinceFirstSampleSeconds: Double
    let accelerationG: Vector3
    let gravityG: Vector3
    let rotationRadiansPerSecond: Vector3
    let attitude: Quaternion
    let verticalAccelerationMetersPerSecondSquared: Double

    // The stored projection in legacy and current logs has the opposite sign
    // from upward physical acceleration. Keep the JSON convention stable.
    var upwardAcceleration: Double { -verticalAccelerationMetersPerSecondSquared }
}

struct MotionCalibration: Codable {
    static let durationSeconds: Double = 3

    let completedAtSeconds: Double
    let frequencyHz: Double
    let verticalOffset: Double
    let verticalNoise: Double

    enum Failure: Error {
        case timing, movement

        var message: String {
            switch self {
            case .timing: return "Замеры шли с пропусками или слишком редко. Повторите калибровку."
            case .movement: return "Телефон двигался. Закрепите его и замрите на 3 секунды."
            }
        }
    }

    static func measure(_ samples: [MotionSample]) throws -> Self {
        guard let first = samples.first, let last = samples.last else { throw Failure.timing }
        let span = last.elapsedSinceFirstSampleSeconds - first.elapsedSinceFirstSampleSeconds
        let frequency = Double(samples.count - 1) / span
        guard span.isFinite, span >= durationSeconds, frequency >= 90 else { throw Failure.timing }

        var previous = first.elapsedSinceFirstSampleSeconds
        var sum = 0.0, squares = 0.0
        for (index, sample) in samples.enumerated() {
            let time = sample.elapsedSinceFirstSampleSeconds
            let gap = time - previous
            guard gap.isFinite, (index == 0 || gap > 0), gap <= 0.05 else { throw Failure.timing }
            previous = time
            let a = sample.accelerationG
            let r = sample.rotationRadiansPerSecond
            let acceleration = (a.x*a.x + a.y*a.y + a.z*a.z).squareRoot()
            let rotation = (r.x*r.x + r.y*r.y + r.z*r.z).squareRoot()
            let vertical = sample.verticalAccelerationMetersPerSecondSquared
            guard acceleration <= 0.10, rotation <= 0.30, vertical.isFinite else { throw Failure.movement }
            sum += vertical
            squares += vertical * vertical
        }
        let offset = sum / Double(samples.count)
        let noise = max(0, squares / Double(samples.count) - offset * offset).squareRoot()
        guard abs(offset) <= 0.30, noise <= 0.20 else { throw Failure.movement }
        return Self(completedAtSeconds: last.elapsedSinceFirstSampleSeconds, frequencyHz: frequency,
                    verticalOffset: offset, verticalNoise: noise)
    }

    func correctedVertical(_ raw: Double, at seconds: Double) -> Double {
        seconds > completedAtSeconds ? raw - verticalOffset : raw
    }
}

struct SavedMotionCalibration: Codable {
    let measurement: MotionCalibration
    let measuredAt: Date
    let systemVersion: String

    func usable(at now: Date, systemVersion: String) -> MotionCalibration? {
        guard self.systemVersion == systemVersion, (0...30 * 86_400).contains(now.timeIntervalSince(measuredAt)),
              measurement.verticalOffset.isFinite, abs(measurement.verticalOffset) <= 0.30,
              (90...200).contains(measurement.frequencyHz), (0...0.20).contains(measurement.verticalNoise) else { return nil }
        return MotionCalibration(completedAtSeconds: 0, frequencyHz: measurement.frequencyHz,
                                 verticalOffset: measurement.verticalOffset, verticalNoise: measurement.verticalNoise)
    }
}

struct LocationSample: Codable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double
    let speedMetersPerSecond: Double?
    let speedAccuracyMetersPerSecond: Double?
}

struct SessionEvent: Encodable {
    let name: String
    let batteryPercent: Int?
    var detail: String?
}

final class SessionStore {
    private let files = FileManager.default
    private let root: URL

    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("Sessions", isDirectory: true)) {
        self.root = root
    }

    func makeLog(for summary: SessionSummary) throws -> SessionLog {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = self.directory(for: summary.id)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            var localDirectory = directory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try localDirectory.setResourceValues(resources)
            return try SessionLog(directory: directory, summary: summary)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func history() throws -> [SessionSummary] {
        guard files.fileExists(atPath: root.path) else { return [] }
        let directories = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return directories.compactMap { directory -> SessionSummary? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("summary.json")),
                  var summary = try? decoder.decode(SessionSummary.self, from: data),
                  directory.lastPathComponent == summary.id.uuidString else { return nil }
            if summary.status == .recording { summary.status = .interrupted }
            return summary
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func logURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("session-\(id.uuidString).jsonl")
    }

    func saveAnalysis(_ analysis: JumpAnalysis, for id: UUID) throws {
        try updateSummary(id) { $0.jumpAnalysis = analysis }
    }

    func saveSetup(_ setup: SessionSetup, for id: UUID) throws {
        try updateSummary(id) { $0.setup = setup.cleaned }
    }

    func saveGPSMetrics(_ metrics: RouteMetrics, for id: UUID) throws {
        try updateSummary(id) { $0.gpsMetrics = metrics }
    }

    func saveNotes(title: String, notes: String, for id: UUID) throws {
        try updateSummary(id) { summary in
            var review = summary.review ?? SessionReview()
            review.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            review.notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
            summary.review = review
        }
    }

    func saveLabel(_ label: JumpLabel, candidateID: UUID, for id: UUID) throws {
        try updateSummary(id) { summary in
            guard let analysis = summary.jumpAnalysis,
                  let candidate = analysis.candidates.first(where: { $0.id == candidateID }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var review = summary.review ?? SessionReview()
            review.setLabel(label, for: candidate, version: analysis.detectorVersion)
            summary.review = review
        }
    }

    private func updateSummary(_ id: UUID, change: (inout SessionSummary) throws -> Void) throws {
        let url = directory(for: id).appendingPathComponent("summary.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var summary = try decoder.decode(SessionSummary.self, from: Data(contentsOf: url))
        guard summary.id == id else { throw CocoaError(.fileReadCorruptFile) }
        try change(&summary)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(summary).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete(_ id: UUID) throws {
        try files.removeItem(at: directory(for: id))
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

// The recorder calls this writer on the main thread and batches disk writes.
final class SessionLog {
    static let targetMotionHz = 100

    private struct Entry<Payload: Encodable>: Encodable {
        let type: String
        let receivedAt = Date()
        let data: Payload
    }

    private struct Start: Encodable {
        let formatVersion = 1
        let targetMotionHz: Int
        let systemVersion: String
        let session: SessionSummary
    }

    private let metadataURL: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var buffer = Data()

    init(directory: URL, summary: SessionSummary) throws {
        metadataURL = directory.appendingPathComponent("summary.json")
        let url = directory.appendingPathComponent("session-\(summary.id.uuidString).jsonl")
        try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        handle = try FileHandle(forWritingTo: url)
        encoder.dateEncodingStrategy = .millisecondsSince1970
    }

    func writeStart(_ summary: SessionSummary, systemVersion: String) throws {
        try append("start", Start(targetMotionHz: Self.targetMotionHz, systemVersion: systemVersion, session: summary))
        try checkpoint(summary)
    }

    func append<Payload: Encodable>(_ type: String, _ payload: Payload) throws {
        buffer.append(try encoder.encode(Entry(type: type, data: payload)))
        buffer.append(0x0A)
    }

    func checkpoint(_ summary: SessionSummary) throws {
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        try encoder.encode(summary).write(
            to: metadataURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func close() {
        try? handle.close()
    }
}
