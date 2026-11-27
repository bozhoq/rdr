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

private struct RiderAccountAvailability: Decodable {
    let methods: [String: Bool]
    let linked: [String]
    let hasPassword: Bool?
    let passwordEnabled: Bool?
    let emailEnabled: Bool?
    let smsEnabled: Bool?
    let mfa: Bool?

    var canRecover: Bool {
        if mfa == true { return passwordEnabled == true && linked.contains("email") && methods["email"] == true }
        return passwordEnabled == true ||
            (linked.contains("email") && methods["email"] == true && emailEnabled != false) ||
            (linked.contains("phone") && methods["phone"] == true && smsEnabled != false)
    }
}

struct RiderAccountAccessSettings: View {
    @ObservedObject var recorder: SessionRecorder
    @State private var confirmingExit = false
    @State private var working = false
    @State private var notice: String?
    @State private var revision = 0

    var body: some View {
        Form {
            RiderLoginSecurity(revision: revision)
            RiderAccountVerification(intent: "auto", verified: { _ in revision += 1 })
            Section {
                Button("Выйти из аккаунта", role: .destructive) { confirmingExit = true }
                    .disabled(working)
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Вход и восстановление")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmingExit, titleVisibility: .visible) {
            Button("Выйти", role: .destructive, action: signOut)
        } message: {
            Text("Для повторного входа используй свой пароль или включённый способ входа по коду.")
        }
    }

    private func signOut() {
        guard !working else { return }
        guard recorder.live == nil, recorder.analyzingSessionID == nil else {
            notice = "Сначала заверши и сохрани каталку."
            return
        }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                let account: RiderAccountAvailability = try await RiderCommunity.decode("account")
                guard account.canRecover else {
                    notice = "Перед выходом привяжи почту или телефон, чтобы сохранить доступ к профилю."
                    return
                }
                let current: RiderCommunity.Registration = try await RiderCommunity.decode("registration")
                if let id = current.profileID { RiderLocalAccount.identify(id) }
                guard recorder.live == nil, recorder.analyzingSessionID == nil else {
                    notice = "Сначала заверши и сохрани каталку."
                    return
                }
                let path = RiderCommunity.usesLANTrust ? "sos/receiver" : "sos/device"
                let _: [String: Bool]? = try? await RiderCommunity.decode(path, method: "DELETE")
                try RiderCommunity.clearDeviceCredential()
                RiderSOSService.shared.resetAccount()
                RiderLocalAccount.markSignedOut()
            } catch {
                notice = "Не удалось выйти. Проверь подключение к Rider и повтори."
            }
        }
    }
}

private struct RiderAccountVerification: View {
    let intent: String
    let verified: (RiderCommunity.Registration) -> Void
    var resetReady: (() -> Void)?

    @State private var availability: RiderAccountAvailability?
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
            if !awaitingCode, availability?.methods[method.rawValue] != true,
               let active = RiderLoginMethod.allCases.first(where: { availability?.methods[$0.rawValue] == true }) {
                method = active
            }
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
                let payload = ["kind":method.rawValue, "intent":intent,
                               "contact":contact.trimmingCharacters(in: .whitespacesAndNewlines)]
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
                if result["resetReady"] == true, let resetReady {
                    awaitingCode = false
                    code = ""
                    resetReady()
                    return
                }
                guard result["verified"] == true else { throw URLError(.badServerResponse) }
                let profile: RiderCommunity.Registration = try await RiderCommunity.decode("registration")
                awaitingCode = false
                code = ""
                await load()
                verified(profile)
            } catch RiderCommunity.Rejection.forbidden {
                notice = "Код неверный или истёк. Проверь код или запроси новый."
            } catch RiderCommunity.Rejection.conflict {
                switch intent {
                case "register": notice = "Этот контакт уже используется. Вернись и выбери «Войти»."
                case "signIn": notice = "Вход по коду недоступен для этого профиля. Попробуй войти по паролю."
                case "reset": notice = "Восстановление по одному коду недоступно. Если включена двухфакторная защита, меняй пароль с устройства, где уже выполнен вход."
                default: notice = "Не удалось привязать этот контакт. Возможно, он уже используется в другом профиле."
                }
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

private struct RiderNewPasswordFields: View {
    @Binding var password: String
    @Binding var repeated: String

    var body: some View {
        SecureField("Новый пароль", text: $password)
            .textContentType(.newPassword)
        SecureField("Повтори новый пароль", text: $repeated)
            .textContentType(.newPassword)
        if !repeated.isEmpty && repeated != password {
            Text("Пароли не совпадают.").font(.footnote).foregroundStyle(.secondary)
        }
        Text("От 15 до 128 символов. Можно использовать пароль из связки ключей iPhone.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

private struct RiderLoginSecurity: View {
    let revision: Int
    @State private var account: RiderAccountAvailability?
    @State private var password = ""
    @State private var repeated = ""
    @State private var current = ""
    @State private var passwordEnabled = true
    @State private var emailEnabled = true
    @State private var smsEnabled = true
    @State private var mfa = false
    @State private var working = false
    @State private var notice: String?

    private var hasPassword: Bool { account?.hasPassword == true }
    private var canSetPassword: Bool { !(account?.linked.isEmpty ?? true) }
    private var emailLinked: Bool { account?.linked.contains("email") == true && account?.methods["email"] == true }
    private var smsLinked: Bool { account?.linked.contains("phone") == true && account?.methods["phone"] == true }

    var body: some View {
        Group {
            Section("Пароль") {
                if let account, account.linked.isEmpty {
                    Text("Сначала привяжи и подтверди телефон или почту ниже.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if canSetPassword {
                    if hasPassword {
                        SecureField("Текущий пароль", text: $current).textContentType(.password)
                    }
                    RiderNewPasswordFields(password: $password, repeated: $repeated)
                    Button(hasPassword ? "Сменить пароль" : "Установить пароль") {
                        save("account/password", fields: ["password":password, "currentPassword":current])
                    }
                    .disabled(working || (hasPassword && current.isEmpty) || !validNewPassword)
                } else if notice == nil {
                    ProgressView()
                }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            if hasPassword {
                Section {
                    Toggle("Вход по паролю", isOn: $passwordEnabled).disabled(mfa)
                    Toggle("Вход по коду из письма", isOn: $emailEnabled).disabled(mfa || !emailLinked)
                    Toggle("Вход по коду из SMS", isOn: $smsEnabled).disabled(mfa || !smsLinked)
                    Toggle("Двухфакторная защита", isOn: $mfa)
                        .disabled(!emailLinked && !mfa)
                        .onChange(of: mfa) { _, enabled in if enabled { passwordEnabled = true } }
                    if !emailLinked && !mfa {
                        Text("Для двухфакторной защиты привяжи почту.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Сохранить способы входа") {
                        save("account/security", fields: [
                            "passwordEnabled":passwordEnabled, "emailEnabled":emailEnabled,
                            "smsEnabled":smsEnabled, "mfa":mfa, "currentPassword":current
                        ])
                    }
                    .disabled(working || current.isEmpty)
                } header: {
                    Text("Способы входа")
                } footer: {
                    Text("Двухфакторная защита требует пароль и код на привязанную почту. Чтобы сохранить изменения, введи текущий пароль выше.")
                }
            }
        }
        .task(id: revision) { await load() }
    }

    private var validNewPassword: Bool {
        (15...128).contains(password.unicodeScalars.count) && password == repeated
    }

    @MainActor private func load() async {
        do {
            let value: RiderAccountAvailability = try await RiderCommunity.decode("account")
            account = value
            passwordEnabled = value.passwordEnabled ?? true
            emailEnabled = value.emailEnabled ?? true
            smsEnabled = value.smsEnabled ?? true
            mfa = value.mfa ?? false
        } catch { if !Task.isCancelled { notice = "Не удалось загрузить настройки входа." } }
    }

    private func save(_ path: String, fields: [String: Any]) {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                let data = try JSONSerialization.data(withJSONObject: fields)
                let _: [String: Bool] = try await RiderCommunity.decode(path, method: "POST", body: data)
                password = ""; repeated = ""; current = ""
                await load()
                notice = "Сохранено."
            } catch RiderCommunity.Rejection.forbidden {
                notice = "Проверь текущий пароль."
            } catch RiderCommunity.Rejection.conflict {
                notice = "Оставь хотя бы один доступный способ входа. Для двухфакторной защиты нужна подтверждённая почта."
            } catch {
                notice = "Не удалось сохранить. Проверь подключение и попробуй ещё раз."
            }
        }
    }
}

private struct RiderPasswordSignIn: View {
    let signedIn: (RiderCommunity.Registration) -> Void
    @State private var method = RiderLoginMethod.email
    @State private var login = ""
    @State private var password = ""
    @State private var secondEmail = ""
    @State private var code = ""
    @State private var stage = Stage.password
    @State private var working = false
    @State private var notice: String?

    private enum Stage: Equatable { case password, email, code }

    var body: some View {
        Section {
            if stage == .password {
                Picker("Логин", selection: $method) {
                    ForEach(RiderLoginMethod.allCases) { choice in Text(choice.title).tag(choice) }
                }.pickerStyle(.segmented)
                TextField(method.placeholder, text: $login)
                    .textContentType(.username)
                    .keyboardType(method == .phone ? .phonePad : .emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Пароль", text: $password).textContentType(.password)
                Button("Войти", action: submitPassword).disabled(login.isEmpty || password.isEmpty || working)
            } else if stage == .email {
                TextField("Привязанная почта", text: $secondEmail)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Отправить код", action: submitPassword).disabled(secondEmail.isEmpty || working)
            } else {
                TextField("Код из письма", text: $code)
                    .textContentType(.oneTimeCode).keyboardType(.numberPad)
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                Button("Подтвердить код", action: submitCode).disabled(code.count != 6 || working)
            }
            if stage != .password {
                Button("Начать заново") {
                    stage = .password
                    password = ""; secondEmail = ""; code = ""; notice = nil
                }
                .disabled(working)
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .onChange(of: method) { _, _ in login = ""; notice = nil }
    }

    private func submitPassword() {
        run {
            let result: [String: String] = try await RiderCommunity.decode(
                "account/password-login", method: "POST",
                body: JSONEncoder().encode(["kind":method.rawValue, "contact":login.trimmingCharacters(in: .whitespacesAndNewlines),
                                            "password":password, "secondEmail":secondEmail.trimmingCharacters(in: .whitespacesAndNewlines)]))
            switch result["step"] {
            case "complete": try await finish()
            case "emailRequired": stage = .email
            case "codeRequired": stage = .code; password = ""
            default: throw URLError(.badServerResponse)
            }
        }
    }

    private func submitCode() {
        run {
            let _: [String: Bool] = try await RiderCommunity.decode("account/verify", method: "POST",
                                                                  body: JSONEncoder().encode(["code":code]))
            try await finish()
        }
    }

    @MainActor private func finish() async throws {
        let profile: RiderCommunity.Registration = try await RiderCommunity.decode("registration")
        password = ""; code = ""
        signedIn(profile)
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do { try await action() }
            catch RiderCommunity.Rejection.forbidden {
                notice = stage == .code ? "Код неверный или истёк." : "Не удалось войти. Проверь логин и пароль."
            } catch {
                notice = "Не удалось выполнить вход. Проверь подключение и попробуй ещё раз."
            }
        }
    }
}

struct RiderRegistrationView: View {
    let onDone: (RiderCommunity.Registration) -> Void

    private enum Route: Hashable {
        case signIn, recovery, register

        var title: String {
            switch self {
            case .signIn: return "Вход"
            case .recovery: return "Восстановление доступа"
            case .register: return "Регистрация"
            }
        }

        var intent: String {
            switch self {
            case .signIn: return "signIn"
            case .recovery: return "reset"
            case .register: return "register"
            }
        }
    }

    private enum SignIn: String, CaseIterable, Identifiable {
        case password = "Пароль"
        case code = "Разовый код"
        var id: Self { self }
    }

    @State private var signIn = SignIn.password
    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var resetting = false
    @State private var navigation: [Route] = []
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
        NavigationStack(path: $navigation) {
            ScrollView {
                VStack(spacing: 16) {
                    RDRWordmark().frame(maxWidth: .infinity)
                    Text("Добро пожаловать в Rider").font(.title2.bold())
                    NavigationLink("Войти", value: Route.signIn)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    NavigationLink("Регистрация", value: Route.register)
                        .buttonStyle(.bordered).controlSize(.large)
                    NavigationLink("Забыли пароль?", value: Route.recovery)
                        .buttonStyle(.plain).foregroundStyle(RiderTheme.accent)
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
            .background(RiderTheme.canvas.ignoresSafeArea())
            .navigationDestination(for: Route.self) { route in
                Form {
                    switch route {
                    case .register:
                        if contactVerified { profileForm }
                        else { RiderAccountVerification(intent: route.intent, verified: acceptStatus) }
                    case .signIn:
                        Picker("Способ входа", selection: $signIn) {
                            ForEach(SignIn.allCases) { option in Text(option.rawValue).tag(option) }
                        }.pickerStyle(.segmented)
                        if signIn == .password { RiderPasswordSignIn(signedIn: acceptStatus) }
                        else { RiderAccountVerification(intent: route.intent, verified: acceptStatus) }
                    case .recovery:
                        if resetting { resetForm }
                        else {
                            Text("Подтверди привязанный контакт, чтобы задать новый пароль.")
                            RiderAccountVerification(intent: route.intent, verified: acceptStatus) { resetting = true }
                        }
                    }
                }
                .navigationTitle(route.title)
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .task {
            if let status: RiderCommunity.Registration = try? await RiderCommunity.decode("registration"),
               !Task.isCancelled {
                if !status.required { onDone(status) }
                else if status.verified == true {
                    contactVerified = true
                    navigation = [.register]
                }
            }
        }
    }

    @ViewBuilder private var profileForm: some View {
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
        }
        Section("Пароль для входа") {
            RiderNewPasswordFields(password: $newPassword, repeated: $repeatedPassword)
        }
        if let notice { Text(notice).foregroundStyle(.red) }
        Button(working ? "Регистрируем…" : "Зарегистрироваться", action: register)
            .disabled(working || !validNewPassword || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      handle.range(of: #"^[a-z0-9_]{3,24}$"#, options: .regularExpression) == nil)
    }

    private var validNewPassword: Bool {
        (15...128).contains(newPassword.unicodeScalars.count) && newPassword == repeatedPassword
    }

    private var resetForm: some View {
        Section("Новый пароль") {
            RiderNewPasswordFields(password: $newPassword, repeated: $repeatedPassword)
            Button("Сохранить пароль и войти", action: resetPassword)
                .disabled(working || !validNewPassword)
            Button("Запросить новый код") {
                resetting = false
                newPassword = ""; repeatedPassword = ""; notice = nil
            }.disabled(working)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func resetPassword() {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                let _: [String: Bool] = try await RiderCommunity.decode("account/password-reset", method: "POST",
                    body: JSONEncoder().encode(["password":newPassword]))
                let profile: RiderCommunity.Registration = try await RiderCommunity.decode("registration")
                newPassword = ""; repeatedPassword = ""
                acceptStatus(profile)
            } catch RiderCommunity.Rejection.forbidden {
                notice = "Подтверждение истекло. Запроси новый код."
            } catch {
                notice = "Не удалось сменить пароль. Проверь подключение и попробуй ещё раз."
            }
        }
    }

    private func acceptStatus(_ status: RiderCommunity.Registration) {
        if !status.required {
            onDone(status)
        } else if status.verified == true {
            contactVerified = true
            if navigation.last != .register { navigation = [.register] }
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
                try await RiderCommunity.register(name: clean, username: handle,
                                                  publicProfile: publicProfile, statsPublic: publicStats,
                                                  password: newPassword)
                let profile: RiderCommunity.Registration = try await RiderCommunity.decode("registration")
                newPassword = ""; repeatedPassword = ""
                acceptStatus(profile)
            } catch RiderCommunity.Rejection.conflict {
                notice = "Этот юзернейм занят."
            } catch {
                notice = "Сервер Rider недоступен. Проверь подключение и попробуй ещё раз."
            }
        }
    }
}
