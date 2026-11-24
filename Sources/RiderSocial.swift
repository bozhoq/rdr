import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct RiderPostLocation: Codable {
    let name: String
    let latitude: Double?
    let longitude: Double?

    var mapURL: URL? {
        guard let latitude, let longitude else { return nil }
        return RiderSpot(name: name, latitude: String(latitude), longitude: String(longitude))?.yandexURL
    }
}

struct RiderPost: Codable, Identifiable {
    let id: UUID
    let createdAt: TimeInterval
    let caption: String
    let location: RiderPostLocation?
    let photo: Data?
    var published: Bool?
    var uploadAttempted: Bool?

    var date: Date { Date(timeIntervalSince1970: createdAt) }
    var remotePhoto: URL? {
        RiderCommunity.endpoint?.appendingPathComponent("posts/\(id.uuidString.lowercased())/photo")
    }
}

struct RiderFeedEntry: Decodable, Identifiable {
    let post: RiderPost
    let author: String
    let username: String?
    let avatar: Data?
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
            RiderPostSquare(post: post).clipShape(RoundedRectangle(cornerRadius: 16))
            if !post.caption.isEmpty { Text(post.caption).textSelection(.enabled) }
            if let location = post.location {
                if let url = location.mapURL {
                    Link(destination: url) { Label(location.name, systemImage: "mappin") }
                } else {
                    Label(location.name, systemImage: "mappin")
                }
            }
            Text(post.date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
            if editable {
                if post.published == true {
                    Label("Опубликовано", systemImage: "checkmark.circle").font(.footnote)
                } else if RiderCommunity.endpoint != nil {
                    Button("Опубликовать") { update(deleting: false) }
                        .buttonStyle(.borderedProminent)
                    Text("В ленте будут видны фото, подпись и выбранная геометка.")
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
            RiderCommentsView(postID: post.id)
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
                self.error = deleting ? "Не удалось удалить публикацию." : "Сначала опубликуйте профиль в разделе «Райдеры». Проверьте подключение и повторите."
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
                error = "Опубликуй профиль в разделе «Райдеры», чтобы комментировать."
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
                             location: location, photo: photo)
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
                    RiderFeedCard(post: entry.post, author: entry.author, username: entry.username, avatar: entry.avatar)
                }
            } else if failed {
                Button("Повторить загрузку") { Task { await load(feed) } }
            } else {
                ProgressView("Загружаем ленту")
            }
        }
        .navigationTitle("Лента")
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

private struct RiderFeedCard: View {
    let post: RiderPost
    let author: String
    let username: String?
    let avatar: Data?
    var editable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RiderPostHeader(author: author, username: username, avatar: avatar)
            NavigationLink {
                RiderPostDetail(original: post, author: author, username: username, avatar: avatar, editable: editable)
            } label: {
                RiderPostSquare(post: post).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть пост \(author)")
            if !post.caption.isEmpty {
                Text(post.caption).font(.subheadline).lineLimit(2)
            }
            if let location = post.location {
                Label(location.name, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink {
                RiderPostDetail(original: post, author: author, username: username,
                                avatar: avatar, editable: editable, openComments: true)
            } label: {
                Label("Комментировать", systemImage: "bubble")
                    .font(.footnote.weight(.semibold)).foregroundStyle(RiderTheme.accent)
            }
            .buttonStyle(.borderless)
        }
        .lagoonCard()
        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
