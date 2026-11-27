import AVKit
import PhotosUI
import SwiftUI

private struct RiderStoryViewer: Decodable, Identifiable {
    let person: RiderPerson
    let liked: Bool
    var id: String { person.id }
}

private struct RiderStoryViewerPage: Decodable {
    let people: [RiderStoryViewer]
    let nextOffset: Int?
}

struct RiderStory: Decodable, Identifiable {
    let id: UUID
    let author: RiderPerson
    let caption: String
    let createdAt: TimeInterval
    let video: Bool
    let seen: Bool
    let mine: Bool
    var liked: Bool?

    var path: String { "stories/" + id.uuidString.lowercased() }
}

struct RiderStoriesStrip: View {
    @AppStorage("rider.profilePhoto") private var avatar = Data()
    @Environment(\.scenePhase) private var phase
    @State private var stories: [RiderStory] = []
    @State private var opened: Deck?
    @Binding var expanded: Bool
    @State private var composing = false
    @State private var failed = false

    private struct Deck: Identifiable {
        let id = UUID()
        let items: [RiderStory]
        let start: Int
    }

    private var hasUnseen: Bool { stories.contains { !$0.seen } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    let preview = stories.first { !$0.seen } ?? stories.first
                    storyAvatar(photo: preview?.author.avatar ?? avatar, fresh: hasUnseen, size: 26)
                    Text("Истории").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(hasUnseen ? "Есть новые истории" : "Нет новых историй")
            .accessibilityHint(expanded ? "Свернуть истории" : "Показать истории")

            if expanded {
                if failed {
                    Button("Обновить истории") { Task { await load() } }.font(.caption)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        Button { composing = true } label: {
                            VStack(spacing: 4) {
                                RiderAvatar(photo: avatar, size: 44)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                                            .padding(4).foregroundStyle(.white).background(RiderTheme.action, in: Circle())
                                    }
                                Text("Добавить").font(.caption2)
                            }
                            .frame(width: 65, height: 66)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Добавить историю")

                        ForEach(authors) { author in
                            let fresh = stories.contains { $0.author.id == author.id && !$0.seen }
                            let mine = stories.contains { $0.author.id == author.id && $0.mine }
                            Button { open(author) } label: {
                                VStack(spacing: 4) {
                                    storyAvatar(photo: author.avatar ?? Data(), fresh: fresh, size: 44)
                                    Text(mine ? "Твои истории" : author.name).font(.caption2).lineLimit(1)
                                }
                                .frame(width: 72, height: 66)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mine ? "Твои истории" : author.name + (fresh ? ", новые истории" : ", истории"))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        .sheet(isPresented: $composing) {
            RiderStoryComposer { stories = $0; composing = false }
        }
        .fullScreenCover(item: $opened, onDismiss: { Task { await load() } }) { deck in
            RiderStoryPlayer(stories: deck.items, start: deck.start) { updated in stories = updated }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
            }
        }
    }

    private var authors: [RiderPerson] {
        var ids = Set<String>()
        return stories.filter { ids.insert($0.author.id).inserted }.map(\.author)
    }

    private func storyAvatar(photo: Data, fresh: Bool, size: CGFloat) -> some View {
        RiderAvatar(photo: photo, size: size)
            .padding(3)
            .overlay { Circle().strokeBorder(fresh ? RiderTheme.accent : .secondary.opacity(0.46), lineWidth: 2) }
            .accessibilityHidden(true)
    }

    private func open(_ author: RiderPerson) {
        let groups = Dictionary(grouping: stories, by: { $0.author.id })
        guard let group = groups[author.id], let first = group.first else { return }
        let people = first.mine ? [author] : authors.filter { groups[$0.id]?.first?.mine == false }
        let items = people.flatMap { person in
            (groups[person.id] ?? []).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
        }
        guard let start = items.firstIndex(where: { $0.author.id == author.id && !$0.seen })
                ?? items.firstIndex(where: { $0.author.id == author.id }) else { return }
        opened = Deck(items: items, start: start)
    }

    @MainActor private func load() async {
        do {
            let result: [RiderStory] = try await RiderCommunity.decode("stories")
            guard !Task.isCancelled else { return }
            stories = result
            failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }
}

private struct RiderStoryComposer: View {
    let onPublish: ([RiderStory]) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var picked: PhotosPickerItem?
    private enum Camera: String, Identifiable {
        case photo, video
        var id: String { rawValue }
    }

    @State private var camera: Camera?
    @State private var filmed: URL?
    @State private var photo: Data?
    @State private var video: Data?
    @State private var caption = ""
    @State private var story = UUID()
    @State private var loading = false
    @State private var publishing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos])) {
                        Label("Выбрать фото или видео", systemImage: "photo.on.rectangle")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { typing = false; camera = .photo } label: { Label("Сделать фото", systemImage: "camera") }
                    }
                    if RiderCameraVideo.available {
                        Button { typing = false; camera = .video } label: { Label("Записать видео", systemImage: "video") }
                    }
                } footer: { Text("История видна 24 часа. Видео до 30 секунд.") }
                if let photo, let image = UIImage(data: photo) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                        .frame(maxWidth: .infinity)
                    if video != nil { Label("Видео", systemImage: "play.rectangle") }
                }
                TextField("Подпись", text: $caption, axis: .vertical).focused($typing).lineLimit(2...4)
                    .onChange(of: caption) { _, value in caption = String(value.prefix(250)) }
                if loading || publishing { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(publishing || loading)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Новая история").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(publishing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Опубликовать", action: publish).disabled(photo == nil || publishing || loading)
                }
            }
            .fullScreenCover(item: $camera) { mode in
                switch mode {
                case .photo:
                    RiderCameraPhoto { image in
                        photo = image.jpegData(compressionQuality: 0.85).flatMap { RiderPostComposer.postJPEG($0) }
                        video = nil
                        story = UUID()
                    }.ignoresSafeArea()
                case .video:
                    RiderCameraVideo { result in
                        switch result {
                        case let .success(url): filmed = url
                        case .failure: error = "Не удалось сохранить видео с камеры."
                        }
                    }.ignoresSafeArea()
                }
            }
        }
        .interactiveDismissDisabled(publishing)
        .task(id: picked) { await load() }
        .task(id: filmed) {
            guard let url = filmed else { return }
            loading = true
            error = nil
            defer {
                try? FileManager.default.removeItem(at: url)
                if !Task.isCancelled { filmed = nil; loading = false }
            }
            do {
                let (cover, clip) = try await RiderMediaEncoding.clip(from: url)
                try Task.checkCancellation()
                photo = cover
                video = clip
                story = UUID()
            } catch {
                if !Task.isCancelled { self.error = "Не удалось подготовить записанное видео." }
            }
        }
    }

    @MainActor private func load() async {
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
                let (poster, data) = try await RiderMediaEncoding.clip(from: clip.url)
                try Task.checkCancellation()
                photo = poster
                video = data
            } else {
                guard let bytes = try await picked.loadTransferable(type: Data.self), let image = RiderPostComposer.postJPEG(bytes) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                photo = image
                video = nil
            }
            story = UUID()
        } catch {
            if !Task.isCancelled { self.error = "Не удалось подготовить вложение. Выбери фото или короткое видео." }
        }
    }

    private func publish() {
        guard !publishing, !loading, let photo else { return }
        typing = false
        publishing = true
        error = nil
        let post = RiderPost(id: story, createdAt: Date().timeIntervalSince1970, caption: caption, location: nil,
                             photo: photo, section: .gallery, video: video)
        Task {
            defer { publishing = false }
            do { onPublish(try await RiderCommunity.publishStory(post)) }
            catch RiderCommunity.Rejection.forbidden { self.error = "Для истории нужен публичный профиль." }
            catch { self.error = "Не удалось опубликовать историю. Попробуй ещё раз." }
        }
    }
}

private struct RiderStoryPlayer: View {
    let stories: [RiderStory]
    let deleted: ([RiderStory]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var likes: [UUID: Bool] = [:]

    init(stories: [RiderStory], start: Int, deleted: @escaping ([RiderStory]) -> Void) {
        self.stories = stories
        self.deleted = deleted
        _index = State(initialValue: start)
    }

    var body: some View {
        let story = stories[index]
        let first = stories.firstIndex { $0.author.id == story.author.id } ?? index
        let count = stories.filter { $0.author.id == story.author.id }.count
        RiderStorySlide(story: story, position: index - first, count: count, canGoBack: index > 0,
                        initialLike: likes[story.id] ?? story.liked ?? false,
                        previous: { if index > 0 { index -= 1 } },
                        next: {
                            if index + 1 < stories.count { index += 1 } else { dismiss() }
                        },
                        onLike: { likes[story.id] = $0 },
                        onDelete: { deleted($0); dismiss() },
                        close: { dismiss() })
            .id(story.id)
    }
}

private struct RiderStorySlide: View {
    let story: RiderStory
    let position: Int
    let count: Int
    let canGoBack: Bool
    let initialLike: Bool
    let previous: () -> Void
    let next: () -> Void
    let onLike: (Bool) -> Void
    let onDelete: ([RiderStory]) -> Void
    let close: () -> Void

    @Environment(\.scenePhase) private var phase
    @FocusState private var typing: Bool
    @State private var player: AVPlayer?
    @State private var source: URL?
    @State private var image: UIImage?
    @State private var duration = 6.0
    @State private var elapsed = 0.0
    @State private var startedAt: TimeInterval?
    @State private var ready = false
    @State private var failed = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var showingViewers = false
    @State private var changingLike = false
    @State private var draft = ""
    @State private var draftID = UUID()
    @State private var sending = false
    @State private var replySent = false
    @State private var error: String?
    @GestureState private var touching = false
    @State private var touch: Touch?

    private struct Touch {
        let downAt: Date
        let startTime: TimeInterval
        var scrubbing = false
    }

    private var playing: Bool {
        ready && phase == .active && touch == nil && !typing && !confirmDelete && !deleting &&
        !showingViewers && !sending && !changingLike && error == nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).allowsHitTesting(false)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit().allowsHitTesting(false)
            }
            if !ready && !failed { ProgressView().tint(.white).allowsHitTesting(false) }
            if failed { Text("История недоступна").allowsHitTesting(false) }
            storyControls
                .allowsHitTesting(!changingLike && !sending && !deleting)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: playing, initial: true) { _, active in updatePlayback(active) }
        .task(id: startedAt) {
            guard let startedAt, playing else { return }
            let remaining = max(0, duration - playbackTime(at: ProcessInfo.processInfo.systemUptime))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled, self.startedAt == startedAt, playing else { return }
            next()
        }
        .onDisappear {
            player?.pause()
            if let source { try? FileManager.default.removeItem(at: source) }
        }
        .sheet(isPresented: $showingViewers) { RiderStoryViewers(path: story.path) }
        .confirmationDialog("Удалить историю?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive, action: deleteStory)
        }
        .alert("Истории", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var storyControls: some View {
        GeometryReader { bounds in
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, active, _ in active = true }
                    .onChanged { updateTouch($0, width: bounds.size.width) }
                    .onEnded { finishTouch($0, width: bounds.size.width) })
        }
        .onChange(of: touching) { _, active in
            if !active {
                Task { @MainActor in
                    await Task.yield()
                    if !touching { touch = nil }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("История")
        .accessibilityHint("Удерживай для паузы и веди пальцем для перемотки")
        .accessibilityAction(named: Text("Предыдущая история")) { if canGoBack { previous() } }
        .accessibilityAction(named: Text("Следующая история")) { next() }
    }

    private func updateTouch(_ gesture: DragGesture.Value, width: CGFloat) {
        if touch == nil {
            updatePlayback(false)
            touch = Touch(downAt: gesture.time, startTime: elapsed)
        }
        guard ready, !typing, var touch, width > 0 else { return }
        let translation = gesture.translation
        let draggedHorizontally = abs(translation.width) > max(10, abs(translation.height))
        guard touch.scrubbing || (draggedHorizontally && gesture.time.timeIntervalSince(touch.downAt) >= 0.24) else { return }
        touch.scrubbing = true
        self.touch = touch
        elapsed = min(max(0, duration - 0.05), max(0, touch.startTime + Double(translation.width / width) * duration))
        player?.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func finishTouch(_ gesture: DragGesture.Value, width: CGFloat) {
        guard let touch else { return }
        defer { self.touch = nil }
        if typing {
            typing = false
            return
        }
        let translation = gesture.translation
        if touch.scrubbing {
            updateTouch(gesture, width: width)
        } else if abs(translation.width) >= 45 && abs(translation.width) > abs(translation.height) {
            if translation.width < 0 { next() }
            else if canGoBack { previous() }
        } else if gesture.time.timeIntervalSince(touch.downAt) < 0.24,
                  hypot(translation.width, translation.height) < 12 {
            if gesture.startLocation.x >= width / 2 { next() }
            else if canGoBack { previous() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: startedAt == nil)) { _ in
                let fraction = min(1, playbackTime(at: ProcessInfo.processInfo.systemUptime) / duration)
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { segment in
                        GeometryReader { bounds in
                            let fill = segment < position ? 1.0 : segment == position ? fraction : 0.0
                            Capsule().fill(.white.opacity(0.35))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white).frame(width: CGFloat(fill) * bounds.size.width)
                                }
                        }
                        .frame(height: 3)
                    }
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                RiderAvatar(photo: story.author.avatar ?? Data(), size: 32)
                    .accessibilityHidden(true)
                Text(story.author.handle).font(.subheadline.bold())
                Spacer()
                if story.mine {
                    Button { confirmDelete = true } label: { RiderCompactAction(icon: "ellipsis") }
                        .disabled(deleting)
                        .accessibilityLabel("Действия с историей")
                }
                Button(action: close) { RiderCompactAction(icon: "xmark") }
                    .accessibilityLabel("Закрыть историю")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .background(.black)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !story.caption.isEmpty {
                Text(story.caption).font(.subheadline).multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if story.mine {
                Button { showingViewers = true } label: {
                    Label("Зрители", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                if replySent {
                    Label("Ответ отправлен", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                HStack(spacing: 4) {
                    TextField("Ответить автору…", text: $draft)
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit(sendReply)
                        .onChange(of: draft) { _, value in
                            if value.count > 1000 { draft = String(value.prefix(1000)) }
                            if !sending && !value.isEmpty { draftID = UUID(); replySent = false }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.15), in: Capsule())
                        .disabled(sending)
                    if sending {
                        ProgressView().frame(width: 44, height: 44)
                    } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: sendReply) { RiderCompactAction(icon: "paperplane.fill") }
                            .accessibilityLabel("Отправить ответ")
                    }
                    Button(action: toggleLike) {
                        RiderCompactAction(icon: initialLike ? "heart.fill" : "heart", selected: initialLike)
                            .foregroundStyle(initialLike ? Color.red : .white)
                    }
                    .disabled(changingLike)
                    .accessibilityLabel(initialLike ? "Убрать лайк" : "Поставить лайк")
                    .accessibilityAddTraits(initialLike ? .isSelected : [])
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black)
    }

    private func playbackTime(at now: TimeInterval) -> TimeInterval {
        elapsed + (startedAt.map { max(0, now - $0) } ?? 0)
    }

    private func updatePlayback(_ active: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if active {
            guard startedAt == nil else { return }
            startedAt = now
            player?.play()
        } else {
            elapsed = playbackTime(at: now)
            startedAt = nil
            player?.pause()
        }
    }

    @MainActor private func load() async {
        do {
            let data = try await RiderCommunity.storyMedia(story.id)
            try Task.checkCancellation()
            guard data.count <= RiderPost.maxVideoBytes else { throw CocoaError(.fileReadTooLarge) }
            if story.video {
                let url = RiderMediaEncoding.temporary("mp4")
                defer {
                    if source != url { try? FileManager.default.removeItem(at: url) }
                }
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let asset = AVURLAsset(url: url)
                let time = try await asset.load(.duration)
                try Task.checkCancellation()
                duration = time.seconds.isFinite ? min(30.5, max(0.5, time.seconds)) : 6
                source = url
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } else {
                image = UIImage(data: data)
                guard image != nil else { throw CocoaError(.fileReadCorruptFile) }
            }
            ready = true
            if !story.mine && !story.seen {
                Task {
                    let _: [String: Bool]? = try? await RiderCommunity.decode(story.path + "/seen", method: "PUT")
                }
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func sendReply() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !message.isEmpty else { return }
        let id = draftID
        sending = true
        Task {
            defer { sending = false }
            do {
                _ = try await RiderCommunity.sendMessage(to: story.author.id, id: id, text: message, post: nil)
                draft = ""
                replySent = true
                typing = false
            } catch RiderCommunity.Rejection.forbidden {
                error = "Для отправки личного сообщения открой профиль во вкладке «Райдер»."
            } catch {
                self.error = "Не удалось отправить ответ. Попробуй ещё раз."
            }
        }
    }

    private func toggleLike() {
        guard !changingLike else { return }
        changingLike = true
        Task {
            defer { changingLike = false }
            do {
                let result: [String: Bool] = try await RiderCommunity.decode(story.path + "/like",
                                                                            method: initialLike ? "DELETE" : "PUT")
                guard let liked = result["liked"] else { throw CocoaError(.fileReadCorruptFile) }
                onLike(liked)
            } catch {
                self.error = "Не удалось обновить лайк. Попробуй ещё раз."
            }
        }
    }

    private func deleteStory() {
        deleting = true
        Task {
            defer { deleting = false }
            do { onDelete(try await RiderCommunity.decode(story.path, method: "DELETE")) }
            catch { self.error = "Не удалось удалить историю. Попробуй ещё раз." }
        }
    }
}

private struct RiderStoryViewers: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var people: [RiderStoryViewer] = []
    @State private var offset: Int? = 0
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(people) { viewer in
                    HStack {
                        Text(viewer.person.handle)
                        Spacer()
                        if viewer.liked {
                            Image(systemName: "heart.fill").foregroundStyle(.red)
                                .accessibilityLabel("Понравилась история")
                        }
                    }
                }
                if failed {
                    Button("Повторить загрузку") { Task { await load() } }
                } else if loading {
                    ProgressView()
                } else if people.isEmpty && offset == nil {
                    Text("Пока никто не посмотрел").foregroundStyle(.secondary)
                } else if !people.isEmpty && offset != nil {
                    Button("Показать ещё") { Task { await load() } }
                }
            }
            .navigationTitle("Зрители")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    @MainActor private func load() async {
        guard let offset, !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let page: RiderStoryViewerPage = try await RiderCommunity.decode(path + "/viewers/\(offset)")
            guard !Task.isCancelled else { return }
            let existing = Set(people.map(\.id))
            people.append(contentsOf: page.people.filter { !existing.contains($0.id) })
            self.offset = page.nextOffset
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
