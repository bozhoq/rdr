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
    private var distanceAnchor: CLLocation?
    private var jumpDetector = JumpDetector()

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
        reloadHistory()
    }

    func requestLocation() {
        location.requestWhenInUseAuthorization()
    }

    func start() {
        guard summary == nil, analyzingSessionID == nil, motionAvailable else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let session = SessionSummary(
            startedAt: Date(),
            gpsEnabledAtStart: locationAuthorized,
            batteryAtStartPercent: batteryPercent,
            jumpAnalysis: JumpAnalysis()
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
        distanceAnchor = nil
        jumpDetector = JumpDetector()
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
            distanceAnchor = nil
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
            if point.horizontalAccuracy <= 30 {
                if let speed = sample.speedMetersPerSecond,
                   let accuracy = sample.speedAccuracyMetersPerSecond, accuracy <= 3 {
                    session.maxSpeedMetersPerSecond = max(session.maxSpeedMetersPerSecond ?? 0, speed)
                }
                updateDistance(&session, with: point)
            } else {
                distanceAnchor = nil
            }
            summary = session
            checkpointIfDue()
        } catch {
            failStorage(error)
        }
    }

    private func updateDistance(_ session: inout SessionSummary, with point: CLLocation) {
        guard let anchor = distanceAnchor, point.timestamp.timeIntervalSince(anchor.timestamp) <= 15 else {
            distanceAnchor = point
            return
        }
        let meters = point.distance(from: anchor)
        guard meters.isFinite else { return }
        if session.distanceMeters == nil { session.distanceMeters = 0 }
        guard meters >= 5 else { return }
        session.distanceMeters = (session.distanceMeters ?? 0) + meters
        distanceAnchor = point
    }

    private func recordEvent(_ name: String, detail: String? = nil) {
        guard let log else { return }
        do {
            try log.append("event", SessionEvent(
                name: name,
                batteryPercent: batteryPercent,
                detail: detail
            ))
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
