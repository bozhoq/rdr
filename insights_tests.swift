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
        let event = JumpCandidate(startSeconds: 3, endSeconds: 5.8, minimumLoadG: 0.2,
                                  returnPeakG: 4, maximumRotationRadiansPerSecond: 2)
        func altitude(_ time: Double, _ meters: Double) -> AltitudeSample {
            AltitudeSample(elapsedSinceFirstSampleSeconds: time, pressureKilopascals: 101, relativeAltitudeMeters: meters)
        }
        let arc = [altitude(1.1, 0), altitude(2.2, 0), altitude(3.25, 1), altitude(4.3, 2), altitude(5.35, 0.8), altitude(6.4, 0)]
        var jumpGPS = RouteFilter()
        let fixes = [jumpGPS.accept(point(3.25), notBefore: origin), jumpGPS.accept(point(6, lon: 0.0002), notBefore: origin)].compactMap { $0 }
        let jump = LiveJumpEstimate.measure(event, altitude: arc, gps: fixes, motionClock: origin)
        check(jump?.heightMeters == 2 && abs((jump?.airtimeSeconds ?? 0) - 2.8) < 1e-9, "Report a bracketed peak and unloading interval")
        check(abs((jump?.distanceMeters ?? 0) - 22.239) < 0.01, "Use only accepted GPS fixes near both boundaries")
        check(LiveJumpEstimate.measure(event, altitude: arc, gps: fixes, motionClock: nil)?.distanceMeters == nil, "No jump distance without a common clock")
        check(LiveJumpEstimate.measure(event, altitude: Array(arc.dropLast()), gps: [], motionClock: nil) == nil, "A rise without a return cannot trigger the voice")
        var interrupted = arc
        interrupted.remove(at: 3)
        check(LiveJumpEstimate.measure(event, altitude: interrupted, gps: [], motionClock: nil) == nil, "Reject a gap across the pressure peak")
        check(LiveJumpEstimate.spokenHeight(2) == "два метра", "Russian plural for integer height")
        check(LiveJumpEstimate.spokenHeight(10.1) == "десять целых одна десятая метра", "Russian speech preserves tenths")

        let smallToss = JumpCandidate(startSeconds: 0, endSeconds: 0.64, minimumLoadG: 0.1,
                                     returnPeakG: 7, maximumRotationRadiansPerSecond: 1)
        let toss = LiveJumpEstimate.phoneToss(smallToss)
        check(toss?.isPhoneToss == true && abs((toss?.heightMeters ?? 0) - 0.5021) < 0.001 && toss?.distanceMeters == nil,
              "Half-meter phone toss works without barometer or GPS")
        var simulation = HandSimulationDetector()
        let raised = [0.01, 0.02, 0.00, 0.33, 0.52, 0.49, 0.17, 0.14]
        let lifts = raised.enumerated().compactMap { index, meters in simulation.consume(altitude(Double(index), meters)) }
        check(lifts.count == 1 && abs(lifts[0].1 - 0.51) < 1e-9 && lifts[0].0.unloadingSeconds == 3,
              "Hand simulation detects a lift, time above its baseline, and return without free fall")
        var gapSimulation = HandSimulationDetector()
        let brokenLift = raised.enumerated().compactMap { index, meters in
            gapSimulation.consume(altitude(Double(index) + (index >= 6 ? 4 : 0), meters))
        }
        check(brokenLift.isEmpty, "Hand simulation cannot bridge a barometer gap")
        var slowSimulation = HandSimulationDetector()
        let ascent = (1...32).map { min(2.5, Double($0) * 0.08) }
        let descent = (1...25).map { 2.5 - Double($0) * 0.085 }
        let slowLift = [0.0, 0.02, 0.01] + ascent + descent
        for (index, meters) in slowLift.enumerated() {
            check(slowSimulation.consume(altitude(Double(index), meters)) == nil, "A slow lift must wait for a settled return")
        }
        let firstNearFloor = Double(slowLift.count)
        check(slowSimulation.consume(altitude(firstNearFloor, 0.20)) == nil, "First reading near floor does not end the test")
        let slowResult = slowSimulation.consume(altitude(firstNearFloor + 1, 0.23))
        check(abs((slowResult?.1 ?? 0) - 2.49) < 1e-9, "A slow ceiling test preserves the original baseline and its peak")
        var offsetSimulation = HandSimulationDetector()
        let offsetReturn = [0.0, 0.01, 0.0, 0.5, 1.4, 2.5, 2.39, 1.5, 0.8, 0.47, 0.44, 0.42]
        let offsetLifts = offsetReturn.enumerated().compactMap { index, meters in
            offsetSimulation.consume(altitude(Double(index), meters))
        }
        check(offsetLifts.count == 1 && abs(offsetLifts[0].1 - 2.497) < 0.01,
              "A long lift with a stable shifted return can still be measured")

        var walkingSimulation = HandSimulationDetector()
        let walkingLift = [0.0, 0.12, -0.08, 0.05, 0.45, 1.3, 2.5, 2.4, 1.2, 0.10, 0.16]
        let walkingResults = walkingLift.enumerated().compactMap { index, height in
            walkingSimulation.consume(altitude(Double(index), height))
        }
        check(walkingResults.count == 1 && abs(walkingResults[0].1 - 2.5) < 0.15,
              "Walking baseline noise still permits a ceiling lift and settled return")
        var incompleteLift = HandSimulationDetector()
        check([0.0, 0.0, 0.0, 0.5, 1.5, 2.5, 2.5, 2.5].enumerated().compactMap { index, height in
            incompleteLift.consume(altitude(Double(index), height))
        }.isEmpty, "A high hold is not a completed lift before descent")
        var loweredBaseline = HandSimulationDetector()
        let twoLevels = [1.0, 1.0, 1.0, 0.2, 0.0, 0.0, 0.0, 0.6, 2.5, 1.2, 0.0, 0.0]
        let floorResults = twoLevels.enumerated().compactMap { index, height in
            loweredBaseline.consume(altitude(Double(index), height))
        }
        check(floorResults.count == 1 && abs(floorResults[0].1 - 2.5) < 0.05,
              "Putting the phone on the floor reacquires its baseline before a lift")

        let airborne = JumpCandidate(startSeconds: 3, endSeconds: 5, minimumLoadG: 0.7,
                                     returnPeakG: 2.1, maximumRotationRadiansPerSecond: 0.5)
        let trajectory = [RidingJumpDetector.Point(time: 3, height: 0), .init(time: 4, height: 1.5),
                          .init(time: 5, height: 0.05), .init(time: 5.3, height: 0)]
        let rideFlight = RidingJumpDetector.Flight(event: airborne, trajectory: trajectory, settledHeight: 0, residualVelocity: 0)
        let sparsePressure = [altitude(1.9, 0), altitude(2.9, 0), altitude(4, 1.4), altitude(5.9, 0), altitude(6.9, 0)]
        let rideResult = LiveJumpEstimate.riding(rideFlight, altitude: sparsePressure, gps: [], motionClock: nil)
        check(rideResult.heightMeters == 1.5 && rideResult.airtimeSeconds == 2, "A sparse barometer can support the inertial peak")
        let conflicting = sparsePressure.map { $0.elapsedSinceFirstSampleSeconds == 4 ? altitude(4, 3.4) : $0 }
        let uncertain = LiveJumpEstimate.riding(rideFlight, altitude: conflicting, gps: [], motionClock: nil)
        check(uncertain.heightMeters == nil && uncertain.airtimeSeconds == 2, "Retain flight time if pressure contradicts the calculated height")
        check(LiveJumpEstimate.riding(rideFlight, altitude: [], gps: [], motionClock: nil).heightMeters == nil,
              "Missing pressure cannot certify a height")
        let restoredEstimate = try JSONDecoder().decode(LiveJumpEstimate.self, from: JSONEncoder().encode(uncertain))
        check(restoredEstimate.heightMeters == nil && restoredEstimate.airtimeSeconds == 2, "An unknown height survives a checkpoint")
        let measurement = MotionCalibration(completedAtSeconds: 5, frequencyHz: 99, verticalOffset: 0.04, verticalNoise: 0.01)
        let preset = SavedMotionCalibration(measurement: measurement, measuredAt: origin, systemVersion: "26.1")
        check(preset.usable(at: origin.addingTimeInterval(600), systemVersion: "26.1")?.completedAtSeconds == 0,
              "A fresh calibration applies from the start of a new session")
        check(preset.usable(at: origin.addingTimeInterval(600), systemVersion: "26.2") == nil &&
              preset.usable(at: origin.addingTimeInterval(31 * 86_400), systemVersion: "26.1") == nil,
              "Stale calibrations and calibrations from another iOS version do not carry over")
        check(KiteCatalog.brands.first(where: { $0.name == "CORE" })?.matches("кор") == true &&
              KiteCatalog.brands.first(where: { $0.name == "Duotone" })?.models.contains("Evo D/LAB") == true,
              "Catalogue preserves model variants and Russian aliases")
        check(SessionSetup(sport: .windsurf, kiteStyle: .bigAir).cleaned.kiteStyle == nil &&
              SessionSetup(sport: .kite, kiteStyle: .wakestyle).activityTitle.contains("Вейкстайл"),
              "Kite style is scoped to compatible activities")
        check(SessionSetup.kiteAreas.count == 29 && SessionSetup.kiteAreas.first == 3 && SessionSetup.kiteAreas.last == 17,
              "Kite size choices span 3 to 17 m², inclusive")
        var equipment = SessionSetup(sport: .kite)
        equipment.selectKite("CORE XR8", area: 9.5)
        equipment.selectBoard(BoardSelection(brand: "Duotone", model: "Jaime SLS", size: "136 × 41 см")!)
        let restoredGear = try JSONDecoder().decode(SessionSetup.self, from: JSONEncoder().encode(equipment.cleaned))
        check(restoredGear.kite == "CORE XR8" && restoredGear.kiteAreaSquareMeters == 9.5 &&
              restoredGear.boardDetails == equipment.boardDetails && restoredGear.boardTitle.contains("136 × 41 см"),
              "Kite area and board brand, model, size survive saving")
        let duotoneBoards = BoardCatalog.brands.first { $0.matches("дуотон") }?.models ?? []
        let jaimeSLS = duotoneBoards.first { $0.name == "Jaime SLS" }
        check(jaimeSLS?.sizes.contains("136 × 41 см") == true, "Search by Cyrillic and keep the board model's verified dimensions")

        let spot = RiderSpot(name: "  Тестовый спот  ", latitude: "55,75", longitude: "37.62")!
        check(spot.name == "Тестовый спот" && spot.latitude == 55.75 && spot.longitude == 37.62, "Parse decimal commas in spot coordinates")
        check(RiderSpot(name: "Bad", latitude: "91", longitude: "37") == nil &&
              RiderSpot(name: "Bad", latitude: "nan", longitude: "37") == nil, "Invalid coordinates cannot create a spot")
        let legacyWind = SessionWind(knots: 10, direction: 315, date: Date(), source: "test")
        check(legacyWind.title.contains("м/с") && legacyWind.title.contains("СЗ") &&
              abs(legacyWind.knots * SessionWind.metersPerSecondPerKnot - 5.14444) < 0.001, "Display historic wind in m/s, from NW")
        let grouped = StarterSpots.decode([["id": spot.id.uuidString, "name": "Каталог", "latitude": 55.75,
                                            "longitude": 37.62, "region": "Регион", "locality": "Берег", "areaOnly": true] as [String: Any]])
        check(StarterSpots.merge(saved: [spot], catalogue: grouped).first?.region == "Регион" &&
              StarterSpots.merge(saved: [spot], catalogue: grouped).first?.name == spot.name,
              "Attach catalogue hierarchy to saved ID while keeping user edits")
        check(BoardCatalog.brands.contains { $0.matches("Молоков") && $0.models.contains { $0.name == "Splash" } },
              "Find Russian board makers by Cyrillic spelling")
        var setupWithSpot = SessionSetup(sport: .kite)
        setupWithSpot.selectSpot(spot)
        let renamed = RiderSpot(id: spot.id, name: "Новое имя", latitude: "55.75", longitude: "37.62")!
        check(renamed.matches(setupWithSpot), "Renaming a spot preserves the links from sessions")
        setupWithSpot.setSpotName("Тестовый Спот")
        check(setupWithSpot.spotID == nil && spot.matches(setupWithSpot), "Legacy text labels and saved spots can match")
        let yandex = URLComponents(url: spot.yandexURL!, resolvingAgainstBaseURL: false)?.queryItems
        check(yandex?.first(where: { $0.name == "ll" })?.value == "37.62,55.75", "Yandex longitude and latitude are in the right order")
        let fallback = URLComponents(url: spot.routeWebURL!, resolvingAgainstBaseURL: false)?.queryItems
        check(fallback?.first(where: { $0.name == "rtext" })?.value == "~55.75,37.62", "Route leaves origin to current location")
        let appRoute = URLComponents(url: spot.routeAppURL!, resolvingAgainstBaseURL: false)
        check(appRoute?.scheme == "yandexmaps" && appRoute?.queryItems?.first(where: { $0.name == "lat_to" })?.value == "55.75",
              "Pass coordinates to the native Maps route")
        let nearby = RiderSpot(name: "Другой спот", latitude: "55.75004", longitude: "37.62001")!
        check(StarterSpots.merge(saved: [nearby], catalogue: [spot]) == [nearby] &&
              StarterSpots.merge(saved: [renamed], catalogue: [spot]) == [renamed],
              "The starter catalogue preserves existing saved spots and IDs")
        let entry: [[String: Any]] = [["id": spot.id.uuidString, "name": spot.name,
                                      "latitude": spot.latitude, "longitude": spot.longitude,
                                      "mapLink": "https://yandex.ru/maps/-/test", "source": "https://example.org/spot"]]
        let starter = StarterSpots.decode(entry).first
        check(starter?.source?.absoluteString == "https://example.org/spot" && starter?.id == spot.id && starter?.yandexURL?.absoluteString == "https://yandex.ru/maps/-/test",
              "Decode the bundled starter catalogue and original map link")
        let fixture = #"{"timezone":"Europe/Moscow","hourly":{"time":[1699980000,1700000000,1700003600,1700007200],"wind_speed_10m":[8,12,null,17],"wind_gusts_10m":[10,19,null],"wind_direction_10m":[0,90,null,225],"temperature_2m":[2,-3,null,0]}}"#
        let forecast = try JSONDecoder().decode(SpotForecast.self, from: Data(fixture.utf8))
        let hours = forecast.hours(near: origin)
        check(hours.count == 2 && hours.first?.temperature == -3 && hours.last?.gust == nil, "Handle past and unavailable forecasts without mismatching arrays")
        check(SpotForecast.compass(360) == "С" && SpotForecast.compass(hours.last?.direction) == "ЮЗ", "Show correct turn and wrap at north")

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
