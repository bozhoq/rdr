import AVKit
import QuickLook
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RiderPostLocation: Codable {
    let name: String
    let latitude: Double?
    let longitude: Double?

    var mapURL: URL? {
        guard let latitude, let longitude else { return nil }
        return RiderSpot(name: name, latitude: String(latitude), longitude: String(longitude))?.yandexURL
    }
}

struct RiderPostEquipment: Codable, Hashable {
    let name: String
    let kite: String
    let board: String

    init(_ preset: GearPreset) {
        let setup = preset.applying(to: SessionSetup())
        name = preset.name
        kite = setup.kiteTitle
        board = setup.boardTitle
    }
    init?(setup: SessionSetup) {
        guard !setup.kiteTitle.isEmpty, !setup.boardTitle.isEmpty else { return nil }
        name = setup.kiteTitle
        kite = setup.kiteTitle
        board = setup.boardTitle
    }
}

struct RiderPerson: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let username: String?
    let avatar: Data?

    var premium: Bool? = nil

    var handle: String { riderHandle(username, or: name) }
}

private func riderHandle(_ username: String?, or name: String) -> String {
    guard let username, !username.isEmpty else { return name }
    return "@" + username
}

/// Keep explicit mentions tappable without adding text to the caption.
struct RiderLinkedText: View {
    let text: String
    var author: String? = nil
    var authorID: String? = nil
    var linkTint = RiderTheme.accent
    @State private var destination: Mention?

    private struct Mention: Identifiable {
        let id: String
    }

    private static let handles = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.+@])@([A-Za-z0-9_]{3,24})(?![A-Za-z0-9_])"#)

    private var content: AttributedString {
        let line = (author.map { $0 + " " } ?? "") + text
        let value = NSMutableAttributedString(string: line)
        let full = NSRange(location: 0, length: value.length)
        for match in Self.handles.matches(in: line, range: full) {
            let tag = (line as NSString).substring(with: match.range(at: 1)).lowercased()
            if let url = URL(string: "rider://profile/" + tag) {
                value.addAttribute(.link, value: url, range: match.range)
            }
        }
        if let author, let authorID, let url = URL(string: "rider://profile/" + authorID) {
            value.addAttribute(.link, value: url, range: NSRange(location: 0, length: (author as NSString).length))
        }
        return (try? AttributedString(value, including: \.uiKit)) ?? AttributedString(line)
    }
    var body: some View {
        Text(content).tint(linkTint)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "rider", url.host == "profile" else { return .systemAction }
                destination = Mention(id: url.lastPathComponent)
                return .handled
            })
            .sheet(item: $destination) { mention in
                NavigationStack {
                    RiderPublicProfileView(id: mention.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Закрыть") { destination = nil }
                            }
                        }
                }
            }
    }
}

struct RiderReaction: Decodable {
    let total: Int
    let mine: Bool
    let people: [RiderPerson]
}

struct RiderActivity: Decodable {
    let id: String?
    let kind: String
    let person: RiderPerson
    let postID: UUID?
    let createdAt: TimeInterval

    var description: String {
        switch kind {
        case "shaka": return "поставил(а) шаку твоему посту"
        case "reply": return "ответил(а) на твой комментарий"
        case "comment": return "оставил(а) комментарий"
        case "repost": return "поделился(-ась) твоим постом"
        default: return "подписался(-ась) на тебя"
        }
    }
}

struct RiderChatAttachment: Decodable {
    let filename: String
    let contentType: String
    let size: Int

    var showsPhoto: Bool { ["image/jpeg", "image/png", "image/heic", "image/heif"].contains(contentType) }
    var isVoice: Bool { contentType == "audio/mp4" }
    var isCircle: Bool { contentType == "video/mp4" && filename == "circle.mp4" }
}

struct RiderChatUpload: Encodable {
    static let maxBytes = 5 * 1024 * 1024
    let filename: String
    let contentType: String
    let data: Data

    init(filename: String, contentType: String, data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let safeName = String(filename.map { character in
            character == "/" || character == "\\" || character == ":" || character.isNewline ? "_" : character
        })
        let title = String(safeName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.filename = title.isEmpty || title == "." || title == ".." ? "Вложение" : title
        self.contentType = contentType
        self.data = data
    }
}

struct RiderMessage: Decodable, Identifiable {
    let id: UUID
    let mine: Bool
    let text: String
    let createdAt: TimeInterval
    let postID: UUID?
    let sharedPost: RiderFeedEntry?
    let attachment: RiderChatAttachment?
    var delivered: Bool?
    var read: Bool?
}

struct RiderUnread: Decodable, Equatable {
    var threads: [String: Int] = [:]
    var activity = 0
    var messages: Int { threads.values.reduce(0, +) }
}

struct RiderBadgeIcon: View {
    let icon: String
    let title: String
    let count: Int

    var body: some View {
        Image(systemName: icon)
            .overlay(alignment: .bottomTrailing) {
                if count > 0 {
                    Text(count > 99 ? "99+" : String(count)).font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 4).frame(minHeight: 14)
                        .foregroundStyle(.white).background(.red, in: Capsule()).offset(x: 8, y: 4)
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(count > 0 ? "\(count) непрочитанных" : "")
    }
}

enum RiderPublicationSection: String, Codable, CaseIterable, Identifiable {
    case gallery, journal
    var id: Self { self }
    var title: String { self == .gallery ? "Фото и видео" : "Стена" }
    var icon: String { self == .gallery ? "square.grid.3x3" : "text.alignleft" }
}

struct RiderPost: Codable, Identifiable {
    static let maxVideoBytes = 12 * 1024 * 1024
    let id: UUID
    let createdAt: TimeInterval
    let caption: String
    let location: RiderPostLocation?
    let photo: Data?
    var published: Bool?
    var uploadAttempted: Bool?
    var equipment: RiderPostEquipment?
    var sourceID: UUID?
    var sourceAuthor: String?
    var sourceUsername: String?
    var section: RiderPublicationSection?
    var video: Data?
    var hasVideo: Bool?
    var hasCover: Bool?

    var publicationSection: RiderPublicationSection { section ?? .gallery }
    var isVideo: Bool { video != nil || hasVideo == true }
    var showsMedia: Bool { photo != nil || (hasCover ?? (publicationSection == .gallery)) }

    var date: Date { Date(timeIntervalSince1970: createdAt) }
    var deletionDescription: String {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? date.formatted(date: .abbreviated, time: .shortened) : String(text.prefix(120))
    }
    var contentID: UUID { sourceID ?? id }
    var remotePhoto: URL? {
        guard showsMedia else { return nil }
        return RiderCommunity.endpoint?.appendingPathComponent("posts/\(contentID.uuidString.lowercased())/photo")
    }
    var publicURL: URL? {
        guard published == true else { return nil }
        return RiderCommunity.endpoint?.appendingPathComponent("posts/\(contentID.uuidString.lowercased())/view")
    }
}

struct RiderCommentSummary: Decodable {
    struct Preview: Decodable {
        let text: String
        let author: String
        let username: String?
    }

    let total: Int
    let preview: Preview?
}

struct RiderFeedEntry: Decodable, Identifiable {
    let post: RiderPost
    let author: String
    let username: String?
    let avatar: Data?
    var premium: Bool? = nil
    let authorID: String?
    let following: Bool?
    let mine: Bool?
    let reposted: Bool?
    let reaction: RiderReaction?
    let commentSummary: RiderCommentSummary?
    var id: UUID { post.id }
}

struct RiderComment: Decodable, Identifiable {
    let id: UUID
    let createdAt: TimeInterval
    let text: String
    let author: String
    let username: String?
    let avatar: Data?
    var premium: Bool? = nil
    let authorID: String?
    let mine: Bool
    let replyTo: UUID?
    let replyName: String?

    var likes: Int?
    var liked: Bool?
    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

struct RiderTopEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let username: String?
    let height: Double?
    let airtime: Double?
    let distance: Double?
    let avatar: Data?
    let kite: String?
    let board: String?
    var spot: String? = nil
    var windMS: Double? = nil
    var windDirection: Double? = nil
    var points: Int?
    var premium: Bool? = nil

    func value(for metric: RiderTopMetric) -> Double? {
        metric == .rank ? points.map(Double.init) : metric.value(height: height, airtime: airtime, distance: distance)
    }
}

struct RiderTopPage: Decodable {
    let leaders: [RiderTopEntry]
    let myPlace: Int?
}

struct RiderTopFilter: Encodable, Equatable {
    let metric: String
    let spotID: UUID?
    let spot: String?
    let startAt: TimeInterval?
    let endAt: TimeInterval?
    var season: Int?
    let withMyPlace = true

    func contains(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return (startAt.map { seconds >= $0 } ?? true) && (endAt.map { seconds < $0 } ?? true)
    }
}

final class RiderSocialStore: ObservableObject {
    @Published private(set) var unread = RiderUnread()
    private var unreadRevision = 0

    @MainActor func acceptUnread(_ value: RiderUnread) {
        unreadRevision += 1
        if unread != value { unread = value }
    }

    @MainActor func refreshUnread() async {
        let revision = unreadRevision
        if let result = try? await RiderCommunity.unread(), !Task.isCancelled, revision == unreadRevision {
            acceptUnread(result)
        }
    }

    @Published private(set) var posts: [RiderPost] = []
    @Published private(set) var reposts: [RiderFeedEntry] = []
    @Published var reactions: [UUID: RiderReaction] = [:]
    @Published var commentSummaries: [UUID: RiderCommentSummary] = [:]
    @Published var myPremium: Bool? = nil
    @Published var follows: [String: Bool] = [:]
    @Published var reposted: [UUID: Bool] = [:]
    @Published private(set) var deletedPosts: Set<UUID> = []
    @Published var statisticsRefresh = 0
    @Published var seasonCredit: RiderCommunity.SeasonCredit?
    @Published var statisticsSynced = 0

    func progress(_ history: [SessionSummary], at now: Date) -> RiderSeasonProgress {
        let local = RiderSeasonProgress(history, at: now)
        guard let seasonCredit, seasonCredit.year == local.year, seasonCredit.followers > 0 else { return local }
        return RiderSeasonProgress(history, at: now, followers: seasonCredit.followers)
    }
    @Published private(set) var localShakas = Set(UserDefaults.standard.stringArray(forKey: "rider.localShakas") ?? [])

    @MainActor func toggleLocalShaka(for post: UUID) {
        let key = post.uuidString
        if localShakas.contains(key) { localShakas.remove(key) } else { localShakas.insert(key) }
        UserDefaults.standard.set(Array(localShakas), forKey: "rider.localShakas")
    }

    @MainActor func refreshReposts() async {
        guard RiderCommunity.endpoint != nil else { return }
        do {
            let entries = try await RiderCommunity.myReposts()
            if !Task.isCancelled { reposts = entries }
        } catch { /* Keep the previous list during a temporary network failure. */ }
    }
    private let directory = RiderLocalAccount.directory("RiderPosts")

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let loaded: [RiderPost] = files.compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(RiderPost.self, from: data)
        }
        posts = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    @MainActor func save(_ post: RiderPost) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(post).write(to: file(for: post.id), options: [.atomic, .completeFileProtection])
        posts = (posts.filter { $0.id != post.id } + [post]).sorted { $0.createdAt > $1.createdAt }
    }

    @MainActor func publish(_ post: RiderPost) async throws {
        var updated = post
        if RiderCommunity.endpoint != nil {
            try await RiderCommunity.publishPost(post)
            updated.published = true
            updated.uploadAttempted = true
            updated.hasVideo = post.isVideo
            updated.video = nil
        }
        try save(updated)
    }

    @MainActor func delete(_ post: RiderPost) async throws {
        if post.published == true || post.uploadAttempted == true {
            try await RiderCommunity.deletePost(post.id)
        }
        let localFile = file(for: post.id)
        if FileManager.default.fileExists(atPath: localFile.path) { try FileManager.default.removeItem(at: localFile) }
        posts.removeAll { $0.id == post.id }
        deletedPosts.insert(post.id)
    }

    @MainActor func makePostsPrivate() {
        for var post in posts where post.published == true || post.uploadAttempted == true {
            post.published = false
            post.uploadAttempted = false
            try? save(post)
        }
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

struct RiderSections<Option: Identifiable & Equatable, Label: View>: View {
    let options: [Option]
    @Binding var selection: Option
    var compact = false
    @ViewBuilder var label: (Option) -> Label
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        let layout = compact && textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(options) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    label(option)
                        .font((compact ? Font.caption : Font.subheadline).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(selected ? RiderTheme.surface : Color.clear)
                                .padding(.vertical, compact ? 5 : 0)
                                .allowsHitTesting(false)
                        }
                        .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, compact ? 0 : 3)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(RiderTheme.border)
                .padding(.vertical, compact ? 2 : 0)
                .allowsHitTesting(false)
        }
    }
}

struct RiderCompactAction: View {
    let icon: String
    var selected = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(selected ? 0.24 : 0.12), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

struct RiderFollowIcon: View {
    let following: Bool

    var body: some View {
        RiderCompactAction(icon: following ? "person.badge.minus" : "person.badge.plus", selected: following)
    }
}

struct RiderPostSquare: View {
    let post: RiderPost
    @State private var localImage: UIImage?

    var body: some View {
        RiderTheme.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { bounds in
                    Group {
                        if let data = post.photo, let loaded = UIImage(data: data) {
                            Image(uiImage: loaded).resizable().scaledToFill()
                        } else if RiderCommunity.usesLANTrust {
                            if let localImage { Image(uiImage: localImage).resizable().scaledToFill() }
                            else { placeholder }
                        } else {
                            AsyncImage(url: post.remotePhoto) { phase in
                                if let photo = phase.image { photo.resizable().scaledToFill() }
                                else { placeholder }
                            }
                        }
                    }
                    .frame(width: bounds.size.width, height: bounds.size.width)
                    .clipped()
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(.interaction, Rectangle())
            .overlay(alignment: .topTrailing) {
                if post.isVideo {
                    Image(systemName: "play.rectangle.fill").padding(8).foregroundStyle(.white)
                        .background(.black.opacity(0.5), in: Capsule()).padding(8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(post.caption.isEmpty ? (post.isVideo ? "Видео публикации" : "Фото публикации") : post.caption)
            .task(id: post.remotePhoto) {
                guard RiderCommunity.usesLANTrust, post.photo == nil, let url = post.remotePhoto else { return }
                localImage = nil
                if let data = await RiderCommunity.localPhoto(url), !Task.isCancelled { localImage = UIImage(data: data) }
            }
    }

    private var placeholder: some View {
        ZStack {
            RiderTheme.surface
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}

private struct RiderClipPlayer: View {
    let post: RiderPost
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var file: URL?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if let player { VideoPlayer(player: player) }
                else if failed { Text("Видео недоступно").foregroundStyle(.white) }
                else { ProgressView().tint(.white) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Закрыть") { dismiss() }
                .buttonStyle(.borderedProminent).padding(12)
        }
        .task {
            do {
                let data: Data
                if let stored = post.video { data = stored }
                else { data = try await RiderCommunity.video(for: post.contentID) }
                try Task.checkCancellation()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                try data.write(to: url, options: .atomic)
                file = url
                let video = AVPlayer(url: url)
                player = video
                video.play()
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }
}

struct RiderPostDetail: View {
    @EnvironmentObject private var social: RiderSocialStore
    @Environment(\.dismiss) private var dismiss
    let original: RiderPost
    let author: String
    let username: String?
    var avatar: Data?
    var editable = false
    var openComments = false
    var entry: RiderFeedEntry?
    @State private var busy = false
    @State private var conversation: RiderPerson?
    @State private var confirmDelete = false
    @State private var error: String?

    private var post: RiderPost {
        guard editable, var local = social.posts.first(where: { $0.id == original.id }) else { return original }
        if original.published == true { local.published = true }
        return local
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                RiderFeedCard(post: post, author: author, username: username, avatar: avatar,
                              editable: editable, entry: entry, opensPost: false, openComments: openComments,
                              onConversation: { conversation = $0 }, embedded: true)
                    .lagoonCard()
                if editable { publishingControls }
            }
            .padding(16)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Публикация")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $conversation) { RiderThreadView(peer: $0) }
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if editable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Удалить публикацию?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { update(deleting: true) }
        } message: {
            Text(post.deletionDescription)
        }
        .disabled(busy)
    }

    @ViewBuilder private var publishingControls: some View {
        if post.published != true || error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if post.published != true {
                    if RiderCommunity.endpoint != nil {
                        Button("Опубликовать") { update(deleting: false) }.buttonStyle(.borderedProminent)
                        Text("В ленте будут видны фото, подпись, выбранная геометка и комплект.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Сохранено на этом iPhone").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .lagoonCard()
        }
    }

    private func update(deleting: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        let current = post
        Task {
            defer { busy = false }
            do {
                if deleting { try await social.delete(current); dismiss() }
                else { try await social.publish(current) }
            } catch {
                self.error = deleting ? "Не удалось удалить публикацию." : "Сначала опубликуйте профиль во вкладке «Райдер». Проверьте подключение и повторите."
            }
        }
    }
}

struct RiderFollowStyle: ButtonStyle {
    let following: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white).padding(.horizontal, 13).frame(minHeight: 44)
            .background(following ? Color(red: 0.12, green: 0.24, blue: 0.29) : Color(red: 0.0, green: 0.35, blue: 0.37), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(configuration.isPressed ? 0.8 : 0.28)) }
    }
}

private struct RiderFollowAppearance<Content: View>: View {
    let following: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().font(.subheadline.weight(.semibold))
            .foregroundStyle(.white).padding(.horizontal, 13).frame(minHeight: 44)
            .background(following ? Color(red: 0.12, green: 0.24, blue: 0.29) : Color(red: 0, green: 0.35, blue: 0.37), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.28)).allowsHitTesting(false) }
            .contentShape(Capsule())
    }
}

struct RiderName: View {
    let name: String
    let premium: Bool?
    init(_ name: String, premium: Bool?) { self.name = name; self.premium = premium }
    var body: some View {
        HStack(spacing: 4) {
            Text(name)
            if premium == true {
                Image(systemName: "star").font(.caption.weight(.bold)).foregroundStyle(LinearGradient(colors: [.teal, Color(red: 0.24, green: 0.83, blue: 0.77)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityLabel("Премиум")
            }
        }.accessibilityElement(children: .combine)
    }
}

struct RiderPostHeader: View {
    let author: String
    let username: String?
    let avatar: Data?
    var premium: Bool? = nil

    var body: some View {
        HStack(spacing: 10) {
            RiderAvatar(photo: avatar ?? Data(), size: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                RiderName(author, premium: premium).font(.headline)
                if let username, !username.isEmpty {
                    Text("@" + username).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RiderReactionPress: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let showNames: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .gesture(LongPressGesture().exclusively(before: TapGesture()).onEnded { result in
                guard enabled else { return }
                switch result {
                case .first: showNames()
                case .second: configuration.trigger()
                }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { configuration.trigger() } }
            .accessibilityAction(named: Text("Посмотреть реакции")) { if enabled { showNames() } }
    }
}

private struct RiderReactionList: View {
    let title: String
    let preview: RiderReaction?
    let fetch: ((Int) async throws -> RiderReaction)?
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: RiderReaction?
    @State private var offset = 0
    @State private var loading = false
    @State private var failed = false
    @State private var hasMore = false

    var body: some View {
        NavigationStack {
            List {
                if let page = loaded ?? preview {
                    ForEach(page.people) { rider in
                        if rider.id == "local" { row(rider) }
                        else {
                            NavigationLink { RiderPublicProfileView(id: rider.id) } label: { row(rider) }
                        }
                    }
                    if page.total == 0 && (loaded != nil || fetch == nil) {
                        Text("Реакций пока нет").foregroundStyle(.secondary)
                    }
                }
                if loading {
                    ProgressView()
                } else if failed {
                    Button("Повторить загрузку") { Task { await load() } }
                } else if hasMore {
                    Button("Показать ещё") { Task { await load() } }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { if loaded == nil { await load() } }
    }

    private func row(_ rider: RiderPerson) -> some View {
        RiderPostHeader(author: rider.name, username: rider.username, avatar: rider.avatar, premium: rider.premium)
    }

    @MainActor private func load() async {
        guard let fetch, !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let page = try await fetch(offset)
            try Task.checkCancellation()
            let previous = loaded?.people ?? []
            let ids = Set(previous.map(\.id))
            offset += page.people.count
            hasMore = !page.people.isEmpty && offset < page.total
            loaded = RiderReaction(total: page.total, mine: page.mine, people: previous + page.people.filter { !ids.contains($0.id) })
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct RiderCommentsView: View {
    @EnvironmentObject private var social: RiderSocialStore
    @Environment(\.dismiss) private var dismiss
    let postID: UUID
    @State private var comments: [RiderComment]?
    @State private var loading = false
    @State private var sending = false
    @State private var draft = ""
    @State private var replying: RiderComment?
    @State private var viewedLikes: RiderComment?
    private static let compactDetent = PresentationDetent.fraction(0.55)
    @State private var detent = RiderCommentsView.compactDetent
    @State private var keyboardVisible = false
    @State private var collapseAfterKeyboard = false
    @FocusState private var composing: Bool
    @State private var draftID = UUID()
    @State private var error: String?

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let comments {
                        if comments.isEmpty {
                            Text("Пока нет комментариев").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(comments) { comment in
                            commentRow(comment).padding(.leading, comment.replyTo == nil ? 0 : 20)
                        }
                    } else if loading {
                        ProgressView("Загружаем комментарии")
                    } else if error != nil {
                        Button("Обновить комментарии") { Task { await load() } }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { editor }
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(item: $viewedLikes) { comment in
                RiderReactionList(title: "Лайки", preview: nil, fetch: { offset in
                    try await RiderCommunity.commentLikes(comment.id, for: postID, offset: offset)
                })
            }
        }
        .presentationDetents([Self.compactDetent, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: composing) { _, editing in
            if editing {
                collapseAfterKeyboard = false
                detent = .large
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
            if collapseAfterKeyboard {
                collapseAfterKeyboard = false
                if !composing { detent = Self.compactDetent }
            }
        }
        .task(id: postID) { await load() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if let replying {
                HStack {
                    RiderLinkedText(text: "Ответ для " + riderHandle(replying.username, or: replying.author)).font(.caption)
                    Spacer()
                    Button("Отмена") { self.replying = nil; draftID = UUID() }
                }.disabled(sending)
            }
            RiderMentionSuggestions.forText($draft, editing: composing, limit: 500)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Написать комментарий", text: $draft, axis: .vertical)
                    .focused($composing).disabled(sending)
                    .id(draftID)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, value in
                        if value.count > 500 { draft = String(value.prefix(500)) }
                    }
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.body.bold())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty || loading || sending)
                .accessibilityLabel("Отправить комментарий")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func commentRow(_ comment: RiderComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let id = comment.authorID {
                NavigationLink { RiderPublicProfileView(id: id) } label: { commentAvatar(comment) }
                    .buttonStyle(.plain).accessibilityLabel(comment.author)
            } else {
                commentAvatar(comment)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Button { beginReply(comment) } label: { RiderName(comment.author, premium: comment.premium).font(.subheadline.bold()) }
                            .buttonStyle(.plain).disabled(sending)
                        if let handle = comment.username { RiderLinkedText(text: "@" + handle).font(.caption) }
                    }
                    Spacer(minLength: 5)
                    if comment.mine {
                        Menu {
                            Button("Удалить комментарий", role: .destructive) {
                                change { try await RiderCommunity.deleteComment(comment.id, for: postID) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").padding(4)
                        }
                        .accessibilityLabel("Действия с комментарием")
                        .disabled(sending)
                    }
                }
                if let recipient = comment.replyName {
                    RiderLinkedText(text: "В ответ @" + recipient).font(.caption2).foregroundStyle(.secondary)
                }
                RiderLinkedText(text: comment.text).font(.subheadline)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        RiderPostDate(date: comment.date)
                        commentActions(comment)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        RiderPostDate(date: comment.date)
                        commentActions(comment)
                    }
                }
            }
        }
    }

    private func commentActions(_ comment: RiderComment) -> some View {
        HStack(spacing: 8) {
            Button { beginReply(comment) } label: {
                Text("Ответить").font(.caption)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sending)
            Spacer(minLength: 0)
            likeButton(comment)
        }
    }

    private func likeButton(_ comment: RiderComment) -> some View {
        Button {
            change { try await RiderCommunity.likeComment(comment.id, for: postID, enabled: comment.liked != true) }
        } label: {
            Label((comment.likes ?? 0).formatted(), systemImage: comment.liked == true ? "heart.fill" : "heart")
                .font(.caption).foregroundStyle(RiderTheme.accent)
                .padding(.horizontal, 4)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(RiderReactionPress { viewedLikes = comment })
        .disabled(sending || loading)
        .accessibilityLabel(comment.liked == true ? "Убрать лайк" : "Лайк комментарию")
        .accessibilityValue((comment.likes ?? 0).formatted())
    }

    private func beginReply(_ comment: RiderComment) {
        guard !sending else { return }
        if replying?.id != comment.id { draftID = UUID() }
        replying = comment
        composing = true
    }

    private func commentAvatar(_ comment: RiderComment) -> some View {
        RiderAvatar(photo: comment.avatar ?? Data(), size: 33)
    }

    @MainActor private func load() async {
        guard !loading, !sending else { return }
        loading = true
        defer { loading = false }
        do {
            let refreshed = try await RiderCommunity.comments(for: postID)
            guard !Task.isCancelled else { return }
            comments = refreshed
            error = nil
        } catch {
            if !Task.isCancelled { self.error = "Не удалось загрузить комментарии." }
        }
    }

    private func submit() {
        let text = trimmed
        guard !text.isEmpty, !sending, !loading else { return }
        let savedDraft = draft
        let id = draftID
        let parent = replying?.id
        collapseAfterKeyboard = keyboardVisible
        composing = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if !keyboardVisible { detent = Self.compactDetent }
        draft = ""
        change(onFailure: { draft = savedDraft }) {
            let result = try await RiderCommunity.submitComment(text, id: id, for: postID, replyTo: parent)
            draft = ""
            draftID = UUID()
            replying = nil
            return result
        }
    }

    private func change(onFailure: (() -> Void)? = nil,
                        _ action: @escaping @MainActor () async throws -> [RiderComment]) {
        guard !loading, !sending else { return }
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                comments = try await action()
                if let result = try? await RiderCommunity.postDetails(postID) {
                    social.commentSummaries[postID] = result.commentSummary
                }
            } catch RiderCommunity.Rejection.forbidden {
                onFailure?()
                error = "Опубликуй профиль во вкладке «Райдер», чтобы комментировать."
            } catch {
                onFailure?()
                self.error = "Не удалось сохранить изменение. Попробуй ещё раз."
            }
        }
    }
}

struct ImportedRiderClip: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { file in
            let suffix = file.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(suffix.isEmpty ? "mov" : suffix)
            try FileManager.default.copyItem(at: file.file, to: copy)
            return Self(url: copy)
        }
    }
}

private struct ImportedRiderPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let copy = RiderMediaEncoding.temporary(file.file.pathExtension.isEmpty ? "img" : file.file.pathExtension)
            try FileManager.default.copyItem(at: file.file, to: copy)
            return Self(url: copy)
        }
    }
}

struct RiderPostComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var social: RiderSocialStore
    @FocusState private var captionFocused: Bool
    @ObservedObject var recorder: SessionRecorder
    @State private var equipmentID: UUID?
    @State private var picked: PhotosPickerItem?
    @State private var choosingMedia = false
    @State private var photo: Data?
    @State private var video: Data?
    @State private var section: RiderPublicationSection
    @State private var caption: String
    @State private var location: RiderPostLocation?
    @State private var error: String?
    @State private var loading = false
    @State private var sending = false
    @State private var postID = UUID()
    @State private var startedAt = Date().timeIntervalSince1970
    @State private var editedGear = false
    @State private var creatingGear = false
    let sessionEquipment: RiderPostEquipment?

    init(recorder: SessionRecorder, artwork: Data? = nil, caption: String = "",
         section: RiderPublicationSection = .gallery, sessionEquipment: RiderPostEquipment? = nil,
         location: RiderPostLocation? = nil) {
        self.recorder = recorder
        self.sessionEquipment = sessionEquipment
        _photo = State(initialValue: artwork)
        _caption = State(initialValue: caption)
        _section = State(initialValue: section)
        _location = State(initialValue: location)
    }

    private var trimmed: String { caption.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var destination: RiderPublicationSection { photo == nil ? .journal : section }
    private var equipment: RiderPostEquipment? {
        recorder.gearPresets.first { $0.id == equipmentID }.map(RiderPostEquipment.init)
            ?? (editedGear ? nil : sessionEquipment)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Раздел", selection: $section) {
                    ForEach(RiderPublicationSection.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Текст публикации", text: $caption, axis: .vertical)
                    .focused($captionFocused).lineLimit(3...7)
                    .onChange(of: caption) { _, value in if value.count > 800 { caption = String(value.prefix(800)) } }
                RiderMentionSuggestions.forText($caption, editing: captionFocused, limit: 800)
                if photo == nil && section == .gallery && !trimmed.isEmpty {
                    Text("Пост с одним текстом появится на стене. Упоминание начинается с @юзернейма.").font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    captionFocused = false
                    choosingMedia = true
                } label: {
                    Label(photo == nil ? "Добавить фото или видео" : "Заменить вложение", systemImage: "photo.on.rectangle")
                }.disabled(loading)
                if loading { ProgressView("Готовим вложение") }
                if let photo {
                    if let preview = UIImage(data: photo) {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 230)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .topTrailing) {
                                if video != nil {
                                    Image(systemName: "play.rectangle.fill").padding(8)
                                }
                            }
                    }
                    Button("Убрать вложение", role: .destructive) { picked = nil; self.photo = nil; video = nil; loading = false }
                        .disabled(loading)
                }
                NavigationLink {
                    RiderPostLocationChoice(spots: recorder.spots, selection: $location)
                } label: { LabeledContent("Геометка", value: location?.name ?? "Добавить") }
                Picker("Кайт-комплект", selection: Binding(get: { equipmentID }, set: { equipmentID = $0; editedGear = true })) {
                    Text(!editedGear ? sessionEquipment?.name ?? "Без комплекта" : "Без комплекта").tag(nil as UUID?)
                    ForEach(recorder.gearPresets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                }
                if sessionEquipment != nil && !editedGear && equipmentID == nil {
                    Button("Убрать комплект каталки") { editedGear = true }
                }
                Button { captionFocused = false; creatingGear = true } label: {
                    Label("Добавить комплект", systemImage: "plus.circle")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(sending)
            .navigationDestination(isPresented: $creatingGear) {
                GearPresetEditor(recorder: recorder) {
                    equipmentID = recorder.gearPresets.first { $0.matches(recorder.draftSetup) }?.id
                    editedGear = true
                    creatingGear = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Новый пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Публикуем…" : "Опубликовать", action: publish)
                        .disabled(sending || loading || (photo == nil && trimmed.isEmpty))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { captionFocused = false }
                }
            }
        }
        .photosPicker(isPresented: $choosingMedia, selection: $picked, matching: .any(of: [.images, .videos]))
        .interactiveDismissDisabled(sending)
        .task(id: picked) { await loadMedia() }
    }

    @MainActor private func loadMedia() async {
        guard let picked else { return }
        loading = true
        error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            if picked.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let clip = try await picked.loadTransferable(type: ImportedRiderClip.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                defer { try? FileManager.default.removeItem(at: clip.url) }
                let (cover, data) = try await RiderMediaEncoding.clip(from: clip.url)
                guard !Task.isCancelled else { return }
                photo = cover
                video = data
            } else {
                guard let item = try await picked.loadTransferable(type: ImportedRiderPhoto.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                defer { try? FileManager.default.removeItem(at: item.url) }
                let image = await Task.detached(priority: .userInitiated) {
                    let source = CGImageSourceCreateWithURL(item.url as CFURL, nil)
                    return Self.postJPEG(source)
                }.value
                guard !Task.isCancelled else { return }
                guard let image else { throw CocoaError(.fileReadCorruptFile) }
                photo = image
                video = nil
            }
        } catch {
            if !Task.isCancelled { self.error = "Не удалось подготовить вложение. Выбери другой файл." }
        }
    }

    nonisolated static func postJPEG(_ data: Data, forChat: Bool = false) -> Data? {
        postJPEG(CGImageSourceCreateWithData(data as CFData, nil), forChat: forChat)
    }

    nonisolated private static func postJPEG(_ source: CGImageSource?, forChat: Bool = false) -> Data? {
        guard let source, let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: forChat ? 3200 : 1080
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumb)
        let qualities: [CGFloat] = forChat ? [0.93, 0.84, 0.72, 0.58] : [0.76, 0.62, 0.48, 0.32]
        for quality in qualities {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= (forChat ? RiderChatUpload.maxBytes : 390_000) { return jpeg }
        }
        return nil
    }

    @MainActor private func publish() {
        guard !sending, !loading, photo != nil || !trimmed.isEmpty else { return }
        captionFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        sending = true
        error = nil
        let post = RiderPost(id: postID, createdAt: startedAt, caption: trimmed, location: location,
                             photo: photo, equipment: equipment, section: destination, video: video)
        Task {
            defer { sending = false }
            do {
                try await social.publish(post)
                dismiss()
            } catch RiderCommunity.Rejection.forbidden {
                self.error = "Включи «Публичный профиль» в настройках Rider, чтобы публиковать."
            } catch {
                self.error = "Не удалось опубликовать. Текст и вложение остались здесь, попробуй ещё раз."
            }
        }
    }
}

private struct RiderPostLocationChoice: View {
    @Environment(\.dismiss) private var dismiss
    let spots: [RiderSpot]
    @Binding var selection: RiderPostLocation?
    @State private var search = ""

    var body: some View {
        List {
            Button("Без геометки") { selection = nil; dismiss() }
            let name = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            if !name.isEmpty {
                Button("Указать «\(name)»") {
                    selection = RiderPostLocation(name: name, latitude: nil, longitude: nil)
                    dismiss()
                }
            }
            ForEach(spots.filter { spot in
                search.isEmpty || spot.name.localizedCaseInsensitiveContains(search) ||
                    spot.accessPoints?.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) == true
            }) { spot in
                Button(spot.name) {
                    selection = RiderPostLocation(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
                    dismiss()
                }
            }
        }
        .navigationTitle("Геометка")
        .searchable(text: $search, prompt: "Спот или место")
    }
}

private struct RiderFeedTopPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RiderFeedView: View {
    @ObservedObject var recorder: SessionRecorder
    @EnvironmentObject private var social: RiderSocialStore
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.username") private var username = ""
    @AppStorage("rider.profilePhoto") private var avatar = Data()
    @State private var selection = Feed.following
    @State private var conversation: RiderPerson?
    @State private var entries: [RiderFeedEntry]?
    @State private var storiesExpanded = false
    @State private var feedTop: CGFloat = 0
    @State private var storiesOpenedAt: CGFloat = 0
    @Namespace private var feedViewport
    @State private var loadedFeed: Feed?
    @State private var failed = false

    private enum Feed: String, CaseIterable, Identifiable {
        case following, recommended
        var id: Self { self }
        var title: String { self == .following ? "Подписки" : "Рекомендации" }
    }

    var body: some View {
        let feed = selection
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if RiderCommunity.endpoint != nil {
                    RiderStoriesStrip(recorder: recorder, expanded: $storiesExpanded)
                }
                RiderSections(options: Feed.allCases, selection: $selection, compact: true) { Text($0.title) }
                if RiderCommunity.endpoint == nil {
                    Text("Общая лента появится после подключения сервера Rider.").foregroundStyle(.secondary)
                    if !social.posts.isEmpty {
                        Section("Мои посты на iPhone") {
                            ForEach(social.posts) { post in
                                RiderFeedCard(post: post, author: name, username: username, avatar: avatar, editable: true)
                            }
                        }
                    }
                } else if let entries, loadedFeed == feed {
                    if entries.isEmpty {
                        Text(feed == .following ? "Здесь появятся посты райдеров, на которых ты подписан." : "Пока нет новых публикаций.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        RiderFeedCard(post: entry.post, author: entry.author, username: entry.username, avatar: entry.avatar,
                                      entry: entry, onConversation: { conversation = $0 })
                    }
                } else if failed {
                    Button("Повторить загрузку") { Task { await load(feed) } }
                } else {
                    ProgressView("Загружаем ленту")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(alignment: .top) {
                GeometryReader { geometry in
                    Color.clear.preference(key: RiderFeedTopPreference.self,
                                           value: geometry.frame(in: .named(feedViewport)).minY.rounded())
                }
                .frame(height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: feedViewport)
        .onChange(of: storiesExpanded) { _, expanded in
            if expanded { storiesOpenedAt = feedTop }
        }
        .onPreferenceChange(RiderFeedTopPreference.self) { [topPosition = $feedTop, expanded = $storiesExpanded,
                                                             openedAt = $storiesOpenedAt] top in
            topPosition.wrappedValue = top
            if expanded.wrappedValue && abs(top - openedAt.wrappedValue) > 28 {
                expanded.wrappedValue = false
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .scrollContentBackground(.hidden).background(RiderTheme.canvas)
        .navigationDestination(item: $conversation) { RiderThreadView(peer: $0) }
        .task(id: feed) { await load(feed) }
        .refreshable { await load(feed) }
    }

    @MainActor private func load(_ feed: Feed) async {
        guard RiderCommunity.endpoint != nil, feed == selection else { return }
        if loadedFeed != feed { entries = nil }
        failed = false
        do {
            let result = try await RiderCommunity.feed(recommended: feed == .recommended)
            guard !Task.isCancelled, feed == selection else { return }
            loadedFeed = feed
            entries = result
        } catch {
            if !Task.isCancelled, feed == selection { failed = true }
        }
    }
}

struct RiderFeedCard: View {
    @EnvironmentObject private var social: RiderSocialStore
    let post: RiderPost
    let author: String
    let username: String?
    let avatar: Data?
    var editable = false
    var entry: RiderFeedEntry?
    var opensPost = true
    var openComments = false
    var onConversation: ((RiderPerson) -> Void)?
    var embedded = false
    @State private var pendingConversation: RiderPerson?
    @State private var changingReaction = false
    @State private var changingFollow = false
    @State private var changingRepost = false
    @State private var sharing = false
    @State private var showingReactions = false
    @State private var showingVideo = false
    @State private var showingComments = false
    @State private var didOpenComments = false
    @State private var confirmingJournalDelete = false
    @State private var updatingJournal = false
    @State private var error: String?

    private var reaction: RiderReaction {
        if post.publicURL != nil {
            return social.reactions[post.contentID] ?? entry?.reaction ?? RiderReaction(total: 0, mine: false, people: [])
        }
        let mine = social.localShakas.contains(post.id.uuidString)
        let user = RiderPerson(id: "local", name: author, username: username, avatar: avatar)
        return RiderReaction(total: mine ? 1 : 0, mine: mine, people: mine ? [user] : [])
    }

    private var commentSummary: RiderCommentSummary? {
        social.commentSummaries[post.contentID] ?? entry?.commentSummary
    }

    private var following: Bool {
        entry?.authorID.flatMap { social.follows[$0] } ?? entry?.following ?? false
    }

    private var reposted: Bool {
        social.reposted[post.contentID] ?? entry?.reposted ?? false
    }

    var body: some View {
        Group {
            if embedded { content } else { content.lagoonCard() }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 7, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .sheet(isPresented: $sharing, onDismiss: openSentConversation) { shareMenu }
        .sheet(isPresented: $showingReactions) { reactionsSheet }
        .sheet(isPresented: $showingComments) { RiderCommentsView(postID: post.contentID) }
        .fullScreenCover(isPresented: $showingVideo) { RiderClipPlayer(post: post) }
        .confirmationDialog("Удалить заметку?", isPresented: $confirmingJournalDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { updateJournal(deleting: true) }
        }
        .task(id: post.publicURL) {
            if openComments, !didOpenComments, post.publicURL != nil {
                didOpenComments = true
                showingComments = true
            }
            await loadInitialReaction()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if let source = post.sourceAuthor {
                RiderLinkedText(text: "Репост · " + riderHandle(post.sourceUsername, or: source))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if post.showsMedia {
                if post.publicationSection == .journal {
                    postPhoto
                } else if post.isVideo {
                    Button { showingVideo = true } label: { postPhoto }
                        .buttonStyle(.plain).accessibilityLabel("Смотреть видео")
                } else if !opensPost {
                    postPhoto
                } else {
                    NavigationLink { detail() } label: { postPhoto }
                        .buttonStyle(.plain).accessibilityLabel("Открыть пост \(author)")
                }
            }
            if let location = post.location {
                Label(location.name, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
            }

            if post.publicationSection == .journal { caption }
            if post.equipment != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actions.fixedSize(horizontal: true, vertical: false)
                        RiderPostEquipmentTag(equipment: post.equipment)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        actions
                        RiderPostEquipmentTag(equipment: post.equipment)
                    }
                }
            } else {
                actions
            }
            if reaction.total > 0 { reactionSummary }
            if post.publicationSection == .gallery { caption }
            if opensPost, let preview = commentSummary?.preview {
                RiderLinkedText(text: preview.text, author: riderHandle(preview.username, or: preview.author), authorID: preview.username)
                    .font(.caption).lineLimit(2)
            }
            RiderPostDate(date: post.date)
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var caption: some View {
        if !post.caption.isEmpty {
            RiderLinkedText(text: post.caption)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func openSentConversation() {
        guard let peer = pendingConversation else { return }
        pendingConversation = nil
        onConversation?(peer)
    }

    private var postPhoto: some View {
        RiderPostSquare(post: post).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @MainActor private func loadInitialReaction() async {
        let id = post.contentID
        guard editable, post.publicURL != nil,
              social.reactions[id] == nil || social.commentSummaries[id] == nil else { return }
        guard let response = try? await RiderCommunity.postDetails(id), !Task.isCancelled else { return }
        if !changingReaction && social.reactions[id] == nil { social.reactions[id] = response.reaction }
        if social.commentSummaries[id] == nil { social.commentSummaries[id] = response.commentSummary }
    }

    private var header: some View {
        HStack {
            if let id = entry?.authorID {
                NavigationLink { RiderPublicProfileView(id: id) } label: {
                    RiderPostHeader(author: author, username: username, avatar: avatar, premium: entry?.premium ?? (editable ? social.myPremium : nil))
                }.buttonStyle(.borderless)
            } else {
                RiderPostHeader(author: author, username: username, avatar: avatar, premium: entry?.premium ?? (editable ? social.myPremium : nil))
            }
            if let target = entry?.authorID, entry?.mine != true {
                Button { toggleFollow(target) } label: {
                    RiderFollowIcon(following: following)
                }
                .buttonStyle(.plain)
                .disabled(changingFollow)
                .accessibilityLabel(following ? "Отписаться" : "Подписаться")
                .accessibilityAddTraits(following ? .isSelected : [])
            }
            if editable && !embedded && post.publicationSection == .journal {
                Menu {
                    if RiderCommunity.endpoint != nil && post.published != true {
                        Button("Опубликовать", systemImage: "arrow.up.circle") { updateJournal(deleting: false) }
                    }
                    Button("Удалить", systemImage: "trash", role: .destructive) { confirmingJournalDelete = true }
                } label: {
                    RiderCompactAction(icon: "ellipsis")
                }
                .disabled(updatingJournal)
                .accessibilityLabel("Действия с заметкой")
            }
        }
    }

    private func updateJournal(deleting: Bool) {
        guard !updatingJournal else { return }
        updatingJournal = true
        error = nil
        Task {
            defer { updatingJournal = false }
            do {
                if deleting { try await social.delete(post) }
                else { try await social.publish(post) }
            } catch {
                showActionError(error)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: toggleShaka) {
                HStack(spacing: 4) {
                    RiderShakaIcon(selected: reaction.mine)
                    Text(reaction.total.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
                }
                .padding(.horizontal, 7)
                .frame(minWidth: 48, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(RiderReactionPress { showingReactions = true })
            .disabled(changingReaction)
            .accessibilityLabel(reaction.mine ? "Убрать шаку" : "Поставить шаку")
            .accessibilityValue(reaction.total.formatted())
            .accessibilityAddTraits(reaction.mine ? .isSelected : [])
            Button { showingComments = true } label: { commentIcon }
            .disabled(post.publicURL == nil)
            .buttonStyle(.borderless)
            .accessibilityLabel("Комментарии")
            .accessibilityValue((commentSummary?.total ?? 0).formatted())
            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 44, height: 44)
                    .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Поделиться")
        }
        .foregroundStyle(RiderTheme.accent)
    }

    private var commentIcon: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble").font(.title3)
            if let total = commentSummary?.total, total > 0 {
                Text(total.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var reactionSummary: some View {
        HStack(spacing: 5) {
            Button { showingReactions = true } label: {
                HStack(spacing: -6) {
                    ForEach(reaction.people) { rider in
                        RiderAvatar(photo: rider.avatar ?? Data(), size: 22)
                    }
                }
            }.accessibilityLabel("Кто поставил шаку")
            if let first = reaction.people.first {
                RiderLinkedText(text: "Шака от " + first.handle)
            }
            if reaction.total > 1 {
                Button { showingReactions = true } label: { Text("и ещё \(reaction.total - 1)") }
            }
        }.font(.caption).buttonStyle(.borderless)
    }

    private var reactionsSheet: some View {
        RiderReactionList(title: "Шака", preview: reaction, fetch: post.publicURL == nil ? nil : { offset in
            try await RiderCommunity.shakas(for: post.contentID, offset: offset)
        })
    }

    private var shareMenu: some View {
        NavigationStack {
            List {
                if let url = post.publicURL {
                    if onConversation != nil {
                        NavigationLink {
                            RiderInboxView(shared: post, onSent: { peer in
                                pendingConversation = peer
                                sharing = false
                            })
                        } label: {
                            Label("Отправить в сообщениях", systemImage: "paperplane")
                        }
                    }
                    if (entry != nil && entry?.mine != true) || reposted {
                        Button {
                            toggleRepost()
                        } label: {
                            Label(reposted ? "Убрать репост" : "Репост в профиль", systemImage: "arrow.2.squarepath")
                        }
                        .disabled(changingRepost)
                    }
                    if !RiderCommunity.usesLANTrust {
                        ShareLink(item: url) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                    }
                }
                if post.publicationSection == .journal && !post.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ShareLink(item: post.caption) { Label("Поделиться текстом", systemImage: "text.alignleft") }
                    Button {
                        UIPasteboard.general.string = post.caption
                        sharing = false
                    } label: {
                        Label("Скопировать текст", systemImage: "doc.on.doc")
                    }
                }
                if let bytes = post.photo, let image = UIImage(data: bytes) {
                    ShareLink(item: RiderPostPhoto(bytes: bytes),
                              message: Text(post.caption), preview: SharePreview("Фото Rider", image: Image(uiImage: image))) {
                        Label("Поделиться фото", systemImage: "square.and.arrow.up")
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Поделиться")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { sharing = false } } }
        }
    }

    private func detail() -> some View {
        RiderPostDetail(original: post, author: author, username: username, avatar: avatar,
                        editable: editable, entry: entry)
    }

    private func toggleShaka() {
        guard post.publicURL != nil else {
            social.toggleLocalShaka(for: post.id)
            return
        }
        let next = !reaction.mine
        changingReaction = true
        error = nil
        Task {
            defer { changingReaction = false }
            do { social.reactions[post.contentID] = try await RiderCommunity.reaction(for: post.contentID, enabled: next) }
            catch { showActionError(error) }
        }
    }

    private func toggleFollow(_ target: String) {
        let next = !following
        changingFollow = true
        error = nil
        Task {
            defer { changingFollow = false }
            do {
                try await RiderCommunity.follow(target, enabled: next)
                social.follows[target] = next
            } catch { showActionError(error) }
        }
    }

    private func toggleRepost() {
        let next = !reposted
        changingRepost = true
        error = nil
        Task {
            defer { changingRepost = false }
            do {
                try await RiderCommunity.repost(post.contentID, enabled: next)
                social.reposted[post.contentID] = next
                await social.refreshReposts()
                sharing = false
            } catch { showActionError(error) }
        }
    }

    private func showActionError(_ failure: Error) {
        if case RiderCommunity.Rejection.forbidden = failure {
            error = "Сначала опубликуй профиль во вкладке «Райдер»."
        } else {
            error = "Не удалось сохранить действие. Попробуй ещё раз."
        }
    }
}

private struct RiderShakaIcon: View {
    let selected: Bool
    @ScaledMetric(relativeTo: .title3) private var size = 23.0

    var body: some View {
        RiderShakaShape()
            .fill(selected ? RiderTheme.accent.opacity(0.20) : .clear)
            .overlay {
                RiderShakaShape()
                    .stroke(RiderTheme.accent, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct RiderShakaShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 12) * scale, y: rect.midY + (y - 12) * scale)
        }

        // The thumb and pinky extend away from the three folded fingers.
        var path = Path()
        path.move(to: point(9, 21))
        path.addQuadCurve(to: point(5.8, 17.3), control: point(6.8, 20))
        path.addLine(to: point(2.4, 13.2))
        path.addQuadCurve(to: point(4.7, 10.8), control: point(0.6, 10.6))
        path.addLine(to: point(7.6, 12.8))
        path.addLine(to: point(7.6, 9.7))
        path.addQuadCurve(to: point(10.9, 9.1), control: point(8.1, 6.8))
        path.addQuadCurve(to: point(14.1, 9.2), control: point(12.6, 7.2))
        path.addQuadCurve(to: point(17, 10), control: point(15.8, 8.4))
        path.addLine(to: point(19.1, 5))
        path.addQuadCurve(to: point(22.2, 5.9), control: point(21.1, 2.8))
        path.addLine(to: point(20.6, 12.6))
        path.addQuadCurve(to: point(16.6, 20.7), control: point(19.3, 18.8))
        path.addQuadCurve(to: point(9, 21), control: point(13.4, 22.3))
        path.closeSubpath()

        path.move(to: point(10.9, 9.1))
        path.addLine(to: point(10.9, 12))
        path.move(to: point(14.1, 9.2))
        path.addLine(to: point(14.1, 12.3))
        return path
    }
}

private struct RiderPostPhoto: Transferable {
    let bytes: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.bytes }
    }
}

private struct RiderPostEquipmentTag: View {
    let equipment: RiderPostEquipment?
    @State private var showing = false

    var body: some View {
        if let equipment {
            Button { showing = true } label: {
                Label { Text(equipment.name) } icon: { EquipmentGlyph(kind: .kite).rendered().frame(width: 15, height: 16) }
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .foregroundStyle(RiderTheme.accent)
                    .background(RiderTheme.canvas, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(.interaction, Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Кайт-комплект \(equipment.name)")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(equipment.name).font(.headline)
                    Label { Text(equipment.kite) } icon: { EquipmentGlyph(kind: .kite).rendered().frame(width: 18, height: 20) }
                    Label { Text(equipment.board) } icon: { EquipmentGlyph(kind: .board).rendered().frame(width: 18, height: 20) }
                }
                .padding(20)
                .presentationCompactAdaptation(.popover)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct RiderPostDate: View {
    let date: Date
    var body: some View {
        TimelineView(.everyMinute) { context in
            let calendar = Calendar.current
            let day = calendar.isDate(date, inSameDayAs: context.date) ? "Сегодня" :
                (calendar.date(byAdding: .day, value: -1, to: context.date).map { calendar.isDate(date, inSameDayAs: $0) } == true
                 ? "Вчера" : date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "ru_RU"))))
            Text("\(day), \(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ru_RU"))))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RiderSharedPostView: View {
    let id: UUID
    var openComments = false
    @State private var entry: RiderFeedEntry?
    @State private var failed = false

    var body: some View {
        Group {
            if let entry {
                RiderPostDetail(original: entry.post, author: entry.author, username: entry.username, avatar: entry.avatar, openComments: openComments, entry: entry)
            } else if failed {
                ContentUnavailableView("Публикация недоступна", systemImage: "photo")
            } else {
                ProgressView().padding(24)
            }
        }
        .background(RiderTheme.canvas)
        .navigationTitle("Публикация")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) {
            do { entry = try await RiderCommunity.postDetails(id) }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct RiderNotificationsView: View {
    @EnvironmentObject private var social: RiderSocialStore
    private struct Batch: Decodable { let items: [RiderActivity]; let sequence: Int }
    @State private var items: [RiderActivity]?
    @ObservedObject private var sos = RiderSOSService.shared
    @State private var failed = false
    @State private var changing = false
    @State private var clearPrompt = false
    @State private var mutationError: String?
    @State private var allowsDrill = false
    @State private var sendingDrill = false

    var body: some View {
        List {
            Button { sos.open() } label: {
                Label("SOS рядом", systemImage: "dot.radiowaves.left.and.right")
            }
            if allowsDrill {
                Button {
                    Task { await drill() }
                } label: { Label("Отправить учебный SOS себе", systemImage: "antenna.radiowaves.left.and.right") }
                .disabled(sendingDrill)
            }
            if let mutationError { Text(mutationError).font(.footnote).foregroundStyle(.secondary) }
            if RiderCommunity.endpoint == nil {
                ContentUnavailableView("Уведомления", systemImage: "bell",
                                       description: Text("Уведомления появятся после подключения сервера Rider."))
            } else if let items {
                if items.isEmpty {
                    ContentUnavailableView("Пока тихо", systemImage: "bell",
                                           description: Text("Здесь появятся реакции, комментарии, репосты и подписки."))
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        NavigationLink { RiderPublicProfileView(id: item.person.id) } label: { activityRow(item) }
                            .buttonStyle(.borderless)
                        if let post = item.postID {
                            NavigationLink {
                                RiderSharedPostView(id: post, openComments: item.kind == "reply" || item.kind == "comment")
                            } label: { Text("К публикации").font(.caption) }.buttonStyle(.borderless)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if let id = item.id {
                            Button(role: .destructive) { Task { await remove(id) } } label: {
                                Label("Удалить", systemImage: "trash")
                            }.disabled(changing)
                        }
                    }
                }
            } else if failed {
                Button("Повторить загрузку") { Task { await load() } }
            } else {
                ProgressView("Загружаем уведомления")
            }
        }
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas)
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Очистить все") { clearPrompt = true }
                    .disabled(changing || items?.isEmpty != false)
            }
        }
        .confirmationDialog("Очистить все уведомления?", isPresented: $clearPrompt, titleVisibility: .visible) {
            Button("Очистить все", role: .destructive) { Task { await remove(nil) } }
        }
        .task {
            allowsDrill = await sos.allowsDrill()
            await load()
        }
        .onChange(of: social.unread.activity) { _, count in if count > 0 { Task { await load() } } }
        .refreshable { await load() }
    }

    private func activityRow(_ item: RiderActivity) -> some View {
        HStack(spacing: 10) {
            RiderAvatar(photo: item.person.avatar ?? Data(), size: 38)
            VStack(alignment: .leading, spacing: 3) {
                (Text(item.person.handle).bold() + Text(" " + item.description)).font(.subheadline)
                RiderPostDate(date: Date(timeIntervalSince1970: item.createdAt))
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor private func drill() async {
        guard !sendingDrill else { return }
        sendingDrill = true
        defer { sendingDrill = false }
        do {
            try await sos.requestDrill()
            NotificationCenter.default.post(name: RiderSOSService.drillNotification, object: nil)
        } catch { mutationError = "Учебный сигнал не отправился." }
    }

    @MainActor private func remove(_ id: String?) async {
        guard !changing else { return }
        changing = true
        mutationError = nil
        defer { changing = false }
        do {
            let counts: RiderUnread
            if let id {
                counts = try await RiderCommunity.decode("activity/hide", method: "PUT", body: JSONEncoder().encode(["id":id]))
                items?.removeAll { $0.id == id }
            } else {
                counts = try await RiderCommunity.decode("activity", method: "DELETE")
                items = []
            }
            social.acceptUnread(counts)
            await load()
        } catch { mutationError = "Не удалось удалить уведомление. Попробуй ещё раз." }
    }

    @MainActor private func load() async {
        guard RiderCommunity.endpoint != nil else { return }
        do {
            let batch: Batch = try await RiderCommunity.decode("activity/read")
            guard !Task.isCancelled else { return }
            items = batch.items
            failed = false
            if let counts = try? await RiderCommunity.readActivity(through: batch.sequence) { social.acceptUnread(counts) }
        } catch { if !Task.isCancelled { failed = true } }
    }
}

struct RiderInboxView: View {
    @EnvironmentObject private var social: RiderSocialStore
    var shared: RiderPost?
    var onSent: ((RiderPerson) -> Void)?
    @State private var sending = false
    @State private var sendError: String?
    @State private var deliveryIDs: [String: UUID] = [:]
    @State private var people: [RiderPerson]?
    @State private var composing = false
    @State private var failed = false
    @State private var search = ""

    private var choosingRecipient: Bool { shared != nil || composing }
    private var query: String { RiderSearch.query(search) }

    var body: some View {
        List {
            if RiderCommunity.endpoint == nil {
                ContentUnavailableView("Сообщения", systemImage: "paperplane",
                                       description: Text("Личные сообщения появятся после подключения сервера Rider."))
            } else if let people {
                if people.isEmpty {
                    Text(choosingRecipient ? "Пока нет доступных райдеров." : "Пока нет переписок.")
                        .foregroundStyle(.secondary)
                }
                if let sendError { Text(sendError).font(.footnote).foregroundStyle(.secondary) }
                if sending { ProgressView("Отправляем пост") }
                Section(query.isEmpty ? "" : choosingRecipient ? "Получатели" : "Переписки") {
                    let matches = people.filter { RiderSearch.matches($0, query: query) }
                    if !query.isEmpty && matches.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
                    ForEach(matches) { recipientRow($0) }
                }
            } else if failed {
                Button("Повторить загрузку") { Task { await load() } }
            } else {
                ProgressView()
            }
            if RiderCommunity.endpoint != nil {
                RiderGlobalSearchSection(query: query, excluding: Set((people ?? []).map(\.id))) { recipientRow($0) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas)
        .searchable(text: $search, prompt: "Имя или @юзернейм")
        .navigationTitle(shared != nil ? "Кому отправить" : composing ? "Новое сообщение" : "Сообщения")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if RiderCommunity.endpoint != nil && shared == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { people = nil; composing.toggle() } label: {
                        Label(composing ? "Переписки" : "Новое сообщение", systemImage: composing ? "tray" : "square.and.pencil")
                    }
                }
            }
        }
        .task(id: choosingRecipient) { await load() }
        .onChange(of: social.unread.threads) { _, _ in if !choosingRecipient { Task { await load() } } }
        .refreshable { await load() }
    }

    @ViewBuilder private func recipientRow(_ rider: RiderPerson) -> some View {
        if let shared {
            Button { send(shared, to: rider) } label: { personRow(rider) }
                .buttonStyle(.plain).disabled(sending)
        } else {
            NavigationLink { RiderThreadView(peer: rider) } label: { personRow(rider) }
        }
    }

    private func personRow(_ rider: RiderPerson) -> some View {
        HStack {
            RiderPostHeader(author: rider.name, username: rider.username, avatar: rider.avatar, premium: rider.premium)
            if !choosingRecipient, let count = social.unread.threads[rider.id], count > 0 {
                Text(count.formatted()).font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4).background(.red, in: Capsule())
                    .accessibilityLabel("\(count) непрочитанных")
            }
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private func send(_ post: RiderPost, to rider: RiderPerson) {
        guard !sending else { return }
        sending = true
        sendError = nil
        let id = deliveryIDs[rider.id, default: UUID()]
        deliveryIDs[rider.id] = id
        Task {
            defer { sending = false }
            do {
                _ = try await RiderCommunity.sendMessage(to: rider.id, id: id, text: "", post: post.contentID)
                onSent?(rider)
            } catch RiderCommunity.Rejection.forbidden {
                sendError = "Включи публичный профиль во вкладке «Райдер», чтобы отправить пост."
            } catch {
                sendError = "Не удалось отправить пост. Попробуй ещё раз."
            }
        }
    }

    @MainActor private func load() async {
        guard RiderCommunity.endpoint != nil else { return }
        let choosing = choosingRecipient
        do {
            let result = choosing ? try await RiderCommunity.recipients() : try await RiderCommunity.conversations()
            if !Task.isCancelled && choosing == choosingRecipient { people = result; failed = false }
        } catch {
            if !Task.isCancelled && choosing == choosingRecipient { failed = true }
        }
    }
}

struct RiderThreadView: View {
    @EnvironmentObject private var social: RiderSocialStore
    @Environment(\.scenePhase) private var phase
    let peer: RiderPerson
    @StateObject private var playback = RiderChatPlayer()
    @StateObject private var recorder = RiderChatRecorder()
    private var chatStyle = RiderChatStyle()
    @State private var conversation: RiderPerson?
    @State private var messages: [RiderMessage]?
    @State private var messageRevision = 0
    @State private var visible = false
    @State private var sendingAt: Date?
    @State private var draft = ""
    @State private var draftID = UUID()
    @State private var sending = false
    @FocusState private var composingText: Bool
    @State private var pickingPhoto = false
    @State private var cameraPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var attachment: RiderChatUpload?
    @State private var preparingAttachment = false
    @State private var error: String?

    init(peer: RiderPerson) {
        self.peer = peer
    }

    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            RiderChatPlayerBar(playback: playback)
            chatViewport
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .task(id: photo) { await attachPhoto() }
        .fullScreenCover(isPresented: $cameraPhoto) {
            RiderCameraPhoto(selected: attachCapturedPhoto)
                .ignoresSafeArea()
        }
        .background {
            RiderChatBackdrop(wallpaper: chatStyle.wallpaper, dark: chatStyle.isDark)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink { RiderPublicProfileView(id: peer.id) } label: {
                    HStack(spacing: 7) {
                        RiderAvatar(photo: peer.avatar ?? Data(), size: 30).accessibilityHidden(true)
                        RiderName(peer.handle, premium: peer.premium)
                            .font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.interaction, Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .navigationDestination(item: $conversation) { RiderThreadView(peer: $0) }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            recorder.cancelPress()
            recorder.discard()
            playback.close()
        }
        .onChange(of: phase) { _, phase in
            if phase == .background {
                recorder.cancelPress()
                recorder.discard()
            }
        }
        .task(id: visible && phase == .active) {
            guard visible, phase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    private var chatViewport: some View {
        GeometryReader { viewport in
            ZStack {
                if let messages {
                    messageHistory(messages)
                } else {
                    ScrollView {
                        if error == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(20)
                        }
                    }
                    .refreshable { await load() }
                }
                if let preview = recorder.preview, recorder.beganAt != nil {
                    RiderCircleRecordingStage(session: preview, recorder: recorder)
                }
            }
            // Clip after flipping the scrolling view so messages cannot enter the toolbar or composer.
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
        }
    }

    private func messageHistory(_ messages: [RiderMessage]) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .id("threadLatest")
                    // The newest bubbles are measured first, even if older attachments have variable heights.
                    LazyVStack(spacing: 9) {
                        if let sendingAt {
                            sendingBubble(at: sendingAt)
                                .scaleEffect(x: 1, y: -1)
                        }
                        ForEach(messages.reversed()) { message in
                            bubble(message)
                                .scaleEffect(x: 1, y: -1)
                        }
                    }
                    .padding(14)
                }
            }
            .scaleEffect(x: 1, y: -1)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: messages.last?.id) { _, _ in
                scroll.scrollTo("threadLatest", anchor: .top)
            }
            .onChange(of: sendingAt != nil) { _, sending in
                if sending { scroll.scrollTo("threadLatest", anchor: .top) }
            }
            .refreshable { await load() }
        }
    }

    private func sendingBubble(at date: Date) -> some View {
        HStack {
            if let attachment {
                Text(attachment.contentType.hasPrefix("image/") ? "Фото" : attachment.contentType == "audio/mp4" ? "Голосовое" : "Кружочек")
            }
            if !text.isEmpty { Text(text) }
            RiderPostDate(date: date)
            receipt(delivered: false, read: false)
        }
        .font(.caption).padding(10)
        .background { chatStyle.bubble(mine: true) }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if let attachment {
                HStack {
                    Label(attachment.filename, systemImage: "paperclip").font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        self.attachment = nil
                        draftID = UUID()
                    } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel("Убрать вложение")
                    .disabled(sending)
                }
            }
            RiderMentionSuggestions.forText($draft, editing: composingText, limit: 1000)
            HStack(alignment: .center, spacing: 8) {
                if recorder.beganAt != nil {
                    RiderRecordingStatus(recorder: recorder)
                } else {
                    messageInput
                        .frame(maxWidth: .infinity)
                }
                if text.isEmpty && attachment == nil {
                    RiderChatCapture(recorder: recorder, event: recordEvent)
                        .disabled(sending || preparingAttachment)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.body.bold())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.interaction, Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Отправить")
                    .disabled(sending || preparingAttachment || recorder.busy)
                }
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .topTrailing) {
            if recorder.beganAt != nil && !recorder.locked {
                VStack(spacing: 5) {
                    Image(systemName: "lock.open").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up").font(.caption.weight(.bold))
                }
                .foregroundStyle(RiderChatCapture.blue)
                .frame(width: 44, height: 52)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                .offset(x: -16, y: -62)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private var messageInput: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { composingText = false; pickingPhoto = true } label: { Label("Медиатека", systemImage: "photo.on.rectangle") }
                Button {
                    composingText = false
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraPhoto = true }
                    else { error = "Камера недоступна на этом устройстве." }
                } label: { Label("Сделать фото", systemImage: "camera") }
            } label: {
                Image(systemName: "photo").font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.interaction, Rectangle())
            }
            .accessibilityLabel("Добавить изображение")
            .disabled(sending || preparingAttachment || recorder.busy)
            TextField("Сообщение", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                .focused($composingText)
                .onChange(of: draft) { _, value in
                    if !sending { draftID = UUID() }
                    if value.count > 1000 { draft = String(value.prefix(1000)) }
                }
                .disabled(sending || recorder.busy)
        }
    }

    private func recordEvent(_ event: RiderChatRecorder.Event) {
        switch event {
        case .began:
            playback.close()
            composingText = false
            error = nil
        case .captured(let upload):
            attachment = upload
            draftID = UUID()
            send()
        case .failed(let message):
            error = message
        }
    }

    private func bubble(_ message: RiderMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let entry = message.sharedPost {
                RiderFeedCard(post: entry.post, author: entry.author, username: entry.username, avatar: entry.avatar,
                              entry: entry, onConversation: { conversation = $0 })
                    .frame(maxWidth: 330)
            } else if let post = message.postID {
                Label("Публикация недоступна", systemImage: "photo").font(.subheadline)
                    .accessibilityIdentifier(post.uuidString)
            }
            if let attachment = message.attachment {
                RiderChatAttachmentView(attachment: attachment, message: message.id, peer: peer.id,
                                        author: message.mine ? "Ты" : peer.name, playback: playback)
            }
            if !message.text.isEmpty { RiderLinkedText(text: message.text, linkTint: chatStyle.linkColor) }
            HStack(spacing: 4) {
                RiderPostDate(date: Date(timeIntervalSince1970: message.createdAt))
                if message.mine { receipt(delivered: message.delivered == true, read: message.read == true) }
            }
        }
        .padding(10)
        .background { chatStyle.bubble(mine: message.mine) }
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    private func receipt(delivered: Bool, read: Bool) -> some View {
        HStack(spacing: -4) {
            Image(systemName: "checkmark")
            if delivered || read { Image(systemName: "checkmark") }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(read ? chatStyle.linkColor : Color.secondary)
        .accessibilityLabel(read ? "Прочитано" : delivered ? "Доставлено" : "Ожидает доставки")
    }

    @MainActor private func load() async {
        guard !sending else { return }
        let revision = messageRevision
        do {
            let result = try await RiderCommunity.messages(with: peer.id)
            guard !Task.isCancelled, !sending, revision == messageRevision, visible else { return }
            messages = result
            error = nil
            let incoming = result.filter { !$0.mine && $0.read != true }.map(\.id)
            if phase == .active, !incoming.isEmpty,
               let counts = try? await RiderCommunity.readMessages(from: peer.id, ids: incoming) {
                social.acceptUnread(counts)
            }
        } catch {
            if !Task.isCancelled && !sending && revision == messageRevision { self.error = "Не удалось загрузить переписку." }
        }
    }

    private func send() {
        let body = text
        let upload = attachment
        let id = draftID
        guard !sending, !preparingAttachment, !body.isEmpty || upload != nil else { return }
        composingText = false
        sending = true
        sendingAt = Date()
        error = nil
        Task {
            defer { sending = false; sendingAt = nil }
            do {
                let result = try await RiderCommunity.sendMessage(to: peer.id, id: id, text: body,
                                                                  post: nil, attachment: upload)
                if let upload, let circle = result.first(where: { $0.id == id && $0.mine })?.attachment,
                   circle.isCircle, circle.filename == upload.filename, circle.size == upload.data.count,
                   let file = try? RiderChatFile(message: id, filename: circle.filename) {
                    try? file.store(upload.data)
                }
                messages = result
                messageRevision += 1
                draftID = UUID()
                draft = ""
                attachment = nil
                composingText = false
            } catch RiderCommunity.Rejection.forbidden {
                error = "Сначала опубликуй профиль во вкладке «Райдер»."
            } catch {
                self.error = "Не удалось отправить сообщение. Попробуй ещё раз."
            }
        }
    }
    @MainActor private func attachPhoto() async {
        guard let photo else { return }
        preparingAttachment = true
        defer { preparingAttachment = false; self.photo = nil }
        do {
            guard let source = try await photo.loadTransferable(type: Data.self),
                  let bytes = RiderPostComposer.postJPEG(source, forChat: true) else { throw CocoaError(.fileReadCorruptFile) }
            guard !Task.isCancelled else { return }
            attachment = try RiderChatUpload(filename: "Фото Rider.jpg", contentType: "image/jpeg", data: bytes)
            draftID = UUID()
            error = nil
        } catch {
            if !Task.isCancelled { self.error = "Не удалось подготовить фото." }
        }
    }

    private func attachCapturedPhoto(_ image: UIImage) {
        do {
            guard let data = image.jpegData(compressionQuality: 0.85),
                  let bytes = RiderPostComposer.postJPEG(data, forChat: true) else { throw CocoaError(.fileReadCorruptFile) }
            attachment = try RiderChatUpload(filename: "rider.jpg", contentType: "image/jpeg", data: bytes)
            draftID = UUID()
            error = nil
        } catch {
            self.error = "Не удалось подготовить снимок."
        }
    }
}

private struct RiderChatAttachmentView: View {
    let attachment: RiderChatAttachment
    let message: UUID
    let peer: String
    let author: String
    let playback: RiderChatPlayer
    @State private var fullScreenPhoto: URL?
    @State private var shareFile: RiderChatFile?
    @State private var preview: UIImage?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if attachment.showsPhoto, let preview, let shareFile {
                Button { fullScreenPhoto = shareFile.url } label: {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("Открыть фото во весь экран")
            } else if let shareFile, attachment.isVoice || attachment.isCircle {
                RiderChatPlayback(url: shareFile.url, circle: attachment.isCircle, message: message, title: author, playback: playback)
            } else if let shareFile {
                ShareLink(item: shareFile, preview: SharePreview(attachment.filename)) { label("square.and.arrow.up") }
            } else if attachment.showsPhoto && !failed {
                ProgressView("Загрузка фото").font(.caption)
            } else {
                Button { Task { await prepare() } } label: { label("arrow.down.circle") }
                    .disabled(loading).buttonStyle(.plain)
            }
            if failed { Text("Не удалось загрузить вложение.").font(.caption2).foregroundStyle(.secondary) }
        }
        .quickLookPreview($fullScreenPhoto)
        .task(id: message) { if attachment.showsPhoto || attachment.isVoice || attachment.isCircle { await prepare() } }
    }

    private func label(_ icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } icon: {
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: icon).foregroundStyle(RiderTheme.accent) }
        }
    }

    @MainActor private func prepare() async {
        guard !loading, shareFile == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let file = try RiderChatFile(message: message, filename: attachment.filename)
            guard attachment.size > 0, attachment.size <= RiderChatUpload.maxBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if attachment.isCircle,
               (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == attachment.size,
               FileManager.default.isReadableFile(atPath: file.url.path) {
                shareFile = file
                failed = false
                return
            }
            let data = try await RiderCommunity.attachment(for: message, with: peer)
            guard !Task.isCancelled else { return }
            guard data.count == attachment.size else { throw CocoaError(.fileReadCorruptFile) }
            try file.store(data)
            if attachment.showsPhoto,
               let thumbnail = RiderPostComposer.postJPEG(data) { preview = UIImage(data: thumbnail) }
            shareFile = file
            failed = false
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct RiderChatFile: Transferable {
    let url: URL

    init(message: UUID, filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.contains("\\"), !filename.contains(":") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        url = FileManager.default.temporaryDirectory.appendingPathComponent("rider-chat", isDirectory: true)
            .appendingPathComponent(message.uuidString, isDirectory: true)
            .appendingPathComponent(filename)
    }

    func store(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
    }
}

struct RiderTopsView: View {
    @EnvironmentObject private var social: RiderSocialStore
    @Environment(\.dynamicTypeSize) private var textSize
    @ObservedObject var recorder: SessionRecorder
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.username") private var username = ""
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @State private var score = RiderTopMetric.height
    @State private var period = RiderTopPeriod.all
    @State private var spotID: UUID?
    @State private var choosingSpot = false
    @State private var remote: RiderTopPage?
    @State private var failed = false
    @State private var loadedFilter: RiderTopFilter?

    private struct RequestKey: Equatable {
        let filter: RiderTopFilter
        let revision: Int
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ranking(at: max(context.date, Date()))
        }
    }

    private func ranking(at now: Date) -> some View {
        let progress = social.progress(recorder.history, at: now)
        let spot = score == .rank ? nil : recorder.spots.first { $0.id == spotID }
        let interval = score == .rank ? nil : period.interval(at: now)
        let filter = RiderTopFilter(metric: score.rawValue, spotID: spot?.id, spot: spot?.name,
                                    startAt: interval?.start.timeIntervalSince1970,
                                    endAt: interval?.end.timeIntervalSince1970,
                                    season: score == .rank ? progress.year : nil)
        let isLocal = RiderCommunity.endpoint == nil || (failed && loadedFilter == filter)
        let entries = isLocal ? localRows(spot: spot, filter: filter, progress: progress) : (loadedFilter == filter ? remote?.leaders : nil)
        return List {
            filters(spot: spot)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            if let entries {
                Section(isLocal ? (score == .rank ? "Мой результат" : "Мои рекорды") : "Топ-50") {
                    if isLocal {
                        Text(RiderCommunity.endpoint == nil
                             ? "Общий рейтинг появится после подключения сервера Rider."
                             : "Общий рейтинг недоступен. Показан личный результат.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if entries.isEmpty {
                        Text(score == .rank ? "В этом сезоне пока нет участников." : "В этом диапазоне пока нет рекордов.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index < 3 {
                            podiumRow(entry, place: index + 1)
                        } else {
                            leaderboardRow(entry, place: index + 1)
                        }
                    }
                }
                if !isLocal {
                    Section {
                        let label = score == .rank ? "по уровню" : score == .height ? "по высоте" : score == .airtime ? "по зависанию" : "по дистанции"
                        if let place = remote?.myPlace {
                            Label("Твоё место \(label) · №\(place)", systemImage: "person.crop.circle")
                        } else {
                            Text("Пока нет результата для этого фильтра").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView("Загружаем рейтинг")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .scrollContentBackground(.hidden).background(RiderTheme.canvas)
        .sheet(isPresented: $choosingSpot) {
            RiderTopSpotPicker(spots: recorder.spots, selection: $spotID)
        }
        .task(id: RequestKey(filter: filter, revision: social.statisticsSynced)) { await load(filter) }
        .refreshable { await load(filter) }
    }

    private func filters(spot: RiderSpot?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if score != .rank {
                Menu {
                    Picker("Период", selection: $period) {
                        ForEach(RiderTopPeriod.allCases) { Text($0.title).tag($0) }
                    }
                } label: { filterLabel(period.title) }
                    .accessibilityLabel("Период, \(period.title)")
            }
            Menu {
                Picker("Показатель", selection: $score) {
                    ForEach([RiderTopMetric.rank, .height, .airtime, .distance]) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
            } label: { filterLabel(score.title) }
                .accessibilityLabel("Показатель, \(score.title)")
            if score != .rank {
                Button { choosingSpot = true } label: { filterLabel(spot?.name ?? "Все споты") }
                    .accessibilityLabel("Спот, \(spot?.name ?? "Все споты")")
            }
        }
        .buttonStyle(.plain)
    }

    private func filterLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.85)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(RiderTheme.accent)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RiderTheme.border).allowsHitTesting(false) }
        .contentShape(Rectangle())
    }

    private func podiumRow(_ entry: RiderTopEntry, place: Int) -> some View {
        let medal = place == 1 ? RiderTheme.gold : place == 2 ? RiderTheme.silver : RiderTheme.bronze
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(String(place)).font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 26, height: 26)
                    .foregroundStyle(medal)
                    .background(medal.opacity(0.16), in: Circle())
                    .accessibilityLabel("Место \(place)")
                RiderAvatar(photo: entry.avatar ?? Data(), size: 42).accessibilityHidden(true)
                riderName(entry)
                scoreValue(entry).font(.title3.bold())
                    .fixedSize(horizontal: true, vertical: false)
                    .multilineTextAlignment(.trailing)
            }
            if score != .rank { recordDetails(entry) }
        }
        .font(.footnote)
        .lagoonCard()
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private func recordDetails(_ entry: RiderTopEntry) -> some View {
        let speed = entry.windMS.map { metric($0, unit: "м/с") }
        let compass = SpotForecast.compass(entry.windDirection)
        let wind = [speed, compass == "—" ? nil : compass].compactMap { $0 }.joined(separator: " · ")
        if entry.kite != nil || entry.board != nil || entry.spot != nil || !wind.isEmpty {
            let column = GridItem(.flexible(), spacing: 12, alignment: .leading)
            LazyVGrid(columns: textSize.isAccessibilitySize ? [column] : [column, column], alignment: .leading, spacing: 8) {
                recordDetail("Кайт", value: entry.kite) { EquipmentGlyph(kind: .kite).rendered(lineWidth: 1.2) }
                recordDetail("Спот", value: entry.spot) {
                    Image(uiImage: RiderSpotIcon.image).resizable().scaledToFit()
                }
                recordDetail("Доска", value: entry.board) { EquipmentGlyph(kind: .board).rendered(lineWidth: 1.2) }
                recordDetail("Ветер", value: wind.isEmpty ? nil : wind) {
                    Image(systemName: "wind")
                }
            }
        }
    }

    private func recordDetail<Icon: View>(_ title: String, value: String?, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(alignment: .top, spacing: 5) {
            icon()
                .foregroundStyle(RiderTheme.accent)
                .frame(width: 19, height: 19)
                .accessibilityHidden(true)
            Text(value ?? "—")
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "Данные не указаны")
    }

    private func leaderboardRow(_ entry: RiderTopEntry, place: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(place)).monospacedDigit().foregroundStyle(RiderTheme.accent)
                .accessibilityLabel("Место \(place)")
            RiderAvatar(photo: entry.avatar ?? Data(), size: 32).accessibilityHidden(true)
            riderName(entry)
            scoreValue(entry).font(.headline)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func scoreValue(_ entry: RiderTopEntry) -> some View {
        HStack(spacing: 6) {
            if score == .rank, let points = entry.points {
                RiderRankBadge(rank: .forPoints(points), size: 28)
                Text("\(points.formatted()) ПТС").monospacedDigit()
            } else {
                Text(metric(entry.value(for: score), unit: score.unit)).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func riderName(_ entry: RiderTopEntry) -> some View {
        if entry.id == "local" {
            rankedRiderLabel(entry)
        } else {
            NavigationLink { RiderPublicProfileView(id: entry.id) } label: { rankedRiderLabel(entry) }
                .buttonStyle(.plain)
        }
    }

    private func rankedRiderLabel(_ entry: RiderTopEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RiderName(entry.name, premium: entry.premium)
                .font(.headline)
                .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.65)
            if let tag = entry.username, !tag.isEmpty {
                Text("@" + tag).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.interaction, Rectangle())
    }

    private func localRows(spot: RiderSpot?, filter: RiderTopFilter, progress: RiderSeasonProgress) -> [RiderTopEntry] {
        if score == .rank {
            guard progress.points > 0 else { return [] }
            return [RiderTopEntry(id: "local", name: name, username: username, height: nil,
                                  airtime: nil, distance: nil, avatar: photo, kite: nil, board: nil, points: progress.points)]
        }
        let matches = recorder.history.filter {
            (spot?.matches($0.setup) ?? true) && filter.contains($0.startedAt)
        }
        let records = RiderJumpScore.records(in: matches)
        guard let best = RiderJumpScore.best(for: score, in: records) else { return [] }
        let wind = matches.first { $0.id == best.id }?.wind
        let speed = wind.map { $0.knots * SessionWind.metersPerSecondPerKnot }
        return [RiderTopEntry(id: "local", name: name, username: username, height: best.height,
                              airtime: best.airtime, distance: best.distance, avatar: photo,
                              kite: best.kite, board: best.board, spot: best.spot,
                              windMS: speed.flatMap { (0...150).contains($0) ? $0 : nil }, windDirection: wind?.direction)]
    }

    @MainActor private func load(_ filter: RiderTopFilter) async {
        guard RiderCommunity.endpoint != nil else { return }
        do {
            let rows = try await RiderCommunity.tops(filter)
            guard !Task.isCancelled else { return }
            remote = rows
            failed = false
            loadedFilter = filter
        } catch {
            if !Task.isCancelled { failed = true; loadedFilter = filter }
        }
    }
}

struct EquipmentGlyph: Shape {
    enum Kind: Equatable { case kite, board }
    let kind: Kind

    @ViewBuilder
    func rendered(lineWidth: CGFloat = 1.5) -> some View {
        if kind == .kite {
            fill()
        } else {
            stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let (horizontal, vertical) = kind == .board ? (1 - y, x) : (x, y)
            return CGPoint(x: rect.minX + rect.width * horizontal, y: rect.minY + rect.height * vertical)
        }
        var shape = Path()
        if kind == .kite {
            shape.move(to: point(0.14, 0.54))
            shape.addCurve(to: point(0.48, 0.23), control1: point(0.16, 0.38), control2: point(0.33, 0.22))
            shape.addCurve(to: point(0.55, 0.34), control1: point(0.51, 0.23), control2: point(0.54, 0.27))
            shape.addCurve(to: point(0.24, 0.58), control1: point(0.52, 0.41), control2: point(0.35, 0.47))
            shape.addCurve(to: point(0.14, 0.54), control1: point(0.20, 0.61), control2: point(0.16, 0.59))
            shape.closeSubpath()

            shape.move(to: point(0.58, 0.24))
            shape.addCurve(to: point(0.84, 0.61), control1: point(0.76, 0.28), control2: point(0.87, 0.43))
            shape.addCurve(to: point(0.70, 0.88), control1: point(0.83, 0.72), control2: point(0.78, 0.85))
            shape.addCurve(to: point(0.57, 0.76), control1: point(0.63, 0.91), control2: point(0.55, 0.83))
            shape.addCurve(to: point(0.66, 0.39), control1: point(0.62, 0.62), control2: point(0.69, 0.48))
            shape.addCurve(to: point(0.58, 0.24), control1: point(0.65, 0.33), control2: point(0.61, 0.28))
            shape.closeSubpath()
        } else {
            shape.move(to: point(0.08, 0.50))
            shape.addCurve(to: point(0.17, 0.34), control1: point(0.08, 0.41), control2: point(0.09, 0.34))
            shape.addCurve(to: point(0.50, 0.38), control1: point(0.33, 0.37), control2: point(0.38, 0.38))
            shape.addCurve(to: point(0.83, 0.34), control1: point(0.62, 0.38), control2: point(0.68, 0.37))
            shape.addCurve(to: point(0.92, 0.50), control1: point(0.91, 0.34), control2: point(0.92, 0.41))
            shape.addCurve(to: point(0.83, 0.66), control1: point(0.92, 0.59), control2: point(0.91, 0.66))
            shape.addCurve(to: point(0.50, 0.62), control1: point(0.67, 0.63), control2: point(0.62, 0.62))
            shape.addCurve(to: point(0.17, 0.66), control1: point(0.38, 0.62), control2: point(0.32, 0.63))
            shape.addCurve(to: point(0.08, 0.50), control1: point(0.09, 0.66), control2: point(0.08, 0.59))
            shape.closeSubpath()
            for x in [CGFloat(0.29), 0.61] {
                shape.move(to: point(x, 0.57))
                shape.addCurve(to: point(x + 0.06, 0.44), control1: point(x - 0.02, 0.50), control2: point(x, 0.45))
                shape.addCurve(to: point(x + 0.09, 0.57), control1: point(x + 0.11, 0.45), control2: point(x + 0.12, 0.52))
            }
            shape.move(to: point(0.46, 0.51))
            shape.addLine(to: point(0.54, 0.51))
        }
        return shape
    }
}

private struct RiderTopSpotPicker: View {
    @Environment(\.dismiss) private var dismiss
    let spots: [RiderSpot]
    @Binding var selection: UUID?
    @State private var search = ""

    private var matchingSpots: [RiderSpot] {
        let locale = Locale(identifier: "ru_RU")
        let query = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let terms = query.split(whereSeparator: \.isWhitespace)
        return spots.filter { spot in
            let labels: [String?] = [spot.name, spot.locality, spot.region]
            let combined = (labels.compactMap { $0 } + (spot.accessPoints ?? []).map(\.name)).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return terms.allSatisfy { combined.contains($0) }
        }.sorted {
            let order = $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
            if order == .orderedSame { return $0.id.uuidString < $1.id.uuidString }
            return order == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Все споты") { selection = nil; dismiss() }
                }
                if matchingSpots.isEmpty {
                    Text("Споты не найдены").foregroundStyle(.secondary)
                }
                ForEach(matchingSpots) { spot in
                    Button {
                        selection = spot.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(spot.name)
                            if let region = spot.region {
                                Text(region).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Выбрать спот")
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название спота")
        }
    }
}
