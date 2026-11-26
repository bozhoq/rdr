import SwiftUI
import AudioToolbox

enum RiderAppearance: String, CaseIterable {
    case lagoon, system, light, dark
    var title: String {
        switch self { case .lagoon: return "Лагуна"; case .system: return "Как на iPhone"; case .light: return "Светлая"; case .dark: return "Тёмная" }
    }
}
struct RiderAppearanceSettings: View {
    @AppStorage("rider.appearance") private var theme = RiderAppearance.lagoon
    @AppStorage("rider.textSize") private var size = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    private var chatStyle = RiderChatStyle()

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
            Section {
                wallpapers
            } header: {
                Text("Фон чата")
            } footer: {
                Text("Выбор сохраняется отдельно для каждой темы.")
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
                .listRowBackground(theme == .lagoon ? RiderTheme.surface : Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme == .lagoon ? RiderTheme.canvas : Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Оформление").navigationBarTitleDisplayMode(.inline)
    }
    private var wallpapers: some View {
        let selection = chatStyle.selection
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                          count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 12) {
            ForEach(chatStyle.options) { wallpaper in
                let selected = selection.wrappedValue == wallpaper
                Button {
                    selection.wrappedValue = wallpaper
                } label: {
                    VStack(spacing: 6) {
                        RiderChatBackdrop(wallpaper: wallpaper, dark: chatStyle.isDark)
                            .frame(height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(selected ? RiderTheme.accent : .primary.opacity(0.10),
                                                  lineWidth: selected ? 2 : 1)
                            }
                            .overlay(alignment: .topTrailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white, RiderTheme.action)
                                        .padding(5)
                                        .accessibilityHidden(true)
                                }
                            }
                        Text(wallpaper.title)
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(.vertical, 4)
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
    @EnvironmentObject private var social: RiderSocialStore
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
                Text(drillAccepted ? "Отклик принят в демо." : "Получен учебный сигнал SOS. Можно проверить окно оповещения и отклик.")
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
        .onReceive(NotificationCenter.default.publisher(for: RiderSOSService.drillNotification)) { _ in
            drillAccepted = false
            showDrill = true
            if RiderAlertKind.sound.enabled { AudioServicesPlaySystemSound(1007) }
            if RiderAlertKind.vibrate.enabled { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("rider.social.open"))) { note in
            opened = note.object as? String; showDestination = true
        }
        .task(id: "\(phase == .active)-\(revision)") {
            guard phase == .active, RiderCommunity.endpoint != nil else { return }
            let prefs = RiderAlertKind.values
            var synced = false
            while !Task.isCancelled {
                await social.refreshUnread()
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
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: banner?.id) {
            guard banner != nil else { return }
            do { try await Task.sleep(for: .seconds(4)); banner = nil } catch {}
        }
        .onChange(of: receiveSOS) { _, on in Task { await RiderSOSService.shared.updateReceiving(on) } }
    }
}


private enum RiderLoginMethod: String, CaseIterable, Identifiable {
    case phone, email

    var id: Self { self }
    var title: String { self == .phone ? "Телефон" : "Почта" }
    var placeholder: String { self == .phone ? "+7 …" : "name@example.com" }
}

struct RiderAccountAccessSettings: View {
    var body: some View {
        Form { RiderAccountVerification { _ in } }
            .navigationTitle("Вход и восстановление")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RiderAccountVerification: View {
    let verified: (RiderCommunity.Registration) -> Void

    private struct Availability: Decodable {
        let methods: [String: Bool]
        let linked: [String]
    }

    @State private var availability: Availability?
    @State private var method = RiderLoginMethod.phone
    @State private var contact = ""
    @State private var code = ""
    @State private var awaitingCode = false
    @State private var working = false
    @State private var notice: String?

    var body: some View {
        Section {
            Picker("Способ входа", selection: $method) {
                ForEach(RiderLoginMethod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(working || awaitingCode)
            if let availability {
                if availability.linked.contains(method.rawValue) {
                    Label("Способ входа привязан", systemImage: "checkmark.circle")
                } else if availability.methods[method.rawValue] != true {
                    Text(method == .phone ? "Отправка SMS пока недоступна." : "Отправка писем пока недоступна.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if awaitingCode {
                    TextField("Код из 6 цифр", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .onChange(of: code) { _, value in
                            code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        }
                    Button("Подтвердить код", action: verify).disabled(code.count != 6 || working)
                    Button("Изменить данные") {
                        awaitingCode = false
                        code = ""
                        notice = nil
                    }.disabled(working)
                } else {
                    TextField(method.placeholder, text: $contact)
                        .textContentType(method == .phone ? .telephoneNumber : .emailAddress)
                        .keyboardType(method == .phone ? .phonePad : .emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Получить код", action: request)
                        .disabled(working || contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if notice == nil {
                ProgressView()
            } else {
                Button("Проверить снова") { Task { await load() } }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Телефон или почта")
        } footer: {
            Text("Подтверждённый контакт позволяет войти в тот же профиль на другом iPhone.")
        }
        .onChange(of: method) { _, _ in contact = ""; code = ""; notice = nil }
        .task { await load() }
    }

    @MainActor private func load() async {
        do {
            availability = try await RiderCommunity.decode("account")
            notice = nil
        } catch {
            if !Task.isCancelled { notice = "Не удалось загрузить доступные способы входа." }
        }
    }

    private func request() {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                let payload = ["kind":method.rawValue, "contact":contact.trimmingCharacters(in: .whitespacesAndNewlines)]
                let result: [String: Bool] = try await RiderCommunity.decode("account/start", method: "POST",
                                                                            body: JSONEncoder().encode(payload))
                guard result["sent"] == true else { throw URLError(.badServerResponse) }
                code = ""
                awaitingCode = true
                notice = method == .phone ? "Код отправлен по SMS." : "Код отправлен на почту."
            } catch {
                notice = "Не удалось отправить код. Проверь данные и попробуй чуть позже."
            }
        }
    }

    private func verify() {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                let result: [String: Bool] = try await RiderCommunity.decode("account/verify", method: "POST",
                                                                            body: JSONEncoder().encode(["code":code]))
                guard result["verified"] == true else { throw URLError(.badServerResponse) }
                let profile: RiderCommunity.Registration = try await RiderCommunity.decode("registration")
                awaitingCode = false
                code = ""
                await load()
                verified(profile)
            } catch RiderCommunity.Rejection.forbidden {
                notice = "Код неверный или истёк. Проверь код или запроси новый."
            } catch RiderCommunity.Rejection.conflict {
                notice = "Этот контакт уже привязан. Для действующего профиля добавляй контакт с устройства, где в него уже выполнен вход."
            } catch {
                notice = "Не удалось подтвердить код. Проверь подключение к Rider."
                await load()
                if let state: RiderCommunity.Registration = try? await RiderCommunity.decode("registration"),
                   state.verified == true, availability?.linked.contains(method.rawValue) == true {
                    awaitingCode = false
                    verified(state)
                }
            }
        }
    }
}

struct RiderRegistrationView: View {
    let onDone: () -> Void
    @AppStorage("rider.profileName") private var savedName = "Райдер"
    @AppStorage("rider.username") private var savedUsername = ""
    @State private var name = ""
    @State private var username = ""
    @State private var publicProfile = true
    @State private var publicStats = true
    @State private var contactVerified = false
    @State private var working = false
    @State private var notice: String?

    private var handle: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    var body: some View {
        NavigationStack {
            Form {
                if contactVerified {
                    Section {
                        TextField("Имя или ник", text: $name)
                            .onChange(of: name) { _, value in name = String(value.prefix(50)) }
                        TextField("Уникальный @юзернейм", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: username) { _, value in username = String(value.prefix(25)) }
                    } header: { Text("Создай профиль Rider") }
                    footer: { Text("Для юзернейма используй 3–24 латинские буквы, цифры или подчёркивания.") }
                    Section {
                        Toggle("Публичный профиль", isOn: $publicProfile)
                        Toggle("Публичная статистика", isOn: $publicStats)
                    } footer: {
                        Text("Открытый профиль позволяет сразу публиковать посты, подписываться и писать райдерам. Публичная статистика открывает графики каталок. Видимость можно изменить в профиле.")
                    }
                    if let notice { Text(notice).foregroundStyle(.red) }
                    Button(working ? "Регистрируем…" : "Зарегистрироваться", action: register)
                        .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  handle.range(of: #"^[a-z0-9_]{3,24}$"#, options: .regularExpression) == nil)
                } else {
                    RiderAccountVerification(verified: acceptStatus)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Добро пожаловать")
            .task {
                // A previous request may have succeeded while the connection was closing.
                if let status: RiderCommunity.Registration = try? await RiderCommunity.decode("registration"),
                   !Task.isCancelled { acceptStatus(status) }
            }
        }
    }

    private func acceptStatus(_ status: RiderCommunity.Registration) {
        if !status.required {
            if let name = status.name { savedName = name }
            if let username = status.username { savedUsername = username }
            onDone()
        } else {
            contactVerified = status.verified == true
        }
    }

    private func register() {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                savedUsername = try await RiderCommunity.register(name: clean, username: handle,
                                        publicProfile: publicProfile, statsPublic: publicStats)
                savedName = clean
                onDone()
            } catch RiderCommunity.Rejection.conflict {
                notice = "Этот юзернейм занят."
            } catch {
                notice = "Сервер Rider недоступен. Проверь подключение и попробуй ещё раз."
            }
        }
    }
}
