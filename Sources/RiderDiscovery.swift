import SwiftUI
import CoreLocation
import Contacts
import CryptoKit

struct RiderDirectory: Decodable {
    var people: [RiderPerson]
    var nearby: [RiderPerson]
    var following: [RiderPerson]? = nil
    var followers: [RiderPerson]? = nil
}
struct RiderPhoneStatus: Decodable {
    let verified: Bool
    let discoverable: Bool
    let smsAvailable: Bool
}
private struct DirectoryInput: Encodable {
    var query = ""
    var lat: Double?
    var lon: Double?
    var mentions: Bool? = nil
}
private func directory(_ input: DirectoryInput) async throws -> RiderDirectory {
    try await RiderCommunity.decode("people/search", method: "POST", body: JSONEncoder().encode(input))
}

enum RiderSearch {
    static func query(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "@" }).prefix(100))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ rider: RiderPerson, query: String) -> Bool {
        query.isEmpty || rider.name.localizedStandardContains(query) ||
            rider.username?.localizedStandardContains(query) == true
    }
}

struct RiderGlobalSearchSection<Row: View>: View {
    let query: String
    let excluding: Set<String>
    @ViewBuilder let row: (RiderPerson) -> Row
    @State private var response: (query: String, people: [RiderPerson])?
    @State private var failedQuery: String?

    var body: some View {
        if !query.isEmpty {
            Section("Глобальный поиск") {
                if response?.query == query, let response {
                    let people = response.people.filter { !excluding.contains($0.id) }
                    if people.isEmpty {
                        Text("Других совпадений нет").foregroundStyle(.secondary)
                    } else {
                        Text("Возможно, вы искали:").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(people) { row($0) }
                    }
                } else if failedQuery == query {
                    Button("Повторить поиск") { Task { await load(query) } }
                } else {
                    ProgressView()
                }
            }
            .task(id: query) { await load(query) }
        }
    }

    @MainActor private func load(_ query: String) async {
        failedQuery = nil
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await directory(DirectoryInput(query: query))
            try Task.checkCancellation()
            response = (query, result.people)
        } catch {
            if !Task.isCancelled { failedQuery = query }
        }
    }
}

struct RiderMentionSuggestions: View {
    @Binding private var text: String
    let limit: Int
    @State private var result: (query: String, page: RiderDirectory)?
    @State private var failedQuery: String?

    private struct SuggestionGroup: Identifiable {
        let title: String
        let people: [RiderPerson]
        var id: String { title }
    }

    private static let pattern = #"(?<![A-Za-z0-9_.+@])@[A-Za-z0-9_]{1,24}\z"#
    private static func token(in text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
    }

    @ViewBuilder static func forText(_ text: Binding<String>, editing: Bool, limit: Int) -> some View {
        if editing && token(in: text.wrappedValue) != nil {
            RiderMentionSuggestions(text: text, limit: limit)
        }
    }

    private var token: Range<String.Index>? { Self.token(in: text) }
    private var query: String? { token.map { String(text[$0].dropFirst()).lowercased() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let query, let result, result.query == query {
                let groups = [
                    SuggestionGroup(title: "Подписки", people: result.page.following ?? []),
                    SuggestionGroup(title: "Подписчики", people: result.page.followers ?? []),
                    SuggestionGroup(title: "Глобальный поиск", people: result.page.people)
                ].filter { !$0.people.isEmpty }
                if groups.isEmpty {
                    Text("Нет совпадений").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Возможно, вы искали:").font(.caption.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(groups) { group in
                                Text(group.title).font(.caption2).foregroundStyle(.secondary)
                                ForEach(group.people) { person in candidate(person, query: query) }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 116)
                }
            } else if let query, failedQuery == query {
                Text("Подсказки недоступны").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .task(id: query) {
            guard let query else { return }
            failedQuery = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let page = try await directory(DirectoryInput(query: query, mentions: true))
                try Task.checkCancellation()
                result = (query, page)
            } catch {
                if !Task.isCancelled { failedQuery = query }
            }
        }
    }

    private func candidate(_ person: RiderPerson, query: String) -> some View {
        Button {
            guard self.query == query, let token, let username = person.username else { return }
            var updated = text
            updated.replaceSubrange(token, with: "@" + username + " ")
            if updated.count <= limit { text = updated }
        } label: {
            HStack(spacing: 6) {
                RiderAvatar(photo: person.avatar ?? Data(), size: 21).accessibilityHidden(true)
                Text(person.handle).fontWeight(.semibold)
                Text(person.name).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
            .frame(minHeight: 44)
            .contentShape(.interaction, Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum ContactNumbers {
    static func hash(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.range(of: #"^[+0-9() .-]{7,40}$"#, options: .regularExpression) != nil else { return nil }
        var digits = cleaned.filter { $0 >= "0" && $0 <= "9" }
        if !cleaned.hasPrefix("+") {
            if digits.count == 11, digits.first == "8" || digits.first == "7" { digits = "7" + digits.dropFirst() }
            else if digits.count == 10 { digits = "7" + digits }
            else { return nil }
        }
        guard (8...15).contains(digits.count), digits.first != "0" else { return nil }
        return SHA256.hash(data: Data(("+" + digits).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ hashes: [String]) async throws -> [RiderPerson] {
        var found: [String: RiderPerson] = [:]
        for offset in stride(from: 0, to: hashes.count, by: 250) {
            try Task.checkCancellation()
            let chunk = Array(hashes[offset..<min(offset + 250, hashes.count)])
            let result: [RiderPerson] = try await RiderCommunity.decode("people/contacts", method: "POST",
                body: JSONEncoder().encode(["hashes": chunk]))
            for person in result { found[person.id] = person }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func fromAddressBook(ask: Bool) async throws -> [RiderPerson] {
        let store = CNContactStore()
        if ask && CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            guard try await store.requestAccess(for: .contacts) else { throw URLError(.noPermissionsToReadFile) }
        }
        let hashes = try await Task.detached(priority: .userInitiated) {
            let request = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor])
            var numbers = Set<String>()
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                for phone in contact.phoneNumbers {
                    if let h = hash(phone.value.stringValue) { numbers.insert(h) }
                }
            }
            return numbers.sorted()
        }.value
        return try await matches(hashes)
    }
}

struct RiderPeopleEntry: View {
    @ObservedObject var recorder: SessionRecorder

    var body: some View {
        NavigationLink {
            RiderPeopleView(recorder: recorder)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RiderTheme.accent)
                .frame(width: 44, height: 44)
                .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(.interaction, Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Найти райдеров")
    }
}

private struct RiderPeopleView: View {
    @ObservedObject var recorder: SessionRecorder
    @State private var query = ""
    @State private var page: RiderDirectory?
    @State private var useArea = false
    @State private var error: String?
    @State private var phone: RiderPhoneStatus?
    @State private var friends: [RiderPerson]?
    @State private var matching = false
    @State private var contactsError: String?
    @State private var confirmContacts = false
    @AppStorage("rider.contactMatchEnabled") private var contactsEnabled = false
    private var input: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNumber: Bool { ContactNumbers.hash(input) != nil }
    private var fix: CLLocationCoordinate2D? { useArea ? recorder.usableFix?.coordinate : nil }
    private var coarseLat: Double? { fix.map { ($0.latitude * 10).rounded()/10 } }
    private var coarseLon: Double? { fix.map { ($0.longitude * 10).rounded()/10 } }
    private var searchKey: String { "\(input)|\(coarseLat ?? 999)|\(coarseLon ?? 999)|\(phone?.verified == true)" }

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Повторить поиск") { Task { await load() } }
            }
            if input.isEmpty {
                Text("Публичный профиль можно найти по нику или @юзернейму. По номеру находятся райдеры, разрешившие такой поиск.")
                    .font(.footnote).foregroundStyle(.secondary)
                Section("Знакомые") {
                    if phone?.verified == true {
                        if let friends { rows(friends); if friends.isEmpty { Text("Совпадений пока нет").foregroundStyle(.secondary) } }
                        if matching { ProgressView() }
                        Button(contactsEnabled ? "Обновить контакты" : "Найти знакомых из контактов") {
                            if contactsEnabled { Task { await match(ask: true) } } else { confirmContacts = true }
                        }.disabled(matching)
                        if let contactsError { Text(contactsError).font(.caption) }
                    } else {
                        NavigationLink { RiderPhoneSettings() } label: { Label("Привязать номер для поиска знакомых", systemImage: "person.crop.circle.badge.checkmark") }
                    }
                }
                Section {
                    if !useArea {
                        Button { useArea = true; recorder.locateSpot() } label: { Label("Найти райдеров поблизости", systemImage: "location") }
                    } else if !recorder.locationAuthorized || fix == nil {
                        Text("Нужна геопозиция iPhone. Разреши доступ к ней в настройках или обнови местоположение.")
                        Button("Обновить геопозицию") { recorder.locateSpot() }
                    } else if let page {
                        rows(page.nearby)
                        if page.nearby.isEmpty { Text("Пока нет райдеров с публикациями поблизости").foregroundStyle(.secondary) }
                    }
                } header: { Text("Рядом") } footer: {
                    Text("По геометкам публичных постов за 90 дней, примерно в 60 км от тебя. Сервер получает округлённые координаты для этого поиска.")
                }
            }
            if let page {
                Section(input.isEmpty ? "Рекомендованные райдеры" : isNumber ? "По номеру" : "Глобальный поиск") {
                    rows(page.people)
                    if page.people.isEmpty { Text("Никого не найдено").foregroundStyle(.secondary) }
                }
            } else if error == nil { ProgressView() }
        }
        .navigationTitle("Найти райдеров").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ник, @юзернейм или номер")
        .task(id: searchKey) { await load() }
        .task {
            phone = try? await RiderCommunity.decode("people/phone")
            if contactsEnabled && phone?.verified == true { await match(ask: false) }
        }
        .alert("Найти знакомых?", isPresented: $confirmContacts) {
            Button("Продолжить") { contactsEnabled = true; Task { await match(ask: true) } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Rider передаст серверу хеши номеров из разрешённых контактов. Имена останутся на iPhone. Сверку можно отключить в настройках номера.") }
    }
    @ViewBuilder private func rows(_ people: [RiderPerson]) -> some View {
        ForEach(people) { p in
            NavigationLink { RiderPublicProfileView(id: p.id) } label: {
                RiderPostHeader(author: p.name, username: p.username, avatar: p.avatar, premium: p.premium)
            }
        }
    }
    @MainActor private func match(ask: Bool) async {
        guard !matching else { return }
        matching = true
        defer { matching = false }
        do { friends = try await ContactNumbers.fromAddressBook(ask: ask); contactsError = nil }
        catch { friends = nil; contactsError = "Проверь доступ к контактам в настройках iPhone и подключение к Rider." }
    }
    @MainActor private func load() async {
        page = nil
        error = nil
        let next = DirectoryInput(query: input, lat: coarseLat, lon: coarseLon)
        do {
            if !input.isEmpty { try await Task.sleep(for: .milliseconds(280)) }
            let response: RiderDirectory
            if isNumber, let h = ContactNumbers.hash(input) {
                guard phone?.verified == true else { error = "Для поиска по номеру привяжи свой номер в профиле."; return }
                response = RiderDirectory(people: try await ContactNumbers.matches([h]), nearby: [])
            } else {
                response = try await directory(next)
            }
            try Task.checkCancellation()
            page = response
        } catch { if !Task.isCancelled { self.error = "Не удалось получить список райдеров." } }
    }
}

struct RiderPhoneSettings: View {
    @State private var status: RiderPhoneStatus?
    @State private var number = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var message: String?
    @State private var removing = false
    @AppStorage("rider.contactMatchEnabled") private var sync = false
    var body: some View {
        Form {
            if let status {
                if status.verified {
                    Label("Номер подтверждён", systemImage: "checkmark.seal.fill")
                    Toggle("Находить меня по номеру", isOn: Binding(get: { status.discoverable }, set: { value in
                        run { self.status = try await RiderCommunity.decode("people/phone", method: "PATCH", body: JSONEncoder().encode(["discoverable":value])) }
                    }))
                    Text("Совпадения видны другим райдерам с подтверждённым номером, когда твой профиль публичный.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if sync { Button("Отключить сверку контактов") { sync = false } }
                    Button("Отвязать номер", role: .destructive) { removing = true }
                } else if status.smsAvailable {
                    Section("Привязка номера") {
                        TextField("+7 …", text: $number).textContentType(.telephoneNumber).keyboardType(.phonePad)
                            .disabled(sent)
                        if sent {
                            TextField("Код из SMS", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                            Button("Подтвердить") { run {
                                self.status = try await RiderCommunity.decode("people/phone/verify", method: "POST", body: JSONEncoder().encode(["code":code]))
                                code = ""; number = ""; sent = false
                            } }.disabled(code.count != 6)
                            Button("Изменить номер или запросить код снова") { sent = false; code = "" }
                        } else {
                            Button("Получить код") { run {
                                let _: [String:Bool] = try await RiderCommunity.decode("people/phone/start", method: "POST", body: JSONEncoder().encode(["phone":number]))
                                sent = true
                            } }.disabled(ContactNumbers.hash(number) == nil)
                        }
                    }
                } else { Text("Этот сервер пока не отправляет SMS. Поиск по нику и @юзернейму уже работает.") }
            } else if message == nil { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary); Button("Обновить") { run { try await refresh() } } }
            if busy { ProgressView() }
        }.disabled(busy)
        .navigationTitle("Номер телефона").navigationBarTitleDisplayMode(.inline)
        .task { do { try await refresh() } catch { message = "Сервер Rider недоступен." } }
        .confirmationDialog("Отвязать номер от Rider?", isPresented: $removing) {
            Button("Отвязать номер", role: .destructive) { run {
                self.status = try await RiderCommunity.decode("people/phone", method: "DELETE"); sync = false
            } }
        }
    }
    @MainActor private func refresh() async throws { status = try await RiderCommunity.decode("people/phone") }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() }
            catch RiderCommunity.Rejection.conflict { message = "Этот номер уже привязан к другому аккаунту." }
            catch { message = "Не удалось выполнить запрос. Проверь номер или код и попробуй чуть позже." }
        }
    }
}
