import SwiftUI
import AudioToolbox

enum RiderAppearance: String, CaseIterable {
    case lagoon, system, light, dark
    var title: String {
        switch self { case .lagoon: return "Лагуна"; case .system: return "Как на iPhone"; case .light: return "Светлая"; case .dark: return "Тёмная" }
    }
    var scheme: ColorScheme? {
        switch self { case .dark: return .dark; case .light: return .light; default: return nil }
    }
}
struct RiderAppearanceSettings: View {
    @AppStorage("rider.appearance") private var theme = RiderAppearance.lagoon
    @AppStorage("rider.textSize") private var size = 0
    var body: some View {
        Form {
            Section("Тема приложения") {
                ForEach(RiderAppearance.allCases, id: \.self) { option in
                    Button { theme = option } label: {
                        HStack {
                            Circle().fill(swatch(option)).frame(width: 22, height: 22).overlay { Circle().stroke(.secondary.opacity(0.4)) }
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            if theme == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(RiderTheme.accent) }
                        }
                    }.accessibilityAddTraits(theme == option ? .isSelected : [])
                }
            }
            Picker("Размер текста", selection: $size) {
                Text("Как на iPhone").tag(0)
                Text("Компактный").tag(1)
                Text("Обычный").tag(2)
                Text("Крупный").tag(3)
                Text("Очень крупный").tag(4)
            }
            Section("Предпросмотр") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Каталка в Межводном", systemImage: "water.waves").font(.headline)
                    Text("Ветер 8 м/с · 2 часа на воде").font(.body)
                }.padding(.vertical, 6)
            }
        }.navigationTitle("Оформление").navigationBarTitleDisplayMode(.inline)
    }
    private func swatch(_ theme: RiderAppearance) -> Color {
        switch theme { case .lagoon: return .teal; case .system: return .gray; case .light: return .white; case .dark: return .black }
    }
}
enum RiderAlertKind: String, CaseIterable {
    case message, sos, reply, comment, follow, reaction, repost, sound, vibrate, preview
    var title: String {
        switch self {
        case .message: return "Сообщения"
        case .sos: return "Сигналы SOS рядом"
        case .reply: return "Ответы на ваши комментарии"
        case .comment: return "Комментарии под постами"
        case .follow: return "Новые подписчики"
        case .reaction: return "Шаки"
        case .repost: return "Репосты"
        case .sound: return "Звук"
        case .vibrate: return "Вибрация в приложении"
        case .preview: return "Показывать имя в уведомлении"
        }
    }
    var enabled: Bool { UserDefaults.standard.object(forKey: "rider.alert." + rawValue) as? Bool ?? true }
    static var values: [String:Bool] { Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue,$0.enabled) }) }
}
private struct RiderAlertRow: View {
    let kind: RiderAlertKind
    @AppStorage private var value: Bool
    init(_ kind: RiderAlertKind) {
        self.kind = kind
        _value = AppStorage(wrappedValue: true, "rider.alert." + kind.rawValue)
    }
    var body: some View { Toggle(kind.title, isOn: $value) }
}
struct RiderAlertSettings: View {
    @ObservedObject private var sos = RiderSOSService.shared
    @State private var demoMessage: String?
    var body: some View {
        Form {
            Section("Оповещения") {
                ForEach([RiderAlertKind.message, .sos, .reply, .comment, .follow, .reaction, .repost], id: \.self) { RiderAlertRow($0) }
            }
            Section("Звук и предпросмотр") {
                ForEach([RiderAlertKind.sound, .vibrate, .preview], id: \.self) { RiderAlertRow($0) }
            }
            Section {
                if RiderCommunity.usesLANTrust {
                    Button("Повторить демо сообщений и SOS") {
                        Task {
                            do {
                                let data: [String:Bool] = try await RiderCommunity.decode("people/demo", method: "POST", body: JSONEncoder().encode(["restart":true]))
                                demoMessage = data["enabled"] == true ? "Проверка начнётся через 20 секунд. Вернись в Rider." : "Этот профиль не участвует в домашнем тесте."
                            } catch { demoMessage = "Сервер не ответил." }
                        }
                    }
                    if let demoMessage { Text(demoMessage).font(.footnote) }
                    Text("В домашней сборке социальные оповещения появляются, пока Rider открыт. Для фоновых push требуется сборка с Apple Push Notifications.")
                } else {
                    Button("Разрешить уведомления iPhone") { Task { await sos.refreshAuthorization(prompt: true) } }
                    Button("Настройки уведомлений iPhone") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } footer: {
                Text("Переключатель SOS управляет входящими сигналами рядом. Отклики на твой собственный сигнал остаются доступны.")
            }
        }.navigationTitle("Уведомления и звуки").navigationBarTitleDisplayMode(.inline)
    }
}

struct RiderSocialAlerts: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var latest: Int?
    @State private var banner: Alert?
    @State private var showDrill = false
    @State private var drillAccepted = false
    @State private var opened: String?
    @State private var showDestination = false
    @State private var revision = 0
    @AppStorage("rider.alert.sos") private var receiveSOS = true
    private struct Alert: Decodable, Identifiable { let id: Int; let kind: String; let created: Double; let name: String }
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let banner, let kind = RiderAlertKind(rawValue: banner.kind), kind.enabled {
                Button {
                    opened = kind == .message ? "message" : "activity"
                    self.banner = nil
                    showDestination = true
                } label: {
                    Label(RiderAlertKind.preview.enabled ? kind.title + " · " + banner.name : kind.title,
                          systemImage: kind == .message ? "bubble.left.fill" : "bell.fill")
                        .font(.subheadline.weight(.semibold)).padding(12).background(.regularMaterial, in: Capsule())
                }.padding(8)
            }
        }.sheet(isPresented: $showDestination) {
            NavigationStack {
                Group { if opened == "message" { RiderInboxView() } else { RiderNotificationsView() } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showDestination = false } } }
            }
        }
        .sheet(isPresented: $showDrill) {
            VStack(spacing: 18) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 48)).foregroundStyle(.orange)
                Text("Учебный SOS").font(.largeTitle.bold())
                Text(drillAccepted ? "Отклик принят в демо." : "Демо-райдер подал учебный сигнал рядом. Проверь, как выглядит отклик.")
                    .multilineTextAlignment(.center)
                if !drillAccepted {
                    Button("Отозваться") { drillAccepted = true }.buttonStyle(.borderedProminent)
                }
                Button(drillAccepted ? "Готово" : "Пропустить") { showDrill = false }
                Text("Тест на этом iPhone. Экстренный сигнал никому не отправляется.").font(.caption).foregroundStyle(.secondary)
            }.padding(24).presentationDetents([.medium])
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            revision = RiderAlertKind.allCases.reduce(0) { $0 * 2 + ($1.enabled ? 1 : 0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("rider.social.open"))) { note in
            opened = note.object as? String; showDestination = true
        }
        .task(id: "\(phase == .active)-\(revision)") {
            guard phase == .active, RiderCommunity.endpoint != nil else { return }
            let prefs = RiderAlertKind.values
            var synced = false
            while !Task.isCancelled {
                if !synced {
                    let saved: [String:Bool]? = try? await RiderCommunity.decode("people/preferences", method: "PUT", body: JSONEncoder().encode(prefs))
                    synced = saved?["saved"] == true
                }
                if RiderCommunity.usesLANTrust {
                    let tick: [String:Bool]? = try? await RiderCommunity.decode("people/demo", method: "POST", body: Data("{}".utf8))
                    if tick?["drill"] == true, RiderAlertKind.sos.enabled, !Task.isCancelled {
                        drillAccepted = false; showDrill = true
                        if RiderAlertKind.sound.enabled { AudioServicesPlaySystemSound(1007) }
                        if RiderAlertKind.vibrate.enabled { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
                    }
                }
                if RiderCommunity.usesLANTrust, let events: [Alert] = try? await RiderCommunity.decode("people/alerts") {
                    if Task.isCancelled { return }
                    if let previous = latest, let event = events.first(where: { $0.id > previous && prefs[$0.kind] == true }) {
                        banner = event
                        if RiderAlertKind.sound.enabled { AudioServicesPlaySystemSound(1007) }
                        if RiderAlertKind.vibrate.enabled { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                    }
                    latest = max(latest ?? 0, events.first?.id ?? 0)
                }
                do { try await Task.sleep(for: .seconds(RiderCommunity.usesLANTrust ? 8 : 60)) } catch { return }
            }
        }
        .task(id: banner?.id) {
            guard banner != nil else { return }
            do { try await Task.sleep(for: .seconds(4)); banner = nil } catch {}
        }
        .onChange(of: receiveSOS) { _, on in Task { await RiderSOSService.shared.updateReceiving(on) } }
    }
}
