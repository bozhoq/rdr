import CoreLocation
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
        UNUserNotificationCenter.current().delegate = self
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
        notification.request.content.userInfo["riderSOS"] == nil ? [] : [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["riderSOS"] as? String).flatMap(UUID.init(uuidString:)) else {
            return
        }
        await MainActor.run { RiderSOSService.shared.open(id) }
    }
}

@MainActor final class RiderSOSService: ObservableObject {
    static let shared = RiderSOSService()

    struct Receipt: Decodable {
        let id: UUID
        let recipients: Int
        let acceptedByAPNs: Int
        let pending: Int
    }

    struct Alert: Decodable, Identifiable {
        let id: UUID
        let createdAt: TimeInterval
        let name: String
        let equipment: String?
        let latitude: Double
        let longitude: Double
        let accuracy: Double
    }

    struct Inbox: Identifiable {
        let id = UUID()
        let selected: UUID?
    }

    private struct Receiver: Codable {
        let token: String
        let location: RiderSOSFix
    }
    private struct ReceiverStatus: Decodable { let enabled: Bool }
    private struct Incident: Encodable {
        let id: UUID
        let name: String
        let equipment: String?
        let location: RiderSOSFix
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "rider.sos.receive")
    @Published private(set) var receiverStatus: String?
    @Published var inbox: Inbox?
    private var token: String?
    private var latestFix: RiderSOSFix?
    private var lastUpdate = Date.distantPast
    private var receiverTask: Task<Void, Never>?
    private var changingConsent = false

    func open(_ selected: UUID? = nil) {
        inbox = Inbox(selected: selected)
    }

    func refreshAuthorization() async {
        guard enabled, RiderCommunity.endpoint != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            await disableReceiving()
            receiverStatus = "Разреши уведомления Rider в настройках iPhone."
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func setReceiving(_ enabled: Bool) async {
        guard !changingConsent else { return }
        changingConsent = true
        defer { changingConsent = false }
        if !enabled {
            await disableReceiving()
            return
        }
        guard RiderCommunity.endpoint != nil else {
            receiverStatus = "Приём SOS станет доступен после подключения сервера Rider."
            return
        }
        do {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                receiverStatus = "Разреши уведомления Rider в настройках iPhone."
                return
            }
            setEnabled(true)
            receiverStatus = "Регистрируем уведомления и ждём GPS…"
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            receiverStatus = "Не удалось включить уведомления."
        }
    }

    private func disableReceiving() async {
        setEnabled(false)
        token = nil
        latestFix = nil
        lastUpdate = .distantPast
        receiverTask?.cancel()
        await receiverTask?.value
        receiverTask = nil
        guard RiderCommunity.endpoint != nil else { return }
        do {
            let _: ReceiverStatus = try await RiderCommunity.decode("sos/receiver", method: "DELETE")
            receiverStatus = nil
        } catch {
            receiverStatus = "Приём выключен здесь. Последняя отметка сервера истечёт через 5 минут."
        }
    }

    private func setEnabled(_ state: Bool) {
        enabled = state
        UserDefaults.standard.set(state, forKey: "rider.sos.receive")
    }

    func register(_ token: String) {
        guard enabled else { return }
        if self.token != token { lastUpdate = .distantPast }
        self.token = token
        uploadLocationIfNeeded()
    }

    func registrationFailed() {
        guard enabled else { return }
        receiverStatus = "iOS не разрешила push для этой установки Rider."
    }

    func observeLocation(_ fix: CLLocation) {
        guard enabled else { return }
        latestFix = RiderSOSFix(fix)
        uploadLocationIfNeeded()
    }

    private func uploadLocationIfNeeded() {
        guard enabled, RiderCommunity.endpoint != nil, let token, let latestFix,
              dateIsFresh(latestFix), Date().timeIntervalSince(lastUpdate) >= 50, receiverTask == nil else { return }
        lastUpdate = Date()
        receiverTask = Task {
            defer { receiverTask = nil }
            do {
                let body = try JSONEncoder().encode(Receiver(token: token, location: latestFix))
                let _: ReceiverStatus = try await RiderCommunity.decode("sos/receiver", method: "PUT", body: body)
                if enabled && !Task.isCancelled { receiverStatus = "Геопозиция обновлена. Принимаешь SOS рядом." }
            } catch {
                if enabled && !Task.isCancelled {
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

    func receipt(_ id: UUID) async throws -> Receipt {
        try await RiderCommunity.decode("sos/\(id.uuidString.lowercased())/receipt")
    }

    func alerts() async throws -> [Alert] {
        try await RiderCommunity.decode("sos/inbox")
    }
}

struct RiderSOSSettings: View {
    @ObservedObject var service = RiderSOSService.shared
    @ObservedObject var recorder: SessionRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Получать SOS рядом", isOn: Binding(get: { service.enabled }, set: { enabled in
                Task {
                    await service.setReceiving(enabled)
                    if service.enabled {
                        if let fix = recorder.usableFix { service.observeLocation(fix) }
                        recorder.locateSpot()
                    }
                }
            }))
            Text(service.receiverStatus ?? "После включения Rider отправляет свежую точку GPS серверу для поиска сигналов в радиусе 1,5 км.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RiderSOSControl: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("rider.profileName") private var name = "Райдер"
    @ObservedObject var recorder: SessionRecorder
    let session: SessionSummary

    @GestureState private var offset: CGFloat = 0
    @State private var started: Date?
    @State private var confirming = false
    @State private var sending = false
    @State private var feedback: String?
    @State private var receipt: RiderSOSService.Receipt?
    @State private var incidentID = UUID()

    private var equipment: String? {
        guard let setup = session.setup else { return nil }
        let items = [recorder.gearPresets.first { $0.matches(setup) }?.name, setup.kiteTitle, setup.boardTitle]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { area in
                let travel = max(1, area.size.width - 54)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0.63, green: 0.12, blue: 0.15))
                    Capsule().strokeBorder(Color.white.opacity(0.55))
                    Text(sending ? "Связываемся с сервером…" : "SOS · веди ползунок медленно")
                        .font(.caption.bold()).frame(maxWidth: .infinity)
                        .padding(.leading, 45).padding(.trailing, 8)
                    Circle().fill(.white).frame(width: 40, height: 40)
                        .overlay { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .black)).foregroundStyle(.red) }
                        .contentShape(Circle())
                        .offset(x: min(travel, max(0, offset)))
                        .gesture(DragGesture(minimumDistance: 4)
                            .updating($offset) { value, state, _ in state = value.translation.width }
                            .onChanged { value in if started == nil { started = value.time } }
                            .onEnded { value in
                                defer { started = nil }
                                guard !sending, value.translation.width >= travel * 0.95 else { return }
                                if let started, value.time.timeIntervalSince(started) >= 2 {
                                    confirming = true
                                } else {
                                    feedback = "Проведи ползунок за 2 секунды или дольше."
                                }
                            })
                        .padding(.leading, 7)
                }
            }
            .frame(height: 50)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SOS райдерам поблизости")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if !sending { confirming = true } }
            .onChange(of: offset) { _, value in if value == 0 { started = nil } }

            if let text = feedback ?? receipt.map(receiptText) {
                Text(text).multilineTextAlignment(.center).font(.caption2.weight(.semibold))
            }
        }
        .confirmationDialog("Подать сигнал SOS?", isPresented: $confirming, titleVisibility: .visible) {
            if RiderCommunity.endpoint != nil {
                Button("Отправить SOS", role: .destructive) { Task { await send() } }
            }
            Button("Позвонить 112") { if let url = URL(string: "tel:112") { openURL(url) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(RiderCommunity.endpoint == nil
                 ? "Сервер Rider ещё не подключён. В опасности звони 112."
                 : "Имя, комплект и точная точка GPS будут доступны райдерам в радиусе 1,5 км. В опасности звони 112.")
        }
        .task(id: receipt?.id) {
            guard let id = receipt?.id else { return }
            for _ in 0..<15 {
                guard (receipt?.pending ?? 0) > 0 else { break }
                do {
                    try await Task.sleep(for: .seconds(4))
                    let result = try await RiderSOSService.shared.receipt(id)
                    if !Task.isCancelled { receipt = result }
                } catch { break }
            }
        }
    }

    private func receiptText(_ received: RiderSOSService.Receipt) -> String {
        if received.recipients == 0 { return "Сигнал принят сервером. Райдеров с активным приёмом рядом нет." }
        if received.pending > 0 { return "SOS принят сервером · адресатов \(received.recipients)" }
        return "Apple приняла \(received.acceptedByAPNs) из \(received.recipients) уведомлений."
    }

    @MainActor private func send() async {
        guard !sending else { return }
        guard let fix = RiderSOSFix(recorder.usableFix) else {
            feedback = "Нет свежей точной GPS-позиции для SOS. В опасности звони 112."
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
                feedback = "Сервер не подтвердил SOS. Проверь связь. В опасности звони 112."
            }
        }
    }
}

struct RiderSOSInbox: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let selected: UUID?
    @State private var alerts: [RiderSOSService.Alert] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                else if !loaded { ProgressView("Проверяем сигналы…") }
                else if alerts.isEmpty {
                    ContentUnavailableView("Активных сигналов нет", systemImage: "dot.radiowaves.left.and.right")
                }
                ForEach(alerts) { alert in
                    Section {
                        Text(alert.name).font(.headline)
                        if let equipment = alert.equipment { LabeledContent("Комплект", value: equipment) }
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
            .task { await load() }
            .refreshable { await load() }
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
