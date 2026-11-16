import Foundation

enum SessionSport: String, Codable, CaseIterable {
    case unclassified, kite, snowkite, wing, groundTest
    var title: String {
        switch self {
        case .unclassified: return "Не указан"
        case .kite: return "Кайтсёрфинг"
        case .snowkite: return "Сноукайтинг"
        case .wing: return "Винг"
        case .groundTest: return "Тест на земле"
        }
    }
    var isRiding: Bool { self == .kite || self == .snowkite || self == .wing }
}

enum PhonePlacement: String, Codable, CaseIterable {
    case unspecified, chest, waist, pocket, board, hand, other
    var title: String {
        switch self {
        case .unspecified: return "Не указано"
        case .chest: return "На груди"
        case .waist: return "На поясе"
        case .pocket: return "В кармане"
        case .board: return "На доске"
        case .hand: return "В руке"
        case .other: return "Другое"
        }
    }
}

struct SessionSetup: Codable {
    var sport: SessionSport = .unclassified
    var spot = ""
    var kite = ""
    var board = ""
    var placement: PhonePlacement = .unspecified
    var cleaned: Self {
        var copy = self
        copy.spot = String(spot.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        copy.kite = String(kite.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        copy.board = String(board.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        return copy
    }
}

struct RouteMetrics: Codable, Sendable {
    var version = "gps-1"
    var accepted = 0
    var rejected = 0
    var segments = 0
    var distanceMeters = 0.0
    var maxSpeedMetersPerSecond: Double?
}

struct RoutePoint: Identifiable, Sendable {
    let id: Int
    let segment: Int
    let speedSegment: Int
    let sample: LocationSample
    let speed: Double?
}

/// The same quality filter is used live, during replay and for GPX export.
/// Thresholds remove obvious GPS failures; they are not a claim of GPS accuracy.
struct RouteFilter {
    private(set) var metrics = RouteMetrics()
    private var previous: LocationSample?
    private var anchor: LocationSample?
    private var lastTimestamp: Date?
    private var speedSegment = 0

    mutating func breakContinuity() {
        previous = nil
        anchor = nil
        speedSegment += 1
    }

    mutating func accept(_ sample: LocationSample, notBefore start: Date) -> RoutePoint? {
        guard sample.timestamp.timeIntervalSince1970.isFinite,
              sample.timestamp >= start,
              lastTimestamp.map({ sample.timestamp > $0 }) ?? true else {
            metrics.rejected += 1
            breakContinuity()
            return nil
        }
        lastTimestamp = sample.timestamp
        guard sample.latitude.isFinite, sample.longitude.isFinite,
              (-90...90).contains(sample.latitude), (-180...180).contains(sample.longitude),
              sample.horizontalAccuracyMeters.isFinite,
              (0...30).contains(sample.horizontalAccuracyMeters) else {
            metrics.rejected += 1
            breakContinuity()
            return nil
        }
        if let previous {
            let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
            if dt > 15 {
                breakContinuity()
            } else if Self.distance(previous, sample) / dt > 60 {
                // Reject the jump, then start afresh on the next valid fix.
                metrics.rejected += 1
                breakContinuity()
                return nil
            }
        }
        if previous == nil {
            metrics.segments += 1
            speedSegment += 1
        }
        if let anchor {
            let distance = Self.distance(anchor, sample)
            if distance >= 5 {
                metrics.distanceMeters += distance
                self.anchor = sample
            }
        } else { anchor = sample }
        previous = sample
        let speed: Double?
        if let value = sample.speedMetersPerSecond, value.isFinite, (0...60).contains(value),
           let accuracy = sample.speedAccuracyMetersPerSecond, accuracy.isFinite, (0...3).contains(accuracy) {
            speed = value
            metrics.maxSpeedMetersPerSecond = max(metrics.maxSpeedMetersPerSecond ?? 0, value)
        } else {
            speed = nil
            speedSegment += 1
        }
        metrics.accepted += 1
        return RoutePoint(id: metrics.accepted, segment: metrics.segments, speedSegment: speedSegment, sample: sample, speed: speed)
    }

    static func distance(_ a: LocationSample, _ b: LocationSample) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians
        let dLon = (b.longitude - a.longitude) * radians
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

struct RouteAnalysis: Sendable {
    let points: [RoutePoint]
    let metrics: RouteMetrics
    let malformedLines: Int

    /// Bound drawing work while keeping endpoints and all discontinuities.
    /// Each segment is sampled independently, so simplification cannot join gaps.
    var displaySegments: [[RoutePoint]] {
        let groups = Dictionary(grouping: points, by: \.segment)
        let step = max(1, Int(ceil(Double(points.count) / 2500)))
        let keys = groups.keys.sorted()
        let groupStep = max(1, Int(ceil(Double(keys.count) / 500)))
        return stride(from: 0, to: keys.count, by: groupStep).compactMap { index in
            let key = keys[index]
            guard let group = groups[key], let last = group.last else { return nil }
            var sampled = stride(from: 0, to: group.count, by: step).map { group[$0] }
            if sampled.last?.id != last.id { sampled.append(last) }
            return sampled
        }
    }

    var displaySpeedPoints: [RoutePoint] {
        let groups = Dictionary(grouping: points.filter { $0.speed != nil }, by: \.speedSegment)
        let step = max(1, Int(ceil(Double(points.count) / 1500)))
        let keys = groups.keys.sorted()
        let groupStep = max(1, Int(ceil(Double(keys.count) / 500)))
        return stride(from: 0, to: keys.count, by: groupStep).flatMap { index -> [RoutePoint] in
            let key = keys[index]
            let group = groups[key] ?? []
            // Keep extrema of each bucket: a short speed peak remains visible.
            return stride(from: 0, to: group.count, by: step).flatMap { start -> [RoutePoint] in
                let bucket = Array(group[start..<min(start + step, group.count)])
                let chosen = [bucket.first!, bucket.min { ($0.speed ?? 0) < ($1.speed ?? 0) }!,
                              bucket.max { ($0.speed ?? 0) < ($1.speed ?? 0) }!, bucket.last!]
                return Dictionary(grouping: chosen, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
            }
        }
    }
}

enum RouteReplay {
    private struct Header: Decodable { let type: String }
    private struct Entry: Decodable { let data: LocationSample }
    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "В записи больше 200 000 точек GPS. Разделите её на более короткие сессии." }
    }

    static func analyze(url: URL, startedAt: Date) throws -> RouteAnalysis {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var buffer = Data()
        var points: [RoutePoint] = []
        var filter = RouteFilter()
        var malformed = 0
        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            do {
                let header = try decoder.decode(Header.self, from: line)
                if header.type == "location" {
                    let sample = try decoder.decode(Entry.self, from: line).data
                    if let point = filter.accept(sample, notBefore: startedAt) { points.append(point) }
                } else if header.type == "event" {
                    // Any event may represent lost permission or GPS failure.
                    // Breaking is conservative and never invents distance.
                    filter.breakContinuity()
                }
            } catch {
                malformed += 1
                filter.breakContinuity()
            }
            if points.count > 200_000 { throw Failure.tooLarge }
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
        return RouteAnalysis(points: points, metrics: filter.metrics, malformedLines: malformed)
    }
}

enum GPXExport {
    static func escape(_ value: String) -> String {
        let legal = String(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        })
        return legal.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    static func write(_ route: RouteAnalysis, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rider-route-\(UUID()).gpx")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Rider\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(escape(name))</name>"
        var segment: Int?
        for point in route.points {
            if point.segment != segment {
                if segment != nil { xml += "</trkseg>" }
                xml += "<trkseg>"
                segment = point.segment
            }
            let sample = point.sample
            let coordinate = String(format: "lat=\"%.8f\" lon=\"%.8f\"", locale: Locale(identifier: "en_US_POSIX"), sample.latitude, sample.longitude)
            xml += "<trkpt \(coordinate)><time>\(formatter.string(from: sample.timestamp))</time></trkpt>\n"
        }
        if segment != nil { xml += "</trkseg>" }
        xml += "</trk></gpx>"
        try Data(xml.utf8).write(to: url, options: .atomic)
        return url
    }
}

struct RiderProgress {
    let sessions: [SessionSummary]
    var duration: Double { sessions.reduce(0) { $0 + max(0, $1.durationSeconds) } }
    var distance: Double { sessions.reduce(0) { $0 + max(0, $1.gpsMetrics?.distanceMeters ?? $1.distanceMeters ?? 0) } }
    var maximumSpeed: Double? {
        sessions.compactMap { $0.gpsMetrics != nil ? $0.gpsMetrics?.maxSpeedMetersPerSecond : $0.maxSpeedMetersPerSecond }
            .filter { $0.isFinite && (0...60).contains($0) }.max()
    }
    var confirmedJumps: Int {
        sessions.reduce(0) { total, session in
            guard let analysis = session.jumpAnalysis, let review = session.review else { return total }
            return total + analysis.candidates.filter { review.label(for: $0, version: analysis.detectorVersion) == .bodyJump }.count
        }
    }
    init(history: [SessionSummary], since: Date? = nil) {
        sessions = history.filter { session in
            session.setup?.sport.isRiding == true && session.status != .recording &&
            (since.map { session.startedAt >= $0 } ?? true)
        }
    }
}
