import SwiftUI
import PhotosUI
import ImageIO
import Security

enum RiderDestination: Hashable { case statistics, session(UUID) }

private struct RiderPublication: Codable {
    let name: String
    let username: String?
    let bio: String?
    let totals: RiderTotals
    let avatar: Data?
    var publicProfile: Bool? = nil
    var statsPublic: Bool? = nil
    var secrets: [RiderMission]? = nil
}

fileprivate struct RemoteRider: Decodable, Identifiable {
    let id: String
    let profile: RiderPublication
    let followers: Int
    let following: Bool
    let followingCount: Int?
}

private struct RiderPublicPage: Decodable {
    let rider: RemoteRider
    let posts: [RiderFeedEntry]
    let points: Int?
    let distance: Double?
    let mine: Bool
}

fileprivate struct CommunityState: Decodable {
    let mine: RemoteRider?
    let riders: [RemoteRider]
}

struct RiderStatisticsUpdate: Encodable, Equatable {
    let year: Int
    let rides: [RiderSeasonProgress.Ride]
    let totals: RiderTotals
    let records: [RiderJumpScore]
    let secrets: [String]

    init(_ history: [SessionSummary], at now: Date) {
        let progress = RiderSeasonProgress(history, at: now)
        year = progress.year
        rides = progress.rides
        totals = RiderTotals(history)
        secrets = RiderMission.earned(in: history).map(\.rawValue).sorted()
        records = RiderJumpScore.records(in: history).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// A test IPA can pin its LAN server without installing a root CA on the iPhone.
private final class RiderLANTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    let root: Data
    let serverCertificate: Data

    init(origin: URL, root: Data, serverCertificate: Data) {
        self.origin = origin
        self.root = root
        self.serverCertificate = serverCertificate
    }

    func matches(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == origin.host && url.port == origin.port &&
            url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == origin.host, space.port == (origin.port ?? 443),
              let trust = space.serverTrust,
              let rootCertificate = SecCertificateCreateWithData(nil, root as CFData),
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, space.host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == serverCertificate else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        matches(request.url) ? request : nil
    }
}

enum RiderCommunity {
    private static let lanTrust: RiderLANTrust? = {
        guard let address = endpoint, let host = address.host,
              let root = Bundle.main.object(forInfoDictionaryKey: "RiderLANRootCertificate") as? Data,
              let certificate = Bundle.main.object(forInfoDictionaryKey: "RiderLANServerCertificate") as? Data else { return nil }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets.map(String.init).joined(separator: ".") == host else { return nil }
        let local = octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
        guard local else { return nil }
        return RiderLANTrust(origin: address, root: root, serverCertificate: certificate)
    }()

    static var usesLANTrust: Bool { lanTrust != nil }

    private static let networkSession: URLSession = {
        guard let lanTrust else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: lanTrust, delegateQueue: nil)
    }()

    static func localPhoto(_ url: URL) async -> Data? {
        guard lanTrust?.matches(url) == true,
              let (data, response) = try? await networkSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 390_000 else { return nil }
        return data
    }

    private struct Health: Decodable { let status: String }
    static func checkHealth() async throws -> Bool {
        let result: Health = try await decode("health")
        return result.status == "ready"
    }

    struct SeasonCredit: Decodable, Equatable {
        let year: Int
        let followers: Int
        let statsPublic: Bool?
    }

    private struct StatisticsRequest: Encodable {
        let update: RiderStatisticsUpdate
        let generatedAt = Date().timeIntervalSince1970
    }

    static func statisticsCredit() async throws -> SeasonCredit {
        try await decode("statistics")
    }

    static func syncStatistics(_ update: RiderStatisticsUpdate) async throws -> SeasonCredit {
        let request = StatisticsRequest(update: update)
        return try await decode("statistics", method: "PUT", body: JSONEncoder().encode(request))
    }

    static var endpoint: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RiderProfileServer") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    fileprivate static func request(_ path: String, method: String = "GET", payload: RiderPublication? = nil) async throws -> CommunityState {
        let body = try payload.map { try JSONEncoder().encode($0) }
        let data = try await requestData(path, method: method, body: body)
        return try JSONDecoder().decode(CommunityState.self, from: data)
    }

    private struct RoutePoint: Encodable {
        let latitude: Double
        let longitude: Double
    }

    private struct RouteMatrixRequest: Encodable {
        let origin: RoutePoint
        let destinations: [RoutePoint]
    }

    private struct RouteMatrixResponse: Decodable {
        let seconds: [Double?]
    }

    static func routeDurations(latitude: Double, longitude: Double, to spots: [RiderSpot]) async throws -> [Double?] {
        let query = RouteMatrixRequest(
            origin: RoutePoint(latitude: latitude, longitude: longitude),
            destinations: spots.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        )
        let data = try await requestData("route-eta", method: "POST", body: JSONEncoder().encode(query))
        let result = try JSONDecoder().decode(RouteMatrixResponse.self, from: data).seconds
        guard result.count == spots.count else { throw URLError(.cannotParseResponse) }
        return result
    }

    static func publishPost(_ post: RiderPost) async throws {
        let path = "posts/" + post.id.uuidString.lowercased()
        _ = try await requestData(path, method: "PUT", body: JSONEncoder().encode(post))
    }

    static func deletePost(_ id: UUID) async throws {
        _ = try await requestData("posts/" + id.uuidString.lowercased(), method: "DELETE", body: nil)
    }

    static func feed(recommended: Bool) async throws -> [RiderFeedEntry] {
        let path = recommended ? "feed/recommended" : "feed/following"
        let data = try await requestData(path, method: "GET", body: nil)
        return try JSONDecoder().decode([RiderFeedEntry].self, from: data)
    }

    static func tops(_ filter: RiderTopFilter) async throws -> [RiderTopEntry] {
        let data = try await requestData("tops", method: "POST", body: JSONEncoder().encode(filter))
        return try JSONDecoder().decode([RiderTopEntry].self, from: data)
    }

    static func comments(for post: UUID) async throws -> [RiderComment] {
        let data = try await requestData(commentPath(post), method: "GET", body: nil)
        return try JSONDecoder().decode([RiderComment].self, from: data)
    }

    static func submitComment(_ text: String, id: UUID, for post: UUID) async throws -> [RiderComment] {
        let data = try await requestData(commentPath(post, id), method: "PUT", body: JSONEncoder().encode(["text": text]))
        return try JSONDecoder().decode([RiderComment].self, from: data)
    }

    static func deleteComment(_ id: UUID, for post: UUID) async throws -> [RiderComment] {
        let data = try await requestData(commentPath(post, id), method: "DELETE", body: nil)
        return try JSONDecoder().decode([RiderComment].self, from: data)
    }

    private static func commentPath(_ post: UUID, _ id: UUID? = nil) -> String {
        let path = "posts/\(post.uuidString.lowercased())/comments"
        return id.map { path + "/" + $0.uuidString.lowercased() } ?? path
    }

    static func follow(_ user: String, enabled: Bool) async throws {
        _ = try await requestData("follow/" + user, method: enabled ? "PUT" : "DELETE", body: nil)
    }

    static func reaction(for post: UUID, enabled: Bool) async throws -> RiderReaction {
        try await decode("posts/\(post.uuidString.lowercased())/shaka", method: enabled ? "PUT" : "DELETE")
    }

    static func postDetails(_ id: UUID) async throws -> RiderFeedEntry {
        try await decode("posts/\(id.uuidString.lowercased())/details")
    }

    static func myReposts() async throws -> [RiderFeedEntry] { try await decode("feed/my-reposts") }

    static func repost(_ post: UUID, enabled: Bool) async throws {
        let data = enabled ? try JSONEncoder().encode(["id": UUID()]) : nil
        _ = try await requestData("posts/\(post.uuidString.lowercased())/repost", method: enabled ? "PUT" : "DELETE", body: data)
    }

    static func activity() async throws -> [RiderActivity] { try await decode("activity") }

    static func conversations() async throws -> [RiderPerson] { try await decode("messages") }

    static func recipients() async throws -> [RiderPerson] {
        try await request("riders").riders.map { rider in
            RiderPerson(id: rider.id, name: rider.profile.name, username: rider.profile.username, avatar: rider.profile.avatar)
        }
    }

    static func messages(with peer: String) async throws -> [RiderMessage] {
        try await decode("messages/" + peer)
    }

    private struct MessageBody: Encodable {
        let text: String
        let postID: UUID?
    }

    static func sendMessage(to peer: String, id: UUID, text: String, post: UUID?) async throws -> [RiderMessage] {
        let body = try JSONEncoder().encode(MessageBody(text: text, postID: post))
        return try await decode("messages/\(peer)/\(id.uuidString.lowercased())", method: "PUT", body: body)
    }

    static func decode<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await requestData(path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum Rejection: Error { case conflict, forbidden }

    private static func requestData(_ path: String, method: String, body: Data?) async throws -> Data {
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
            let created = UUID().uuidString + UUID().uuidString
            var item = query
            item[kSecValueData as String] = Data(created.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecSuccess {
                token = created
            } else if added == errSecDuplicateItem,
                      SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
                      let data = result as? Data, let saved = String(data: data, encoding: .utf8) {
                token = saved
            } else {
                throw URLError(.userAuthenticationRequired)
            }
        }
        var req = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await networkSession.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        if statusCode == 409 { throw Rejection.conflict }
        if statusCode == 403 { throw Rejection.forbidden }
        guard statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

struct RiderProfileView: View {
    @EnvironmentObject private var social: RiderSocialStore
    @ObservedObject var recorder: SessionRecorder
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.username") private var username = ""
    @AppStorage("rider.profileBio") private var bio = ""
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @State private var picked: PhotosPickerItem?
    @State private var editing = false
    @State private var draftUsername = ""
    @State private var showingAchievements = false
    @State private var composing = false
    @State private var mine: RemoteRider?
    @State private var loadingProfile = true
    @State private var savingProfile = false
    @State private var profileError: String?
    @State private var showingRanks = false
    @State private var lanServerStatus: String?
    @State private var checkingLANServer = false

    private var cleanedUsername: String {
        draftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^@", with: "", options: .regularExpression).lowercased()
    }

    private var usernameValid: Bool {
        cleanedUsername.isEmpty || cleanedUsername.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil
    }

    var body: some View {
        let totals = RiderTotals(recorder.history)
        let badges = RiderAchievement.milestones(totals, followers: mine?.followers ?? 0)
        let secrets = RiderMission.firstCompletions(in: recorder.history)
        return ScrollView {
            VStack(spacing: 18) {
                profile
                if RiderCommunity.endpoint != nil { privacyControls }
                if RiderCommunity.usesLANTrust { lanServerCheck }
                TimelineView(.everyMinute) { context in
                    Button { showingRanks = true } label: {
                        RiderRankCard(progress: social.progress(recorder.history, at: max(context.date, Date())))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Открыть шкалу рангов")
                }
                NavigationLink(value: RiderDestination.statistics) {
                    shortcut("Личная статистика", subtitle: "Сессии, маршруты и комплекты", icon: "chart.bar.xaxis")
                }
                .buttonStyle(.plain)
                records(totals)
                compactStats(timeOnWater: totals.timeOnWater, unlocked: badges.filter(\.unlocked).count,
                             total: badges.count)
                posts
            }
            .padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { RiderNotificationsView() } label: {
                    Label("Уведомления", systemImage: "bell").labelStyle(.iconOnly)
                }
                NavigationLink { RiderInboxView() } label: {
                    Label("Сообщения", systemImage: "paperplane").labelStyle(.iconOnly)
                }
            }
        }
        .task { await social.refreshReposts() }
        .sheet(isPresented: $composing) {
            RiderPostComposer(spots: recorder.spots, presets: recorder.gearPresets)
        }
        .sheet(isPresented: $showingRanks) {
            NavigationStack {
                List {
                    let progress = social.progress(recorder.history, at: Date())
                    Section {
                        ForEach(RiderRank.allCases) { rank in
                            Label {
                                Text("Ранг \(rank.rawValue)")
                            } icon: {
                                RiderRankBadge(rank: rank, size: 30)
                            }
                            .badge(rank.threshold.formatted() + " ПТС")
                        }
                    } footer: {
                        Text("1 ПТС за минуту завершённой каталки и 5 ПТС за засчитанный прыжок от 2 м. За одну сессию учитываются до 8 часов и 100 прыжков. После S очки продолжают накапливаться. Новый сезон начинается 1 января по Москве.")
                    }
                    Section("Ачивки сезона · \(progress.achievementPoints.formatted()) ПТС") {
                        ForEach(progress.achievements) { award in
                            Label(award.title, systemImage: award.unlocked ? "checkmark.seal.fill" : "lock")
                                .badge("+\(award.seasonBonus) ПТС")
                                .accessibilityValue(award.unlocked ? "Получена" : award.goal)
                        }
                    }
                }
                .navigationTitle("Ранги Rider")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingRanks = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingAchievements) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        achievements(badges)
                        RiderSecretAchievements(completed: secrets)
                    }.padding(16)
                }
                    .background(RiderTheme.canvas.ignoresSafeArea())
                    .navigationTitle("Ачивки")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingAchievements = false } }
                    }
            }
        }
        .task { await loadProfile() }
        .refreshable { await loadProfile() }
        .onChange(of: social.follows) { _, _ in Task { await loadProfile() } }
        .sheet(isPresented: $editing) { profileEditor }
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
            if let mine, !savingProfile {
                await saveProfile(publicProfile: mine.profile.publicProfile ?? true,
                                  statsPublic: mine.profile.statsPublic ?? true)
            }
        }
    }

    private var lanServerCheck: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Домашний сервер Rider", systemImage: "network").font(.subheadline.bold())
            if let lanServerStatus { Text(lanServerStatus).font(.caption).foregroundStyle(.secondary) }
            Button(checkingLANServer ? "Проверяем…" : "Проверить сервер") {
                checkingLANServer = true
                Task {
                    defer { checkingLANServer = false }
                    do { lanServerStatus = try await RiderCommunity.checkHealth() ? "Сервер отвечает" : "Сервер пока не готов" }
                    catch { lanServerStatus = "Нет связи. Проверь Wi-Fi, доступ к локальной сети и запуск сервера на ПК." }
                }
            }
            .buttonStyle(.bordered).disabled(checkingLANServer)
        }
        .lagoonCard()
    }

    private var profileEditor: some View {
        NavigationStack {
            Form {
                TextField("Имя", text: $name)
                    .onChange(of: name) { _, value in if value.count > 50 { name = String(value.prefix(50)) } }
                Section {
                    TextField("@юзернейм", text: $draftUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("3–24 строчные латинские буквы, цифры или _.")
                }
                TextField("О себе", text: $bio, axis: .vertical)
                    .lineLimit(3...5)
                    .onChange(of: bio) { _, value in if value.count > 160 { bio = String(value.prefix(160)) } }
                if let profileError {
                    Text(profileError).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        if let mine {
                            Task {
                                let saved = await saveProfile(publicProfile: mine.profile.publicProfile ?? true,
                                                              statsPublic: mine.profile.statsPublic ?? true,
                                                              handle: cleanedUsername)
                                if saved { editing = false }
                            }
                        } else {
                            username = cleanedUsername
                            editing = false
                        }
                    }.disabled(!usernameValid || savingProfile)
                }
            }
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 15) {
                PhotosPicker(selection: $picked, matching: .images) {
                    RiderAvatar(photo: photo, size: 68)
                        .overlay { Circle().strokeBorder(RiderTheme.foam.opacity(0.8), lineWidth: 2) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Выбрать фото райдера")
                .disabled(savingProfile)
                VStack(alignment: .leading, spacing: 4) {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(title.isEmpty ? "Райдер" : title).font(.title2.bold())
                    if !username.isEmpty {
                        Text("@" + username).font(.subheadline).foregroundStyle(RiderTheme.foam)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    draftUsername = username
                    profileError = nil
                    editing = true
                } label: {
                    Image(systemName: "pencil").font(.headline).padding(10)
                        .background(.white.opacity(0.17), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Изменить профиль")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { followCounts }
                VStack(alignment: .leading, spacing: 4) { followCounts }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(RiderTheme.foam)
            if !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var followCounts: some View {
        if RiderCommunity.endpoint != nil {
            RiderFollowCount(id: "me", kind: .followers, count: mine?.followers ?? 0)
            RiderFollowCount(id: "me", kind: .following, count: mine?.followingCount ?? 0)
        } else {
            Text("Подписчики · 0")
            Text("Подписан · 0")
        }
    }

    private var privacyControls: some View {
        let visible = mine.map { $0.profile.publicProfile ?? true } ?? false
        let statsVisible = mine.map { $0.profile.statsPublic ?? true } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            Toggle("Публичный профиль", isOn: Binding(get: { visible }, set: { updateVisibility(profile: $0) }))
            Divider()
            Toggle("Публичная статистика", isOn: Binding(get: { statsVisible }, set: { updateVisibility(stats: $0) }))
            if statsVisible && !visible {
                Text("Статистика появится, когда откроешь профиль.").font(.footnote).foregroundStyle(.secondary)
            }
            if loadingProfile || savingProfile { ProgressView().controlSize(.small) }
            if let profileError {
                Text(profileError).font(.footnote).foregroundStyle(.secondary)
                if loadingProfile { Button("Повторить") { Task { await loadProfile() } } }
            }
        }
        .tint(Color.green)
        .disabled(savingProfile)
        .lagoonCard()
    }

    @MainActor private func loadProfile() async {
        guard RiderCommunity.endpoint != nil, !savingProfile else { return }
        do {
            let account = try await RiderCommunity.request("me").mine
            guard !Task.isCancelled, !savingProfile else { return }
            mine = account
            if let handle = account?.profile.username { username = handle }
            profileError = nil
            loadingProfile = false
        } catch {
            if !Task.isCancelled { profileError = "Не удалось загрузить профиль. Проверь подключение к Rider." }
        }
    }

    private func updateVisibility(profile: Bool? = nil, stats: Bool? = nil) {
        guard !savingProfile else { return }
        Task {
            if loadingProfile {
                await loadProfile()
                guard !loadingProfile else { return }
            }
            guard mine != nil else {
                await saveProfile(publicProfile: profile ?? false, statsPublic: stats ?? false)
                return
            }
            savingProfile = true
            profileError = nil
            defer { savingProfile = false }
            let flags = ["publicProfile": profile, "statsPublic": stats].compactMapValues { $0 }
            do {
                let result: CommunityState = try await RiderCommunity.decode(
                    "me", method: "PATCH", body: JSONEncoder().encode(flags))
                mine = result.mine
                social.statisticsRefresh += 1
                await social.refreshReposts()
            } catch {
                profileError = "Не удалось изменить видимость. Проверь подключение к Rider."
            }
        }
    }

    @discardableResult
    @MainActor private func saveProfile(publicProfile: Bool, statsPublic: Bool, handle: String? = nil) async -> Bool {
        guard !savingProfile else { return false }
        savingProfile = true
        profileError = nil
        defer { savingProfile = false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = handle ?? username
        let payload = RiderPublication(name: title.isEmpty ? "Райдер" : title, username: tag.isEmpty ? nil : tag,
                                       bio: bio, totals: RiderTotals([]), avatar: photo.isEmpty ? nil : photo,
                                       publicProfile: publicProfile, statsPublic: statsPublic)
        do {
            let result = try await RiderCommunity.request("me", method: "PUT", payload: payload)
            mine = result.mine
            username = result.mine?.profile.username ?? tag
            social.statisticsRefresh += 1
            return true
        } catch RiderCommunity.Rejection.conflict {
            profileError = "Этот юзернейм уже занят. Выбери другой."
        } catch {
            profileError = "Не удалось сохранить профиль. Проверь подключение к Rider."
        }
        return false
    }

    private struct ProfilePublication: Identifiable {
        let post: RiderPost
        var repost: RiderFeedEntry?
        var id: UUID { post.id }
    }

    private var posts: some View {
        var publications = social.posts.map { ProfilePublication(post: $0) }
        publications.append(contentsOf: social.reposts.map { ProfilePublication(post: $0.post, repost: $0) })
        publications.sort { $0.post.createdAt > $1.post.createdAt }
        return LazyVStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Посты").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { composing = true } label: {
                    Label("Добавить пост", systemImage: "plus").font(.subheadline.weight(.semibold))
                }.buttonStyle(.bordered)
            }
            if publications.isEmpty {
                Text("Здесь будут твои фото с каталок.").font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(publications) { publication in
                    NavigationLink {
                        let entry = publication.repost
                        RiderPostDetail(original: publication.post, author: entry?.author ?? name,
                                        username: entry == nil ? username : entry?.username,
                                        avatar: entry == nil ? photo : entry?.avatar,
                                        editable: entry == nil, entry: entry)
                    } label: {
                        RiderPostSquare(post: publication.post)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func shortcut(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(RiderTheme.accent)
                .frame(width: 38, height: 38)
                .background(RiderTheme.canvas, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .lagoonCard()
        .contentShape(Rectangle())
    }

    private func records(_ totals: RiderTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Рекорды").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .leading)], spacing: 10) {
                record("Топ прыжок", value: metric(totals.height, unit: "м"), icon: "arrow.up.right")
                record("Топ завис", value: metric(totals.airtime, unit: "с"), icon: "timer")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactStats(timeOnWater: String, unlocked: Int, total: Int) -> some View {
        VStack(spacing: 0) {
            summaryRow("Часы на воде", value: timeOnWater, icon: "water.waves")
                .accessibilityElement(children: .combine)
            Divider()
            Button { showingAchievements = true } label: {
                summaryRow("Ачивки", value: "\(unlocked) из \(total)", icon: "medal", opensDetails: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ачивки")
            .accessibilityValue("\(unlocked) из \(total)")
        }
        .padding(.horizontal, 12)
        .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func summaryRow(_ title: String, value: String, icon: String, opensDetails: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(RiderTheme.accent)
                .frame(width: 21).accessibilityHidden(true)
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 6)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
            if opensDetails {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func record(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.subheadline.bold()).foregroundStyle(RiderTheme.accent).accessibilityHidden(true)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .lagoonCard()
        .accessibilityElement(children: .combine)
    }

    private func achievements(_ badges: [RiderAchievement]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach(badges) { badge in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: badge.icon)
                                .foregroundStyle(badge.unlocked ? RiderTheme.accent : Color.secondary)
                            Spacer()
                            Image(systemName: badge.unlocked ? "checkmark.seal.fill" : "lock")
                                .foregroundStyle(badge.unlocked ? RiderTheme.accent : Color.secondary)
                        }
                        .font(.title3.weight(.semibold))
                        .accessibilityHidden(true)
                        Text(badge.title).font(.subheadline.bold())
                        Text(badge.goal).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: badge.progress).tint(RiderTheme.accent)
                            .accessibilityLabel(badge.unlocked ? "Получена" : "Прогресс")
                    }
                    .lagoonCard()
                }
            }
        }
    }
}

private extension RiderRank {
    var tint: Color {
        switch self {
        case .e: return RiderTheme.accent
        case .d: return Color(red: 0.25, green: 0.82, blue: 0.69)
        case .c: return Color(red: 0.42, green: 0.70, blue: 1)
        case .b: return Color(red: 0.72, green: 0.62, blue: 1)
        case .a: return Color(red: 1, green: 0.69, blue: 0.40)
        case .s: return Color(red: 1, green: 0.88, blue: 0.48)
        }
    }
}

struct RiderRankBadge: View {
    let rank: RiderRank
    let size: CGFloat

    var body: some View {
        Text(rank.rawValue)
            .font(.system(size: size * 0.53, weight: .black, design: .monospaced))
            .foregroundStyle(rank.tint)
            .frame(width: size, height: size)
            .background(Color(red: 0.05, green: 0.13, blue: 0.19), in: RoundedRectangle(cornerRadius: size * 0.26))
            .overlay { RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(rank.tint.opacity(0.65)) }
            .accessibilityLabel("Ранг \(rank.rawValue)")
    }
}

struct RiderRankCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: RiderSeasonProgress

    var body: some View {
        let color = progress.rank.tint
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RiderRankBadge(rank: progress.rank, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(progress.points.formatted()) ПТС")
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("Сезон \(String(progress.year))").font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 4)
                if let next = progress.rank.next {
                    Text("До \(next.rawValue) · \((next.threshold - progress.points).formatted())")
                        .font(.caption.bold().monospacedDigit()).foregroundStyle(color)
                } else {
                    Text("Высший ранг").font(.caption.bold()).foregroundStyle(color)
                }
            }
            if progress.rank == .s {
                Label("ПТС копятся до конца сезона", systemImage: "infinity")
                    .font(.caption.weight(.semibold)).foregroundStyle(color)
            } else {
                ProgressView(value: progress.fraction)
                    .tint(color)
                    .accessibilityLabel("Прогресс ранга")
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.13, blue: 0.19),
                                              Color(red: 0.10, green: 0.25, blue: 0.30)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.45)).allowsHitTesting(false) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: progress.points)
        .accessibilityElement(children: .combine)
    }
}

struct RiderRankPromotion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let previous: RiderRank
    let current: RiderRank
    let dismiss: () -> Void
    @State private var revealed = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    ForEach(0..<3) { index in
                        Circle().strokeBorder(current.tint.opacity(0.35 - Double(index) * 0.09))
                            .frame(width: CGFloat(126 + index * 33), height: CGFloat(126 + index * 33))
                    }
                    .scaleEffect(reduceMotion || revealed ? 1 : 0.38)
                    RiderRankBadge(rank: current, size: 94)
                        .scaleEffect(reduceMotion || revealed ? 1 : 0.6)
                        .rotationEffect(.degrees(reduceMotion || revealed ? 0 : -12))
                }
                .frame(height: 194)
                Text("Ранг повышен").font(.title.bold())
                Text("\(previous.rawValue) → \(current.rawValue)")
                    .font(.title2.monospaced().bold()).foregroundStyle(current.tint)
                Button("Продолжить", action: dismiss)
                    .buttonStyle(.borderedProminent).tint(current.tint)
                    .foregroundStyle(Color(red: 0.05, green: 0.13, blue: 0.19))
            }
            .foregroundStyle(.white)
            .padding(28)
            .background(Color(red: 0.05, green: 0.13, blue: 0.19), in: RoundedRectangle(cornerRadius: 28))
        }
        .accessibilityAddTraits(.isModal)
        .task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.63, dampingFraction: 0.64)) { revealed = true }
        }
        .sensoryFeedback(.success, trigger: revealed)
    }
}

struct RiderAvatar: View {
    let photo: Data
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(RiderTheme.accent)
                    .background(RiderTheme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private enum RiderFollowKind: String {
    case followers, following

    var title: String { self == .followers ? "Подписчики" : "Подписки" }
    var label: String { self == .followers ? "Подписчики" : "Подписан" }
}

private struct RiderFollowCount: View {
    let id: String
    let kind: RiderFollowKind
    let count: Int

    var body: some View {
        NavigationLink {
            RiderFollowList(id: id, kind: kind)
        } label: {
            Text("\(kind.label) · \(count)").frame(minHeight: 36)
        }
        .buttonStyle(.plain)
    }
}

private struct RiderFollowList: View {
    let id: String
    let kind: RiderFollowKind
    @State private var people: [RiderPerson]?
    @State private var failed = false
    @State private var search = ""

    var body: some View {
        List {
            if let people {
                if people.isEmpty {
                    ContentUnavailableView(kind == .followers ? "Пока нет подписчиков" : "Пока нет подписок",
                                           systemImage: "person.2")
                }
                ForEach(people.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.handle.localizedCaseInsensitiveContains(search) }) { person in
                    NavigationLink {
                        RiderPublicProfileView(id: person.id)
                    } label: {
                        RiderPostHeader(author: person.name, username: person.username, avatar: person.avatar)
                            .padding(.vertical, 4)
                    }
                }
            } else if failed {
                Button("Повторить загрузку") { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Имя или @юзернейм")
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas)
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        do {
            let result: [RiderPerson] = try await RiderCommunity.decode("riders/\(id)/\(kind.rawValue)")
            if !Task.isCancelled { people = result; failed = false }
        } catch {
            if !Task.isCancelled { people = nil; failed = true }
        }
    }
}

struct RiderPublicProfileView: View {
    @EnvironmentObject private var social: RiderSocialStore
    let id: String
    @State private var page: RiderPublicPage?
    @State private var unavailable = false
    @State private var busy = false
    @State private var actionError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let page {
                    profile(page.rider, isMine: page.mine)
                    if let points = page.points { statistics(page, points: points) }
                    publications(page.posts)
                } else if unavailable {
                    ContentUnavailableView("Профиль недоступен", systemImage: "person.crop.circle",
                                           description: Text("Профиль закрыт или связь с сервером потеряна."))
                    Button("Повторить загрузку") { Task { await load() } }
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }.padding(16)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(page?.rider.profile.username.map { "@" + $0 } ?? "Райдер")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
        .refreshable { await load() }
    }

    private func profile(_ rider: RemoteRider, isMine: Bool) -> some View {
        let user = rider.profile
        let following = social.follows[rider.id] ?? rider.following
        return VStack(alignment: .leading, spacing: 12) {
            RiderPostHeader(author: user.name, username: user.username, avatar: user.avatar)
            if let bio = user.bio { Text(bio).font(.subheadline) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { followCounts(rider) }
                VStack(alignment: .leading, spacing: 0) { followCounts(rider) }
            }.font(.subheadline.weight(.medium))
            if !isMine {
                HStack {
                    Button(following ? "Отписаться" : "Подписаться") {
                        busy = true
                        actionError = false
                        Task {
                            defer { busy = false }
                            do {
                                try await RiderCommunity.follow(rider.id, enabled: !following)
                                social.follows[rider.id] = !following
                                await load()
                            } catch { actionError = true }
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    NavigationLink {
                        RiderThreadView(peer: RiderPerson(id: rider.id, name: user.name, username: user.username,
                                                         avatar: user.avatar))
                    } label: {
                        Label("Написать", systemImage: "paperplane")
                    }.buttonStyle(.bordered)
                }
                if actionError { Text("Не удалось изменить подписку.").font(.footnote).foregroundStyle(.secondary) }
            }
        }.lagoonCard()
    }

    @ViewBuilder private func followCounts(_ rider: RemoteRider) -> some View {
        RiderFollowCount(id: rider.id, kind: .followers, count: rider.followers)
        RiderFollowCount(id: rider.id, kind: .following, count: rider.followingCount ?? 0)
    }

    private func statistics(_ page: RiderPublicPage, points: Int) -> some View {
        let totals = page.rider.profile.totals
        let awards = RiderAchievement.milestones(totals, followers: page.rider.followers).filter(\.unlocked)
        let secrets = page.rider.profile.secrets ?? []
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                RiderRankBadge(rank: .forPoints(points), size: 31)
                Text("\(points.formatted()) ПТС").font(.headline)
                Spacer()
                Text("Ранг сезона").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("Топ прыжок", value: metric(totals.height, unit: "м"))
            LabeledContent("Топ завис", value: metric(totals.airtime, unit: "с"))
            LabeledContent("Топ дистанция", value: metric(page.distance, unit: "м"))
            LabeledContent("Часы на воде", value: totals.timeOnWater)
            DisclosureGroup("Ачивки · \(awards.count + secrets.count)") {
                VStack(alignment: .leading, spacing: 8) {
                    if awards.isEmpty && secrets.isEmpty {
                        Text("Пока нет открытых ачивок").foregroundStyle(.secondary)
                    }
                    ForEach(awards) { Label($0.title, systemImage: "checkmark.seal") }
                    ForEach(secrets) { Label($0.rule.title, systemImage: "sparkles") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }.font(.subheadline).lagoonCard()
    }

    private func publications(_ posts: [RiderFeedEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Посты").font(.title3.bold())
            if posts.isEmpty {
                Text("Пока нет публикаций").font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(posts) { entry in
                    NavigationLink {
                        RiderPostDetail(original: entry.post, author: entry.author, username: entry.username,
                                        avatar: entry.avatar, entry: entry)
                    } label: {
                        RiderPostSquare(post: entry.post)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.post.caption.isEmpty ? "Открыть пост" : entry.post.caption)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func load() async {
        do {
            let result: RiderPublicPage = try await RiderCommunity.decode("riders/" + id)
            if !Task.isCancelled { page = result; unavailable = false }
        } catch {
            if !Task.isCancelled { page = nil; unavailable = true }
        }
    }
}
