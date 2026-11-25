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

struct RiderChatPlayback: View {
    let url: URL
    let circle: Bool
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        if circle {
            ZStack {
                if let player { VideoPlayer(player: player).allowsHitTesting(false) }
                Button(action: toggle) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .padding(13).background(.black.opacity(0.57), in: Circle()).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityLabel(playing ? "Пауза" : "Смотреть кружочек")
            }
            .frame(width: 168, height: 168)
            .background(.black, in: Circle()).clipShape(Circle())
            .overlay { Circle().strokeBorder(RiderTheme.accent.opacity(0.7), lineWidth: 2) }
            .task { player = AVPlayer(url: url) }
            .onDisappear { player?.pause() }
        } else {
            Button(action: toggle) {
                Label(playing ? "Пауза" : "Голосовое", systemImage: playing ? "pause.circle.fill" : "waveform.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(RiderTheme.accent)
            }.buttonStyle(.plain)
            .task { player = AVPlayer(url: url) }
            .onDisappear { player?.pause() }
        }
    }

    private func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if let duration = player.currentItem?.duration.seconds, duration.isFinite,
               player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
            playing = true
        } else {
            player.pause()
            playing = false
        }
    }
}
