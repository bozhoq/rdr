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
}

struct RiderPerson: Decodable, Identifiable {
    let id: String
    let name: String
    let username: String?
    let avatar: Data?

    var handle: String { riderHandle(username, or: name) }
}

private func riderHandle(_ username: String?, or name: String) -> String {
    guard let username, !username.isEmpty else { return name }
    return "@" + username
}

struct RiderReaction: Decodable {
    let total: Int
    let mine: Bool
    let people: [RiderPerson]
}

struct RiderActivity: Decodable {
    let kind: String
    let person: RiderPerson
    let postID: UUID?
    let createdAt: TimeInterval

    var description: String {
        switch kind {
        case "shaka": return "поставил(а) шаку твоему посту"
        case "comment": return "оставил(а) комментарий"
        case "repost": return "поделился(-ась) твоим постом"
        default: return "подписался(-ась) на тебя"
        }
    }
}

struct RiderMessage: Decodable, Identifiable {
    let id: UUID
    let mine: Bool
    let text: String
    let createdAt: TimeInterval
    let postID: UUID?
    let postCaption: String?
}

struct RiderPost: Codable, Identifiable {
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

    var date: Date { Date(timeIntervalSince1970: createdAt) }
    var contentID: UUID { sourceID ?? id }
    var remotePhoto: URL? {
        RiderCommunity.endpoint?.appendingPathComponent("posts/\(contentID.uuidString.lowercased())/photo")
    }
    var publicURL: URL? {
        guard published == true else { return nil }
        return RiderCommunity.endpoint?.appendingPathComponent("posts/\(contentID.uuidString.lowercased())/view")
    }
}

struct RiderFeedEntry: Decodable, Identifiable {
    let post: RiderPost
    let author: String
    let username: String?
    let avatar: Data?
    let authorID: String?
    let following: Bool?
    let mine: Bool?
    let reposted: Bool?
    let reaction: RiderReaction?
    var id: UUID { post.id }
}

struct RiderComment: Decodable, Identifiable {
    let id: UUID
    let createdAt: TimeInterval
    let text: String
    let author: String
    let username: String?
    let mine: Bool

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

    func value(for metric: RiderTopMetric) -> Double? {
        metric.value(height: height, airtime: airtime, distance: distance)
    }
}

struct RiderTopFilter: Encodable, Equatable {
    let metric: String
    let spotID: UUID?
    let spot: String?
    let startAt: TimeInterval?
    let endAt: TimeInterval?

    func contains(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return (startAt.map { seconds >= $0 } ?? true) && (endAt.map { seconds < $0 } ?? true)
    }
}

final class RiderSocialStore: ObservableObject {
    @Published private(set) var posts: [RiderPost] = []
    @Published private(set) var reposts: [RiderFeedEntry] = []
    @Published var reactions: [UUID: RiderReaction] = [:]
    @Published var follows: [String: Bool] = [:]
    @Published var reposted: [UUID: Bool] = [:]
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
    private let directory = URL.applicationSupportDirectory.appendingPathComponent("RiderPosts", isDirectory: true)

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
        updated.uploadAttempted = true
        try save(updated)
        try await RiderCommunity.publishPost(updated)
        updated.published = true
        try save(updated)
    }

    @MainActor func delete(_ post: RiderPost) async throws {
        if post.published == true || post.uploadAttempted == true {
            try await RiderCommunity.deletePost(post.id)
        }
        try FileManager.default.removeItem(at: file(for: post.id))
        posts.removeAll { $0.id == post.id }
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

struct RiderPostSquare: View {
    let post: RiderPost

    var body: some View {
        GeometryReader { bounds in
            Group {
                if let data = post.photo, let loaded = UIImage(data: data) {
                    Image(uiImage: loaded).resizable().scaledToFill()
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
        .aspectRatio(1, contentMode: .fit)
        .background(RiderTheme.surface)
        .accessibilityLabel(post.caption.isEmpty ? "Фото публикации" : post.caption)
    }

    private var placeholder: some View {
        ZStack {
            RiderTheme.surface
            Image(systemName: "photo").foregroundStyle(.secondary)
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
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var post: RiderPost { editable ? social.posts.first { $0.id == original.id } ?? original : original }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 12) {
                    postContent
                    commentsSection
                        .id("post-comments")
                }
                .padding(16)
            }
            .task {
                guard openComments else { return }
                await Task.yield()
                scroll.scrollTo("post-comments", anchor: .top)
            }
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Публикация")
        .navigationBarTitleDisplayMode(.inline)
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
        }
        .disabled(busy)
    }

    private var postContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            RiderPostHeader(author: author, username: username, avatar: avatar)
            if let source = post.sourceAuthor {
                Label(riderHandle(post.sourceUsername, or: source), systemImage: "arrow.2.squarepath")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            RiderPostSquare(post: post).clipShape(RoundedRectangle(cornerRadius: 16))
            RiderPostEquipmentTag(equipment: post.equipment)
            if !post.caption.isEmpty { Text(post.caption).textSelection(.enabled) }
            if let location = post.location {
                if let url = location.mapURL {
                    Link(destination: url) { Label(location.name, systemImage: "mappin") }
                } else {
                    Label(location.name, systemImage: "mappin")
                }
            }
            RiderPostDate(date: post.date)
            if editable {
                if post.published == true {
                    Label("Опубликовано", systemImage: "checkmark.circle").font(.footnote)
                } else if RiderCommunity.endpoint != nil {
                    Button("Опубликовать") { update(deleting: false) }
                        .buttonStyle(.borderedProminent)
                    Text("В ленте будут видны фото, подпись, выбранная геометка и комплект.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Сохранено на этом iPhone").font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .lagoonCard()
    }

    @ViewBuilder private var commentsSection: some View {
        if RiderCommunity.endpoint != nil && (!editable || post.published == true) {
            RiderCommentsView(postID: post.contentID)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text("Комментарии").font(.headline)
                Text("Комментарии откроются после публикации поста в общей ленте.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                self.error = deleting ? "Не удалось удалить публикацию." : "Сначала опубликуйте профиль в настройках публичного профиля. Проверьте подключение и повторите."
            }
        }
    }
}

private struct RiderPostHeader: View {
    let author: String
    let username: String?
    let avatar: Data?

    var body: some View {
        HStack(spacing: 10) {
            RiderAvatar(photo: avatar ?? Data(), size: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(author).font(.headline)
                if let username, !username.isEmpty {
                    Text("@" + username).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RiderCommentsView: View {
    let postID: UUID
    @State private var comments: [RiderComment]?
    @State private var loading = false
    @State private var sending = false
    @State private var draft = ""
    @State private var draftID = UUID()
    @State private var error: String?

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Комментарии").font(.headline).accessibilityAddTraits(.isHeader)
            if let comments {
                if comments.isEmpty {
                    Text("Пока нет комментариев").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(comments) { comment in
                    commentRow(comment)
                }
            } else if loading {
                ProgressView("Загружаем комментарии")
            } else if error != nil {
                Button("Обновить комментарии") { Task { await load() } }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Написать комментарий", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, value in
                        if value.count > 500 { draft = String(value.prefix(500)) }
                    }
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.body.bold())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty || loading || sending)
                .accessibilityLabel("Отправить комментарий")
            }
        }
        .lagoonCard()
        .task(id: postID) { await load() }
    }

    private func commentRow(_ comment: RiderComment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.author).font(.subheadline.weight(.semibold))
                    if let username = comment.username, !username.isEmpty {
                        Text("@" + username).font(.caption).foregroundStyle(.secondary)
                    }
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
            Text(comment.text).font(.subheadline).textSelection(.enabled)
            Text(comment.date, format: .dateTime.day().month().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
        }
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
        guard !text.isEmpty else { return }
        let id = draftID
        change {
            let result = try await RiderCommunity.submitComment(text, id: id, for: postID)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            draftID = UUID()
            return result
        }
    }

    private func change(_ action: @escaping @MainActor () async throws -> [RiderComment]) {
        guard !loading, !sending else { return }
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do { comments = try await action() }
            catch RiderCommunity.Rejection.forbidden {
                error = "Опубликуй профиль в настройках публичного профиля, чтобы комментировать."
            } catch {
                self.error = "Не удалось сохранить изменение. Попробуй ещё раз."
            }
        }
    }
}

struct RiderPostComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var social: RiderSocialStore
    let spots: [RiderSpot]
    let presets: [GearPreset]
    @State private var equipmentID: UUID?
    @State private var picked: PhotosPickerItem?
    @State private var photo: Data?
    @State private var caption = ""
    @State private var location: RiderPostLocation?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                PhotosPicker(selection: $picked, matching: .images) {
                    Label(photo == nil ? "Выбрать фотографию" : "Заменить фотографию", systemImage: "photo")
                }
                if loading { ProgressView("Готовим фото") }
                if let photo {
                    RiderPostSquare(post: RiderPost(id: UUID(), createdAt: 0, caption: "", location: nil, photo: photo))
                }
                TextField("Подпись", text: $caption, axis: .vertical)
                    .lineLimit(2...5)
                    .onChange(of: caption) { _, value in
                        if value.count > 800 { caption = String(value.prefix(800)) }
                    }
                NavigationLink {
                    RiderPostLocationChoice(spots: spots, selection: $location)
                } label: {
                    LabeledContent("Геометка", value: location?.name ?? "Добавить")
                }
                if !presets.isEmpty {
                    Picker("Кайт-комплект", selection: $equipmentID) {
                        Text("Без комплекта").tag(nil as UUID?)
                        ForEach(presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                Button("Сохранить пост") { save() }
                    .disabled(photo == nil || loading)
            }
            .navigationTitle("Новый пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .task(id: picked) { await loadPhoto() }
    }

    @MainActor private func loadPhoto() async {
        guard let picked else { return }
        loading = true
        error = nil
        do {
            let data = try await picked.loadTransferable(type: Data.self)
            guard !Task.isCancelled else { return }
            if let data, let image = Self.postJPEG(data) { photo = image }
            else { error = "Не удалось подготовить фото. Выберите другое." }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Не удалось прочитать фото."
        }
        loading = false
    }

    private static func postJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1080
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumb)
        let qualities: [CGFloat] = [0.76, 0.62, 0.48, 0.32]
        for quality in qualities {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 390_000 { return jpeg }
        }
        return nil
    }

    @MainActor private func save() {
        guard let photo else { return }
        let post = RiderPost(id: UUID(), createdAt: Date().timeIntervalSince1970,
                             caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                             location: location, photo: photo,
                             equipment: presets.first { $0.id == equipmentID }.map(RiderPostEquipment.init))
        do { try social.save(post); dismiss() }
        catch { self.error = "Не удалось сохранить пост на iPhone." }
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

struct RiderFeedView: View {
    @EnvironmentObject private var social: RiderSocialStore
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.username") private var username = ""
    @AppStorage("rider.profilePhoto") private var avatar = Data()
    @State private var selection = Feed.following
    @State private var entries: [RiderFeedEntry]?
    @State private var failed = false

    private enum Feed: String, CaseIterable, Identifiable {
        case following, recommended
        var id: Self { self }
        var title: String { self == .following ? "Подписки" : "Рекомендации" }
    }

    var body: some View {
        let feed = selection
        return List {
            Picker("Лента", selection: $selection) {
                ForEach(Feed.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if RiderCommunity.endpoint == nil {
                Text("Общая лента появится после подключения сервера Rider.").foregroundStyle(.secondary)
                if !social.posts.isEmpty {
                    Section("Мои посты на iPhone") {
                        ForEach(social.posts) { post in
                            RiderFeedCard(post: post, author: name, username: username, avatar: avatar, editable: true)
                        }
                    }
                }
            } else if let entries {
                if entries.isEmpty {
                    Text(feed == .following ? "Здесь появятся посты райдеров, на которых ты подписан." : "Пока нет новых публикаций.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    RiderFeedCard(post: entry.post, author: entry.author, username: entry.username, avatar: entry.avatar, entry: entry)
                }
            } else if failed {
                Button("Повторить загрузку") { Task { await load(feed) } }
            } else {
                ProgressView("Загружаем ленту")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .scrollContentBackground(.hidden).background(RiderTheme.canvas)
        .task(id: feed) { await load(feed) }
        .refreshable { await load(feed) }
    }

    @MainActor private func load(_ feed: Feed) async {
        guard RiderCommunity.endpoint != nil, feed == selection else { return }
        entries = nil
        failed = false
        do {
            let result = try await RiderCommunity.feed(recommended: feed == .recommended)
            guard !Task.isCancelled, feed == selection else { return }
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
    @State private var changingReaction = false
    @State private var changingFollow = false
    @State private var changingRepost = false
    @State private var sharing = false
    @State private var showingReactions = false
    @State private var error: String?

    private var reaction: RiderReaction {
        if post.publicURL != nil {
            return social.reactions[post.contentID] ?? entry?.reaction ?? RiderReaction(total: 0, mine: false, people: [])
        }
        let mine = social.localShakas.contains(post.id.uuidString)
        let user = RiderPerson(id: "local", name: author, username: username, avatar: avatar)
        return RiderReaction(total: mine ? 1 : 0, mine: mine, people: mine ? [user] : [])
    }

    private var following: Bool {
        entry?.authorID.flatMap { social.follows[$0] } ?? entry?.following ?? false
    }

    private var reposted: Bool {
        social.reposted[post.contentID] ?? entry?.reposted ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if let source = post.sourceAuthor {
                Label("Репост · " + riderHandle(post.sourceUsername, or: source), systemImage: "arrow.2.squarepath")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            NavigationLink {
                detail()
            } label: {
                RiderPostSquare(post: post).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть пост \(author)")

            HStack(spacing: 8) {
                actions
                Spacer(minLength: 0)
                RiderPostEquipmentTag(equipment: post.equipment)
            }
            if reaction.total > 0 { reactionSummary }
            if !post.caption.isEmpty {
                (Text(riderHandle(post.sourceUsername ?? (post.sourceID == nil ? username : nil),
                                  or: post.sourceAuthor ?? author)).fontWeight(.bold)
                    + Text(" ") + Text(post.caption))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if let location = post.location {
                Label(location.name, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
            }
            RiderPostDate(date: post.date)
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .lagoonCard()
        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 7, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .sheet(isPresented: $sharing) { shareMenu }
        .sheet(isPresented: $showingReactions) { reactionsSheet }
        .task(id: post.publicURL) { await loadInitialReaction() }
    }

    @MainActor private func loadInitialReaction() async {
        let id = post.contentID
        guard editable, post.publicURL != nil, social.reactions[id] == nil else { return }
        guard let response = try? await RiderCommunity.postDetails(id),
              !Task.isCancelled, !changingReaction, social.reactions[id] == nil else { return }
        social.reactions[id] = response.reaction
    }

    private var header: some View {
        HStack {
            RiderPostHeader(author: author, username: username, avatar: avatar)
            if let target = entry?.authorID, entry?.mine != true {
                Button(following ? "Подписан" : "Подписаться") { toggleFollow(target) }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(following ? Color.primary : RiderTheme.foam)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(following ? RiderTheme.canvas : RiderTheme.action, in: Capsule())
                    .buttonStyle(.borderless)
                    .disabled(changingFollow)
                    .accessibilityAddTraits(following ? .isSelected : [])
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
            .buttonStyle(.borderless)
            .disabled(changingReaction)
            .accessibilityLabel(reaction.mine ? "Убрать шаку" : "Поставить шаку")
            .accessibilityValue(reaction.total.formatted())
            .accessibilityAddTraits(reaction.mine ? .isSelected : [])
            NavigationLink {
                detail(comments: true)
            } label: {
                Image(systemName: "bubble").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Комментарии")
            Button { sharing = true } label: {
                Image(systemName: "paperplane").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Поделиться")
        }
        .foregroundStyle(RiderTheme.accent)
    }

    private var reactionSummary: some View {
        Button { showingReactions = true } label: {
            HStack(spacing: 7) {
                HStack(spacing: -6) {
                    ForEach(reaction.people) { rider in
                        RiderAvatar(photo: rider.avatar ?? Data(), size: 22)
                            .overlay { Circle().strokeBorder(RiderTheme.surface, lineWidth: 1.5) }
                    }
                }.accessibilityHidden(true)
                if let first = reaction.people.first {
                    let others = reaction.total - 1
                    Text(others > 0 ? "Шака от \(first.handle) и ещё \(others)" : "Шака от \(first.handle)")
                        .lineLimit(1)
                } else {
                    Text("Шака · \(reaction.total)")
                }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    private var reactionsSheet: some View {
        NavigationStack {
            List {
                Label {
                    Text("Реакций: \(reaction.total)").font(.headline)
                } icon: {
                    RiderShakaIcon(selected: false)
                }
                ForEach(reaction.people) { rider in
                    RiderPostHeader(author: rider.name, username: rider.username, avatar: rider.avatar)
                }
            }
            .navigationTitle("Шака")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingReactions = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var shareMenu: some View {
        NavigationStack {
            List {
                if let url = post.publicURL {
                    NavigationLink {
                        RiderInboxView(shared: post, onSent: { sharing = false })
                    } label: {
                        Label("Отправить в сообщениях", systemImage: "paperplane")
                    }
                    if (entry != nil && entry?.mine != true) || reposted {
                        Button {
                            toggleRepost()
                        } label: {
                            Label(reposted ? "Убрать репост" : "Репост в профиль", systemImage: "arrow.2.squarepath")
                        }
                        .disabled(changingRepost)
                    }
                    ShareLink(item: url) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                } else if let bytes = post.photo, let image = UIImage(data: bytes) {
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

    private func detail(comments: Bool = false) -> some View {
        RiderPostDetail(original: post, author: author, username: username, avatar: avatar,
                        editable: editable, openComments: comments)
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
            error = "Сначала опубликуй профиль в настройках публичного профиля."
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
                Label(equipment.name, systemImage: "wind")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .foregroundStyle(RiderTheme.accent)
                    .background(RiderTheme.canvas, in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Кайт-комплект \(equipment.name)")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(equipment.name).font(.headline)
                    Label(equipment.kite, systemImage: "wind")
                    Label(equipment.board, systemImage: "rectangle.roundedbottom")
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
    @State private var entry: RiderFeedEntry?
    @State private var failed = false

    var body: some View {
        ScrollView {
            if let entry {
                RiderFeedCard(post: entry.post, author: entry.author, username: entry.username, avatar: entry.avatar, entry: entry)
                    .padding(14)
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
    @State private var items: [RiderActivity]?
    @State private var failed = false

    var body: some View {
        List {
            if RiderCommunity.endpoint == nil {
                ContentUnavailableView("Уведомления", systemImage: "bell",
                                       description: Text("Уведомления появятся после подключения сервера Rider."))
            } else if let items {
                if items.isEmpty {
                    ContentUnavailableView("Пока тихо", systemImage: "bell",
                                           description: Text("Здесь появятся реакции, комментарии, репосты и подписки."))
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let post = item.postID {
                        NavigationLink { RiderSharedPostView(id: post) } label: { activityRow(item) }
                    } else {
                        activityRow(item)
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
        .task { await load() }
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

    @MainActor private func load() async {
        guard RiderCommunity.endpoint != nil else { return }
        do {
            let result = try await RiderCommunity.activity()
            if !Task.isCancelled { items = result; failed = false }
        } catch { if !Task.isCancelled { failed = true } }
    }
}

struct RiderInboxView: View {
    var shared: RiderPost?
    var onSent: (() -> Void)?
    @State private var people: [RiderPerson]?
    @State private var composing = false
    @State private var failed = false
    @State private var search = ""

    private var choosingRecipient: Bool { shared != nil || composing }

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
                ForEach(people.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.handle.localizedCaseInsensitiveContains(search) }) { rider in
                    NavigationLink {
                        RiderThreadView(peer: rider, shared: shared, onSent: onSent)
                    } label: {
                        RiderPostHeader(author: rider.name, username: rider.username, avatar: rider.avatar)
                            .padding(.vertical, 4)
                    }
                }
            } else if failed {
                Button("Повторить загрузку") { Task { await load() } }
            } else {
                ProgressView()
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
        .refreshable { await load() }
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

private struct RiderThreadView: View {
    let peer: RiderPerson
    let shared: RiderPost?
    var onSent: (() -> Void)?
    @State private var messages: [RiderMessage] = []
    @State private var messageRevision = 0
    @State private var draft = ""
    @State private var draftID = UUID()
    @State private var sending = false
    @State private var attached = true
    @State private var error: String?

    private var attachment: RiderPost? { attached ? shared : nil }
    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(messages) { message in
                        bubble(message)
                    }
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in
                if let id { scroll.scrollTo(id, anchor: .bottom) }
            }
            .refreshable { await load() }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(RiderTheme.canvas)
        .navigationTitle(peer.handle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: peer.id) { await load() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let attachment {
                HStack {
                    Label(attachment.caption.isEmpty ? "Публикация Rider" : attachment.caption, systemImage: "photo")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Button { attached = false; draftID = UUID() } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Убрать публикацию").disabled(sending)
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            HStack(alignment: .bottom) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onChange(of: draft) { _, value in
                        if !sending { draftID = UUID() }
                        if value.count > 1000 { draft = String(value.prefix(1000)) }
                    }
                    .disabled(sending)
                Button(action: send) { Image(systemName: "arrow.up").font(.body.bold()).frame(minHeight: 27) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Отправить")
                    .disabled(sending || (text.isEmpty && attachment == nil))
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func bubble(_ message: RiderMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let post = message.postID {
                NavigationLink { RiderSharedPostView(id: post) } label: {
                    Label(message.postCaption ?? "Публикация Rider", systemImage: "photo")
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                }
            }
            if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
            RiderPostDate(date: Date(timeIntervalSince1970: message.createdAt))
        }
        .padding(10)
        .background(message.mine ? RiderTheme.accent.opacity(0.15) : RiderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    @MainActor private func load() async {
        guard !sending else { return }
        let revision = messageRevision
        do {
            let result = try await RiderCommunity.messages(with: peer.id)
            if !Task.isCancelled && !sending && revision == messageRevision { messages = result; error = nil }
        } catch {
            if !Task.isCancelled && !sending && revision == messageRevision { self.error = "Не удалось загрузить переписку." }
        }
    }

    private func send() {
        let body = text
        let post = attachment?.contentID
        guard !sending, !body.isEmpty || post != nil else { return }
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                messages = try await RiderCommunity.sendMessage(to: peer.id, id: draftID, text: body, post: post)
                messageRevision += 1
                draftID = UUID()
                draft = ""
                attached = false
                if post != nil { onSent?() }
            } catch RiderCommunity.Rejection.forbidden {
                error = "Сначала опубликуй профиль в настройках публичного профиля."
            } catch {
                self.error = "Не удалось отправить сообщение. Попробуй ещё раз."
            }
        }
    }
}

struct RiderTopsView: View {
    @ObservedObject var recorder: SessionRecorder
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.username") private var username = ""
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @State private var score = RiderTopMetric.height
    @State private var period = RiderTopPeriod.all
    @State private var spotID: UUID?
    @State private var choosingSpot = false
    @State private var remote: [RiderTopEntry]?
    @State private var failed = false
    @State private var loadedFilter: RiderTopFilter?

    var body: some View {
        TimelineView(.everyMinute) { context in
            ranking(at: context.date)
        }
    }

    private func ranking(at now: Date) -> some View {
        let spot = recorder.spots.first { $0.id == spotID }
        let interval = period.interval(at: now)
        let filter = RiderTopFilter(metric: score.rawValue, spotID: spot?.id, spot: spot?.name,
                                    startAt: interval?.start.timeIntervalSince1970,
                                    endAt: interval?.end.timeIntervalSince1970)
        let isLocal = RiderCommunity.endpoint == nil || (failed && loadedFilter == filter)
        let entries = isLocal ? localRows(spot: spot, filter: filter) : (loadedFilter == filter ? remote : nil)
        return List {
            filters(spot: spot)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            if let entries {
                Section(isLocal ? "Мои рекорды" : "Таблица лидеров") {
                    if isLocal {
                        Text(RiderCommunity.endpoint == nil
                             ? "Общий рейтинг появится после подключения сервера Rider."
                             : "Общий рейтинг недоступен. Показаны личные рекорды.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if entries.isEmpty {
                        Text("В этом диапазоне пока нет рекордов.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index < 3 {
                            podiumRow(entry, place: index + 1)
                        } else {
                            leaderboardRow(entry, place: index + 1)
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
        .task(id: filter) { await load(filter) }
        .refreshable { await load(filter) }
    }

    private func filters(spot: RiderSpot?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Menu {
                Picker("Период", selection: $period) {
                    ForEach(RiderTopPeriod.allCases) { Text($0.title).tag($0) }
                }
            } label: { filterLabel(period.title) }
                .accessibilityLabel("Период, \(period.title)")
            Menu {
                Picker("Показатель", selection: $score) {
                    ForEach(RiderTopMetric.allCases) { Text($0.title).tag($0) }
                }
            } label: { filterLabel(score.title) }
                .accessibilityLabel("Показатель, \(score.title)")
            Button { choosingSpot = true } label: {
                filterLabel(spot?.name ?? "Все споты")
            }
            .accessibilityLabel("Спот, \(spot?.name ?? "Все споты")")
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
                Spacer(minLength: 4)
                Text(metric(entry.value(for: score), unit: score.unit))
                    .font(.title3.bold().monospacedDigit()).multilineTextAlignment(.trailing)
            }
            if let kite = entry.kite {
                equipmentLabel(kite, glyph: .kite).accessibilityLabel("Кайт \(kite)")
            }
            if let board = entry.board {
                equipmentLabel(board, glyph: .board).accessibilityLabel("Доска \(board)")
            }
            if entry.kite == nil && entry.board == nil {
                Text("Снаряжение не указано")
            }
        }
        .font(.footnote)
        .lagoonCard()
        .listRowBackground(Color.clear)
    }

    private func equipmentLabel(_ name: String, glyph: EquipmentGlyph.Kind) -> some View {
        Label {
            Text(name)
        } icon: {
            EquipmentGlyph(kind: glyph)
                .stroke(RiderTheme.accent, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }

    private func leaderboardRow(_ entry: RiderTopEntry, place: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(place)).monospacedDigit().foregroundStyle(RiderTheme.accent)
                .accessibilityLabel("Место \(place)")
            riderName(entry)
            Spacer(minLength: 4)
            Text(metric(entry.value(for: score), unit: score.unit)).font(.headline.monospacedDigit())
        }
    }

    private func riderName(_ entry: RiderTopEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            if let tag = entry.username, !tag.isEmpty {
                Text("@" + tag).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func localRows(spot: RiderSpot?, filter: RiderTopFilter) -> [RiderTopEntry] {
        let matches = recorder.history.filter {
            (spot?.matches($0.setup) ?? true) && filter.contains($0.startedAt)
        }
        let records = RiderJumpScore.records(in: matches)
        guard let best = RiderJumpScore.best(for: score, in: records) else { return [] }
        return [RiderTopEntry(id: "local", name: name, username: username, height: best.height,
                              airtime: best.airtime, distance: best.distance, avatar: photo,
                              kite: best.kite, board: best.board)]
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

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var shape = Path()
        if kind == .kite {
            shape.move(to: point(0.08, 0.64))
            shape.addQuadCurve(to: point(0.92, 0.64), control: point(0.5, -0.37))
            shape.addQuadCurve(to: point(0.08, 0.64), control: point(0.5, 0.26))
            shape.move(to: point(0.08, 0.64))
            shape.addLine(to: point(0.5, 0.92))
            shape.addLine(to: point(0.92, 0.64))
        } else {
            let inset = CGRect(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.06,
                               width: rect.width * 0.28, height: rect.height * 0.88)
            shape.addRoundedRect(in: inset, cornerSize: CGSize(width: rect.width * 0.14, height: rect.height * 0.14))
            for y in [CGFloat(0.36), CGFloat(0.64)] {
                shape.move(to: point(0.37, y))
                shape.addLine(to: point(0.63, y))
            }
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
