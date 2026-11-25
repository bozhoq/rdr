import AVKit
import PhotosUI
import SwiftUI

struct RiderStory: Decodable, Identifiable {
    let id: UUID
    let author: RiderPerson
    let caption: String
    let createdAt: TimeInterval
    let video: Bool
    let seen: Bool
    let mine: Bool
}

struct RiderStoriesStrip: View {
    @AppStorage("rider.profilePhoto") private var avatar = Data()
    @Environment(\.scenePhase) private var phase
    @State private var stories: [RiderStory] = []
    @State private var opened: Deck?
    @State private var composing = false
    @State private var failed = false
    private struct Deck: Identifiable { let id = UUID(); let items: [RiderStory] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Истории", systemImage: "sun.horizon").font(.subheadline.weight(.semibold))
                Spacer()
                if failed { Button("Обновить") { Task { await load() } }.font(.caption) }
                else { Text("24 часа").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    Button { composing = true } label: {
                        VStack(spacing: 4) {
                            RiderAvatar(photo: avatar, size: 45)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                                        .padding(4).foregroundStyle(.white).background(RiderTheme.action, in: Circle())
                                }
                            Text("Добавить").font(.caption2)
                        }.frame(width: 65, height: 70)
                    }.buttonStyle(.plain).accessibilityLabel("Добавить историю")
                    ForEach(authors) { author in
                        let items = stories.filter { $0.author.id == author.id }.reversed()
                        let fresh = items.contains { !$0.seen }
                        Button {
                            let start = items.firstIndex { !$0.seen } ?? items.startIndex
                            opened = Deck(items: Array(items[start...]))
                        } label: {
                            VStack(spacing: 4) {
                                RiderAvatar(photo: author.avatar ?? Data(), size: 45)
                                    .padding(3)
                                    .overlay { RoundedRectangle(cornerRadius: 17)
                                        .strokeBorder(fresh ? RiderTheme.accent : .secondary.opacity(0.46), lineWidth: 2) }
                                Text(author.name).font(.caption2).lineLimit(1)
                            }.frame(width: 65, height: 70)
                        }.buttonStyle(.plain)
                        .accessibilityLabel(author.name + (fresh ? ", новые истории" : ", истории"))
                    }
                }.padding(.horizontal, 1)
            }.scrollIndicators(.hidden)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
        .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 17))
        .sheet(isPresented: $composing) {
            RiderStoryComposer { stories = $0; composing = false }
        }
        .fullScreenCover(item: $opened, onDismiss: { Task { await load() } }) { deck in
            RiderStoryPlayer(stories: deck.items) { updated in stories = updated }
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
    @State private var camera = false
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
                        Button { typing = false; camera = true } label: { Label("Сделать фото", systemImage: "camera") }
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
            .fullScreenCover(isPresented: $camera) {
                RiderCameraPhoto { image in
                    photo = image.jpegData(compressionQuality: 0.85).flatMap { RiderPostComposer.postJPEG($0) }
                    video = nil
                    story = UUID()
                }.ignoresSafeArea()
            }
        }
        .interactiveDismissDisabled(publishing)
        .task(id: picked) { await load() }
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
    @Environment(\.scenePhase) private var phase
    @State private var index = 0
    @State private var player: AVPlayer?
    @State private var source: URL?
    @State private var image: UIImage?
    @State private var duration = 6.0
    @State private var elapsed = 0.0
    @State private var ready = false
    @State private var failed = false
    @State private var confirmDelete = false

    private var current: RiderStory { stories[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player).allowsHitTesting(false) }
            else if let image { Image(uiImage: image).resizable().scaledToFit() }
            HStack(spacing: 0) {
                Button { if index > 0 { index -= 1 } } label: { Color.clear.contentShape(Rectangle()) }
                    .accessibilityLabel("Предыдущая история")
                Button(action: next) { Color.clear.contentShape(Rectangle()) }
                    .accessibilityLabel("Следующая история")
            }.buttonStyle(.plain)
            if !ready && !failed { ProgressView().tint(.white) }
            if failed { Text("История недоступна").foregroundStyle(.white) }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(stories.indices, id: \.self) { i in
                        ProgressView(value: i < index ? 1.0 : i == index ? min(elapsed / duration, 1) : 0.0).tint(.white)
                    }
                }
                HStack(spacing: 8) {
                    RiderAvatar(photo: current.author.avatar ?? Data(), size: 32)
                    Text(current.author.handle).font(.subheadline.bold())
                    Spacer()
                    if current.mine {
                        Button { confirmDelete = true } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("Действия с историей")
                    }
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .accessibilityLabel("Закрыть")
                }.foregroundStyle(.white)
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !current.caption.isEmpty {
                Text(current.caption).font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(12).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14)).padding()
            }
        }
        .task(id: current.id) { await load(current) }
        .task(id: ready && phase == .active && !confirmDelete) {
            guard ready, phase == .active, !confirmDelete else { player?.pause(); return }
            player?.play()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                elapsed += 0.1
                if elapsed >= duration { next(); return }
            }
        }
        .onDisappear { reset() }
        .confirmationDialog("Удалить историю?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                let id = current.id
                Task {
                    if let latest: [RiderStory] = try? await RiderCommunity.decode("stories/" + id.uuidString.lowercased(), method: "DELETE") {
                        deleted(latest)
                        dismiss()
                    }
                }
            }
        }
    }

    private func next() {
        if index + 1 < stories.count { index += 1 } else { dismiss() }
    }

    @MainActor private func load(_ story: RiderStory) async {
        reset()
        do {
            let data = try await RiderCommunity.storyMedia(story.id)
            try Task.checkCancellation()
            guard data.count <= RiderPost.maxVideoBytes else { throw CocoaError(.fileReadTooLarge) }
            if story.video {
                let url = RiderMediaEncoding.temporary("mp4")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                source = url
                let asset = AVURLAsset(url: url)
                let time = try await asset.load(.duration)
                try Task.checkCancellation()
                duration = time.seconds.isFinite ? min(30.5, max(0.5, time.seconds)) : 6
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } else {
                image = UIImage(data: data)
                guard image != nil else { throw CocoaError(.fileReadCorruptFile) }
            }
            ready = true
            if !story.seen {
                let _: [String:Bool]? = try? await RiderCommunity.decode("stories/" + story.id.uuidString.lowercased() + "/seen", method: "PUT")
            }
        } catch { if !Task.isCancelled { failed = true } }
    }

    private func reset() {
        ready = false
        elapsed = 0
        duration = 6
        failed = false
        player?.pause()
        player = nil
        image = nil
        if let source { try? FileManager.default.removeItem(at: source) }
        source = nil
    }
}
