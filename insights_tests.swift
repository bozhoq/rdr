import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

@main enum InsightsTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    static func point(_ t: Double, lat: Double = 0, lon: Double = 0, accuracy: Double = 5, speed: Double? = 10, speedAccuracy: Double? = 1) -> LocationSample {
        LocationSample(timestamp: origin.addingTimeInterval(t), latitude: lat, longitude: lon, horizontalAccuracyMeters: accuracy, speedMetersPerSecond: speed, speedAccuracyMetersPerSecond: speedAccuracy)
    }
    static func main() throws {
        var filter = RouteFilter()
        let first = filter.accept(point(0), notBefore: origin)!
        check(first.segment == 1 && filter.metrics.distanceMeters == 0, "First fix is not travelled distance")
        _ = filter.accept(point(1, lon: 0.0001), notBefore: origin)
        check(abs(filter.metrics.distanceMeters - 11.1195) < 0.01, "Known equatorial distance")
        check(filter.metrics.maxSpeedMetersPerSecond == 10, "Measured speed accepted")
        let beforeGap = filter.metrics.distanceMeters
        let after = filter.accept(point(20, lon: 0.001), notBefore: origin)!
        check(after.segment == 2 && filter.metrics.distanceMeters == beforeGap, "No distance across a GPS gap")
        check(filter.accept(point(21, lon: 20), notBefore: origin) == nil, "Reject teleport")
        let resumed = filter.accept(point(22, lon: 0.0011), notBefore: origin)!
        check(resumed.segment == 3 && filter.metrics.distanceMeters == beforeGap, "No line or distance after rejected teleport")
        for bad in [point(23, accuracy: 31), point(24, lat: 91), point(25, lon: .nan), point(26, accuracy: -1), point(27, accuracy: .infinity)] {
            check(filter.accept(bad, notBefore: origin) == nil, "Reject invalid GPS")
        }
        check(filter.accept(point(-1), notBefore: origin) == nil, "Ignore fix before session")
        let good = filter.accept(point(28), notBefore: origin)!
        check(filter.accept(point(28), notBefore: origin) == nil, "Reject duplicate time")
        check(filter.accept(point(27), notBefore: origin) == nil, "Reject backwards time")
        let next = filter.accept(point(29), notBefore: origin)!
        check(next.segment > good.segment, "Bad timestamp breaks track")
        let noSpeed = filter.accept(point(30, speed: 100), notBefore: origin)!
        let speedResumed = filter.accept(point(31), notBefore: origin)!
        check(noSpeed.speed == nil && speedResumed.speedSegment != next.speedSegment, "Invalid speed breaks chart, keeps route")
        for sample in [point(32, speed: -1), point(33, speed: .nan), point(34, speedAccuracy: nil), point(35, speedAccuracy: 4)] {
            check(filter.accept(sample, notBefore: origin)!.speed == nil, "Speed needs valid accuracy")
        }
        var small = RouteFilter()
        _ = small.accept(point(0), notBefore: origin)
        _ = small.accept(point(1, lon: 0.00001), notBefore: origin)
        check(small.metrics.distanceMeters == 0, "Small GPS jitter is not distance")
        _ = small.accept(point(2, lon: 0.00005), notBefore: origin)
        check(small.metrics.distanceMeters > 5, "Accumulate displacement from anchor")
        check(RouteFilter.distance(point(0, lon: 179.999), point(1, lon: -179.999)) < 230, "Antimeridian distance takes short route")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rider-insights-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("old-log.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        struct Entry: Encodable { let type = "location"; let data: LocationSample }
        let samples = [point(0), point(1, lon: 0.0001), point(2, accuracy: 100), point(3, lon: 0.0002), point(4, lon: 0.0003)]
        var bytes = Data()
        for sample in samples { bytes.append(try encoder.encode(Entry(data: sample))); bytes.append(10) }
        bytes.append(Data("{\"type\":\"event\",\"data\":{\"name\":\"background\"}}\n".utf8))
        bytes.append(try encoder.encode(Entry(data: point(5, lon: 0.0004))))
        bytes.append(Data("\n{\"type\":".utf8))
        try bytes.write(to: raw)
        let replay = try RouteReplay.analyze(url: raw, startedAt: origin)
        check(replay.points.count == 5 && replay.metrics.rejected == 1, "Old log locations decode")
        check(replay.metrics.segments == 3 && replay.malformedLines == 1, "Events and truncated line split continuity")
        check(abs(replay.metrics.distanceMeters - 22.239) < 0.02, "Replay excludes missing intervals")
        let afterReplay = try Data(contentsOf: raw)
        check(afterReplay == bytes, "Raw input untouched")
        let gpx = try GPXExport.write(replay, name: "Rider <test> & \"name\"\u{1}")
        defer { try? FileManager.default.removeItem(at: gpx) }
        let xml = try Data(contentsOf: gpx)
        let parser = XMLParser(data: xml)
        check(parser.parse(), "GPX is well-formed XML despite special characters")
        let document = try XMLDocument(data: xml)
        let text = String(decoding: xml, as: UTF8.self)
        check(text.components(separatedBy: "<trkseg>").count - 1 == 3, "GPX preserves all gaps")
        check(text.components(separatedBy: "<trkpt ").count - 1 == 5, "GPX includes all accepted points")
        check(text.contains("Rider &lt;test&gt; &amp; &quot;name&quot;"), "Escaped track name")
        check(document.rootElement()?.namespace(forPrefix: "")?.stringValue == "http://www.topografix.com/GPX/1/1", "GPX namespace")
        check(!text.contains("<ele>") && !text.contains("motion"), "No invented altitude or raw sensor data")

        var dense = RouteFilter()
        var points: [RoutePoint] = []
        for i in 0..<10_000 {
            if let value = dense.accept(point(Double(i), lon: Double(i) * 0.00001, speed: i == 1234 ? 30 : 2), notBefore: origin) { points.append(value) }
        }
        let large = RouteAnalysis(points: points, metrics: dense.metrics, malformedLines: 0)
        check(large.displaySegments[0].first?.id == points.first?.id && large.displaySegments[0].last?.id == points.last?.id, "Drawing keeps endpoints")
        check(large.displaySegments[0].count <= 2501, "Map drawing is bounded")
        check(large.displaySpeedPoints.contains { $0.speed == 30 }, "Chart retains narrow speed peak")
        var fragmented = RouteFilter()
        var fragments: [RoutePoint] = []
        for i in 0..<3000 { fragmented.breakContinuity(); fragments.append(fragmented.accept(point(Double(i)), notBefore: origin)!) }
        let fragmentedRoute = RouteAnalysis(points: fragments, metrics: fragmented.metrics, malformedLines: 0)
        check(fragmentedRoute.displaySegments.count <= 500 && fragmentedRoute.displaySpeedPoints.count <= 500, "Thousands of gaps cannot overload drawing")

        let store = SessionStore(root: root.appendingPathComponent("sessions"))
        var session = SessionSummary(startedAt: origin, gpsEnabledAtStart: true, batteryAtStartPercent: 70)
        session.status = .finished
        session.durationSeconds = 600
        session.distanceMeters = 100
        session.maxSpeedMetersPerSecond = 20
        let log = try store.makeLog(for: session)
        try log.writeStart(session, systemVersion: "test")
        try log.checkpoint(session)
        log.close()
        try store.saveSetup(SessionSetup(sport: .kite, spot: "  Тестовый спот  ", kite: "9 м²", board: "twintip", placement: .waist), for: session.id)
        try store.saveGPSMetrics(replay.metrics, for: session.id)
        try store.saveNotes(title: "Test", notes: "notes", for: session.id)
        let restored = try store.history()[0]
        check(restored.setup?.spot == "Тестовый спот" && restored.setup?.placement == .waist, "Setup persists and trims")
        check(restored.gpsMetrics?.accepted == 5 && restored.review?.notes == "notes", "Independent edits preserve fields")
        check(restored.matches("спот") && restored.matches("9 м²") && restored.matches("twintip"), "Search includes setup")
        check(SessionSetup(spot: String(repeating: "я", count: 200)).cleaned.spot.count == 100, "Unicode length limit")
        var test = restored; test.id = UUID(); test.setup?.sport = .groundTest
        var unclassified = restored; unclassified.id = UUID(); unclassified.setup = nil
        var active = restored; active.id = UUID(); active.status = .recording
        let progress = RiderProgress(history: [restored, test, unclassified, active])
        check(progress.sessions.count == 1 && progress.duration == 600, "Statistics exclude tests, legacy unclassified and active recording")
        check(progress.distance == replay.metrics.distanceMeters, "Progress uses refreshed route metrics")
        check(RiderProgress(history: [restored], since: origin.addingTimeInterval(1)).sessions.isEmpty, "Period filtering")
        var noGPS = restored; noGPS.gpsMetrics = RouteMetrics()
        check(RiderProgress(history: [noGPS]).maximumSpeed == nil, "No fallback to obsolete speed after GPS replay")
        let oldData = try encoder.encode(session)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let old = try decoder.decode(SessionSummary.self, from: oldData)
        check(old.setup == nil && old.gpsMetrics == nil, "Legacy summary compatibility")
        let report = String(decoding: try SessionReport.data(for: restored), as: UTF8.self)
        check(!report.contains("latitude") && report.contains("Тестовый спот"), "Result export includes setup, not route coordinates")
        print("PASS: \(checks) route, GPX, setup and progress checks")
    }
}
