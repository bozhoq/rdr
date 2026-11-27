import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import SwiftUI
import UIKit

final class SessionRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var live: SessionSummary?
    @Published private(set) var history: [SessionSummary] = []
    @Published private(set) var favoriteSpots = Set((UserDefaults.standard.stringArray(forKey: "rider.favoriteSpots") ?? []).compactMap(UUID.init(uuidString:)))
    @Published private(set) var spots: [RiderSpot] = []
    @Published private(set) var gearPresets: [GearPreset] = []
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var motionIsRecent = false
    @Published var errorMessage: String?
    @Published private(set) var analyzingSessionID: UUID?
    @Published var draftSetup = SessionSetup(sport: .kite)
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationMessage: String?
    @Published private(set) var voiceEnabled = (UserDefaults.standard.object(forKey: "rider.jumpVoice") as? Bool) ?? true
    @Published private(set) var sensorCheckRunning = false
    @Published private(set) var checkedSensors: RecordingSensors?
    @Published private(set) var checkedCalibration: MotionCalibration?
    @Published private(set) var sensorCheckMessage: String?
    @Published var automaticConditions = (UserDefaults.standard.object(forKey: "rider.autoConditions") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(automaticConditions, forKey: "rider.autoConditions") }
    }
    @Published var manualWind: ManualWindRange?
    @Published var manualDirection: Int?
    @Published var automaticSpotOverride: String?
    @Published private(set) var attemptedLocation = false
    @Published private(set) var previewFix: CLLocation?
    @Published private(set) var locating = false
    private var conditionsResolved = false
    private var weatherTask: Task<Void, Never>?

    private let store: SessionStore
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let speech = AVSpeechSynthesizer()
    private let location = CLLocationManager()
    private var log: SessionLog?
    private var summary: SessionSummary?
    private var timer: Timer?
    private let clock = ContinuousClock()
    private var startedAt: ContinuousClock.Instant?
    private var lastCheckpoint: ContinuousClock.Instant?
    private var lastMotionReceivedAt: ContinuousClock.Instant?
    private var motionTimeOrigin: TimeInterval?
    private var lastLocationTimestamp: Date?
    private var routeFilter = RouteFilter()
    private var ridingDetector = RidingJumpDetector()
    private var verticalSamples: [VerticalTrajectory.Sample] = []
    private var lastMarkerAt: ContinuousClock.Instant?
    private var calibrationStartedAt: ContinuousClock.Instant?
    private var calibrationSamples: [MotionSample] = []
    private var recentAltitude: [AltitudeSample] = []
    private var recentFixes: [RoutePoint] = []
    private var approachDetector = ApproachJumpDetector()
    private var pendingRides = RideJumpQueue()
    private var motionClock: Date?
    private let gearPresetsKey = "rider.gearPresets"
    private let calibrationKey = "rider.calibrationByPlacement"
    @Published private(set) var motionCheckPercent = 0
    @Published private(set) var pressureCheckSamples = 0
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var checkOrigin: TimeInterval?

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }
    var pressureAvailable: Bool {
        CMAltimeter.isRelativeAltitudeAvailable() &&
            CMAltimeter.authorizationStatus() != .denied && CMAltimeter.authorizationStatus() != .restricted
    }
    var locationAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var hasRecordingSensors: Bool { motionAvailable || pressureAvailable || locationAuthorized }
    var usableFix: CLLocation? {
        guard locationAuthorized, let fix = previewFix, abs(fix.timestamp.timeIntervalSinceNow) <= 45 else { return nil }
        return fix
    }
    func nearestSpot(to fix: CLLocation) -> RiderSpot? {
        spots.filter { $0.areaOnly != true }.map { spot in
            (spot, min(fix.distance(from: CLLocation(latitude: spot.latitude, longitude: spot.longitude)),
                       spot.accessPoints?.map { fix.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }.min() ?? .infinity))
        }.filter { $0.1 <= 1500 }.min(by: { $0.1 < $1.1 })?.0
    }
    func locateSpot() {
        guard summary == nil else { return }
        attemptedLocation = true
        if authorization == .notDetermined { location.requestWhenInUseAuthorization() }
        else if locationAuthorized { locating = true; location.requestLocation() }
    }
    func refreshSOSFix() {
        guard summary?.gpsEnabledAtStart != true, locationAuthorized else { return }
        location.requestLocation()
    }

    var manualWindValid: Bool { manualDirection == nil || manualWind != nil }

    private var effectivePlacement: PhonePlacement { .chest }

    private var sensorInventory: RecordingSensors {
        RecordingSensors(accelerometer: motion.isAccelerometerAvailable, gyroscope: motion.isGyroAvailable,
                         deviceMotion: motionAvailable, barometer: pressureAvailable, locationAllowed: locationAuthorized)
    }

    private var calibrationPresets: [String: SavedMotionCalibration] {
        guard let data = UserDefaults.standard.data(forKey: calibrationKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedMotionCalibration].self, from: data)) ?? [:]
    }

    var savedCalibration: MotionCalibration? {
        calibrationPresets[effectivePlacement.rawValue]?.usable(at: Date(), systemVersion: UIDevice.current.systemVersion)
    }

    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("Sessions", isDirectory: true)) {
        store = SessionStore(root: root)
        super.init()
        speech.usesApplicationAudioSession = false
        authorization = location.authorizationStatus
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.showsBackgroundLocationIndicator = true
        if let data = UserDefaults.standard.data(forKey: "rider.sessionSetup"),
           let setup = try? JSONDecoder().decode(SessionSetup.self, from: data) { draftSetup = setup.forRecording }
        let saved = UserDefaults.standard.data(forKey: "rider.spots").flatMap {
            try? JSONDecoder().decode([RiderSpot].self, from: $0)
        } ?? []
        spots = StarterSpots.merge(saved: saved, catalogue: StarterSpots.load())
        let catalog = spots
        favoriteSpots = Set(favoriteSpots.map { old in catalog.first(where: { $0.includes(old) })?.id ?? old })
        if let place = catalog.first(where: { $0.accessPoints != nil && $0.matches(draftSetup) }) { draftSetup.selectSpot(place) }
        if let data = UserDefaults.standard.data(forKey: gearPresetsKey),
           let presets = try? JSONDecoder().decode([GearPreset].self, from: data) { gearPresets = presets }
        reloadHistory()
    }

    func requestLocation() {
        location.requestWhenInUseAuthorization()
    }

    func reuseSetup(_ setup: SessionSetup) {
        guard live == nil else { return }
        draftSetup = setup.forRecording
        if let data = try? JSONEncoder().encode(draftSetup) { UserDefaults.standard.set(data, forKey: "rider.sessionSetup") }
    }

    func saveGearPreset(named name: String, equipment: SessionSetup) -> Bool {
        guard live == nil, let preset = GearPreset(name: name, setup: equipment),
              !gearPresets.contains(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame || $0.matches(equipment) }),
              persistGearPresets(gearPresets + [preset]) else { return false }
        useGearPreset(preset)
        return true
    }

    func clearGearPreset() {
        var setup = draftSetup
        setup.clearEquipment()
        reuseSetup(setup)
    }

    func useGearPreset(_ preset: GearPreset) {
        reuseSetup(preset.applying(to: draftSetup))
    }

    func deleteGearPreset(_ preset: GearPreset) {
        if persistGearPresets(gearPresets.filter { $0.id != preset.id }), preset.matches(draftSetup) {
            clearGearPreset()
        }
    }

    private func persistGearPresets(_ presets: [GearPreset]) -> Bool {
        guard let data = try? JSONEncoder().encode(presets) else { return false }
        UserDefaults.standard.set(data, forKey: gearPresetsKey)
        gearPresets = presets
        return true
    }

    func saveSpot(_ spot: RiderSpot) -> Bool {
        if spots.contains(where: { $0.id != spot.id && $0.name.caseInsensitiveCompare(spot.name) == .orderedSame }) {
            return false
        }
        var updated = spots.filter { $0.id != spot.id }
        updated.append(spot)
        updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        UserDefaults.standard.set(data, forKey: "rider.spots")
        spots = updated
        if draftSetup.spotID == spot.id {
            var setup = draftSetup
            setup.selectSpot(spot)
            reuseSetup(setup)
        }
        return true
    }

    func toggleFavorite(_ spot: RiderSpot) {
        if !favoriteSpots.insert(spot.id).inserted { favoriteSpots.remove(spot.id) }
        UserDefaults.standard.set(favoriteSpots.map(\.uuidString), forKey: "rider.favoriteSpots")
    }

    func deletePersonalSpot(_ spot: RiderSpot) {
        guard spots.contains(where: { $0.id == spot.id && $0.region == nil }) else { return }
        let kept = spots.filter { $0.id != spot.id }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: "rider.spots")
        spots = kept
        if favoriteSpots.contains(spot.id) { toggleFavorite(spot) }
        if automaticSpotOverride == spot.name { automaticSpotOverride = nil }
        if draftSetup.spotID == spot.id {
            draftSetup.setSpotName("")
            if let data = try? JSONEncoder().encode(draftSetup) { UserDefaults.standard.set(data, forKey: "rider.sessionSetup") }
        }
    }

    func chooseSpot(_ spot: RiderSpot) {
        automaticConditions = false
        var setup = draftSetup
        setup.selectSpot(spot)
        reuseSetup(setup)
    }

    func checkSensors() {
        guard summary == nil, !sensorCheckRunning else { return }
        let id = UUID()
        checkID = id
        checkOrigin = nil
        calibrationSamples.removeAll()
        checkedCalibration = nil
        motionCheckPercent = 0
        pressureCheckSamples = 0
        sensorCheckMessage = nil
        checkedSensors = sensorInventory
        sensorCheckRunning = true
        if motionAvailable {
            motion.deviceMotionUpdateInterval = 1 / Double(SessionLog.targetMotionHz)
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
                guard let self, self.checkID == id else { return }
                if error != nil {
                    self.checkedSensors?.motionResponded = false
                    return
                }
                guard let motion else { return }
                let origin = self.checkOrigin ?? motion.timestamp
                self.checkOrigin = origin
                guard let sample = Self.motionSample(motion, elapsed: motion.timestamp - origin) else { return }
                if self.checkedSensors?.motionResponded != true { self.checkedSensors?.motionResponded = true }
                self.calibrationSamples.append(sample)
                let progress = min(99, Int(sample.elapsedSinceFirstSampleSeconds * 20))
                if progress != self.motionCheckPercent { self.motionCheckPercent = progress }
                if sample.elapsedSinceFirstSampleSeconds >= 5.0 {
                    self.finishSensorCheck(id)
                }
            }
        }
        if pressureAvailable {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let self, self.checkID == id else { return }
                if let data, error == nil, data.pressure.doubleValue.isFinite, data.pressure.doubleValue > 0 {
                    self.pressureCheckSamples += 1
                    self.checkedSensors?.pressureResponded = true
                    if self.pressureCheckSamples >= 3 { self.altimeter.stopRelativeAltitudeUpdates() }
                } else if error != nil {
                    self.checkedSensors?.pressureResponded = false
                    self.altimeter.stopRelativeAltitudeUpdates()
                }
            }
        }
        checkTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finishSensorCheck(id)
        }
    }

    private func finishSensorCheck(_ id: UUID) {
        guard checkID == id else { return }
        if checkedSensors?.motionResponded == nil { checkedSensors?.motionResponded = false }
        if checkedSensors?.pressureResponded == nil { checkedSensors?.pressureResponded = false }
        if checkedSensors?.motionResponded == true {
            do {
                guard let first = calibrationSamples.first, let last = calibrationSamples.last,
                      last.elapsedSinceFirstSampleSeconds - first.elapsedSinceFirstSampleSeconds >= 5,
                      calibrationSamples.allSatisfy({ abs($0.gravityG.z) >= 0.985 }) else {
                    sensorCheckMessage = "Положите iPhone горизонтально на 5 секунд и повторите проверку."
                    stopSensorCheck()
                    return
                }
                let calibration = try MotionCalibration.measure(calibrationSamples)
                checkedCalibration = MotionCalibration(completedAtSeconds: 0, frequencyHz: calibration.frequencyHz,
                                                       verticalOffset: calibration.verticalOffset, verticalNoise: calibration.verticalNoise)
                motionCheckPercent = 100
                if let checkedCalibration { saveCalibration(checkedCalibration, placement: effectivePlacement) }
            } catch let failure as MotionCalibration.Failure {
                sensorCheckMessage = failure.message
            } catch {
                sensorCheckMessage = "Поправку движения не удалось измерить."
            }
        } else {
            sensorCheckMessage = "Датчики движения не ответили. Можно начать каталку с доступными датчиками."
        }
        stopSensorCheck()
    }

    private func stopSensorCheck() {
        guard checkID != nil else { return }
        checkID = nil
        checkTask?.cancel()
        checkTask = nil
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        calibrationSamples.removeAll()
        sensorCheckRunning = false
    }

    func cancelSensorCheck() {
        stopSensorCheck()
        checkedSensors = nil
        checkedCalibration = nil
        sensorCheckMessage = nil
    }

    func start(mission: RiderMission? = nil) {
        guard summary == nil, analyzingSessionID == nil, hasRecordingSensors, automaticConditions || manualWindValid else { return }
        stopSensorCheck()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let calibration = checkedCalibration ?? savedCalibration
        var sessionSetup = draftSetup.forRecording
        if !gearPresets.contains(where: { $0.matches(sessionSetup) }) {
            sessionSetup.clearEquipment()
        }
        let fix = automaticConditions ? usableFix : nil
        if automaticConditions {
            sessionSetup.spotID = nil
            sessionSetup.spot = ""
            if let automaticSpotOverride { sessionSetup.setSpotName(automaticSpotOverride) }
            else if let fix, let nearest = nearestSpot(to: fix) { sessionSetup.selectSpot(nearest) }
        }
        if sessionSetup.spotID == nil, let matching = spots.first(where: { $0.matches(sessionSetup) }) {
            sessionSetup.selectSpot(matching)
        }
        var sensors = sensorInventory
        sensors.motionResponded = checkedSensors?.motionResponded
        sensors.pressureResponded = checkedSensors?.pressureResponded
        let sensorStart = ProcessInfo.processInfo.systemUptime
        var session = SessionSummary(
            startedAt: Date(),
            gpsEnabledAtStart: locationAuthorized,
            batteryAtStartPercent: batteryPercent,
            jumpAnalysis: JumpAnalysis(detectorVersion: RidingJumpDetector.version),
            markers: [],
            setup: sessionSetup,
            gpsMetrics: RouteMetrics(),
            altitude: AltitudeMetrics(supported: sensors.barometer),
            motionCalibration: calibration,
            liveJumpEstimates: [:],
            handSimulationTest: false,
            reusedMotionCalibration: checkedCalibration == nil && calibration != nil,
            recordingMode: .battle,
            sensors: sensors
        )
        session.mission = sessionSetup.sport.isRiding ? mission : nil
        session.automaticConditions = automaticConditions
        if !automaticConditions, let range = manualWind {
            session.wind = SessionWind(knots: range.midpoint / SessionWind.metersPerSecondPerKnot,
                                       direction: manualDirection.map { Double($0) },
                                       date: session.startedAt, source: "Вручную", range: range)
        }
        do {
            let newLog = try store.makeLog(for: session)
            do {
                try newLog.writeStart(session, systemVersion: UIDevice.current.systemVersion)
            } catch {
                newLog.close()
                try? store.delete(session.id)
                throw error
            }
            summary = session
            log = newLog
        } catch {
            UIDevice.current.isBatteryMonitoringEnabled = false
            errorMessage = "Не удалось начать запись. \(error.localizedDescription)"
            return
        }

        live = session
        checkedSensors = nil
        checkedCalibration = nil
        automaticSpotOverride = nil
        conditionsResolved = fix != nil
        weatherTask?.cancel()
        if let fix { fetchWind(at: fix, for: session.id, started: session.startedAt) }
        startedAt = clock.now
        lastCheckpoint = startedAt
        lastMotionReceivedAt = nil
        motionTimeOrigin = sensorStart
        lastLocationTimestamp = nil
        routeFilter = RouteFilter()
        if let data = try? JSONEncoder().encode(draftSetup.cleaned) { UserDefaults.standard.set(data, forKey: "rider.sessionSetup") }
        ridingDetector = RidingJumpDetector()
        verticalSamples.removeAll(keepingCapacity: true)
        lastMarkerAt = nil
        motionIsRecent = false
        resetCalibration()
        recentAltitude.removeAll()
        recentFixes.removeAll()
        approachDetector = ApproachJumpDetector()
        pendingRides = RideJumpQueue()
        motionClock = session.startedAt

        if session.gpsEnabledAtStart {
            location.allowsBackgroundLocationUpdates = true
            location.startUpdatingLocation()
        }
        if sensors.barometer { startAltitude(sessionID: session.id, origin: sensorStart) }
        if sensors.deviceMotion {
            motion.deviceMotionUpdateInterval = 1 / Double(SessionLog.targetMotionHz)
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
                guard let self, self.summary?.id == session.id else { return }
                if let error {
                    self.motion.stopDeviceMotionUpdates()
                    self.recordEvent("motionError", detail: error.localizedDescription)
                    if !sensors.barometer && !session.gpsEnabledAtStart {
                        self.finish(.interrupted)
                        self.errorMessage = "Нет данных с датчиков для продолжения записи."
                    }
                } else if let data {
                    self.recordMotion(data)
                }
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkpointIfDue()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        finish(.finished)
    }

    func toggleVoice() {
        voiceEnabled.toggle()
        UserDefaults.standard.set(voiceEnabled, forKey: "rider.jumpVoice")
        if !voiceEnabled { speech.stopSpeaking(at: .immediate) }
    }

    func calibrateMotion() {
        guard let summary, summary.motionCalibration == nil, motionIsRecent, !isCalibrating else { return }
        resetCalibration()
        calibrationStartedAt = clock.now
        isCalibrating = true
    }

    private func resetCalibration(message: String? = nil) {
        calibrationStartedAt = nil
        calibrationSamples.removeAll()
        isCalibrating = false
        calibrationMessage = message
    }

    func addMarker(_ kind: MarkerKind) {
        guard var session = summary, let log,
              let elapsed = session.motion.lastElapsedSeconds,
              let received = lastMotionReceivedAt,
              received.duration(to: clock.now) <= .milliseconds(250) else {
            errorMessage = "Для метки нужны свежие данные движения. Дождитесь возобновления записи датчиков."
            return
        }
        if let lastMarkerAt, lastMarkerAt.duration(to: clock.now) < .milliseconds(500) { return }
        let marker = SessionMarker(elapsedSeconds: elapsed, kind: kind)
        do {
            try log.append("marker", marker)
            if session.markers == nil { session.markers = [] }
            session.markers?.append(marker)
            summary = session
            lastMarkerAt = clock.now
            checkpointIfDue(force: true)
        } catch { failStorage(error) }
    }

    @discardableResult
    func saveNotes(title: String, notes: String, for id: UUID) -> Bool {
        guard summary?.id != id, analyzingSessionID != id else { return false }
        do {
            try store.saveNotes(title: title, notes: notes, for: id)
            reloadHistory()
            return true
        } catch {
            errorMessage = "Не удалось сохранить заметки. \(error.localizedDescription)"
            return false
        }
    }

    func label(_ candidate: UUID, as label: JumpLabel, in id: UUID) {
        guard summary?.id != id, analyzingSessionID != id else { return }
        do {
            try store.saveLabel(label, candidateID: candidate, for: id)
            reloadHistory()
        } catch {
            errorMessage = "Не удалось сохранить отметку. \(error.localizedDescription)"
        }
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard summary != nil else { return }
        if phase != .active, isCalibrating {
            resetCalibration(message: "Для калибровки оставьте Rider открытым.")
        }
        switch phase {
        case .active: recordEvent("active")
        case .inactive: recordEvent("inactive")
        case .background: recordEvent("background")
        @unknown default: return
        }
        checkpointIfDue(force: true)
    }

    func exportURL(for id: UUID) -> URL {
        store.logURL(for: id)
    }

    func saveSetup(_ setup: SessionSetup, for id: UUID) -> Bool {
        guard summary?.id != id, analyzingSessionID != id else { return false }
        do { try store.saveSetup(setup, for: id); reloadHistory(); return true }
        catch { errorMessage = "Не удалось сохранить снаряжение. \(error.localizedDescription)"; return false }
    }

    func saveGPSMetrics(_ metrics: RouteMetrics, for id: UUID) {
        guard summary?.id != id else { return }
        do { try store.saveGPSMetrics(metrics, for: id); reloadHistory() }
        catch { errorMessage = "Маршрут открыт, но GPS-итоги не сохранены. \(error.localizedDescription)" }
    }

    func delete(_ id: UUID) {
        guard summary?.id != id, analyzingSessionID != id else { return }
        do {
            try store.delete(id)
            history.removeAll { $0.id == id }
        } catch {
            errorMessage = "Не удалось удалить сессию. \(error.localizedDescription)"
        }
    }

    @MainActor
    func analyze(_ id: UUID) async {
        guard summary == nil, analyzingSessionID == nil,
              history.first(where: { $0.id == id })?.canReplayGroundEvents == true else { return }
        analyzingSessionID = id
        defer { analyzingSessionID = nil }
        let url = store.logURL(for: id)
        do {
            let analysis = try await Task.detached(priority: .userInitiated) {
                try JumpReplay.analyze(url: url)
            }.value
            try store.saveAnalysis(analysis, for: id)
            reloadHistory()
        } catch {
            errorMessage = "Не удалось разобрать запись. \(error.localizedDescription)"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if locationAuthorized && (automaticConditions || attemptedLocation) && summary == nil { locateSpot() }
        if summary?.gpsEnabledAtStart == true && !locationAuthorized {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            routeFilter.breakContinuity()
            recordEvent("locationPermissionLost")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locating = false
        if let fix = locations.last(where: { (0...65).contains($0.horizontalAccuracy) && abs($0.timestamp.timeIntervalSinceNow) <= 45 }) {
            previewFix = fix
            Task { @MainActor in RiderSOSService.shared.observeLocation(fix) }
        } else { previewFix = nil }
        guard summary?.gpsEnabledAtStart == true, locationAuthorized else { return }
        for point in locations {
            recordLocation(point)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locating = false
        previewFix = nil
        if (error as? CLError)?.code == .locationUnknown { return }
        recordEvent("locationError", detail: error.localizedDescription)
    }

    private var batteryPercent: Int? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int((level * 100).rounded()) : nil
    }

    private static func motionSample(_ motion: CMDeviceMotion, elapsed: Double) -> MotionSample? {
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        let a = motion.userAcceleration
        let g = motion.gravity
        let r = motion.rotationRate
        let q = motion.attitude.quaternion
        let gravityNorm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard gravityNorm.isFinite, gravityNorm > 0 else { return nil }
        return MotionSample(
            elapsedSinceFirstSampleSeconds: elapsed,
            accelerationG: Vector3(x: a.x, y: a.y, z: a.z),
            gravityG: Vector3(x: g.x, y: g.y, z: g.z),
            rotationRadiansPerSecond: Vector3(x: r.x, y: r.y, z: r.z),
            attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w),
            verticalAccelerationMetersPerSecondSquared: -(a.x * g.x + a.y * g.y + a.z * g.z) * 9.80665 / gravityNorm
        )
    }

    private func recordMotion(_ motion: CMDeviceMotion) {
        guard var session = summary, let log, let origin = motionTimeOrigin else { return }
        let elapsed = motion.timestamp - origin
        guard elapsed > (session.motion.lastElapsedSeconds ?? -.infinity),
              let sample = Self.motionSample(motion, elapsed: elapsed) else { return }
        do {
            try log.append("motion", sample)
            session.motion.add(elapsed)
            try updateCalibration(sample, session: &session, log: log)
            let vertical = session.motionCalibration.map {
                -$0.correctedVertical(sample.verticalAccelerationMetersPerSecondSquared, at: elapsed)
            } ?? sample.upwardAcceleration
            verticalSamples.append(.init(time: elapsed, acceleration: vertical))
            if verticalSamples.count >= 4800 { verticalSamples.removeFirst(800) }
            let moving: Bool
            if let latest = recentFixes.last, let speed = latest.speed, let motionClock {
                let age = motionClock.addingTimeInterval(elapsed).timeIntervalSince(latest.sample.timestamp)
                moving = speed >= 2 && speed - (latest.sample.speedAccuracyMetersPerSecond ?? .infinity) >= 1.3 && (0...2).contains(age)
            } else {
                moving = false
            }
            if let excursion = approachDetector.process(sample, calibration: session.motionCalibration, moving: moving) {
                let evidence = approachDetector.approach(before: excursion.event.startSeconds)
                pendingRides.add(excursion, gpsApproach: evidence.gps)
            }
            if let flight = ridingDetector.process(sample, calibration: session.motionCalibration, moving: moving) {
                // Look before the push so the takeoff itself cannot provide the approach.
                let evidence = approachDetector.approach(before: flight.event.startSeconds - 0.30)
                if evidence.allowed { pendingRides.add(flight, gpsApproach: evidence.gps) }
            }
            if let reason = ridingDetector.lastRejection {
                try log.append("event", SessionEvent(name: "jumpRejected", batteryPercent: batteryPercent, detail: reason))
            }
            session.jumpAnalysis?.discontinuities = ridingDetector.discontinuities
            summary = session
            lastMotionReceivedAt = clock.now
            checkpointIfDue()
        } catch {
            failStorage(error)
        }
    }

    private func updateCalibration(_ sample: MotionSample, session: inout SessionSummary, log: SessionLog) throws {
        guard isCalibrating else { return }
        calibrationSamples.append(sample)
        guard let first = calibrationSamples.first else { return }
        if sample.elapsedSinceFirstSampleSeconds - first.elapsedSinceFirstSampleSeconds < MotionCalibration.durationSeconds {
            if calibrationSamples.count >= 1_000 { resetCalibration(message: MotionCalibration.Failure.timing.message) }
            return
        }
        let result: MotionCalibration
        do {
            result = try MotionCalibration.measure(calibrationSamples)
        } catch let failure as MotionCalibration.Failure {
            resetCalibration(message: failure.message)
            return
        }
        try log.append("motionCalibration", result)
        session.motionCalibration = result
        if let placement = session.setup?.placement { saveCalibration(result, placement: placement) }
        resetCalibration()
    }

    private func saveCalibration(_ result: MotionCalibration, placement: PhonePlacement) {
        guard placement != .unspecified else { return }
        var presets = calibrationPresets
        presets[placement.rawValue] = SavedMotionCalibration(measurement: result, measuredAt: Date(), systemVersion: UIDevice.current.systemVersion)
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: calibrationKey) }
    }

    private func startAltitude(sessionID: UUID, origin: TimeInterval) {
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, var session = self.summary, session.id == sessionID,
                  var altitude = session.altitude, !altitude.stoppedWithError, let log = self.log else { return }
            do {
                if let error {
                    self.altimeter.stopRelativeAltitudeUpdates()
                    altitude.stoppedWithError = true
                    try log.append("event", SessionEvent(name: "altitudeError", batteryPercent: self.batteryPercent, detail: error.localizedDescription))
                } else if let data {
                    // Both Core Motion streams use seconds since boot.
                    let sample = AltitudeSample(elapsedSinceFirstSampleSeconds: data.timestamp - origin,
                                                pressureKilopascals: data.pressure.doubleValue,
                                                relativeAltitudeMeters: data.relativeAltitude.doubleValue)
                    guard altitude.add(sample) else { return }
                    try log.append("altitude", sample)
                    self.recentAltitude.append(sample)
                    self.recentAltitude.removeAll { sample.elapsedSinceFirstSampleSeconds - $0.elapsedSinceFirstSampleSeconds > 36 }
                    if self.recentAltitude.count > 128 { self.recentAltitude.removeFirst() }
                } else { return }
                session.altitude = altitude
                self.summary = session
                self.checkpointIfDue(force: error != nil)
            } catch {
                self.failStorage(error)
            }
        }
    }

    private func recordLocation(_ point: CLLocation) {
        guard var session = summary, let log,
              point.timestamp >= session.startedAt,
              point.timestamp > (lastLocationTimestamp ?? .distantPast),
              CLLocationCoordinate2DIsValid(point.coordinate),
              point.horizontalAccuracy.isFinite, point.horizontalAccuracy >= 0 else { return }
        if session.automaticConditions == true, !conditionsResolved, point.horizontalAccuracy <= 65,
           abs(point.timestamp.timeIntervalSinceNow) <= 45 {
            conditionsResolved = true
            if session.setup?.spot.isEmpty != false, let nearest = nearestSpot(to: point) { session.setup?.selectSpot(nearest) }
            fetchWind(at: point, for: session.id, started: session.startedAt)
        }
        let sample = LocationSample(
            timestamp: point.timestamp,
            latitude: point.coordinate.latitude,
            longitude: point.coordinate.longitude,
            horizontalAccuracyMeters: point.horizontalAccuracy,
            speedMetersPerSecond: point.speed.isFinite && point.speed >= 0 ? point.speed : nil,
            speedAccuracyMetersPerSecond: point.speedAccuracy.isFinite && point.speedAccuracy >= 0 ? point.speedAccuracy : nil
        )
        do {
            try log.append("location", sample)
            lastLocationTimestamp = point.timestamp
            session.locationCount += 1
            if let accepted = routeFilter.accept(sample, notBefore: session.startedAt) {
                recentFixes.append(accepted)
                recentFixes.removeAll { sample.timestamp.timeIntervalSince($0.sample.timestamp) > 36 }
                if recentFixes.count > 128 { recentFixes.removeFirst() }
            }
            session.gpsMetrics = routeFilter.metrics
            session.distanceMeters = routeFilter.metrics.accepted > 0 ? routeFilter.metrics.distanceMeters : nil
            session.maxSpeedMetersPerSecond = routeFilter.metrics.maxSpeedMetersPerSecond
            summary = session
            checkpointIfDue()
        } catch {
            failStorage(error)
        }
    }

    private func fetchWind(at fix: CLLocation, for id: UUID, started: Date) {
        // Forecast grid resolution is coarser than a GPS fix. Send rounded coordinates.
        guard let point = RiderSpot(name: "GPS", latitude: String((fix.coordinate.latitude * 100).rounded() / 100),
                                    longitude: String((fix.coordinate.longitude * 100).rounded() / 100)),
              let url = SpotForecast.requestURL(for: point) else { return }
        weatherTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let hour = try JSONDecoder().decode(SpotForecast.self, from: data).hours(near: started)
                        .min(by: { abs($0.time.timeIntervalSince(started)) < abs($1.time.timeIntervalSince(started)) }),
                      abs(hour.time.timeIntervalSince(started)) <= 3600,
                      let self, var current = self.summary, current.id == id else { return }
                current.wind = SessionWind(knots: hour.speed, gust: hour.gust, direction: hour.direction,
                                           date: hour.time, source: "Прогноз Open-Meteo")
                self.summary = current
                self.checkpointIfDue(force: true)
            } catch { /* Offline sessions keep the wind field empty. */ }
        }
    }

    private struct JumpEstimateEntry: Encodable {
        let startSeconds: Double
        let endSeconds: Double
        let estimate: LiveJumpEstimate
    }

    private func resolveJumps(_ session: inout SessionSummary, log: SessionLog, finishing: Bool = false) throws {
        let elapsed = ProcessInfo.processInfo.systemUptime - (motionTimeOrigin ?? ProcessInfo.processInfo.systemUptime)
        for flight in approachDetector.pressureFlights(recentAltitude) {
            pendingRides.add(flight, gpsApproach: approachDetector.approach(before: flight.event.startSeconds).gps)
        }
        let confirmed = pendingRides.resolve(through: elapsed, finishing: finishing, vertical: verticalSamples,
                                             altitude: recentAltitude, gps: recentFixes, motionClock: motionClock, holdingFrom: approachDetector.holdingFrom)
        for (event, estimate) in confirmed {
            try log.append("jumpCandidate", event)
            session.jumpAnalysis?.candidates.append(event)
            try storeEstimate(estimate, for: event, session: &session, log: log, speak: !finishing)
        }
    }

    private func storeEstimate(_ estimate: LiveJumpEstimate, for event: JumpCandidate,
                               session: inout SessionSummary, log: SessionLog, speak: Bool) throws {
        let key = SessionReview.key(for: event, version: session.jumpAnalysis?.detectorVersion ?? JumpDetector.version)
        try log.append("liveJumpEstimate", JumpEstimateEntry(startSeconds: event.startSeconds, endSeconds: event.endSeconds, estimate: estimate))
        session.liveJumpEstimates?[key] = estimate
        let phrase = estimate.heightMeters.flatMap(LiveJumpEstimate.spokenHeight)
            .map { estimate.assumesLevelLanding == true || estimate.inertialLift == true ? "Примерно \($0)" : $0 }
            ?? (session.recordingMode == .battle ? "Прыжок" : nil)
        if speak, voiceEnabled, let phrase {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            speech.speak(utterance)
        }
    }

    private func recordEvent(_ name: String, detail: String? = nil) {
        guard let log else { return }
        do {
            try log.append("event", SessionEvent(
                name: name,
                batteryPercent: batteryPercent,
                detail: detail
            ))
            routeFilter.breakContinuity()
        } catch {
            failStorage(error)
        }
    }

    private func checkpointIfDue(force: Bool = false) {
        guard var session = summary, let log, let lastCheckpoint else { return }
        let now = clock.now
        if let calibrationStartedAt, calibrationStartedAt.duration(to: now) > .seconds(6) {
            resetCalibration(message: MotionCalibration.Failure.timing.message)
        }
        guard force || lastCheckpoint.duration(to: now) >= .seconds(1) else { return }
        updateCheckpoint(&session, at: now)
        do {
            try resolveJumps(&session, log: log)
            try log.checkpoint(session)
            self.lastCheckpoint = now
            summary = session
            live = session
            motionIsRecent = lastMotionReceivedAt.map { $0.duration(to: now) <= .seconds(2) } ?? false
        } catch {
            failStorage(error)
        }
    }

    private func updateCheckpoint(_ session: inout SessionSummary, at now: ContinuousClock.Instant) {
        if let startedAt {
            let elapsed = startedAt.duration(to: now).components
            session.durationSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        session.batteryAtCheckpointPercent = batteryPercent
    }

    private func finish(_ status: SessionSummary.Status) {
        guard var session = summary, let log else { return }
        session.status = status
        updateCheckpoint(&session, at: clock.now)
        do {
            try resolveJumps(&session, log: log, finishing: true)
            try log.append("end", session)
            try log.checkpoint(session)
            stopSensors()
            reloadHistory()
        } catch {
            failStorage(error)
        }
    }

    private func stopSensors() {
        summary = nil
        speech.stopSpeaking(at: .immediate)
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        timer?.invalidate()
        timer = nil
        log?.close()
        log = nil
        live = nil
        motionIsRecent = false
        resetCalibration()
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func failStorage(_ error: Error) {
        stopSensors()
        reloadHistory()
        errorMessage = "Запись остановлена из-за ошибки сохранения. \(error.localizedDescription)"
    }

    private func reloadHistory() {
        do {
            history = try store.history().map { saved in
                var session = saved
                if let spot = spots.first(where: { $0.accessPoints != nil && $0.matches(saved.setup) }) {
                    session.setup?.selectSpot(spot)
                }
                return session
            }
        } catch {
            errorMessage = "Не удалось прочитать историю. \(error.localizedDescription)"
        }
    }
}
