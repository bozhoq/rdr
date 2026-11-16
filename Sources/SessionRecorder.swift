import CoreLocation
import CoreMotion
import Foundation
import SwiftUI
import UIKit

final class SessionRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var live: SessionSummary?
    @Published private(set) var history: [SessionSummary] = []
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var motionIsRecent = false
    @Published var errorMessage: String?
    @Published private(set) var analyzingSessionID: UUID?
    @Published var draftSetup = SessionSetup(sport: .groundTest)

    private let store = SessionStore()
    private let motion = CMMotionManager()
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
    private var jumpDetector = JumpDetector()
    private var lastMarkerAt: ContinuousClock.Instant?

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }
    var locationAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    override init() {
        super.init()
        authorization = location.authorizationStatus
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.showsBackgroundLocationIndicator = true
        if let data = UserDefaults.standard.data(forKey: "rider.sessionSetup"),
           let setup = try? JSONDecoder().decode(SessionSetup.self, from: data) { draftSetup = setup }
        reloadHistory()
    }

    func requestLocation() {
        location.requestWhenInUseAuthorization()
    }

    func reuseSetup(_ setup: SessionSetup) {
        guard live == nil else { return }
        draftSetup = setup.cleaned
        if let data = try? JSONEncoder().encode(draftSetup) { UserDefaults.standard.set(data, forKey: "rider.sessionSetup") }
    }

    func start() {
        guard summary == nil, analyzingSessionID == nil, motionAvailable else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let session = SessionSummary(
            startedAt: Date(),
            gpsEnabledAtStart: locationAuthorized,
            batteryAtStartPercent: batteryPercent,
            jumpAnalysis: JumpAnalysis(),
            markers: [],
            setup: draftSetup.cleaned,
            gpsMetrics: RouteMetrics()
        )
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
        startedAt = clock.now
        lastCheckpoint = startedAt
        lastMotionReceivedAt = nil
        motionTimeOrigin = nil
        lastLocationTimestamp = nil
        routeFilter = RouteFilter()
        if let data = try? JSONEncoder().encode(draftSetup.cleaned) { UserDefaults.standard.set(data, forKey: "rider.sessionSetup") }
        jumpDetector = JumpDetector()
        lastMarkerAt = nil
        motionIsRecent = false

        if session.gpsEnabledAtStart {
            location.allowsBackgroundLocationUpdates = true
            location.startUpdatingLocation()
        }
        motion.deviceMotionUpdateInterval = 1 / Double(SessionLog.targetMotionHz)
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
            guard let self, self.summary?.id == session.id else { return }
            if let error {
                self.recordEvent("motionError", detail: error.localizedDescription)
                self.finish(.interrupted)
                self.errorMessage = "Запись движения прервалась. \(error.localizedDescription)"
            } else if let data {
                self.recordMotion(data)
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
        guard summary == nil, analyzingSessionID == nil else { return }
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
        if summary?.gpsEnabledAtStart == true && !locationAuthorized {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            routeFilter.breakContinuity()
            recordEvent("locationPermissionLost")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard summary?.gpsEnabledAtStart == true, locationAuthorized else { return }
        for point in locations {
            recordLocation(point)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        recordEvent("locationError", detail: error.localizedDescription)
    }

    private var batteryPercent: Int? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int((level * 100).rounded()) : nil
    }

    private func recordMotion(_ motion: CMDeviceMotion) {
        guard var session = summary, let log, motion.timestamp.isFinite else { return }
        let origin = motionTimeOrigin ?? motion.timestamp
        let elapsed = motion.timestamp - origin
        guard elapsed > (session.motion.lastElapsedSeconds ?? -.infinity) else { return }
        let a = motion.userAcceleration
        let g = motion.gravity
        let r = motion.rotationRate
        let q = motion.attitude.quaternion
        let gravityNorm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard gravityNorm.isFinite, gravityNorm > 0 else { return }
        let sample = MotionSample(
            elapsedSinceFirstSampleSeconds: elapsed,
            accelerationG: Vector3(x: a.x, y: a.y, z: a.z),
            gravityG: Vector3(x: g.x, y: g.y, z: g.z),
            rotationRadiansPerSecond: Vector3(x: r.x, y: r.y, z: r.z),
            attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w),
            verticalAccelerationMetersPerSecondSquared: -(a.x * g.x + a.y * g.y + a.z * g.z) * 9.80665 / gravityNorm
        )
        do {
            try log.append("motion", sample)
            session.motion.add(elapsed)
            if let candidate = jumpDetector.process(sample) {
                try log.append("jumpCandidate", candidate)
                session.jumpAnalysis?.candidates.append(candidate)
            }
            session.jumpAnalysis?.discontinuities = jumpDetector.discontinuities
            summary = session
            motionTimeOrigin = origin
            lastMotionReceivedAt = clock.now
            checkpointIfDue()
        } catch {
            failStorage(error)
        }
    }

    private func recordLocation(_ point: CLLocation) {
        guard var session = summary, let log,
              point.timestamp >= session.startedAt,
              point.timestamp > (lastLocationTimestamp ?? .distantPast),
              CLLocationCoordinate2DIsValid(point.coordinate),
              point.horizontalAccuracy.isFinite, point.horizontalAccuracy >= 0 else { return }
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
            _ = routeFilter.accept(sample, notBefore: session.startedAt)
            session.gpsMetrics = routeFilter.metrics
            session.distanceMeters = routeFilter.metrics.accepted > 0 ? routeFilter.metrics.distanceMeters : nil
            session.maxSpeedMetersPerSecond = routeFilter.metrics.maxSpeedMetersPerSecond
            summary = session
            checkpointIfDue()
        } catch {
            failStorage(error)
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
        guard force || lastCheckpoint.duration(to: now) >= .seconds(1) else { return }
        updateCheckpoint(&session, at: now)
        do {
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
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        timer?.invalidate()
        timer = nil
        log?.close()
        log = nil
        live = nil
        motionIsRecent = false
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func failStorage(_ error: Error) {
        stopSensors()
        reloadHistory()
        errorMessage = "Запись остановлена из-за ошибки сохранения. \(error.localizedDescription)"
    }

    private func reloadHistory() {
        do {
            history = try store.history()
        } catch {
            errorMessage = "Не удалось прочитать историю. \(error.localizedDescription)"
        }
    }
}
