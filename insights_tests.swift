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

        var rideForProfile = SessionSummary(startedAt: origin, gpsEnabledAtStart: false, batteryAtStartPercent: nil)
        rideForProfile.status = .finished
        rideForProfile.setup = SessionSetup(sport: .kite)
        rideForProfile.durationSeconds = 7 * 3600
        let unmeasuredJump = JumpCandidate(startSeconds: 20, endSeconds: 30, minimumLoadG: 0.2,
                                           returnPeakG: 4, maximumRotationRadiansPerSecond: 2)
        rideForProfile.jumpAnalysis = JumpAnalysis(candidates: [event, unmeasuredJump])
        rideForProfile.liveJumpEstimates = [
            SessionReview.key(for: event, version: JumpDetector.version):
                LiveJumpEstimate(heightMeters: 5, airtimeSeconds: 3, distanceMeters: nil),
            SessionReview.key(for: unmeasuredJump, version: JumpDetector.version):
                LiveJumpEstimate(heightMeters: nil, airtimeSeconds: 10, distanceMeters: nil),
        ]
        var interruptedRideForProfile = rideForProfile
        interruptedRideForProfile.status = .interrupted
        interruptedRideForProfile.durationSeconds = 3 * 3600 + 120
        interruptedRideForProfile.jumpAnalysis = nil
        var landTestForProfile = rideForProfile
        landTestForProfile.recordingMode = .test
        let profileTotals = RiderTotals([rideForProfile, interruptedRideForProfile, landTestForProfile])
        check(profileTotals.sessions == 2 && profileTotals.timeOnWater == "10 ч 2 мин" &&
              profileTotals.jumps == 1 && profileTotals.height == 5 && profileTotals.airtime == 3,
              "Sum saved riding time and count only measured jumps, skipping land tests")
        let profileBadges = RiderAchievement.milestones(profileTotals)
        check(profileBadges.first(where: { $0.id == "five-meters" })?.unlocked == true &&
              profileBadges.first(where: { $0.id == "ten-hours" })?.progress == 1 &&
              profileBadges.first(where: { $0.id == "fifty-hours" })?.unlocked == false,
              "Unlock achievements at the exact thresholds and clamp progress")
        let socialBadges = RiderAchievement.milestones(profileTotals, followers: 10)
        let followerBadge = socialBadges.first { $0.id == "ten-followers" }
        check(socialBadges.count == 10 && followerBadge?.unlocked == true &&
              socialBadges.first { $0.id == "fifty-followers" }?.unlocked == false,
              "Follower awards reflect real counts and leave higher goals locked")
        check(RiderJumpScore.records(in: [rideForProfile, interruptedRideForProfile, landTestForProfile]).count == 1,
              "Leaderboard shares measured riding results without report logs or test jumps")
        let rankingZone = TimeZone(identifier: "Europe/Moscow")!
        let dateParser = ISO8601DateFormatter()
        let rankingNow = dateParser.date(from: "2026-01-01T14:15:00+03:00")!
        let rankingMidnight = dateParser.date(from: "2026-01-01T00:00:00+03:00")!
        let yesterdayMidnight = dateParser.date(from: "2025-12-31T00:00:00+03:00")!
        let mondayMidnight = dateParser.date(from: "2025-12-29T00:00:00+03:00")!
        let nextMonthMidnight = dateParser.date(from: "2026-02-01T00:00:00+03:00")!
        let todayInterval = RiderTopPeriod.today.interval(at: rankingNow, timeZone: rankingZone)
        let yesterdayInterval = RiderTopPeriod.yesterday.interval(at: rankingNow, timeZone: rankingZone)
        check(todayInterval?.start == rankingMidnight && yesterdayInterval?.start == yesterdayMidnight &&
              yesterdayInterval?.end == rankingMidnight && RiderTopPeriod.all.interval(at: rankingNow) == nil,
              "The leaderboard uses full local days, not rolling 24-hour windows")
        check(RiderTopPeriod.week.interval(at: rankingNow, timeZone: rankingZone)?.start == mondayMidnight &&
              RiderTopPeriod.month.interval(at: rankingNow, timeZone: rankingZone)?.end == nextMonthMidnight,
              "Use Monday and calendar month boundaries even across New Year")

        var shortHighRide = rideForProfile
        shortHighRide.setup?.selectKite("XR8", area: 9)
        shortHighRide.setup?.selectBoard(BoardSelection(brand: "CORE", model: "Fusion", size: "137 см")!)
        let recordKey = SessionReview.key(for: event, version: JumpDetector.version)
        shortHighRide.liveJumpEstimates?[recordKey] = LiveJumpEstimate(heightMeters: 8, airtimeSeconds: 3, distanceMeters: 18)
        var longLowerRide = rideForProfile
        longLowerRide.id = UUID()
        longLowerRide.setup?.selectKite("Rebel", area: 12)
        longLowerRide.liveJumpEstimates?[recordKey] = LiveJumpEstimate(heightMeters: 5, airtimeSeconds: 4, distanceMeters: 36)
        let eventRecords = RiderJumpScore.records(in: [shortHighRide, longLowerRide, interruptedRideForProfile])
        let winningHeight = RiderJumpScore.best(for: .height, in: eventRecords)
        let winningDistance = RiderJumpScore.best(for: .distance, in: eventRecords)
        check(winningHeight?.kite?.contains("XR8") == true && winningHeight?.board?.contains("Fusion") == true &&
              winningDistance?.kite?.contains("Rebel") == true && winningDistance?.distance == 36 &&
              RiderJumpScore.best(for: .airtime, in: eventRecords)?.id == longLowerRide.id,
              "Select the record session for each metric and keep that session's equipment")
        check(RiderJumpScore.best(for: .distance, in: RiderJumpScore.records(in: [rideForProfile])) == nil,
              "A session without measured flight distance cannot enter the distance ranking")
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
        let gearPreset = GearPreset(name: "  Флэт  ", setup: equipment)!
        let savedPreset = try JSONDecoder().decode(GearPreset.self, from: JSONEncoder().encode(gearPreset))
        let otherSetup = SessionSetup(sport: .kite, spot: "Донузлав", placement: .chest)
        let applied = savedPreset.applying(to: otherSetup)
        check(savedPreset.id == gearPreset.id && savedPreset.name == "Флэт" && savedPreset.matches(applied) &&
              applied.kiteAreaSquareMeters == 9.5 && applied.boardDetails == equipment.boardDetails &&
              applied.spot == otherSetup.spot && applied.placement == otherSetup.placement,
              "Apply a stored equipment pair without changing spot or phone placement")
        var otherSize = equipment
        otherSize.kiteAreaSquareMeters = 12
        check(!gearPreset.matches(otherSize) && GearPreset(name: "Пустой", setup: otherSetup) == nil,
              "Kite sizes distinguish presets and incomplete gear cannot create a preset")
        let duotoneBoards = BoardCatalog.brands.first { $0.matches("дуотон") }?.models ?? []
        let jaimeSLS = duotoneBoards.first { $0.name == "Jaime SLS" }
        check(jaimeSLS?.sizes.contains("136 × 41 см") == true, "Search by Cyrillic and keep the board model's verified dimensions")

        let spot = RiderSpot(name: "  Тестовый спот  ", latitude: "55,75", longitude: "37.62")!
        check(spot.name == "Тестовый спот" && spot.latitude == 55.75 && spot.longitude == 37.62, "Parse decimal commas in spot coordinates")
        var spotWithShore = spot
        spotWithShore.waterBearing = 0
        let restoredShore = try JSONDecoder().decode(RiderSpot.self, from: JSONEncoder().encode(spotWithShore))
        check(restoredShore.waterBearing == 0 && restoredShore.id == spot.id && spot.waterBearing == nil &&
              SpotForecast.shoreWind(from: 360, waterBearing: 0) == "К берегу" &&
              SpotForecast.shoreWind(from: 180, waterBearing: 0) == "От берега" &&
              SpotForecast.shoreWind(from: 270, waterBearing: 0) == "Вдоль берега" &&
              SpotForecast.shoreWind(from: 0, waterBearing: nil) == nil,
              "Preserve a configured shoreline and interpret weather bearings as wind origin")
        check(RiderSpot(name: "Bad", latitude: "91", longitude: "37") == nil &&
              RiderSpot(name: "Bad", latitude: "nan", longitude: "37") == nil, "Invalid coordinates cannot create a spot")
        var oldPlacement = SessionSetup(sport: .kite, placement: .waist)
        check(oldPlacement.placement == .waist && oldPlacement.forRecording.placement == .chest,
              "New recordings always use chest placement while saved history retains its placement")
        oldPlacement = gearPreset.applying(to: oldPlacement)
        oldPlacement.clearEquipment()
        check(oldPlacement.kiteTitle.isEmpty && oldPlacement.boardTitle.isEmpty &&
              oldPlacement.kiteAreaSquareMeters == nil && oldPlacement.boardDetails == nil,
              "Removing the preset clears both equipment fields and their metadata")
        let enteredWind = SessionWind(knots: 13.5 / SessionWind.metersPerSecondPerKnot, direction: 135,
                                      date: origin, source: "Вручную", range: .twelveToFifteen)
        let savedWindRange = try JSONDecoder().decode(SessionWind.self, from: JSONEncoder().encode(enteredWind))
        check(savedWindRange.title == "12–15 м/с · ЮВ" && savedWindRange.range?.midpoint == 13.5,
              "Show the selected manual wind range after reloading a session")
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
        check(SpotRoadTravel.durationLabel(2695) == "45 мин" &&
              SpotRoadTravel.durationLabel(4500) == "1 ч 15 мин" &&
              SpotRoadTravel.durationLabel(0) == "1 мин" && SpotRoadTravel.durationLabel(.infinity) == nil,
              "Show short, long and unavailable automobile travel times")
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
        let daylightFixture = fixture.replacingOccurrences(of: #""temperature_2m":[2,-3,null,0]"#, with: #""temperature_2m":[15,14,null,1],"weather_code":[0,3,95,61],"is_day":[1,1,1,0]"#)
        let dayForecast = try JSONDecoder().decode(SpotForecast.self, from: Data(daylightFixture.utf8))
        let dayHours = dayForecast.hours(near: Date(timeIntervalSince1970: 1699979999))
        check(dayHours.first?.condition.name == "Солнечно" && dayHours.last?.condition.name == "Дождь" &&
              dayHours.last?.daylight == false && SpotForecast.windArrow(315) == "↘", "Weather and downwind arrows")
        let midnight = ISO8601DateFormatter().date(from: "2025-04-03T00:00:00+03:00")!
        let timestamps = (0..<48).map { midnight.timeIntervalSince1970 + Double($0 * 3600) }
        let scale = SessionWind.metersPerSecondPerKnot
        func windowForecast(wind: (Int) -> Double?) throws -> SpotForecast {
            let speeds: [Any] = (0..<48).map { hour in
                if let speed = wind(hour) { return speed / scale }
                return NSNull()
            }
            let gusts = (0..<48).map { Double($0) / scale }
            let codes = (0..<48).map { $0 == 14 ? 95 : 0 }
            let hourly: [String: Any] = ["time": timestamps, "wind_speed_10m": speeds,
                                         "wind_gusts_10m": gusts, "weather_code": codes]
            let payload: [String: Any] = ["timezone": "Europe/Moscow", "hourly": hourly]
            return try JSONDecoder().decode(SpotForecast.self, from: JSONSerialization.data(withJSONObject: payload))
        }

        let rankingForecast = try windowForecast { hour in Double(hour) }
        let late = midnight.addingTimeInterval(23 * 3600)
        let summaries = rankingForecast.windowSummaries(relativeTo: late)
        let windows = SpotForecast.Window.allCases
        check(windows.map(\.title) == ["07:00–10:00", "10:00–13:00", "13:00–16:00", "16:00–20:00"] &&
              windows.compactMap { summaries[$0]?.hours } == [3, 3, 3, 5],
              "Divide 07:00 through 20:00 into local windows without double counting")
        let averages = windows.compactMap { summaries[$0]?.meanWind }
        check(averages.count == 4 && zip(averages, [8.0, 11, 14, 18]).allSatisfy { pair in abs(pair.0 - pair.1) < 0.00001 } &&
              summaries[.afternoon]?.thunder == true && abs((summaries[.afternoon]?.maxGust ?? 0) - 15) < 0.00001,
              "Keep the earlier forecasts, peak gusts and thunder in the right window")
        check(rankingForecast.windowSummaries(relativeTo: midnight.addingTimeInterval(-1)).isEmpty,
              "Missing day has no window summaries")

        let windyMorning = try windowForecast { hour in (7..<10).contains(hour) ? 9 : 2 }
        let windyEvening = try windowForecast { hour in (16...20).contains(hour) ? 11 : 2 }
        let weakForecast = try windowForecast { _ in 3 }
        var regionForecasts = [(spot, windyMorning), (nearby, windyEvening)]
        for i in 1...5 {
            let extra = RiderSpot(name: "Спот \(i)", latitude: "55.75", longitude: "37.62")!
            regionForecasts.append((extra, weakForecast))
        }
        let rankings = SpotForecast.rankings(relativeTo: late, forecasts: regionForecasts)
        check(rankings.allSatisfy { $0.spots.count == 5 } &&
              rankings.first?.spots.first?.id == spot.id && rankings.last?.spots.first?.id == nearby.id &&
              rankings[1].spots.allSatisfy { $0.weather.windLevel == .calm },
              "Pick a separate winner for each window and still show five results in weak wind")
        let beforeMorning = midnight.addingTimeInterval(6 * 3600)
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let atEight = midnight.addingTimeInterval(20 * 3600)
        check(SpotForecast.RankingDay.forEveningSwitch(at: atEight.addingTimeInterval(-1), calendar: localCalendar) == .today &&
              SpotForecast.RankingDay.forEveningSwitch(at: atEight, calendar: localCalendar) == .tomorrow &&
              SpotForecast.RankingDay.forEveningSwitch(at: midnight.addingTimeInterval(24 * 3600), calendar: localCalendar) == .today,
              "Rank tomorrow after the evening cutoff and today again at midnight")
        let nextRankings = SpotForecast.rankings(for: .tomorrow, relativeTo: late, forecasts: [(spot, rankingForecast)])
        check(nextRankings.count == 4 && abs((nextRankings.first?.spots.first?.weather.meanWind ?? 0) - 32) < 0.00001,
              "Rank tomorrow's hours in the spot's local timezone")
        let favoriteForecasts = [(spot, windyMorning), (nearby, windyEvening)]
        let firstWindow = SpotForecast.nearestWindWindow(after: beforeMorning, forecasts: favoriteForecasts)
        let eveningWindow = SpotForecast.nearestWindWindow(after: midnight.addingTimeInterval(10 * 3600),
                                                          forecasts: favoriteForecasts)
        check(firstWindow?.spot.id == spot.id && firstWindow?.start == midnight.addingTimeInterval(7 * 3600) &&
              eveningWindow?.spot.id == nearby.id && eveningWindow?.start == midnight.addingTimeInterval(16 * 3600),
              "Prefer the nearest eligible favorite window even when the later one is windier")
        let fadingWind = try windowForecast { hour in (7..<9).contains(hour) ? 12 : 1 }
        let tomorrowWind = try windowForecast { hour in (31..<34).contains(hour) ? 7 : 1 }
        let activeWindow = SpotForecast.nearestWindWindow(after: midnight.addingTimeInterval(7.5 * 3600),
                                                         forecasts: [(spot, windyMorning)])
        let nextDay = SpotForecast.nearestWindWindow(after: midnight.addingTimeInterval(9.5 * 3600),
                                                    forecasts: [(spot, fadingWind), (nearby, tomorrowWind)])
        check(activeWindow?.start == midnight.addingTimeInterval(7.5 * 3600) &&
              nextDay?.spot.id == nearby.id && nextDay?.start == midnight.addingTimeInterval(31 * 3600) &&
              SpotForecast.nearestWindWindow(after: late, forecasts: [(spot, weakForecast)]) == nil,
              "Use remaining hours in an active window and look at the next local day")
        let missingForecast = try windowForecast { hour in hour == 17 ? 7 : nil }
        let partial = missingForecast.windowSummaries(relativeTo: late)
        check(partial.count == 1 && partial[.evening]?.hours == 1 && partial[.evening]?.windLevel == .light,
              "Missing hours and windows do not turn into a forecast of zero wind")

        check([3.99, 4, 5.6, 7.99, 8, 9.99, 10].map(SpotForecast.WindLevel.average) == [.calm, .light, .light, .light, .medium, .medium, .strong] &&
              SpotForecast.WindLevel.average(5.6).description == "Обнаружен лайтвинд" &&
              SpotForecast.WindLevel.average(3.99).description == "Штиль" &&
              [8.99, 9, 12, 13, 13.01].map(SpotForecast.WindLevel.gust) == [.light, .medium, .medium, .medium, .strong],
              "Classify sustained wind and gusts independently at the specified thresholds")
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
