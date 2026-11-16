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
}

struct LocationSample: Encodable {
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
    private let root = URL.applicationSupportDirectory.appendingPathComponent("Sessions", isDirectory: true)

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
