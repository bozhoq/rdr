import AVKit
import SwiftUI
import UIKit

enum RiderMediaEncoding {
    static func clip(from source: URL, maxBytes: Int = RiderPost.maxVideoBytes) async throws -> (Data, Data) {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, (0.2...30.3).contains(duration.seconds),
              let exporter = AVAssetExportSession(asset: asset, presetName: maxBytes < RiderPost.maxVideoBytes
                                                  ? AVAssetExportPreset640x480 : AVAssetExportPreset960x540) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = temporary("mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let (frame, _) = try await generator.image(at: .zero)
        guard let cover = UIImage(cgImage: frame).jpegData(compressionQuality: 0.68), cover.count <= 390_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (cover, try Data(contentsOf: output))
    }

    static func temporary(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
    }
}

struct RiderCameraPhoto: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let selected: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: RiderCameraPhoto
        init(_ parent: RiderCameraPhoto) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.selected(image) }
            parent.dismiss()
        }
    }
}

struct RiderChatCapture: View {
    let started: () -> Void
    let captured: (RiderChatUpload) -> Void
    let failed: (String) -> Void

    @State private var video = false
    @State private var rear = false
    @State private var held = false
    @State private var longPress: Task<Void, Never>?
    @State private var beganAt: Date?
    @State private var processing = false
    @State private var camera: RoundCamera?
    @State private var audio: AVAudioRecorder?
    @State private var timeLimit: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .trailing) {
            if video {
                Button {
                    rear.toggle()
                    camera?.switchCamera(rear ? .back : .front)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .frame(width: 42, height: 42)
                }.buttonStyle(.plain).accessibilityLabel(rear ? "Фронтальная камера" : "Основная камера")
                .offset(x: -44, y: -53)
            }
            Image(systemName: video ? "video.circle" : "mic")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(beganAt == nil ? RiderTheme.accent : .red)
                .frame(width: 42, height: 42)
                .background(RiderTheme.surface, in: Circle())
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in startPress() }
                    .onEnded { _ in endPress() })
                .accessibilityLabel(video ? "Запись кружочка" : "Запись голосового")
                .accessibilityHint("Коснись для смены режима, удерживай для записи")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { video.toggle() }
                .accessibilityAction(named: Text("Начать или закончить запись")) {
                    if beganAt != nil { finish() }
                    else { held = true; Task { await begin() } }
                }
        }
        .overlay(alignment: .trailing) {
            if let beganAt {
                VStack(spacing: 4) {
                    if let camera {
                        CameraPreview(session: camera.session)
                            .frame(width: 154, height: 154)
                            .clipShape(Circle())
                            .overlay { Circle().strokeBorder(RiderTheme.accent, lineWidth: 3) }
                    }
                    TimelineView(.periodic(from: beganAt, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(beganAt)))
                        Label(String(format: "%d:%02d", seconds / 60, seconds % 60), systemImage: "record.circle.fill")
                            .font(.caption.bold().monospacedDigit()).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.75), in: Capsule())
                    }
                }.fixedSize().offset(x: -5, y: camera == nil ? -53 : -148)
                .allowsHitTesting(false)
            }
        }
        .onDisappear {
            held = false
            longPress?.cancel()
            timeLimit?.cancel()
            if let audio {
                audio.stop()
                try? FileManager.default.removeItem(at: audio.url)
                self.audio = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            camera?.stop(discard: true)
            camera = nil
        }
    }

    private func startPress() {
        guard !held, !processing else { return }
        held = true
        longPress = Task {
            do { try await Task.sleep(for: .milliseconds(270)) } catch { return }
            if held { await begin() }
        }
    }

    private func endPress() {
        guard held else { return }
        held = false
        let wasTap = longPress != nil && !processing && beganAt == nil
        longPress?.cancel()
        longPress = nil
        if beganAt != nil { finish() }
        else if wasTap { video.toggle() }
    }

    @MainActor private func begin() async {
        guard held, !processing, beganAt == nil else { return }
        processing = true
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let lens = video ? await AVCaptureDevice.requestAccess(for: .video) : true
        processing = false
        guard mic, lens else { failed("Разреши Rider доступ к микрофону и камере в настройках iPhone."); return }
        guard held, !Task.isCancelled else { return }
        started()
        do {
            if video {
                let capture = RoundCamera()
                camera = capture
                capture.start(position: rear ? .back : .front) { result in
                    Task { @MainActor in await completeVideo(result) }
                }
            } else {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                let recorder = try AVAudioRecorder(url: RiderMediaEncoding.temporary("m4a"), settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 32_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000
                ])
                audio = recorder
                guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            }
            beganAt = Date()
            timeLimit = Task {
                do { try await Task.sleep(for: .seconds(video ? 30 : 60)); finish() } catch {}
            }
        } catch {
            audio = nil
            failed("Не удалось начать запись.")
        }
    }

    @MainActor private func finish() {
        guard let beganAt else { return }
        self.beganAt = nil
        timeLimit?.cancel()
        let short = Date().timeIntervalSince(beganAt) < 0.45
        if let camera {
            processing = !short
            camera.stop(discard: short)
        } else if let audio {
            audio.stop()
            self.audio = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            defer { try? FileManager.default.removeItem(at: audio.url) }
            if !short {
                do {
                    captured(try RiderChatUpload(filename: "voice.m4a", contentType: "audio/mp4", data: Data(contentsOf: audio.url)))
                } catch { failed("Не удалось сохранить голосовое.") }
            }
        }
    }

    @MainActor private func completeVideo(_ result: Result<URL?, Error>) async {
        camera = nil
        beganAt = nil
        timeLimit?.cancel()
        defer { processing = false }
        do {
            guard let url = try result.get() else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            let (_, data) = try await RiderMediaEncoding.clip(from: url, maxBytes: RiderChatUpload.maxBytes)
            captured(try RiderChatUpload(filename: "circle.mp4", contentType: "video/mp4", data: data))
        } catch { failed("Не удалось записать кружочек. Попробуй короче.") }
    }
}

private final class RoundCamera: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "rider.camera")
    private let movie = AVCaptureMovieFileOutput()
    private var lens: AVCaptureDeviceInput?
    private var completion: ((Result<URL?, Error>) -> Void)?
    private var discarded = false

    func start(position: AVCaptureDevice.Position, completion: @escaping (Result<URL?, Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.session.sessionPreset = .medium
            guard self.useCamera(position),
                  let microphone = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: microphone),
                  self.session.canAddInput(input), self.session.canAddOutput(self.movie) else {
                self.complete(.failure(CocoaError(.featureUnsupported)))
                return
            }
            self.session.addInput(input)
            self.session.addOutput(self.movie)
            self.movie.maxRecordedDuration = CMTime(seconds: 30, preferredTimescale: 600)
            self.movie.maxRecordedFileSize = 14 * 1024 * 1024
            self.movie.connection(with: .video)?.videoOrientation = .portrait
            self.session.startRunning()
            self.movie.startRecording(to: RiderMediaEncoding.temporary("mov"), recordingDelegate: self)
        }
    }

    func switchCamera(_ position: AVCaptureDevice.Position) {
        queue.async { _ = self.useCamera(position) }
    }

    private func useCamera(_ position: AVCaptureDevice.Position) -> Bool {
        if lens?.device.position == position { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let lens { session.removeInput(lens) }
        guard session.canAddInput(input) else {
            if let lens, session.canAddInput(lens) { session.addInput(lens) }
            return false
        }
        session.addInput(input)
        lens = input
        return true
    }

    func stop(discard: Bool) {
        queue.async {
            self.discarded = self.discarded || discard
            if self.movie.isRecording { self.movie.stopRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            if self.discarded {
                try? FileManager.default.removeItem(at: url)
                self.complete(.success(nil))
            } else if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                try? FileManager.default.removeItem(at: url)
                self.complete(.failure(error))
            } else {
                self.complete(.success(url))
            }
        }
    }

    private func complete(_ result: Result<URL?, Error>) {
        if session.isRunning { session.stopRunning() }
        let callback = completion
        completion = nil
        callback?(result)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Host: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        guard let layer = view.layer as? AVCaptureVideoPreviewLayer else { return }
        layer.videoGravity = .resizeAspectFill
        layer.session = session
        layer.connection?.videoOrientation = .portrait
    }
}


@MainActor final class RiderChatPlayer: ObservableObject {
    struct Track: Identifiable {
        let id: UUID
        let url: URL
        let title: String
        let circle: Bool
    }

    @Published private(set) var track: Track?
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var speed = 1.0
    private(set) var player: AVPlayer?
    private var tracking: Task<Void, Never>?

    func select(_ item: Track) {
        if track?.id == item.id { toggle(); return }
        close()
        let player = AVPlayer(url: item.url)
        self.player = player
        track = item
        toggle()
        tracking = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime) {
                guard let self, !Task.isCancelled else { return }
                if self.track?.id == item.id, let received = notification.object as? AVPlayerItem, received === player.currentItem {
                    self.close()
                    return
                }
            }
        }
    }

    func updateProgress() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        let length = player.currentItem?.duration.seconds ?? 0
        if length.isFinite && length > 0 { duration = length }
        if seconds.isFinite { position = max(0, seconds) }
        if duration > 0 && playing && position >= duration - 0.02 && player.timeControlStatus == .paused { close() }
    }

    func toggle() {
        guard let player else { return }
        playing.toggle()
        if playing { player.playImmediately(atRate: Float(speed)) }
        else { player.pause() }
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        if playing { player?.playImmediately(atRate: Float(speed)) }
    }

    func seek(_ seconds: Double) {
        guard duration > 0, let player else { return }
        let target = min(duration, max(0, seconds))
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func close() {
        tracking?.cancel()
        tracking = nil
        player?.pause()
        player = nil
        track = nil
        playing = false
        position = 0
        duration = 0
    }

    static func time(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

struct RiderChatPlayerBar: View {
    @ObservedObject var playback: RiderChatPlayer
    @State private var seek: Double?
    private let speeds = [1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        if let track = playback.track {
            VStack(spacing: 1) {
                HStack(spacing: 12) {
                    Button { playback.toggle() } label: {
                        Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 36, height: 36)
                    }.accessibilityLabel(playback.playing ? "Пауза" : "Воспроизвести")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.circle ? "Видеосообщение" : "Голосовое сообщение")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 3)
                    Menu {
                        ForEach(speeds, id: \.self) { speed in
                            Button {
                                playback.setSpeed(speed)
                            } label: {
                                if playback.speed == speed { Label(label(speed), systemImage: "checkmark") }
                                else { Text(label(speed)) }
                            }
                        }
                    } label: {
                        Text(label(playback.speed)).font(.subheadline.bold().monospacedDigit())
                            .padding(.horizontal, 6).frame(height: 36)
                    }
                    .accessibilityLabel("Скорость воспроизведения \(label(playback.speed))")
                    Button { playback.close() } label: {
                        Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 36, height: 36)
                    }.accessibilityLabel("Закрыть проигрыватель")
                }
                HStack(spacing: 8) {
                    Text(RiderChatPlayer.time(seek ?? playback.position))
                    Slider(value: Binding(get: { min(max(0.1, playback.duration), seek ?? playback.position) },
                                          set: { seek = $0 }),
                           in: 0...max(0.1, playback.duration), onEditingChanged: { editing in
                        if !editing, let seek { playback.seek(seek); self.seek = nil }
                    }).disabled(playback.duration <= 0)
                    .accessibilityLabel("Перемотка")
                    Text(RiderChatPlayer.time(playback.duration))
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(RiderTheme.border).allowsHitTesting(false) }
            .padding(.horizontal, 10)
            .task(id: track.id) {
                seek = nil
                while !Task.isCancelled && playback.track?.id == track.id {
                    playback.updateProgress()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
    }

    private func label(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

struct RiderChatPlayback: View {
    let url: URL
    let circle: Bool
    let message: UUID
    let title: String
    @ObservedObject var playback: RiderChatPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: UIImage?
    @State private var scrub: Double?

    private var active: Bool { playback.track?.id == message }
    private var progress: Double {
        playback.duration > 0 ? min(1, (scrub ?? playback.position) / playback.duration) : 0
    }

    var body: some View {
        Group {
            if circle {
                ZStack {
                    Circle().fill(.black)
                    if active, let player = playback.player { RiderVideoLayer(player: player) }
                    else if let poster { Image(uiImage: poster).resizable().scaledToFill() }
                    if active { progressRing }
                    if !active || !playback.playing {
                        Button(action: play) {
                            Image(systemName: "play.fill").font(.headline)
                                .padding(14).background(.black.opacity(0.64), in: Circle()).foregroundStyle(.white)
                        }.buttonStyle(.plain).accessibilityLabel("Смотреть кружочек")
                    }
                }
                .frame(width: active ? 270 : 144, height: active ? 270 : 144)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(RiderTheme.accent.opacity(0.78), lineWidth: 2).allowsHitTesting(false) }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: active)
                .task(id: url) { await loadCover() }
            } else {
                Button(action: play) {
                    HStack(spacing: 8) {
                        Image(systemName: active && playback.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                        Text("Голосовое").font(.subheadline.weight(.semibold))
                        if active { Text(RiderChatPlayer.time(playback.position)).font(.caption.monospacedDigit()) }
                    }.foregroundStyle(RiderTheme.accent)
                }.buttonStyle(.plain)
            }
        }
    }

    private var progressRing: some View {
        GeometryReader { area in
            let center = CGPoint(x: area.size.width / 2, y: area.size.height / 2)
            ZStack {
                Circle().strokeBorder(.white.opacity(0.32), lineWidth: 3).padding(8)
                Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(9)
                Circle().strokeBorder(.clear, lineWidth: 26)
                    .contentShape(RiderScrubRing(), eoFill: true)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        scrub = seconds(at: value.location, around: center)
                    }.onEnded { value in
                        playback.seek(seconds(at: value.location, around: center))
                        scrub = nil
                    })
                    .accessibilityHidden(true)
            }
        }
    }

    private func seconds(at point: CGPoint, around center: CGPoint) -> Double {
        let angle = atan2(Double(point.x - center.x), Double(center.y - point.y))
        let fraction = (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi)
        return playback.duration * fraction
    }

    private func play() {
        playback.select(.init(id: message, url: url, title: title, circle: circle))
    }

    @MainActor private func loadCover() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        if let frame = try? await generator.image(at: .zero), !Task.isCancelled { poster = UIImage(cgImage: frame.image) }
    }
}

private struct RiderScrubRing: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        path.addEllipse(in: rect.insetBy(dx: 28, dy: 28))
        return path
    }
}

private struct RiderVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    final class Host: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        guard let layer = view.layer as? AVPlayerLayer else { return }
        layer.player = player
        layer.videoGravity = .resizeAspectFill
    }
}

struct RiderChatBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let motifs = ["kite", "board", "wind", "palm.tree", "sun.horizon", "water.waves", "umbrella.beach", "location.north.line"]
            let columns = max(3, Int(size.width / 70))
            let step = size.width / Double(columns)
            guard step > 0 else { return }
            for row in 0..<(Int(size.height / 72) + 2) {
                for column in -1...columns {
                    var tile = context
                    let index = (row * 5 + column + motifs.count) % motifs.count
                    tile.translateBy(x: Double(column) * step + step * (row.isMultiple(of: 2) ? 0.43 : 0.89),
                                     y: Double(row) * 72 + 20)
                    tile.rotate(by: .degrees(Double((row * 17 + (column + 1) * 11) % 42) - 21))
                    tile.opacity = scheme == .dark ? 0.20 : 0.23
                    let motif = motifs[index]
                    if motif == "kite" || motif == "board" {
                        let glyph = EquipmentGlyph(kind: motif == "kite" ? .kite : .board)
                        tile.stroke(glyph.path(in: CGRect(x: -15, y: -15, width: 30, height: 30)),
                                    with: .color(RiderTheme.accent), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    } else {
                        tile.draw(Text(Image(systemName: motif)).font(.system(size: 26, weight: .ultraLight))
                            .foregroundColor(RiderTheme.accent), at: .zero)
                    }
                }
            }
        }.background(RiderTheme.canvas)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}
