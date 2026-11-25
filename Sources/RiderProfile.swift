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
    let records: [RiderJumpScore]?
}

fileprivate struct RemoteRider: Decodable, Identifiable {
    let id: String
    let profile: RiderPublication
    let followers: Int
    let following: Bool
    let followingCount: Int?
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

    init(_ history: [SessionSummary], at now: Date) {
        let progress = RiderSeasonProgress(history, at: now)
        year = progress.year
        rides = progress.rides
        totals = RiderTotals(history)
        records = RiderJumpScore.records(in: history).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

enum RiderCommunity {
    struct SeasonCredit: Decodable, Equatable {
        let year: Int
        let followers: Int
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

    private static func decode<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
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
        let (data, response) = try await URLSession.shared.data(for: req)
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
    @State private var showingRanks = false
    @State private var showingStickers = false

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
        let stickers = RiderMission.earned(in: recorder.history)
        return ScrollView {
            VStack(spacing: 18) {
                profile
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
                             total: badges.count, stickers: stickers.count)
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
        .sheet(isPresented: $showingStickers) { RiderMissionPicker(earned: stickers) }
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
                ScrollView { achievements(badges).padding(16) }
                    .background(RiderTheme.canvas.ignoresSafeArea())
                    .navigationTitle("Ачивки")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingAchievements = false } }
                    }
            }
        }
        .task {
            guard RiderCommunity.endpoint != nil else { return }
            if let state = try? await RiderCommunity.request("riders"), !Task.isCancelled { mine = state.mine }
        }
        .sheet(isPresented: $editing) { profileEditor(totals) }
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

    private func profileEditor(_ totals: RiderTotals) -> some View {
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
                if RiderCommunity.endpoint != nil {
                    NavigationLink("Публичный профиль") {
                        RiderCommunityView(totals: totals, records: RiderJumpScore.records(in: recorder.history),
                                           didLoad: { state in
                                               mine = state.mine
                                               if state.mine == nil { social.seasonCredit = nil }
                                               social.statisticsRefresh += 1
                                           })
                    }
                }
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        username = cleanedUsername
                        editing = false
                    }.disabled(!usernameValid)
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
        Text("Подписчики: \(mine?.followers ?? 0)")
        Text("Подписан: \(mine?.followingCount ?? 0)")
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

    private func compactStats(timeOnWater: String, unlocked: Int, total: Int, stickers: Int) -> some View {
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
            Divider()
            Button { showingStickers = true } label: {
                summaryRow("Наклейки", value: "\(stickers) из \(RiderMission.allCases.count)", icon: "seal", opensDetails: true)
            }
            .buttonStyle(.plain)
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

private struct RiderCommunityView: View {
    @EnvironmentObject private var social: RiderSocialStore
    let totals: RiderTotals
    let records: [RiderJumpScore]
    let didLoad: (CommunityState) -> Void
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.username") private var username = ""
    @AppStorage("rider.profileBio") private var bio = ""
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @State private var community: CommunityState?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            if RiderCommunity.endpoint == nil {
                ContentUnavailableView("Сообщество пока недоступно", systemImage: "person.2",
                                       description: Text("Публичные профили и подписки появятся после подключения сервера Rider."))
            } else {
                Section {
                    if let community {
                        if let me = community.mine {
                            LabeledContent("Подписчики", value: String(me.followers))
                            LabeledContent("Подписан", value: String(me.followingCount ?? 0))
                        }
                        Button(community.mine == nil ? "Опубликовать профиль" : "Обновить профиль") {
                            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let description = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                            perform("me", method: "PUT", payload: RiderPublication(
                                name: title.isEmpty ? "Райдер" : String(title.prefix(50)),
                                username: username.isEmpty ? nil : username,
                                bio: description.isEmpty ? nil : String(description.prefix(160)),
                                totals: totals, avatar: photo.isEmpty ? nil : photo, records: records
                            ))
                        }
                        if community.mine != nil {
                            Button("Сделать профиль закрытым") { perform("me", method: "DELETE") }
                        }
                    }
                } header: {
                    Text("Мой публичный профиль")
                } footer: {
                    Text("Публикуются имя, юзернейм, фото и описание. Сессии обновляют общие рекорды и годовой рейтинг. В рейтинг ранга передаются время начала, длительность и число засчитанных прыжков.")
                }
                Section("Другие райдеры") {
                    if community?.riders.isEmpty == true {
                        Text("Пока никто не опубликовал профиль").foregroundStyle(.secondary)
                    }
                    ForEach(community?.riders ?? []) { rider in
                        DisclosureGroup {
                            if let bio = rider.profile.bio, !bio.isEmpty { Text(bio) }
                            LabeledContent("Топ прыжок", value: metric(rider.profile.totals.height, unit: "м"))
                            LabeledContent("Топ завис", value: metric(rider.profile.totals.airtime, unit: "с"))
                            LabeledContent("Часы на воде", value: rider.profile.totals.timeOnWater)
                            LabeledContent("Подписчики", value: String(rider.followers))
                            Button(rider.following ? "Отписаться" : "Подписаться") {
                                perform("follow/" + rider.id, method: rider.following ? "DELETE" : "PUT")
                            }
                        } label: {
                            HStack(spacing: 9) {
                                RiderAvatar(photo: rider.profile.avatar ?? Data(), size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rider.profile.name).font(.headline)
                                    if let tag = rider.profile.username { Text("@" + tag).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                Button("Обновить список райдеров") { perform("riders") }
            }
            if busy { ProgressView("Загружаем") }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(busy)
        .navigationTitle("Публичный профиль")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(RiderTheme.canvas)
        .onAppear { if community == nil && RiderCommunity.endpoint != nil { perform("riders") } }
    }

    private func perform(_ path: String, method: String = "GET", payload: RiderPublication? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await RiderCommunity.request(path, method: method, payload: payload)
                community = result
                didLoad(result)
                if path == "me", method == "DELETE" { social.makePostsPrivate() }
                message = nil
            } catch RiderCommunity.Rejection.conflict {
                message = "Этот юзернейм уже занят. Выбери другой в профиле."
            } catch {
                message = "Нет подтверждения от сервера. Проверьте связь и обновите данные."
            }
        }
    }
}
