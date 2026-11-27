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
    var recordsPublic: Bool? = nil
    var birthday: String? = nil
    var showBirthday: Bool? = nil
    var premium: Bool? = nil
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
    let year: Int?
    let sessionRecords: [RiderPublicRide]?
    let rides: [RiderPublicRide]?
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
    let publicRides: [RiderPublicRide]

    init(_ history: [SessionSummary], at now: Date) {
        let progress = RiderSeasonProgress(history, at: now)
        year = progress.year
        rides = progress.rides
        totals = RiderTotals(history)
        publicRides = RiderPublicRide.summaries(in: history)
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
        configuration.timeoutIntervalForResource = 100
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

    struct Registration: Decodable {
        let required: Bool
        let verified: Bool?
        let name: String?
        let username: String?
        let profileID: String?
        let bio: String?
        let avatar: Data?
        let birthday: String?
        let showBirthday: Bool?
    }

    private struct RegistrationPayload: Encodable {
        let name: String
        let username: String
        let publicProfile: Bool
        let statsPublic: Bool
        let password: String
        let totals = RiderTotals([])
    }

    static func register(name: String, username: String, publicProfile: Bool, statsPublic: Bool,
                         password: String) async throws {
        let payload = RegistrationPayload(name: name, username: username, publicProfile: publicProfile,
                                          statsPublic: statsPublic, password: password)
        let _: CommunityState = try await decode("registration", method: "PUT", body: JSONEncoder().encode(payload))
    }

    static func unread() async throws -> RiderUnread {
        try await decode("unread")
    }

    static func readMessages(from peer: String, ids: [UUID]) async throws -> RiderUnread {
        try await decode("messages/" + peer + "/read", method: "PUT", body: JSONEncoder().encode(["messages": ids]))
    }

    static func readActivity(through sequence: Int) async throws -> RiderUnread {
        try await decode("activity/read", method: "PUT", body: JSONEncoder().encode(["sequence":sequence]))
    }

    static func storyMedia(_ id: UUID) async throws -> Data {
        try await requestData("stories/" + id.uuidString.lowercased() + "/media", method: "GET", body: nil, timeout: 60)
    }

    static func publishStory(_ post: RiderPost) async throws -> [RiderStory] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try await requestData("stories/" + post.id.uuidString.lowercased(), method: "PUT",
                                         body: encoder.encode(post), timeout: 90)
        return try JSONDecoder().decode([RiderStory].self, from: data)
    }

    static func statisticsCredit() async throws -> SeasonCredit {
        do {
            return try await decode("statistics")
        } catch Rejection.forbidden {
            _ = try await requestData("membership", method: "PUT", body: nil)
            return try await decode("statistics")
        }
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
        let data = try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return try encoder.encode(post)
        }.value
        _ = try await requestData(path, method: "PUT", body: data, timeout: post.isVideo ? 90 : 12)
    }

    static func video(for post: UUID) async throws -> Data {
        let data = try await requestData("posts/\(post.uuidString.lowercased())/video", method: "GET", body: nil, timeout: 60)
        guard data.count <= RiderPost.maxVideoBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    static func commentLikes(_ comment: UUID, for post: UUID, offset: Int) async throws -> RiderReaction {
        try await decode("posts/\(post.uuidString.lowercased())/comments/\(comment.uuidString.lowercased())/like/\(offset)")
    }

    static func shakas(for post: UUID, offset: Int) async throws -> RiderReaction {
        try await decode("posts/\(post.uuidString.lowercased())/shakas/\(offset)")
    }

    static func likeComment(_ id: UUID, for post: UUID, enabled: Bool) async throws -> [RiderComment] {
        try await decode(commentPath(post, id) + "/like", method: enabled ? "PUT" : "DELETE")
    }

    static func deletePost(_ id: UUID) async throws {
        _ = try await requestData("posts/" + id.uuidString.lowercased(), method: "DELETE", body: nil)
    }

    static func feed(recommended: Bool) async throws -> [RiderFeedEntry] {
        let path = recommended ? "feed/recommended" : "feed/following"
        let data = try await requestData(path, method: "GET", body: nil)
        return try JSONDecoder().decode([RiderFeedEntry].self, from: data)
    }

    static func tops(_ filter: RiderTopFilter) async throws -> RiderTopPage {
        let data = try await requestData("tops", method: "POST", body: JSONEncoder().encode(filter))
        return try JSONDecoder().decode(RiderTopPage.self, from: data)
    }

    static func comments(for post: UUID) async throws -> [RiderComment] {
        let data = try await requestData(commentPath(post), method: "GET", body: nil)
        return try JSONDecoder().decode([RiderComment].self, from: data)
    }

    static func submitComment(_ text: String, id: UUID, for post: UUID, replyTo: UUID?) async throws -> [RiderComment] {
        var body = ["text": text]
        body["replyTo"] = replyTo?.uuidString
        let data = try await requestData(commentPath(post, id), method: "PUT", body: JSONEncoder().encode(body))
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
        let attachment: RiderChatUpload?
    }

    static func attachment(for message: UUID, with peer: String) async throws -> Data {
        try await requestData("messages/\(peer)/\(message.uuidString.lowercased())/attachment", method: "GET", body: nil)
    }

    static func sendMessage(to peer: String, id: UUID, text: String, post: UUID?,
                            attachment: RiderChatUpload? = nil) async throws -> [RiderMessage] {
        let body = try JSONEncoder().encode(MessageBody(text: text, postID: post, attachment: attachment))
        let data = try await requestData("messages/\(peer)/\(id.uuidString.lowercased())", method: "PUT",
                                         body: body, timeout: attachment == nil ? 12 : 60)
        return try JSONDecoder().decode([RiderMessage].self, from: data)
    }

    static func decode<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await requestData(path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum Rejection: Error { case conflict, forbidden, notFound }

    private static func credentialQuery(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "RiderCommunity",
         kSecAttrAccount as String: endpoint.absoluteString]
    }

    static func clearDeviceCredential() throws {
        guard let endpoint else { return }
        let result = SecItemDelete(credentialQuery(endpoint) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    private static func requestData(_ path: String, method: String, body: Data?, timeout: TimeInterval = 12) async throws -> Data {
        guard let base = endpoint else { throw URLError(.unsupportedURL) }
        let query = credentialQuery(base)
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
        var req = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
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
        if statusCode == 404 && path.hasPrefix("sos/") { throw Rejection.notFound }
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
    @State private var publicationSection = RiderPublicationSection.gallery
    @State private var remotePublications: [RiderFeedEntry] = []
    @AppStorage("rider.appearance") private var appearance = RiderAppearance.lagoon
    @State private var draftUsername = ""
    @State private var draftName = ""
    @State private var draftBio = ""
    @State private var draftPhoto = Data()
    @State private var editorPicker: PhotosPickerItem?
    @AppStorage("rider.birthDay") private var birthDay = ""
    @AppStorage("rider.birthVisible") private var birthVisible = false
    @State private var draftBirth = Date()
    @State private var hasBirth = false
    @State private var visibleBirth = false
    private static let birthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.defaultDate = Date(timeIntervalSince1970: 951825600)
        f.dateFormat = "MM-dd"
        return f
    }()
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
            VStack(spacing: 9) {
                TimelineView(.everyMinute) { context in
                    profile(rank: social.progress(recorder.history, at: max(context.date, Date())).rank)
                }
                RiderProfileRecords(totals: totals,
                                    distance: RiderPublicRide.summaries(in: recorder.history).compactMap(\.distance).max(),
                                    locked: mine?.profile.recordsPublic == false)
                posts
            }
            .padding(12)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { RiderNotificationsView() } label: {
                    RiderBadgeIcon(icon: "bell", title: "Уведомления", count: social.unread.activity)
                }
                NavigationLink { RiderInboxView() } label: {
                    RiderBadgeIcon(icon: "paperplane", title: "Сообщения", count: social.unread.messages)
                }
            }
        }
        .task(id: social.posts.map { "\($0.id)-\($0.published == true)" }) {
            guard RiderCommunity.endpoint != nil else { return }
            if let page: RiderPublicPage = try? await RiderCommunity.decode("riders/me"), !Task.isCancelled {
                remotePublications = page.posts
            }
        }
        .sheet(isPresented: $composing) {
            RiderPostComposer(recorder: recorder, section: publicationSection)
        }
        .sheet(isPresented: $showingRanks) {
            NavigationStack {
                List {
                    let progress = social.progress(recorder.history, at: Date())
                    RiderRankCard(progress: progress)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    Section {
                        ForEach(RiderRank.allCases) { rank in
                            Label {
                                Text("Уровень \(rank.rawValue)")
                            } icon: {
                                RiderRankBadge(rank: rank, size: 30)
                            }
                            .badge(riderPoints(rank.threshold))
                        }
                    } footer: {
                        Text("1 балл за минуту завершённой каталки и 5 баллов за засчитанный прыжок от 2 м. За одну сессию учитываются до 8 часов и 100 прыжков. На уровне 5+ баллы продолжают накапливаться. Новый сезон начинается 1 января по Москве.")
                    }
                    Section("Достижения сезона · \(riderPoints(progress.achievementPoints))") {
                        ForEach(progress.achievements) { award in
                            Label(award.title, systemImage: award.unlocked ? "checkmark.seal.fill" : "lock")
                                .badge(riderPoints(award.seasonBonus, withPlus: true))
                                .accessibilityValue(award.unlocked ? "Получена" : award.goal)
                        }
                    }
                }
                .navigationTitle("Уровни Rider")
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
                        RiderAchievementsGrid(badges: badges)
                        RiderSecretAchievements(completed: secrets)
                    }.padding(16)
                }
                    .background(RiderTheme.canvas.ignoresSafeArea())
                    .navigationTitle("Достижения")
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
    }

    private var profileEditor: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $editorPicker, matching: .images) {
                        VStack(spacing: 8) {
                            RiderAvatar(photo: draftPhoto, size: 82)
                            Text("Изменить фотографию").font(.subheadline.weight(.semibold))
                        }.frame(maxWidth: .infinity)
                    }.listRowBackground(Color.clear)
                }
                Section {
                    VStack(alignment: .leading) {
                        Text("Никнейм").font(.caption).foregroundStyle(.secondary)
                        TextField("Как тебя называть", text: $draftName)
                            .onChange(of: draftName) { _, v in if v.count > 50 { draftName = String(v.prefix(50)) } }
                    }
                    VStack(alignment: .leading) {
                        Text("Уникальный юзернейм").font(.caption).foregroundStyle(.secondary)
                        TextField("@username", text: $draftUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading) {
                        Text("Описание профиля").font(.caption).foregroundStyle(.secondary)
                        TextField("О себе", text: $draftBio, axis: .vertical).lineLimit(2...4)
                            .onChange(of: draftBio) { _, v in if v.count > 160 { draftBio = String(v.prefix(160)) } }
                    }
                } footer: { Text("Юзернейм: 3–24 латинские буквы, цифры или _.") }
                Section {
                    DisclosureGroup {
                        Toggle("Указать день рождения", isOn: $hasBirth)
                        if hasBirth {
                            DatePicker("Дата", selection: $draftBirth, in: ...Date(), displayedComponents: .date)
                            Toggle("Показывать день и месяц", isOn: $visibleBirth)
                        }
                    } label: { Label("День рождения", systemImage: "birthday.cake") }
                    NavigationLink { RiderAccountAccessSettings(recorder: recorder) } label: { Label("Вход и восстановление", systemImage: "key") }
                    NavigationLink { RiderPhoneSettings() } label: { Label("Номер телефона", systemImage: "phone.fill") }
                }
                Section {
                    NavigationLink { RiderAlertSettings() } label: { Label("Уведомления и звуки", systemImage: "bell.badge.fill") }
                    NavigationLink { RiderAppearanceSettings() } label: { Label("Оформление", systemImage: "circle.lefthalf.filled") }
                    if RiderCommunity.endpoint != nil {
                        NavigationLink { Form { privacyControls }.navigationTitle("Конфиденциальность") } label: {
                            Label("Конфиденциальность", systemImage: "lock.fill")
                        }
                    }
                }
                if let profileError { Text(profileError).font(.footnote).foregroundStyle(.red) }
                if RiderCommunity.usesLANTrust {
                    Section("Домашний сервер") { lanServerCheck }
                }
            }
            .scrollContentBackground(.hidden)
            .background(appearance == .lagoon ? RiderTheme.canvas : Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: editorPicker) {
                guard let pick = editorPicker, let data = try? await pick.loadTransferable(type: Data.self),
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary),
                      let jpg = UIImage(cgImage: thumb).jpegData(compressionQuality: 0.65),
                      jpg.count <= 96000, !Task.isCancelled else { return }
                draftPhoto = jpg
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { editing = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Отмена").disabled(savingProfile)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if RiderCommunity.endpoint != nil {
                                guard await saveProfile(publicProfile: mine?.profile.publicProfile ?? false,
                                    statsPublic: mine?.profile.statsPublic ?? false,
                                    handle: cleanedUsername, fromEditor: true) else { return }
                            } else { username = cleanedUsername }
                            name = draftName; bio = draftBio; photo = draftPhoto
                            birthDay = hasBirth ? Self.birthFormat.string(from: draftBirth) : ""
                            birthVisible = hasBirth && visibleBirth
                            editing = false
                        }
                    } label: { Image(systemName: "checkmark.circle.fill").font(.title2) }
                    .accessibilityLabel("Сохранить профиль").disabled(!usernameValid || savingProfile || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.interactiveDismissDisabled(savingProfile)
        }
    }

    private func profile(rank: RiderRank) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                PhotosPicker(selection: $picked, matching: .images) {
                    RiderAvatar(photo: photo, size: 62)
                        .overlay { Circle().strokeBorder(RiderTheme.foam.opacity(0.8), lineWidth: 2) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Выбрать фото райдера")
                .disabled(savingProfile)
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                RiderProfileTitle(name: title.isEmpty ? "Райдер" : title, username: username, premium: mine?.profile.premium)
                HStack(spacing: 0) {
                    Button { showingRanks = true } label: {
                        RiderRankBadge(rank: rank, size: 32)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Уровень \(rank.rawValue)")
                    Button {
                        draftName = name; draftBio = bio; draftPhoto = photo; editorPicker = nil
                        let saved = mine?.profile.birthday ?? birthDay
                        hasBirth = !saved.isEmpty; draftBirth = Self.birthFormat.date(from: saved) ?? Date()
                        visibleBirth = mine?.profile.showBirthday ?? birthVisible
                        draftUsername = username
                        profileError = nil
                        editing = true
                    } label: {
                        RiderCompactAction(icon: "pencil")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Изменить профиль")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { followCounts }
                VStack(alignment: .leading, spacing: 4) { followCounts }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(RiderTheme.foam)
            if !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 0) {
                Label(RiderTotals(recorder.history).timeOnWater, systemImage: "water.waves")
                    .font(.caption.weight(.semibold)).foregroundStyle(RiderTheme.foam)
                Spacer(minLength: 4)
                Button { showingAchievements = true } label: { RiderCompactAction(icon: "medal") }
                    .accessibilityLabel("Достижения")
                NavigationLink(value: RiderDestination.statistics) {
                    RiderCompactAction(icon: "clock.arrow.circlepath")
                }.accessibilityLabel("История каталок")
                NavigationLink {
                    RiderAnalytics(title: "Личная статистика", rides: RiderPublicRide.summaries(in: recorder.history))
                } label: {
                    RiderCompactAction(icon: "chart.bar.xaxis")
                }.accessibilityLabel("Личная статистика")
            }.buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var followCounts: some View {
        if RiderCommunity.endpoint != nil {
            RiderFollowCount(id: "me", kind: .followers, count: mine?.followers ?? 0)
            RiderFollowCount(id: "me", kind: .following, count: mine?.followingCount ?? 0)
        } else {
            Text("Подписчики 0")
            Text("Подписки 0")
        }
    }

    private var privacyControls: some View {
        let visible = mine.map { $0.profile.publicProfile ?? true } ?? false
        let statsVisible = mine.map { $0.profile.statsPublic ?? true } ?? false
        let recordsVisible = mine?.profile.recordsPublic ?? true
        return Section("Видимость") {
            Toggle("Публичный профиль", isOn: Binding(get: { visible }, set: { updateVisibility(profile: $0) }))
            Toggle("Публичная статистика", isOn: Binding(get: { statsVisible }, set: { updateVisibility(stats: $0) }))
            Toggle("Публичные рекорды", isOn: Binding(get: { recordsVisible }, set: { updateVisibility(records: $0) }))
            Text("Открой статистику, чтобы показать графики по ветру, спотам и комплектам. Публичные рекорды показываются в профиле и дают участие в «Топах».")
                .font(.footnote).foregroundStyle(.secondary)
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
    }

    @MainActor private func loadProfile() async {
        guard RiderCommunity.endpoint != nil, !savingProfile else { return }
        do {
            let account = try await RiderCommunity.request("me").mine
            guard !Task.isCancelled, !savingProfile else { return }
            mine = account
            social.myPremium = account?.profile.premium
            if let handle = account?.profile.username { username = handle }
            profileError = nil
            loadingProfile = false
        } catch {
            if !Task.isCancelled { profileError = "Не удалось загрузить профиль. Проверь подключение к Rider." }
        }
    }

    private func updateVisibility(profile: Bool? = nil, stats: Bool? = nil, records: Bool? = nil) {
        guard !savingProfile else { return }
        Task {
            if loadingProfile {
                await loadProfile()
                guard !loadingProfile else { return }
            }
            guard mine != nil else {
                await saveProfile(publicProfile: profile ?? false, statsPublic: stats ?? false, recordsPublic: records)
                return
            }
            savingProfile = true
            profileError = nil
            defer { savingProfile = false }
            let flags = ["publicProfile": profile, "statsPublic": stats, "recordsPublic": records].compactMapValues { $0 }
            do {
                let result: CommunityState = try await RiderCommunity.decode(
                    "me", method: "PATCH", body: JSONEncoder().encode(flags))
                mine = result.mine
                social.statisticsRefresh += 1
                if records != nil { social.statisticsSynced += 1 }
                await social.refreshReposts()
            } catch {
                profileError = "Не удалось изменить видимость. Проверь подключение к Rider."
            }
        }
    }

    @discardableResult
    @MainActor private func saveProfile(publicProfile: Bool, statsPublic: Bool, recordsPublic: Bool? = nil,
                                        handle: String? = nil, fromEditor: Bool = false) async -> Bool {
        guard !savingProfile else { return false }
        savingProfile = true
        profileError = nil
        defer { savingProfile = false }
        let title = (fromEditor ? draftName : name).trimmingCharacters(in: .whitespacesAndNewlines)
        let image = fromEditor ? draftPhoto : photo
        let tag = handle ?? username
        var payload = RiderPublication(name: title.isEmpty ? "Райдер" : title, username: tag.isEmpty ? nil : tag,
                                       bio: fromEditor ? draftBio : bio, totals: RiderTotals([]), avatar: image.isEmpty ? nil : image,
                                       publicProfile: publicProfile, statsPublic: statsPublic, recordsPublic: recordsPublic)
        if fromEditor {
            payload.birthday = hasBirth ? Self.birthFormat.string(from: draftBirth) : ""
            payload.showBirthday = hasBirth && visibleBirth
        }
        do {
            let result = try await RiderCommunity.request("me", method: "PUT", payload: payload)
            mine = result.mine
            username = result.mine?.profile.username ?? tag
            social.statisticsRefresh += 1
            if recordsPublic != nil { social.statisticsSynced += 1 }
            return true
        } catch RiderCommunity.Rejection.conflict {
            profileError = "Этот юзернейм уже занят. Выбери другой."
        } catch {
            profileError = "Не удалось сохранить профиль. Проверь подключение к Rider."
        }
        return false
    }

    private var posts: some View {
        RiderProfilePublications(entries: remotePublications, isMine: true, name: name,
                                 username: username, avatar: photo, selection: $publicationSection,
                                 addPost: { composing = true })
    }

}

private struct RiderProfilePublications: View {
    struct Entry: Identifiable {
        let post: RiderPost
        let remote: RiderFeedEntry?
        var id: UUID { post.id }

        func resolved(using local: RiderPost?) -> RiderPost {
            guard var local else { return post }
            if let remote {
                local.published = remote.post.published
                local.hasVideo = remote.post.hasVideo
                local.hasCover = remote.post.hasCover
            }
            return local
        }

        static func merged(remote: [RiderFeedEntry], local: [RiderPost]) -> [Self] {
            var collected: [UUID: Self] = [:]
            for entry in remote { collected[entry.id] = Self(post: entry.post, remote: entry) }
            for post in local {
                let shared = collected[post.id]
                collected[post.id] = Self(post: shared?.resolved(using: post) ?? post, remote: shared?.remote)
            }
            return collected.values.sorted {
                $0.post.createdAt == $1.post.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.post.createdAt > $1.post.createdAt
            }
        }
    }

    @EnvironmentObject private var social: RiderSocialStore
    let entries: [RiderFeedEntry]
    let isMine: Bool
    let name: String
    let username: String?
    let avatar: Data?
    @Binding var selection: RiderPublicationSection
    var addPost: (() -> Void)?
    @State private var gallery: GallerySelection?
    @State private var conversation: RiderPerson?

    private struct GallerySelection: Hashable {
        let id = UUID()
        let initial: UUID
        let posts: [Entry]

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        let posts = Entry.merged(remote: entries.filter { !social.deletedPosts.contains($0.id) },
                                 local: isMine ? social.posts : []).filter { $0.post.publicationSection == selection }
        VStack(alignment: .leading, spacing: 8) {
            publicationControls
            if posts.isEmpty {
                Text(selection == .gallery ? "Пока нет фото и видео." : "Стена пока пуста.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if selection == .gallery {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(posts) { item in
                        Button {
                            gallery = GallerySelection(initial: item.id, posts: posts)
                        } label: {
                            RiderPostSquare(post: item.post)
                                .contentShape(.interaction, Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.post.deletionDescription)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(posts) { item in
                        RiderFeedCard(post: item.post, author: item.remote?.author ?? name, username: item.remote?.username ?? username,
                                      avatar: item.remote?.avatar ?? avatar, editable: isMine && item.post.sourceID == nil, entry: item.remote,
                                      onConversation: { conversation = $0 })
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationDestination(item: $conversation) { RiderThreadView(peer: $0) }
        .navigationDestination(item: $gallery) { selection in
            RiderProfileGallery(items: selection.posts, initial: selection.initial, isMine: isMine,
                                name: name, username: username, avatar: avatar)
                .id(selection.id)
        }
    }

    @ViewBuilder private var publicationControls: some View {
        if let addPost {
            HStack(spacing: 5) {
                publicationTab(.gallery)
                Button(action: addPost) {
                    Image(systemName: "plus.app.fill")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(RiderTheme.accent)
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Добавить пост")
                .accessibilityHint(selection.title)
                publicationTab(.journal)
            }
            .padding(4)
            .background(RiderTheme.border, in: RoundedRectangle(cornerRadius: 13))
        } else {
            RiderSections(options: RiderPublicationSection.allCases, selection: $selection) { section in
                Image(systemName: section.icon).accessibilityLabel(section.title)
            }
        }
    }

    private func publicationTab(_ section: RiderPublicationSection) -> some View {
        Button {
            selection = section
        } label: {
            Image(systemName: section.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selection == section ? RiderTheme.accent : .secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selection == section ? RiderTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }
}

private struct RiderProfileGallery: View {
    @EnvironmentObject private var social: RiderSocialStore
    let items: [RiderProfilePublications.Entry]
    let isMine: Bool
    let name: String
    let username: String?
    let avatar: Data?
    let initial: UUID
    @State private var didPosition = false
    @State private var deleting: RiderPost?
    @State private var deletionInProgress = false
    @State private var deleteError = false
    @State private var detail: Detail?
    @State private var conversation: RiderPerson?

    private struct Detail: Identifiable {
        let item: RiderProfilePublications.Entry
        var id: UUID { item.id }
    }

    init(items: [RiderProfilePublications.Entry], initial: UUID, isMine: Bool,
         name: String, username: String?, avatar: Data?) {
        self.items = items
        self.isMine = isMine
        self.name = name
        self.username = username
        self.avatar = avatar
        self.initial = initial
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items.filter { !social.deletedPosts.contains($0.id) }) { item in
                        card(item).id(item.id)
                    }
                }
                .padding(12)
            }
            .task {
                guard !didPosition else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                reader.scrollTo(initial, anchor: .top)
                didPosition = true
            }
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Публикации")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(item: $conversation) { RiderThreadView(peer: $0) }
        .confirmationDialog("Удалить эту публикацию?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { post in
            Button("Удалить", role: .destructive) { delete(post) }
        } message: { post in
            Text(post.deletionDescription)
        }
        .alert("Не удалось удалить публикацию", isPresented: $deleteError) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $detail) { request in
            let item = request.item
            NavigationStack {
                RiderPostDetail(original: item.post, author: item.remote?.author ?? name,
                                username: item.remote?.username ?? username, avatar: item.remote?.avatar ?? avatar,
                                editable: isMine && item.post.sourceID == nil, entry: item.remote)
            }
        }
    }

    private func card(_ item: RiderProfilePublications.Entry) -> some View {
        let post = item.resolved(using: isMine ? social.posts.first { $0.id == item.id } : nil)
        return VStack(alignment: .trailing, spacing: 4) {
            if isMine && post.sourceID == nil {
                Menu {
                    if post.published != true && RiderCommunity.endpoint != nil {
                        Button("Опубликовать", systemImage: "arrow.up.circle") {
                            detail = Detail(item: item)
                        }
                    }
                    Button("Удалить", systemImage: "trash", role: .destructive) { deleting = post }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(deletionInProgress)
                .accessibilityLabel("Управление публикацией")
            }
            RiderFeedCard(post: post, author: item.remote?.author ?? name, username: item.remote?.username ?? username,
                          avatar: item.remote?.avatar ?? avatar, editable: isMine && item.post.sourceID == nil,
                          entry: item.remote, opensPost: false,
                          onConversation: { conversation = $0 })
        }
    }

    private func delete(_ target: RiderPost) {
        guard !deletionInProgress else { return }
        deletionInProgress = true
        Task {
            defer { deletionInProgress = false }
            do { try await social.delete(target) }
            catch { deleteError = true }
        }
    }
}

private struct RiderProfileShortcut: View {
    let title: String
    let subtitle: String
    var icon = "chart.bar.xaxis"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(RiderTheme.accent)
                .frame(width: 28, height: 28)
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
        .padding(9).background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

}

private struct RiderProfileRecords: View {
    let totals: RiderTotals
    var distance: Double?
    var locked = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) { recordItems }
            VStack(spacing: 10) { recordItems }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var recordItems: some View {
        record("Топ прыжок", value: metric(totals.height, unit: "м")) { RiderJumpRecordIcon() }
        record("Топ завис", value: metric(totals.airtime, unit: "с")) { Image(systemName: "timer") }
        record("Топ дистанция", value: metric(distance, unit: "м")) { RiderJumpDistanceIcon() }
    }

    private func record<Icon: View>(_ title: String, value: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 3) {
            icon().font(.subheadline.bold()).foregroundStyle(RiderTheme.accent)
                .frame(height: 22)
                .accessibilityHidden(true)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.headline)
                    .accessibilityLabel("Рекорд скрыт")
            } else {
                Text(value).font(.headline.monospacedDigit())
            }
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 9)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

}

private struct RiderProfileSummary: View {
    let timeOnWater: String
    let unlocked: Int
    let total: Int
    let onAchievements: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) { HStack(spacing: 12) { items }; VStack(spacing: 2) { items } }
            .padding(.horizontal, 9).background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder private var items: some View {
            summaryRow("Часы на воде", value: timeOnWater, icon: "water.waves")
                .accessibilityElement(children: .combine)

            Button(action: onAchievements) {
                summaryRow("Достижения", value: "\(unlocked) из \(total)", icon: "medal", opensDetails: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Достижения")
            .accessibilityValue("\(unlocked) из \(total)")
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

}

private struct RiderAchievementsGrid: View {
    let badges: [RiderAchievement]

    var body: some View {
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
            .font(.system(size: size * (rank == .s ? 0.41 : 0.53), weight: .black, design: .monospaced))
            .foregroundStyle(rank.tint)
            .frame(width: size, height: size)
            .background(Color(red: 0.05, green: 0.13, blue: 0.19), in: RoundedRectangle(cornerRadius: size * 0.26))
            .overlay { RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(rank.tint.opacity(0.65)) }
            .accessibilityLabel("Уровень \(rank.rawValue)")
    }
}

struct RiderRankCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let points: Int
    let year: Int
    private var rank: RiderRank { .forPoints(points) }

    init(progress: RiderSeasonProgress) {
        self.init(points: progress.points, year: progress.year)
    }

    init(points: Int, year: Int) {
        self.points = points
        self.year = year
    }

    var body: some View {
        let color = rank.tint
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RiderRankBadge(rank: rank, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(riderPoints(points))
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("Сезон \(String(year))").font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 4)
                if let next = rank.next {
                    Text("До уровня \(next.rawValue)\n\(riderPoints(next.threshold - points))")
                        .multilineTextAlignment(.trailing)
                        .font(.caption.bold().monospacedDigit()).foregroundStyle(color)
                } else {
                    Text("Высший уровень").font(.caption.bold()).foregroundStyle(color)
                }
            }
            if rank == .s {
                Label("Баллы копятся до конца сезона", systemImage: "infinity")
                    .font(.caption.weight(.semibold)).foregroundStyle(color)
            } else {
                ProgressView(value: Double(points - rank.threshold) / Double((rank.next?.threshold ?? rank.threshold + 1) - rank.threshold))
                    .tint(color)
                    .accessibilityLabel("Прогресс уровня")
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: points)
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
                Text("Уровень повышен").font(.title.bold())
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
        .contentShape(Circle())
    }
}

private enum RiderFollowKind: String {
    case followers, following

    var title: String { self == .followers ? "Подписчики" : "Подписки" }
}

private struct RiderFollowCount: View {
    let id: String
    let kind: RiderFollowKind
    let count: Int

    var body: some View {
        NavigationLink {
            RiderFollowList(id: id, kind: kind)
        } label: {
            HStack(spacing: 3) {
                Text(kind.title)
                Text(count.formatted()).fontWeight(.semibold)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
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

    private var query: String { RiderSearch.query(search) }

    var body: some View {
        List {
            Section(kind.title) {
                if let people {
                    let matches = people.filter { RiderSearch.matches($0, query: query) }
                    if matches.isEmpty {
                        Text(query.isEmpty
                             ? (kind == .followers ? "Пока нет подписчиков" : "Пока нет подписок")
                             : "Ничего не найдено").foregroundStyle(.secondary)
                    }
                    ForEach(matches) { riderRow($0) }
                } else if failed {
                    Button("Повторить загрузку") { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
            RiderGlobalSearchSection(query: query, excluding: Set((people ?? []).map(\.id))) { riderRow($0) }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ник или @юзернейм")
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas)
        .task { await load() }
        .refreshable { await load() }
    }

    private func riderRow(_ person: RiderPerson) -> some View {
        NavigationLink { RiderPublicProfileView(id: person.id) } label: {
            RiderPostHeader(author: person.name, username: person.username, avatar: person.avatar, premium: person.premium)
                .padding(.vertical, 4)
        }
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

private struct RiderProfileTitle: View {
    let name: String
    let username: String?
    let premium: Bool?
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RiderName(name, premium: premium)
                .font(.title2.bold())
                .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.62)
            if let username, !username.isEmpty {
                Text("@" + username)
                    .font(.subheadline)
                    .foregroundStyle(RiderTheme.foam)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RiderPublicProfileView: View {
    @EnvironmentObject private var social: RiderSocialStore
    @Environment(\.riderOpenOwnProfile) private var openOwnProfile
    @Environment(\.dismiss) private var dismiss
    @AppStorage("rider.accountID") private var accountID = ""
    @AppStorage("rider.username") private var ownUsername = ""
    let id: String
    @State private var page: RiderPublicPage?
    @State private var unavailable = false
    @State private var busy = false
    @State private var actionError = false
    @State private var showingAchievements = false

    @State private var publicationSection = RiderPublicationSection.gallery

    private var isSelf: Bool {
        id == "me" || id == accountID || (!ownUsername.isEmpty && id.lowercased() == ownUsername.lowercased())
            || page?.mine == true
    }

    var body: some View {
        if isSelf, let openOwnProfile {
            Color.clear.task {
                dismiss()
                openOwnProfile()
            }
        } else {
            publicProfile
        }
    }

    private var publicProfile: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let page {
                    profile(page.rider, isMine: page.mine, rank: page.points.map { RiderRank.forPoints($0) })
                    if page.points != nil || page.rider.profile.recordsPublic == false {
                        RiderProfileRecords(totals: page.rider.profile.totals, distance: page.distance,
                                            locked: page.rider.profile.recordsPublic == false)
                    } else {
                        Label("Статистика закрыта", systemImage: "lock")
                            .font(.subheadline).foregroundStyle(.secondary).lagoonCard()
                    }
                    RiderProfilePublications(entries: page.posts, isMine: page.mine, name: page.rider.profile.name,
                                             username: page.rider.profile.username, avatar: page.rider.profile.avatar,
                                             selection: $publicationSection)
                } else if unavailable {
                    ContentUnavailableView("Профиль недоступен", systemImage: "person.crop.circle",
                                           description: Text("Профиль закрыт или связь с сервером потеряна."))
                    Button("Повторить загрузку") { Task { await load() } }
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }.padding(12)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(page?.rider.profile.username.map { "@" + $0 } ?? "Райдер")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingAchievements) {
            if let page, page.points != nil {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            RiderAchievementsGrid(badges: badges(for: page))
                            if let secrets = page.rider.profile.secrets, !secrets.isEmpty {
                                Text("Секретные").font(.headline)
                                ForEach(secrets) { mission in
                                    Label(mission.rule.title, systemImage: "sparkles").lagoonCard()
                                }
                            }
                        }.padding(16)
                    }
                    .background(RiderTheme.canvas.ignoresSafeArea())
                    .navigationTitle("Достижения")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingAchievements = false } }
                    }
                }
            }
        }
    }

    private func profile(_ rider: RemoteRider, isMine: Bool, rank: RiderRank?) -> some View {
        let user = rider.profile
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                RiderAvatar(photo: user.avatar ?? Data(), size: 50)
                    .overlay { Circle().strokeBorder(RiderTheme.foam.opacity(0.8), lineWidth: 2) }
                RiderProfileTitle(name: user.name, username: user.username, premium: user.premium)
                if rank != nil || (!isMine && user.publicProfile != false) {
                    profileActions(rider, isMine: isMine, rank: rank)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { followCounts(rider) }
                VStack(alignment: .leading, spacing: 0) { followCounts(rider) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(RiderTheme.foam)
            if let birth = user.birthday, birth.count == 5 {
                let parts = birth.split(separator: "-")
                if parts.count == 2 { Label("\(parts[1]).\(parts[0])", systemImage: "birthday.cake").font(.caption) }
            }
            if let bio = user.bio { Text(bio).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 0) {
                Label(user.totals.timeOnWater, systemImage: "water.waves")
                    .font(.caption.weight(.semibold)).foregroundStyle(RiderTheme.foam)
                Spacer(minLength: 4)
                if rank != nil {
                    Button { showingAchievements = true } label: { RiderCompactAction(icon: "medal") }
                        .accessibilityLabel("Достижения")
                }
                if let rides = page?.rides {
                    NavigationLink {
                        List(rides.sorted { $0.startedAt > $1.startedAt }) { ride in
                            RiderRideCard(date: ride.date, title: ride.spot) {
                                Label("\(Int(ride.seconds / 60)) мин · \(ride.jumps) прыжков", systemImage: "water.waves")
                                    .font(.subheadline)
                            }
                            .listRowSeparator(.hidden)
                        }
                        .overlay {
                            if rides.isEmpty { ContentUnavailableView("Пока нет каталок", systemImage: "water.waves").allowsHitTesting(false) }
                        }
                        .navigationTitle("История каталок")
                    } label: {
                        RiderCompactAction(icon: "clock.arrow.circlepath")
                    }.accessibilityLabel("История каталок")
                    NavigationLink {
                        RiderAnalytics(title: user.username.map { "Статистика @" + $0 } ?? "Статистика райдера", rides: rides)
                    } label: {
                        RiderCompactAction(icon: "chart.bar.xaxis")
                    }.accessibilityLabel("Статистика райдера")
                }
            }.buttonStyle(.plain)
            if actionError { Text("Не удалось изменить подписку.").font(.footnote) }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 24))
        .tint(RiderTheme.foam)
    }

    private func profileActions(_ rider: RemoteRider, isMine: Bool, rank: RiderRank?) -> some View {
        let user = rider.profile
        let following = social.follows[rider.id] ?? rider.following
        return HStack(spacing: 0) {
            if let rank {
                RiderRankBadge(rank: rank, size: 32).frame(width: 44, height: 44)
            }
            if !isMine && user.publicProfile != false {
                Button {
                    busy = true
                    actionError = false
                    Task {
                        defer { busy = false }
                        do {
                            try await RiderCommunity.follow(rider.id, enabled: !following)
                            social.follows[rider.id] = !following
                            await load(keepPageOnFailure: true)
                        } catch { actionError = true }
                    }
                } label: {
                    RiderFollowIcon(following: following)
                }
                .disabled(busy)
                .accessibilityLabel(following ? "Отписаться" : "Подписаться")
                .accessibilityAddTraits(following ? .isSelected : [])
                NavigationLink {
                    RiderThreadView(peer: RiderPerson(id: rider.id, name: user.name, username: user.username,
                                                     avatar: user.avatar, premium: user.premium))
                } label: {
                    RiderCompactAction(icon: "paperplane")
                }
                .accessibilityLabel("Написать")
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func followCounts(_ rider: RemoteRider) -> some View {
        let following = social.follows[rider.id] ?? rider.following
        let followers = max(0, rider.followers + (following ? 1 : 0) - (rider.following ? 1 : 0))
        RiderFollowCount(id: rider.id, kind: .followers, count: followers)
        RiderFollowCount(id: rider.id, kind: .following, count: rider.followingCount ?? 0)
    }

    private func badges(for page: RiderPublicPage) -> [RiderAchievement] {
        RiderAchievement.milestones(page.rider.profile.totals, followers: page.rider.followers)
    }

    @MainActor private func load(keepPageOnFailure: Bool = false) async {
        do {
            let result: RiderPublicPage = try await RiderCommunity.decode("riders/" + id)
            if !Task.isCancelled { page = result; unavailable = false }
        } catch {
            if !Task.isCancelled && !keepPageOnFailure { page = nil; unavailable = true }
        }
    }
}


struct RiderRideCard<Content: View>: View {
    let date: Date
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty { Text(title).font(.headline).lineLimit(2) }
            Text(date, format: .dateTime.day().month(.wide).hour().minute()).font(.headline)
            content
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 18))
    }
}

