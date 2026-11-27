import AVFoundation
import AudioToolbox
import CoreLocation
import MapKit
import SwiftUI
import UIKit
import UserNotifications

struct RiderSOSFix: Codable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let capturedAt: TimeInterval

    init?(_ fix: CLLocation?) {
        guard let fix, CLLocationCoordinate2DIsValid(fix.coordinate),
              (0...65).contains(fix.horizontalAccuracy),
              (-5...45).contains(-fix.timestamp.timeIntervalSinceNow) else { return nil }
        latitude = fix.coordinate.latitude
        longitude = fix.coordinate.longitude
        accuracy = fix.horizontalAccuracy
        capturedAt = fix.timestamp.timeIntervalSince1970
    }
}

final class RiderSOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "RIDER_SOS_ACCEPT", title: "Отозваться", options: [.foreground]),
            UNNotificationAction(identifier: "RIDER_SOS_SKIP", title: "Пропустить", options: [])
        ]
        center.setNotificationCategories([UNNotificationCategory(identifier: "RIDER_SOS", actions: actions,
                                                                  intentIdentifiers: [])])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in RiderSOSService.shared.register(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in RiderSOSService.shared.registrationFailed() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard !UserDefaults.standard.bool(forKey: "rider.accountNeedsSignIn") else { return [] }
        let info = notification.request.content.userInfo
        if let kind = info["riderSocial"] as? String {
            guard RiderAlertKind(rawValue: kind)?.enabled == true else { return [] }
            return RiderAlertKind.sound.enabled ? [.banner, .sound] : [.banner]
        }
        if info["riderSOS"] != nil && RiderAlertKind.sos.enabled {
            await MainActor.run { RiderSOSService.shared.playAlarm() }
            return [.banner]
        }
        guard info["riderSOSReply"] != nil else { return [] }
        return RiderAlertKind.sound.enabled ? [.banner, .sound] : [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard !UserDefaults.standard.bool(forKey: "rider.accountNeedsSignIn") else { return }
        let info = response.notification.request.content.userInfo
        if let kind = info["riderSocial"] as? String {
            await MainActor.run { NotificationCenter.default.post(name: Notification.Name("rider.social.open"), object: kind) }
            return
        }
        if let id = (info["riderSOSReply"] as? String).flatMap(UUID.init(uuidString:)) {
            await MainActor.run { RiderSOSService.shared.openReceipt(id) }
            return
        }
        guard let id = (info["riderSOS"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        await RiderSOSService.shared.handleNotification(id, action: response.actionIdentifier)
    }
}

@MainActor final class RiderSOSService: ObservableObject {
    static let shared = RiderSOSService()

    struct Responder: Decodable, Identifiable {
        let id: String
        let name: String
        let decidedAt: TimeInterval
    }

    struct Receipt: Decodable {
        let id: UUID
        let recipients: Int
        let acceptedByAPNs: Int
        let inApp: Int?
        let seenInApp: Int?
        let pending: Int
        let location: RiderSOSFix?
        let responders: [Responder]?
        let createdAt: TimeInterval?
        let closed: Bool?

        var active: Bool {
            closed != true && (createdAt.map { Date().timeIntervalSince1970 - $0 < 900 } ?? true)
        }

        var status: String {
            if closed == true { return "Сигнал завершён" }
            if !active { return "Время оповещения истекло" }
            if recipients == 0 { return "Сигнал принят. Нет доступных райдеров поблизости." }
            if let inApp, inApp > 0 { return "SOS в Rider · получено \(seenInApp ?? 0) из \(inApp)" }
            if pending > 0 { return "Сигнал принят сервером · адресатов \(recipients)" }
            return "Apple приняла \(acceptedByAPNs) из \(recipients) уведомлений"
        }
    }

    enum Decision: String, Codable { case accept, skip }

    struct Alert: Decodable, Identifiable {
        let id: UUID
        let createdAt: TimeInterval
        let name: String
        let equipment: String?
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        let decision: Decision?
    }

    struct Inbox: Identifiable {
        let id = UUID()
        let selected: UUID?
        var outgoing = false
    }

    private struct Receiver: Codable {
        let token: String?
        let location: RiderSOSFix
    }
    private struct ReceiverStatus: Decodable { let enabled: Bool }
    private struct DecisionBody: Codable { let action: Decision; let name: String }
    private struct DecisionResult: Decodable { let action: Decision }
    private struct Incident: Encodable {
        let id: UUID
        let name: String
        let equipment: String?
        let location: RiderSOSFix
    }

    @Published private(set) var available = false
    @Published private(set) var receiverStatus: String?
    @Published var inbox: Inbox?
    private(set) var radarVisible = false
    private var token: String?
    private var latestFix: RiderSOSFix?
    private var lastUpdate = Date.distantPast
    private var receiverTask: Task<Void, Never>?
    private var requestingPermission = false
    private var announcedForeground: Set<UUID> = []
    private var soundedForeground: Set<UUID> = []
    private var alarm: AVAudioPlayer?
    private var alarmTask: Task<Void, Never>?
    private var previousAudio: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                                options: AVAudioSession.CategoryOptions)?
    private let registeredKey = "rider.sos.registered"

    func open(_ selected: UUID? = nil) {
        inbox = Inbox(selected: selected)
    }

    func openReceipt(_ id: UUID) {
        if !radarVisible { inbox = Inbox(selected: id, outgoing: true) }
    }

    func showRadar(_ visible: Bool) { radarVisible = visible }

    func handleNotification(_ id: UUID, action: String) async {
        switch action {
        case "RIDER_SOS_ACCEPT":
            do {
                let decision = try await decide(.accept, for: id)
                if decision == .accept { open(id) }
            } catch { open(id) }
        case "RIDER_SOS_SKIP":
            do { _ = try await decide(.skip, for: id) }
            catch { receiverStatus = "Не удалось сохранить пропуск. Сигнал остаётся в списке." }
        case UNNotificationDefaultActionIdentifier: open(id)
        default: break
        }
    }

    func refreshAuthorization(prompt: Bool = false) async {
        guard RiderCommunity.endpoint != nil, !requestingPermission else { return }
        if RiderCommunity.usesLANTrust {
            available = true
            uploadLocationIfNeeded()
            return
        }
        requestingPermission = true
        defer { requestingPermission = false }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined && prompt {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        available = status == .authorized || status == .provisional || status == .ephemeral
        guard available else {
            receiverStatus = status == .denied ? "Для SOS разреши уведомления Rider в настройках iPhone." : nil
            token = nil
            receiverTask?.cancel()
            await receiverTask?.value
            if UserDefaults.standard.bool(forKey: registeredKey) {
                do {
                    let _: ReceiverStatus = try await RiderCommunity.decode("sos/device", method: "DELETE")
                    UserDefaults.standard.removeObject(forKey: registeredKey)
                } catch { /* Try again the next time the app becomes active. */ }
            }
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
        uploadLocationIfNeeded()
    }

    func register(_ token: String) {
        guard available else { return }
        if self.token != token { lastUpdate = .distantPast }
        self.token = token
        uploadLocationIfNeeded()
        Task {
            do {
                let body = try JSONEncoder().encode(["token": token])
                let _: ReceiverStatus = try await RiderCommunity.decode("sos/device", method: "PUT", body: body)
                if available { UserDefaults.standard.set(true, forKey: registeredKey) }
            } catch {
                if available { receiverStatus = "Не удалось зарегистрировать уведомления SOS." }
            }
        }
    }

    func registrationFailed() {
        guard available else { return }
        receiverStatus = "iOS не разрешила push для этой установки Rider."
    }

    func observeLocation(_ fix: CLLocation) {
        latestFix = RiderSOSFix(fix)
        uploadLocationIfNeeded()
    }

    func updateReceiving(_ enabled: Bool) async {
        if enabled { lastUpdate = .distantPast; await refreshAuthorization(prompt: true); return }
        receiverTask?.cancel()
        await receiverTask?.value
        guard !RiderAlertKind.sos.enabled else { return }
        if RiderCommunity.endpoint != nil {
            let _: ReceiverStatus? = try? await RiderCommunity.decode("sos/receiver", method: "DELETE")
        }
        receiverStatus = "Входящие SOS рядом выключены."
    }

    private func uploadLocationIfNeeded() {
        let lan = RiderCommunity.usesLANTrust
        guard RiderAlertKind.sos.enabled, available, RiderCommunity.endpoint != nil, lan || token != nil, let latestFix,
              dateIsFresh(latestFix), receiverTask == nil,
              Date().timeIntervalSince(lastUpdate) >= (lan ? 14 : 50) else { return }
        lastUpdate = Date()
        receiverTask = Task {
            defer { receiverTask = nil }
            do {
                let body = try JSONEncoder().encode(Receiver(token: token, location: latestFix))
                let result: ReceiverStatus = try await RiderCommunity.decode(lan ? "sos/foreground" : "sos/receiver",
                                                                              method: "PUT", body: body)
                if available && !Task.isCancelled {
                    receiverStatus = result.enabled ? "Геопозиция обновлена. Принимаешь SOS рядом." : "Входящие SOS рядом выключены."
                    if !result.enabled { lastUpdate = .distantPast }
                }
            } catch {
                if available && !Task.isCancelled {
                    receiverStatus = "Не удалось обновить позицию для SOS."
                    lastUpdate = Date().addingTimeInterval(-35)
                }
            }
        }
    }

    private func dateIsFresh(_ fix: RiderSOSFix) -> Bool {
        (-5...45).contains(Date().timeIntervalSince1970 - fix.capturedAt)
    }

    func send(id: UUID, name: String, equipment: String?, location: RiderSOSFix) async throws -> Receipt {
        let payload = Incident(id: id, name: String(name.prefix(50)), equipment: equipment.map { String($0.prefix(320)) },
                               location: location)
        return try await RiderCommunity.decode("sos", method: "POST", body: JSONEncoder().encode(payload))
    }

    static let drillNotification = Notification.Name("rider.sos.drill")

    func allowsDrill() async -> Bool {
        guard RiderCommunity.usesLANTrust else { return false }
        let result: [String: Bool]? = try? await RiderCommunity.decode("people/demo/status")
        return result?["enabled"] == true
    }

    func requestDrill() async throws {
        let result: [String: Bool] = try await RiderCommunity.decode("people/demo/sos", method: "POST", body: Data("{}".utf8))
        guard result["drill"] == true else { throw URLError(.badServerResponse) }
    }

    func close(_ id: UUID) async throws -> Receipt {
        try await RiderCommunity.decode("sos/\(id.uuidString.lowercased())/close", method: "PUT")
    }

    func receipt(_ id: UUID) async throws -> Receipt {
        try await RiderCommunity.decode("sos/\(id.uuidString.lowercased())/receipt")
    }

    func decide(_ action: Decision, for id: UUID) async throws -> Decision {
        let name = UserDefaults.standard.string(forKey: "rider.profileName") ?? "Райдер"
        let payload = DecisionBody(action: action, name: String(name.prefix(50)))
        let result: DecisionResult = try await RiderCommunity.decode("sos/\(id.uuidString.lowercased())/decision",
                                                                    method: "PUT", body: JSONEncoder().encode(payload))
        return result.action
    }

    func resetAccount() {
        receiverTask?.cancel()
        announcedForeground.removeAll()
        soundedForeground.removeAll()
        receiverStatus = nil
        lastUpdate = .distantPast
        latestFix = nil
        token = nil
        inbox = nil
        stopAlarm()
    }

    func pollForeground() async {
        guard RiderCommunity.usesLANTrust, RiderAlertKind.sos.enabled else { return }
        uploadLocationIfNeeded()
        await receiverTask?.value
        guard !Task.isCancelled, let items = try? await alerts(), !Task.isCancelled, RiderAlertKind.sos.enabled else { return }
        let ids = items.map(\.id)
        announcedForeground.formIntersection(ids)
        soundedForeground.formIntersection(ids)
        let pending = items.filter { $0.decision == nil }
        let newSignals = pending.filter { !soundedForeground.contains($0.id) }
        if !newSignals.isEmpty {
            soundedForeground.formUnion(newSignals.map(\.id))
            playAlarm()
        }
        guard inbox == nil, !radarVisible,
              let incoming = pending.first(where: { !announcedForeground.contains($0.id) }) else { return }
        announcedForeground.insert(incoming.id)
        open(incoming.id)
    }

    func playAlarm() {
        if RiderAlertKind.sound.enabled {
            stopAlarm()
            do {
                let session = AVAudioSession.sharedInstance()
                if session.category == .ambient || session.category == .soloAmbient {
                    let settings = (session.category, session.mode, session.categoryOptions)
                    try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
                    previousAudio = settings
                }
                let player = try AVAudioPlayer(data: Self.alarmAudio)
                alarm = player
                guard player.play() else { throw CocoaError(.featureUnsupported) }
                alarmTask = Task {
                    do { try await Task.sleep(for: .seconds(player.duration + 0.15)) } catch { return }
                    stopAlarm()
                }
            } catch {
                stopAlarm()
                AudioServicesPlaySystemSound(1007)
            }
        }
        if RiderAlertKind.vibrate.enabled { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    private func stopAlarm() {
        alarmTask?.cancel()
        alarmTask = nil
        alarm?.stop()
        alarm = nil
        if let previousAudio {
            self.previousAudio = nil
            let session = AVAudioSession.sharedInstance()
            if session.category == .playback && session.categoryOptions == .mixWithOthers {
                try? session.setCategory(previousAudio.category, mode: previousAudio.mode, options: previousAudio.options)
            }
        }
    }

    private static let alarmAudio: Data = {
        let sampleRate = 22_050
        let count = Int(Double(sampleRate) * 2.4)
        var wave = Data("RIFF".utf8)
        func word(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        func integer(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        integer(UInt32(36 + count * 2))
        wave.append(contentsOf: "WAVEfmt ".utf8)
        integer(16)
        word(1)
        word(1)
        integer(UInt32(sampleRate))
        integer(UInt32(sampleRate * 2))
        word(2)
        word(16)
        wave.append(contentsOf: "data".utf8)
        integer(UInt32(count * 2))
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let pulse = time.truncatingRemainder(dividingBy: 0.8)
            let ramp = max(0, min(1, pulse / 0.07, (0.65 - pulse) / 0.12))
            let frequency = 610 + 360 * (1 - cos(2 * .pi * time / 0.8)) / 2
            phase += 2 * .pi * frequency / Double(sampleRate)
            let sample = Int16((sin(phase) + 0.18 * sin(2 * phase)) * ramp * 14_000)
            word(UInt16(bitPattern: sample))
        }
        return wave
    }()

    func alerts() async throws -> [Alert] {
        try await RiderCommunity.decode("sos/inbox")
    }
}

struct RiderSOSReadiness: View {
    @ObservedObject private var service = RiderSOSService.shared
    @ObservedObject var recorder: SessionRecorder
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("SOS рядом", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            if RiderCommunity.usesLANTrust {
                if !recorder.locationAuthorized {
                    Text("Для приёма SOS рядом включи точную геопозицию.")
                    Button("Разрешить геопозицию") { recorder.locateSpot() }.buttonStyle(.borderless)
                } else {
                    Text(service.receiverStatus ?? "Получаешь SOS в радиусе 1,5 км, пока открыт Rider.")
                }
            } else if RiderCommunity.endpoint == nil {
                Text("Приём появится после подключения сервера Rider.")
            } else if !service.available {
                Text(service.receiverStatus ?? "Чтобы получать сигналы от райдеров рядом, разреши уведомления.")
                Button("Разрешить уведомления") {
                    Task {
                        await service.refreshAuthorization(prompt: true)
                        if !service.available, let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }.buttonStyle(.borderless)
            } else if !recorder.locationAuthorized {
                Text("Для поиска сигналов в радиусе 1,5 км нужна точная геопозиция.")
                Button("Разрешить геопозицию") { recorder.locateSpot() }.buttonStyle(.borderless)
            } else {
                Text(service.receiverStatus ?? "Приём включён. Rider обновляет позицию для поиска сигналов в радиусе 1,5 км.")
            }
        }
        .font(.caption)
    }
}

struct RiderSOSControl: View {
    @AppStorage("rider.profileName") private var name = "Райдер"
    @ObservedObject var recorder: SessionRecorder
    let session: SessionSummary

    @GestureState private var offset: CGFloat = 0
    @State private var started: Date?
    @State private var showingRadar = false
    @State private var sending = false
    @State private var feedback: String?
    @State private var receipt: RiderSOSService.Receipt?
    @State private var incidentID = UUID()
    @State private var allowsDrill = false
    @State private var drillRequested = false

    private var equipment: String? {
        guard let setup = session.setup else { return nil }
        let labels: [String?] = [recorder.gearPresets.first { $0.matches(setup) }?.name, setup.kiteTitle, setup.boardTitle]
        let items = labels.compactMap { $0 }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { area in
                let travel = max(1, area.size.width - 54)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0.63, green: 0.12, blue: 0.15))
                    Capsule().strokeBorder(Color.white.opacity(0.55))
                    Text(receipt?.active == true ? "SOS активен · открыть радар" : "SOS · веди ползунок медленно")
                        .font(.caption.bold()).frame(maxWidth: .infinity)
                        .padding(.leading, 45).padding(.trailing, 8)
                    Circle().fill(.white).frame(width: 40, height: 40)
                        .overlay { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.red) }
                        .contentShape(Circle())
                        .offset(x: min(travel, max(0, offset)))
                        .gesture(DragGesture(minimumDistance: 4)
                            .updating($offset) { value, state, _ in state = value.translation.width }
                            .onChanged { value in if started == nil { started = value.time } }
                            .onEnded { value in
                                defer { started = nil }
                                guard value.translation.width >= travel * 0.95 else { return }
                                if receipt?.active == true || started.map({ value.time.timeIntervalSince($0) >= 2 }) == true {
                                    showingRadar = true
                                    feedback = nil
                                } else if receipt?.active != true {
                                    feedback = "Проведи ползунок за 2 секунды или дольше."
                                }
                            })
                        .padding(.leading, 7)
                }
            }
            .frame(height: 50)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Открыть радар SOS")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showingRadar = true }

            if receipt?.active == true {
                Button("Открыть радар SOS") { showingRadar = true }
                    .font(.caption2.bold()).buttonStyle(.plain)
            } else if let feedback {
                Text(feedback).multilineTextAlignment(.center).font(.caption2.weight(.semibold))
            }
        }
        .task { allowsDrill = await RiderSOSService.shared.allowsDrill() }
        .sheet(isPresented: $showingRadar, onDismiss: {
            started = nil
            if drillRequested {
                drillRequested = false
                NotificationCenter.default.post(name: RiderSOSService.drillNotification, object: nil)
            }
        }) {
            RiderSOSRadarScreen(fix: receipt?.location ?? RiderSOSFix(recorder.usableFix),
                                receipt: receipt, sending: sending, message: feedback,
                                send: RiderCommunity.endpoint != nil ? { Task { await send() } } : nil,
                                drill: allowsDrill ? { Task { await sendDrill() } } : nil,
                                closeSignal: receipt?.active == true ? { Task { await closeSignal() } } : nil,
                                enableReplies: RiderCommunity.endpoint != nil && !RiderCommunity.usesLANTrust ? {
                Task { await RiderSOSService.shared.refreshAuthorization(prompt: true) }
            } : nil)
            .onAppear {
                RiderSOSService.shared.showRadar(true)
                recorder.refreshSOSFix()
            }
            .onDisappear { RiderSOSService.shared.showRadar(false) }
            .task(id: receipt?.id) { await followResponses() }
        }
    }

    @MainActor private func followResponses() async {
        guard let id = receipt?.id else { return }
        for _ in 0..<225 {
            guard receipt?.active == true else { break }
            do {
                try await Task.sleep(for: .seconds(4))
                let updated = try await RiderSOSService.shared.receipt(id)
                guard !Task.isCancelled else { return }
                receipt = updated
                feedback = nil
            } catch {
                if !Task.isCancelled, receipt?.active == true { feedback = "Связь прервалась. Проверяем отклики снова." }
            }
        }
    }

    @MainActor private func sendDrill() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            try await RiderSOSService.shared.requestDrill()
            drillRequested = true
            showingRadar = false
        } catch { feedback = "Сервер не подтвердил учебный сигнал." }
    }

    @MainActor private func closeSignal() async {
        guard !sending, let id = receipt?.id else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await RiderSOSService.shared.close(id)
            receipt = nil
            feedback = "Сигнал завершён. Радар готов к новой отправке."
        } catch { feedback = "Не удалось завершить сигнал. Проверь связь." }
    }

    @MainActor private func send() async {
        guard !sending, receipt?.active != true else { return }
        guard let fix = RiderSOSFix(recorder.usableFix) else {
            feedback = "Для отправки нужна свежая точная GPS-позиция."
            return
        }
        sending = true
        feedback = nil
        defer { sending = false }
        do {
            receipt = try await RiderSOSService.shared.send(id: incidentID, name: name, equipment: equipment, location: fix)
            incidentID = UUID()
        } catch {
            if let received = try? await RiderSOSService.shared.receipt(incidentID) {
                receipt = received
                incidentID = UUID()
            } else {
                feedback = "Сервер не подтвердил сигнал SOS."
            }
        }
    }
}

private struct RiderSOSRadarScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = RiderSOSService.shared
    let fix: RiderSOSFix?
    let receipt: RiderSOSService.Receipt?
    let sending: Bool
    let message: String?
    let send: (() -> Void)?
    var drill: (() -> Void)? = nil
    var closeSignal: (() -> Void)? = nil
    @State private var confirmClose = false
    let enableReplies: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    RiderRadarMap(fix: fix, transmitting: sending || (receipt?.active == true && receipt?.recipients != 0))
                    if let receipt {
                        RiderSOSResponseSummary(receipt: receipt)
                    } else if sending {
                        Label("Связываемся с сервером", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                    } else {
                        if send != nil {
                            Text(fix == nil ? "Ждём точную GPS-позицию" : "Готов к отправке").font(.title3.bold())
                            Text("Имя, комплект и точка GPS будут доступны райдерам в зоне оповещения.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if RiderCommunity.usesLANTrust {
                                Text("В домашней сборке сигналы видны на телефонах, где открыт Rider.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if RiderCommunity.endpoint == nil {
                            Text("Сервер Rider ещё не подключён.").font(.title3.bold())
                        } else if message == nil {
                            ProgressView("Загружаем отклики")
                        }
                    }
                    if let message { Text(message).font(.subheadline.bold()).foregroundStyle(.secondary) }
                    if let send, receipt?.active != true {
                        Button(action: send) {
                            Label("Отправить SOS", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                        .disabled(sending || fix == nil)
                    }
                    if let drill {
                        Button(action: drill) {
                            Label("Отправить учебный SOS себе", systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.orange).disabled(sending)
                    }
                    if closeSignal != nil {
                        Button("Завершить SOS", role: .destructive) { confirmClose = true }
                            .buttonStyle(.bordered).disabled(sending)
                    }
                    if let enableReplies, !service.available, !sending {
                        Button("Разрешить push для откликов", action: enableReplies)
                            .font(.subheadline).buttonStyle(.borderless)
                    }
                }.padding(16)
            }
            .background(RiderTheme.canvas)
            .navigationTitle("Радар SOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
            .confirmationDialog("Завершить активный сигнал SOS?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Завершить SOS", role: .destructive) { closeSignal?() }
            }
        }
    }
}

private struct RiderRadarMap: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fix: RiderSOSFix?
    let transmitting: Bool
    private let color = Color(red: 1, green: 0.36, blue: 0.31)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.12, green: 0.06, blue: 0.08)
                    if let fix {
                        let center = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
                        let region = MKCoordinateRegion(center: center, latitudinalMeters: 3900, longitudinalMeters: 3900)
                        Map(initialPosition: .region(region), interactionModes: []) {
                            MapCircle(center: center, radius: 1500)
                                .foregroundStyle(color.opacity(0.16))
                                .stroke(color.opacity(0.9), lineWidth: 1.5)
                        }
                        .id("\(fix.latitude),\(fix.longitude)")
                        .environment(\.colorScheme, .dark)
                    }
                    reticle
                    if transmitting && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                            let time = context.date.timeIntervalSinceReferenceDate / 3.5
                            ZStack {
                                ForEach(0..<3) { index in
                                    let phase = (time + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                                    Circle().strokeBorder(color.opacity((1 - phase) * 0.85), lineWidth: 2)
                                        .frame(width: min(proxy.size.width, proxy.size.height) * phase * 0.77)
                                }
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel(fix == nil ? "Схема зоны SOS, координаты ожидаются" : "Карта зоны оповещения 1,5 километра")
            }
            .aspectRatio(1, contentMode: .fit)
            HStack(spacing: 6) {
                Label("Радиус 1,5 км", systemImage: "scope")
                Spacer()
                if let fix {
                    Text(String(format: "%.4f, %.4f", fix.latitude, fix.longitude))
                } else {
                    Text("Схема")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var reticle: some View {
        ZStack {
            Circle().strokeBorder(color.opacity(0.34), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                .padding(45)
            Circle().strokeBorder(color.opacity(0.25), lineWidth: 1).padding(93)
            Circle().fill(color).frame(width: 14, height: 14)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                .shadow(color: color, radius: transmitting ? 14 : 5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RiderSOSResponseSummary: View {
    let receipt: RiderSOSService.Receipt

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(receipt.status, systemImage: receipt.active ? "dot.radiowaves.left.and.right" : "clock")
                .font(.subheadline.weight(.semibold))
            if let responders = receipt.responders, !responders.isEmpty {
                Text("Райдеры откликнулись").font(.headline)
                ForEach(responders) { responder in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(responder.name).font(.subheadline.bold())
                            Text("Сообщил, что идёт на помощь").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.fill.checkmark").foregroundStyle(RiderTheme.accent)
                    }
                }
            } else if receipt.active && receipt.recipients > 0 {
                Text("Пока ждём откликов").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .lagoonCard()
    }
}

struct RiderSOSOutgoing: View {
    let id: UUID
    @State private var current: RiderSOSService.Receipt?
    @State private var closing = false
    @State private var message: String?

    var body: some View {
        RiderSOSRadarScreen(fix: current?.location, receipt: current, sending: closing,
                            message: message, send: nil,
                            closeSignal: current?.active == true ? { Task { await close() } } : nil, enableReplies: nil)
            .task(id: id) {
                for _ in 0..<225 {
                    do {
                        current = try await RiderSOSService.shared.receipt(id)
                        message = nil
                        guard current?.active == true else { break }
                        try await Task.sleep(for: .seconds(4))
                    } catch {
                        if !Task.isCancelled { message = "Сигнал недоступен или срок оповещения истёк." }
                        break
                    }
                }
            }
    }
    @MainActor private func close() async {
        closing = true
        defer { closing = false }
        do { current = try await RiderSOSService.shared.close(id); message = nil }
        catch { message = "Не удалось завершить сигнал." }
    }

}

struct RiderSOSInbox: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let selected: UUID?
    @State private var alerts: [RiderSOSService.Alert] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var deciding = Set<UUID>()

    var body: some View {
        NavigationStack {
            List {
                if alerts.contains(where: { $0.decision == nil }) {
                    alarmHeader
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                else if !loaded { ProgressView("Проверяем сигналы…") }
                else if alerts.isEmpty {
                    ContentUnavailableView("Активных сигналов нет", systemImage: "dot.radiowaves.left.and.right")
                }
                ForEach(alerts) { alert in
                    Section {
                        Text(alert.name).font(.headline)
                        if let equipment = alert.equipment { LabeledContent("Комплект", value: equipment) }
                        if alert.decision == .accept {
                            Label("Ты откликнулся на SOS", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(RiderTheme.accent)
                        } else {
                            HStack {
                                Button("Отозваться") { Task { await decide(.accept, alert: alert) } }
                                    .buttonStyle(.borderedProminent).tint(RiderTheme.action)
                                Button("Пропустить") { Task { await decide(.skip, alert: alert) } }
                                    .buttonStyle(.bordered)
                            }
                            .disabled(deciding.contains(alert.id))
                            Text("Отклик сообщит автору SOS, что ты идёшь на помощь.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("Время", value: Date(timeIntervalSince1970: alert.createdAt).formatted(.dateTime.hour().minute()))
                        Text(String(format: "%.5f, %.5f", alert.latitude, alert.longitude))
                            .font(.subheadline.monospacedDigit()).textSelection(.enabled)
                        Button {
                            if let spot = RiderSpot(name: "SOS", latitude: String(alert.latitude), longitude: String(alert.longitude)),
                               let web = spot.routeWebURL {
                                if let app = spot.routeAppURL { openURL(app) { opened in if !opened { openURL(web) } } }
                                else { openURL(web) }
                            }
                        } label: { Label("Маршрут в Яндекс Картах", systemImage: "location.fill") }
                    } header: {
                        Text("Сигнал SOS")
                    } footer: {
                        Text("Точка зафиксирована в момент сигнала. Маршрут Яндекс Карт проходит по суше.")
                    }
                }
            }
            .navigationTitle("SOS рядом")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                repeat {
                    await load()
                    guard RiderCommunity.usesLANTrust else { return }
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                } while !Task.isCancelled
            }
            .refreshable { await load() }
        }
    }

    private var alarmHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "sos.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("SOS ALARM").font(.caption.weight(.black).monospaced()).tracking(2)
                    .foregroundStyle(Color(red: 1, green: 0.71, blue: 0.64))
                Text("Сигнал бедствия рядом").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.50, green: 0.10, blue: 0.15),
                                             Color(red: 0.20, green: 0.07, blue: 0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    @MainActor private func decide(_ decision: RiderSOSService.Decision, alert: RiderSOSService.Alert) async {
        guard deciding.insert(alert.id).inserted else { return }
        defer { deciding.remove(alert.id) }
        do {
            let saved = try await RiderSOSService.shared.decide(decision, for: alert.id)
            if saved == .skip { alerts.removeAll { $0.id == alert.id } }
            await load()
        } catch {
            self.error = "Сервер не подтвердил действие. Попробуй ещё раз."
        }
    }

    @MainActor private func load() async {
        do {
            let items = try await RiderSOSService.shared.alerts()
            alerts = items.filter { $0.id == selected } + items.filter { $0.id != selected }
            error = nil
        } catch {
            self.error = "Не удалось получить сигналы SOS с сервера."
        }
        loaded = true
    }
}
