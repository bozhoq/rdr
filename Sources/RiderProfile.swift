import SwiftUI
import PhotosUI
import ImageIO
import Security

struct RiderTotals: Codable {
    let sessions: Int
    let jumps: Int
    let height: Double?
    let airtime: Double?
    let seconds: Double

    init(_ history: [SessionSummary]) {
        let rides = history.filter { $0.status == .finished && $0.setup?.sport.isRiding == true && $0.handSimulationTest != true }
        let events = rides.flatMap { session in
            (session.jumpAnalysis?.candidates ?? []).compactMap { session.liveEstimate(for: $0) }
        }.filter { $0.isPhoneToss != true && $0.isHandLift != true }
        sessions = rides.count
        jumps = events.count
        height = events.compactMap(\.heightMeters).max()
        airtime = events.map(\.airtimeSeconds).max()
        seconds = rides.reduce(0) { $0 + $1.durationSeconds }
    }
}

private struct RiderPublication: Codable {
    let name: String
    let totals: RiderTotals
    let avatar: Data?
}

private struct RemoteRider: Decodable, Identifiable {
    let id: String
    let profile: RiderPublication
    let followers: Int
    let following: Bool
}

private struct CommunityState: Decodable {
    let mine: RemoteRider?
    let riders: [RemoteRider]
}

private enum RiderCommunity {
    static var endpoint: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RiderProfileServer") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func request(_ path: String, method: String = "GET", payload: RiderPublication? = nil) async throws -> CommunityState {
        guard let base = endpoint else { throw URLError(.unsupportedURL) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "RiderCommunity", kSecAttrAccount as String: base.absoluteString]
        var result: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let token: String
        if status == errSecSuccess, let data = result as? Data, let saved = String(data: data, encoding: .utf8) {
            token = saved
        } else {
            guard status == errSecItemNotFound else { throw URLError(.userAuthenticationRequired) }
            token = UUID().uuidString + UUID().uuidString
            var item = query
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw URLError(.userAuthenticationRequired) }
        }
        var req = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let payload {
            req.httpBody = try JSONEncoder().encode(payload)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CommunityState.self, from: data)
    }
}

struct RiderProfileView: View {
    @ObservedObject var recorder: SessionRecorder
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @AppStorage("rider.publicPreview") private var publicPreview = false
    @State private var picked: PhotosPickerItem?
    @State private var community: CommunityState?
    @State private var busy = false
    @State private var message: String?
    private var rides: [SessionSummary] {
        recorder.history.filter { $0.status == .finished && $0.setup?.sport.isRiding == true && $0.handSimulationTest != true }
    }
    private var totals: RiderTotals { RiderTotals(rides) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    PhotosPicker(selection: $picked, matching: .images) {
                        if let image = UIImage(data: photo) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 62)).foregroundStyle(RiderTheme.accent)
                        }
                    }.accessibilityLabel("Выбрать фото райдера")
                    VStack(alignment: .leading) {
                        TextField("Имя райдера", text: $name).font(.title2.bold())
                        if let me = community?.mine { Text("Подписчики · \(me.followers)").font(.caption) }
                        else { Text("Сессии · \(totals.sessions)").font(.subheadline) }
                    }
                }
                Picker("Статистика", selection: $publicPreview) {
                    Text("Личная").tag(false)
                    Text("Публичная").tag(true)
                }.pickerStyle(.segmented)
                LabeledContent("Прыжки", value: String(totals.jumps))
                LabeledContent("Лучший прыжок", value: metric(totals.height, unit: "м"))
                LabeledContent("Топ зависание", value: metric(totals.airtime, unit: "с"))
                LabeledContent("Время на воде", value: "\(Int(totals.seconds / 60)) мин")
            }
            if publicPreview {
                Section("Публичная карточка") {
                    if RiderCommunity.endpoint == nil {
                        Text("Локальный предпросмотр. Публикация и подписки появятся после подключения сервера Rider.")
                            .foregroundStyle(.secondary)
                    } else {
                        if community != nil {
                            Button(community?.mine == nil ? "Опубликовать фото, имя и итоги" : "Обновить публичную карточку") {
                                perform("me", method: "PUT", payload: RiderPublication(name: String(name.prefix(50)), totals: totals,
                                                                                      avatar: photo.isEmpty ? nil : photo))
                            }
                            if community?.mine != nil { Button("Сделать профиль закрытым") { perform("me", method: "DELETE") } }
                        }
                        Button("Обновить список райдеров") { perform("riders") }
                        ForEach(community?.riders ?? []) { rider in
                            DisclosureGroup(rider.profile.name) {
                                if let data = rider.profile.avatar, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(height: 70)
                                }
                                LabeledContent("Лучший прыжок", value: metric(rider.profile.totals.height, unit: "м"))
                                LabeledContent("Подписчики", value: String(rider.followers))
                                Button(rider.following ? "Отписаться" : "Подписаться") {
                                    perform("follow/" + rider.id, method: rider.following ? "DELETE" : "PUT")
                                }
                            }
                        }
                    }
                }.disabled(busy)
            } else {
                Section("Мои сессии") {
                    ForEach(rides) { session in
                        NavigationLink {
                            SessionDetail(recorder: recorder, originalSession: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.setup?.spot.isEmpty == false ? session.setup!.spot : "Спот не указан").font(.headline)
                                Text(session.startedAt, format: .dateTime.day().month().year())
                                Text((session.wind.map { $0.source + " · " + $0.title } ?? "Ветер не указан") +
                                     " · " + metric(RiderTotals([session]).height, unit: "м")).font(.caption)
                            }
                        }
                    }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Райдер")
        .scrollContentBackground(.hidden).background(RiderTheme.canvas)
        .onChange(of: publicPreview, initial: true) { _, on in
            if on && RiderCommunity.endpoint != nil { perform("riders") }
        }
        .task(id: picked) {
            guard let picked else { return }
            guard let data = try? await picked.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320
                  ] as CFDictionary), let jpg = UIImage(cgImage: thumb).jpegData(compressionQuality: 0.65),
                  jpg.count <= 96_000, !Task.isCancelled else { return }
            photo = jpg
        }
    }

    private func perform(_ path: String, method: String = "GET", payload: RiderPublication? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { community = try await RiderCommunity.request(path, method: method, payload: payload); message = nil }
            catch { message = "Нет подтверждения от сервера. Проверьте связь и обновите данные." }
        }
    }
}
