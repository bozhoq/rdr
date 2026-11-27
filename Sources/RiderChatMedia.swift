import AVKit
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct RiderVoiceMessage: View {
    let url: URL
    let playing: Bool
    let elapsed: String?
    let play: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowWidth = RiderChatPlayback.thumbnailDiameter
    @State private var requested = false
    @State private var expanded = false
    @State private var transcript: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button(action: play) {
                    HStack(spacing: 6) {
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 21))
                        Text("Голосовое").font(.subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.68)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Приостановить голосовое" : "Воспроизвести голосовое")
                transcriptButton
            }
            .foregroundStyle(RiderTheme.accent)
            if let elapsed {
                Text(elapsed).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if requested {
                ProgressView("Распознаём речь…").font(.caption)
            } else if expanded, let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if expanded, let transcript {
                Text(transcript).font(.subheadline).textSelection(.enabled)
            }
        }
        .frame(width: min(220, max(RiderChatPlayback.thumbnailDiameter, rowWidth)), alignment: .leading)
        .task(id: requested) {
            guard requested else { return }
            defer { requested = false }
            do {
                let result = try await RiderSpeechTranscription.recognize(url)
                try Task.checkCancellation()
                transcript = result
            } catch {
                if !Task.isCancelled {
                    self.error = (error as? RiderSpeechTranscription.Failure)?.message
                        ?? "Не удалось расшифровать голосовое. Нажми «А» для повтора."
                }
            }
        }
    }

    private var transcriptButton: some View {
        Button {
            if transcript != nil {
                expanded.toggle()
            } else {
                error = nil
                expanded = true
                requested = true
            }
        } label: {
            VStack(spacing: 1) {
                Text("А").font(.system(size: 13, weight: .bold))
                Image(systemName: expanded && transcript != nil ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .frame(width: 30, height: 30)
            .background(RiderTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .frame(width: 44, height: 44, alignment: .trailing)
            .contentShape(.interaction, Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(requested)
        .accessibilityLabel(expanded && transcript != nil ? "Свернуть расшифровку" : "Расшифровать голосовое")
    }
}

private enum RiderSpeechTranscription {
    enum Failure: Error {
        case permission, unavailable, empty

        var message: String {
            switch self {
            case .permission: return "Разреши Rider распознавание речи в настройках iPhone."
            case .unavailable: return "Распознавание русского языка на этом iPhone сейчас недоступно."
            case .empty: return "В голосовом не удалось разобрать речь."
            }
        }
    }

    static func recognize(_ url: URL) async throws -> String {
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard permission == .authorized else { throw Failure.permission }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw Failure.unavailable }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 45)
        var sections: [String] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }
            let text = try await recognize(buffer, with: recognizer)
            if !text.isEmpty { sections.append(text) }
        }
        guard !sections.isEmpty else { throw Failure.empty }
        return sections.joined(separator: " ")
    }

    private static func recognize(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let (results, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                continuation.yield(result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines))
                continuation.finish()
            } else if let error {
                continuation.finish(throwing: error)
            }
        }
        defer { task.cancel() }
        request.append(buffer)
        request.endAudio()
        for try await text in results { return text }
        try Task.checkCancellation()
        return ""
    }
}

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

    static func chatCircle(from sources: [URL], limit: Double) async throws -> Data {
        let asset: AVAsset
        let videoComposition: AVVideoComposition?
        if sources.count == 1, let only = sources.first {
            asset = AVURLAsset(url: only)
            videoComposition = nil
        } else {
            let joined = try await joinCircleSegments(sources)
            asset = joined.0
            videoComposition = joined.1
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds >= 0.2 else { throw CocoaError(.fileReadCorruptFile) }
        let maximum = CMTime(seconds: limit, preferredTimescale: 600)
        let bytes: [Int] = sources.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        let canRemux = videoComposition == nil && bytes.count == sources.count &&
            bytes.reduce(0, +) <= RiderChatUpload.maxBytes
        var presets = canRemux ? [AVAssetExportPresetPassthrough] : []
        presets += [AVAssetExportPreset640x480, AVAssetExportPresetLowQuality]
        for preset in presets {
            try Task.checkCancellation()
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
                  exporter.supportedFileTypes.contains(.mp4) else { continue }
            let output = temporary("mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            exporter.outputURL = output
            exporter.outputFileType = .mp4
            exporter.videoComposition = videoComposition
            exporter.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, maximum))
            exporter.shouldOptimizeForNetworkUse = true
            await exporter.export()
            try Task.checkCancellation()
            guard exporter.status == .completed, let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= RiderChatUpload.maxBytes else { continue }
            return try Data(contentsOf: output)
        }
        throw CocoaError(.fileReadTooLarge)
    }

    private static func joinCircleSegments(_ sources: [URL]) async throws -> (AVComposition, AVVideoComposition?) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let side: CGFloat = 480
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var firstGeometry: (size: CGSize, transform: CGAffineTransform)?
        var matchingGeometry = true
        var cursor = CMTime.zero
        for url in sources {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await video.load(.timeRange)
            guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { continue }
            try videoTrack.insertTimeRange(range, of: video, at: cursor)

            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = CMTimeRangeGetIntersection(try await audio.load(.timeRange), otherRange: range)
                if audioRange.duration.seconds > 0 {
                    try audioTrack.insertTimeRange(audioRange, of: audio, at: cursor + (audioRange.start - range.start))
                }
            }

            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            if let firstGeometry {
                matchingGeometry = matchingGeometry && size == firstGeometry.size && transform == firstGeometry.transform
            } else {
                firstGeometry = (size, transform)
            }
            let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
            guard bounds.width > 0, bounds.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let scale = max(side / bounds.width, side / bounds.height)
            let crop = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (side - bounds.width * scale) / 2,
                                                 y: (side - bounds.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(transform.concatenating(crop), at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + range.duration
        }
        guard let firstGeometry else { throw CocoaError(.fileReadCorruptFile) }
        if matchingGeometry {
            videoTrack.preferredTransform = firstGeometry.transform
            return (composition, nil)
        }
        let rendered = AVMutableVideoComposition()
        rendered.instructions = instructions
        rendered.renderSize = CGSize(width: side, height: side)
        rendered.frameDuration = CMTime(value: 1, timescale: 30)
        return (composition, rendered)
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

struct RiderCameraVideo: UIViewControllerRepresentable {
    let selected: (Result<URL, Error>) -> Void
    @Environment(\.dismiss) private var dismiss

    static var available: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) &&
        UIImagePickerController.availableMediaTypes(for: .camera)?.contains(UTType.movie.identifier) == true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoMaximumDuration = 30
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: RiderCameraVideo
        init(_ parent: RiderCameraVideo) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            do {
                guard let source = info[.mediaURL] as? URL else { throw CocoaError(.fileReadCorruptFile) }
                let saved = RiderMediaEncoding.temporary(source.pathExtension.isEmpty ? "mov" : source.pathExtension)
                try FileManager.default.copyItem(at: source, to: saved)
                parent.selected(.success(saved))
            } catch {
                parent.selected(.failure(error))
            }
            parent.dismiss()
        }
    }
}

@MainActor final class RiderChatRecorder: ObservableObject {
    static let circleLimit = 59.0
    static let voiceLimit = 180.0

    enum Event {
        case began
        case captured(RiderChatUpload)
        case failed(String)
    }

    @Published private(set) var isCircle = false
    @Published private(set) var beganAt: Date?
    @Published private(set) var locked = false
    @Published private(set) var busy = false
    @Published private(set) var preview: AVCaptureSession?
    @Published private(set) var rear = false
    @Published private(set) var switching = false
    @Published private(set) var torchOn = false

    private var camera: RoundCamera?
    private var audio: AVAudioRecorder?
    private var holdTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var attempt: UUID?
    private var event: ((Event) -> Void)?
    private var pressed = false
    private var didHold = false
    private var translation = CGSize.zero

    var limit: Double { isCircle ? Self.circleLimit : Self.voiceLimit }

    func press(translation: CGSize, event: @escaping (Event) -> Void) {
        if !pressed {
            guard !busy, beganAt == nil else { return }
            pressed = true
            didHold = false
            holdTask = Task {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard pressed else { return }
                didHold = true
                await begin(locked: false, event: event)
            }
        }
        move(to: translation)
    }

    func move(to translation: CGSize) {
        guard pressed else { return }
        self.translation = translation
        guard beganAt != nil, !locked else { return }
        if translation.width < -78 && -translation.width > -translation.height {
            discard()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if translation.height < -62 && -translation.height >= abs(translation.width) {
            locked = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func release() {
        guard pressed else { return }
        pressed = false
        holdTask?.cancel()
        holdTask = nil
        if beganAt != nil {
            if !locked { finish() }
        } else if !didHold && !busy {
            isCircle.toggle()
        } else if busy && camera == nil && exportTask == nil {
            discard()
        }
    }

    func cancelPress() {
        guard pressed else { return }
        pressed = false
        holdTask?.cancel()
        holdTask = nil
        if !locked && (beganAt != nil || (busy && camera == nil && exportTask == nil)) { discard() }
    }

    func accessibleRecord(event: @escaping (Event) -> Void) {
        if beganAt != nil { finish(); return }
        Task { await begin(locked: true, event: event) }
    }

    private func begin(locked: Bool, event: @escaping (Event) -> Void) async {
        guard !busy, beganAt == nil else { return }
        let id = UUID()
        attempt = id
        busy = true
        self.event = event
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard attempt == id else { return }
        let lens = mic && isCircle ? await AVCaptureDevice.requestAccess(for: .video) : true
        guard attempt == id else { return }
        guard (locked || pressed), !Task.isCancelled else { discard(); return }
        guard mic, lens else {
            complete(.failed(isCircle ? "Разреши доступ к камере и микрофону в настройках iPhone."
                                      : "Разреши доступ к микрофону в настройках iPhone."))
            return
        }
        event(.began)
        self.locked = locked
        if isCircle {
            let capture = RoundCamera()
            rear = false
            torchOn = false
            camera = capture
            preview = capture.session
            beganAt = Date()
            busy = false
            capture.start(position: .front, maxDuration: Self.circleLimit) { result in
                Task { @MainActor in self.completeVideo(result, attempt: id) }
            }
        } else {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                let recorder = try AVAudioRecorder(url: RiderMediaEncoding.temporary("m4a"), settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 32_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000
                ])
                audio = recorder
                guard recorder.record(forDuration: Self.voiceLimit) else { throw CocoaError(.fileWriteUnknown) }
                beganAt = Date()
                busy = false
                limitTask = Task {
                    do { try await Task.sleep(for: .seconds(Self.voiceLimit)) } catch { return }
                    finish()
                }
            } catch {
                removeAudio()
                complete(.failed("Не удалось начать голосовую запись."))
            }
        }
        move(to: translation)
    }

    func flipCamera() {
        guard let camera, !switching, beganAt != nil else { return }
        let next = !rear
        switching = true
        camera.switchCamera(next ? .back : .front) { changed in
            Task { @MainActor in
                guard self.camera === camera else { return }
                self.switching = false
                self.torchOn = false
                if changed {
                    self.rear = next
                } else if self.beganAt != nil {
                    self.event?(.failed("Не удалось переключить камеру. Запись продолжается."))
                }
            }
        }
    }

    func toggleTorch() {
        guard let camera, rear, !switching, beganAt != nil else { return }
        let enabled = !torchOn
        camera.setTorch(enabled) { changed in
            Task { @MainActor in
                if self.camera === camera && self.rear && changed { self.torchOn = enabled }
            }
        }
    }

    func finish() {
        guard let beganAt else { return }
        let short = Date().timeIntervalSince(beganAt) < 0.45
        if short { discard(); return }
        self.beganAt = nil
        locked = false
        limitTask?.cancel()
        limitTask = nil
        if let camera {
            busy = true
            preview = nil
            camera.stop(discard: false)
        } else if let audio {
            audio.stop()
            defer { removeAudio() }
            do {
                let upload = try RiderChatUpload(filename: "voice.m4a", contentType: "audio/mp4", data: Data(contentsOf: audio.url))
                complete(.captured(upload))
            } catch { complete(.failed("Не удалось сохранить голосовое.")) }
        }
    }

    func discard() {
        attempt = nil
        event = nil
        beganAt = nil
        locked = false
        preview = nil
        switching = false
        busy = false
        limitTask?.cancel()
        limitTask = nil
        exportTask?.cancel()
        exportTask = nil
        camera?.stop(discard: true)
        camera = nil
        if audio != nil { removeAudio() }
    }

    private func removeAudio() {
        if let audio {
            audio.stop()
            try? FileManager.default.removeItem(at: audio.url)
        }
        self.audio = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func complete(_ result: Event) {
        let callback = event
        event = nil
        attempt = nil
        busy = false
        locked = false
        callback?(result)
    }

    private func completeVideo(_ result: Result<[URL], Error>, attempt id: UUID) {
        guard attempt == id else {
            for url in (try? result.get()) ?? [] { try? FileManager.default.removeItem(at: url) }
            return
        }
        camera = nil
        preview = nil
        beganAt = nil
        switching = false
        locked = false
        busy = true
        exportTask = Task {
            defer { if attempt == id { exportTask = nil } }
            do {
                let urls = try result.get()
                guard !urls.isEmpty else { discard(); return }
                defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
                let data = try await RiderMediaEncoding.chatCircle(from: urls, limit: Self.circleLimit)
                guard attempt == id, !Task.isCancelled else { return }
                let upload = try RiderChatUpload(filename: "circle.mp4", contentType: "video/mp4", data: data)
                exportTask = nil
                complete(.captured(upload))
            } catch {
                guard attempt == id, !Task.isCancelled else { return }
                exportTask = nil
                complete(.failed("Не удалось сохранить кружочек."))
            }
        }
    }
}

struct RiderChatCapture: View {
    @ObservedObject var recorder: RiderChatRecorder
    let event: (RiderChatRecorder.Event) -> Void
    @GestureState private var fingerDown = false

    static let blue = Color(red: 0.16, green: 0.42, blue: 0.85)

    var body: some View {
        Group {
            if recorder.locked && recorder.beganAt != nil {
                Button { recorder.finish() } label: { control(icon: "arrow.up", active: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Отправить запись")
            } else {
                control(icon: recorder.isCircle ? "video" : "mic", active: recorder.beganAt != nil)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($fingerDown) { _, down, _ in down = true }
                        .onChanged { recorder.press(translation: $0.translation, event: event) }
                        .onEnded {
                            recorder.move(to: $0.translation)
                            recorder.release()
                        })
                    .accessibilityLabel(recorder.isCircle ? "Запись кружочка" : "Запись голосового")
                    .accessibilityHint("Коснись для смены режима, удерживай для записи")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { recorder.press(translation: .zero, event: event); recorder.release() }
                    .accessibilityAction(named: Text("Начать или отправить запись")) {
                        recorder.accessibleRecord(event: event)
                    }
            }
        }
        .onChange(of: fingerDown) { _, down in
            if !down {
                Task { @MainActor in
                    await Task.yield()
                    if !fingerDown { recorder.cancelPress() }
                }
            }
        }
    }

    private func control(icon: String, active: Bool) -> some View {
        ZStack {
            if active {
                Circle().fill(Self.blue.opacity(0.19)).frame(width: 66, height: 66)
                Circle().fill(Self.blue.opacity(0.38)).frame(width: 58, height: 58)
            }
            if recorder.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: active ? 23 : 20, weight: .semibold))
                    .foregroundStyle(active ? Color.white : RiderTheme.accent)
                    .frame(width: active ? 52 : 44, height: active ? 52 : 44)
                    .background(active ? Self.blue : RiderTheme.surface, in: Circle())
            }
        }
        .frame(width: 52, height: 48)
        .contentShape(Rectangle())
    }
}

struct RiderRecordingStatus: View {
    @ObservedObject var recorder: RiderChatRecorder

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
            if let start = recorder.beganAt {
                TimelineView(.periodic(from: start, by: 0.1)) { frame in
                    let tenths = Int(min(recorder.limit, max(0, frame.date.timeIntervalSince(start))) * 10)
                    Text(String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10))
                        .font(.subheadline.monospacedDigit())
                }
            }
            Spacer(minLength: 6)
            if recorder.locked {
                Button("Отмена", role: .destructive) { recorder.discard() }
                    .buttonStyle(.borderless)
            } else {
                Label("Влево для отмены", systemImage: "chevron.left")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background(.regularMaterial, in: Capsule())
    }
}

struct RiderCircleRecordingStage: View {
    let session: AVCaptureSession
    @ObservedObject var recorder: RiderChatRecorder

    var body: some View {
        GeometryReader { bounds in
            let size = min(bounds.size.width * 0.88, bounds.size.height * 0.73, 400)
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                preview(size: size).allowsHitTesting(false)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button { recorder.flipCamera() } label: { tool("camera.rotate.fill") }
                        .accessibilityLabel(recorder.rear ? "Переключить на фронтальную камеру" : "Переключить на основную камеру")
                    if recorder.rear {
                        Button { recorder.toggleTorch() } label: { tool(recorder.torchOn ? "bolt.fill" : "bolt.slash") }
                            .accessibilityLabel(recorder.torchOn ? "Выключить подсветку" : "Включить подсветку")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 18)
                .padding(.bottom, 12)
                .disabled(recorder.switching)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LinearGradient(colors: [Color(red: 0.04, green: 0.14, blue: 0.20), .black],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
    }

    private func tool(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.title3)
            .frame(width: 48, height: 48)
            .background(.white.opacity(0.14), in: Circle())
            .contentShape(.interaction, Rectangle())
    }

    private func preview(size: CGFloat) -> some View {
        CameraPreview(session: session)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                if let start = recorder.beganAt {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { frame in
                        let fraction = min(1, max(0, frame.date.timeIntervalSince(start) / recorder.limit))
                        Circle().inset(by: 3).strokeBorder(.white.opacity(0.24), lineWidth: 3)
                            .overlay {
                                Circle().trim(from: 0, to: fraction)
                                    .stroke(RiderChatCapture.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .padding(5)
                            }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

private final class RoundCamera: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "rider.camera")
    private let movie = AVCaptureMovieFileOutput()
    private var lens: AVCaptureDeviceInput?
    private var completion: ((Result<[URL], Error>) -> Void)?
    private var discarded = false
    private var stopRequested = false
    private var segments: [URL] = []
    private var currentSegment: URL?
    private var closingSegment = false
    private var remaining: Double = 0
    private var switching: (position: AVCaptureDevice.Position, callback: (Bool) -> Void)?
    // Keep the delegate alive until AVFoundation delivers the final file.
    private var activeCapture: RoundCamera?

    func start(position: AVCaptureDevice.Position, maxDuration: Double, completion: @escaping (Result<[URL], Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.activeCapture = self
            self.remaining = maxDuration
            guard self.useCamera(position),
                  let microphone = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: microphone),
                  self.session.canAddInput(input), self.session.canAddOutput(self.movie) else {
                self.complete(.failure(CocoaError(.featureUnsupported)))
                return
            }
            self.session.addInput(input)
            self.session.addOutput(self.movie)
            if self.session.canSetSessionPreset(.vga640x480) {
                self.session.sessionPreset = .vga640x480
            } else if self.session.canSetSessionPreset(.medium) {
                self.session.sessionPreset = .medium
            }
            self.movie.maxRecordedFileSize = 64 * 1024 * 1024
            self.session.startRunning()
            if !self.startSegment() { self.finishCapture() }
        }
    }

    private func startSegment() -> Bool {
        guard let connection = movie.connection(with: .video) else { return false }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        let supported = movie.supportedOutputSettingsKeys(for: connection)
        if supported.contains(AVVideoCodecKey), movie.availableVideoCodecTypes.contains(.h264) {
            var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264]
            if supported.contains(AVVideoCompressionPropertiesKey) {
                // Leave room for the audio track and container within the chat upload limit.
                settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 420_000]
            }
            movie.setOutputSettings(settings, for: connection)
        }
        let url = RiderMediaEncoding.temporary("mov")
        currentSegment = url
        closingSegment = false
        movie.maxRecordedDuration = CMTime(seconds: remaining, preferredTimescale: 600)
        movie.startRecording(to: url, recordingDelegate: self)
        return true
    }

    private func requestSegmentEnd() {
        guard currentSegment != nil, !closingSegment, movie.isRecording else { return }
        closingSegment = true
        movie.stopRecording()
    }

    func switchCamera(_ position: AVCaptureDevice.Position, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard !self.stopRequested, self.completion != nil, self.switching == nil else { completion(false); return }
            self.switching = (position, completion)
            self.requestSegmentEnd()
        }
    }

    func setTorch(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        queue.async { completion(!self.stopRequested && self.configureTorch(enabled)) }
    }

    private func configureTorch(_ enabled: Bool) -> Bool {
        let mode: AVCaptureDevice.TorchMode = enabled ? .on : .off
        guard let device = lens?.device, device.hasTorch, device.isTorchModeSupported(mode) else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = mode
            return true
        } catch { return false }
    }

    private func useCamera(_ position: AVCaptureDevice.Position) -> Bool {
        if lens?.device.position == position { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        _ = configureTorch(false)
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
            self.stopRequested = true
            if self.currentSegment != nil { self.requestSegmentEnd() }
            else if self.completion != nil { self.finishCapture() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async {
            guard self.currentSegment == url else { return }
            if self.stopRequested || self.switching != nil { self.requestSegmentEnd() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard self.currentSegment == url else { return }
            self.currentSegment = nil
            self.closingSegment = false
            let valid = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
            if !self.discarded && valid {
                let duration = AVURLAsset(url: url).duration.seconds
                if duration.isFinite && duration > 0 {
                    self.segments.append(url)
                    self.remaining -= duration
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }

            if let pending = self.switching, !self.stopRequested, self.remaining > 0.2 {
                self.switching = nil
                let changed = self.useCamera(pending.position)
                let resumed = self.startSegment()
                pending.callback(changed && resumed)
                if !resumed { self.finishCapture(after: error) }
            } else {
                self.finishCapture(after: error)
            }
        }
    }

    private func finishCapture(after error: Error? = nil) {
        if discarded {
            complete(.success([]))
        } else if segments.isEmpty {
            complete(.failure(error ?? CocoaError(.fileReadCorruptFile)))
        } else {
            complete(.success(segments))
        }
    }

    private func complete(_ result: Result<[URL], Error>) {
        _ = configureTorch(false)
        if session.isRunning { session.stopRunning() }
        let callback = completion
        completion = nil
        switching?.callback(false)
        switching = nil
        if discarded {
            for url in segments { try? FileManager.default.removeItem(at: url) }
        }
        segments.removeAll()
        activeCapture = nil
        callback?(result)
    }

}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Host: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.isUserInteractionEnabled = false
        return host
    }

    func updateUIView(_ view: Host, context: Context) {
        guard let layer = view.layer as? AVCaptureVideoPreviewLayer else { return }
        layer.videoGravity = .resizeAspectFill
        if layer.session !== session { layer.session = session }
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
    private var scrubbing = false
    private var endingScrub = false
    private var seeking = false
    private var pendingSeek: Double?

    static let speeds = [1.0, 1.25, 1.5, 1.75, 2.0]

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
                if !self.scrubbing, self.track?.id == item.id, let received = notification.object as? AVPlayerItem, received === player.currentItem {
                    self.close()
                    return
                }
            }
        }
    }

    func updateProgress() {
        guard let player, !scrubbing else { return }
        let seconds = player.currentTime().seconds
        let length = player.currentItem?.duration.seconds ?? 0
        if length.isFinite && length > 0 { duration = length }
        if seconds.isFinite { position = max(0, seconds) }
        if duration > 0 && playing && position >= duration - 0.02 && player.timeControlStatus == .paused { close() }
    }

    func toggle() {
        guard let player else { return }
        playing.toggle()
        guard !scrubbing else { return }
        if playing { player.playImmediately(atRate: Float(speed)) }
        else { player.pause() }
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        if playing && !scrubbing { player?.playImmediately(atRate: Float(speed)) }
    }

    func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        setSpeed(Self.speeds[(index + 1) % Self.speeds.count])
    }

    func beginScrub() {
        guard duration > 0, let player else { return }
        scrubbing = true
        endingScrub = false
        player.pause()
    }

    func previewScrub(_ seconds: Double) {
        guard scrubbing, !endingScrub else { return }
        let target = min(duration, max(0, seconds))
        position = target
        pendingSeek = target
        advanceScrub()
    }

    func endScrub() {
        guard scrubbing else { return }
        endingScrub = true
        advanceScrub()
    }

    private func advanceScrub() {
        guard !seeking, let player else { return }
        if let target = pendingSeek {
            pendingSeek = nil
            seeking = true
            // Keep the decoder on the last visible frame when the indicator reaches the end.
            let frame = min(max(0, duration - 1.0 / 60), target)
            player.seek(to: CMTime(seconds: frame, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    guard player === self.player else { return }
                    self.seeking = false
                    self.advanceScrub()
                }
            }
        } else if endingScrub {
            endingScrub = false
            scrubbing = false
            if playing { player.playImmediately(atRate: Float(speed)) }
        }
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
        scrubbing = false
        endingScrub = false
        seeking = false
        pendingSeek = nil
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
                    Button { playback.cycleSpeed() } label: {
                        Text(label(playback.speed)).font(.subheadline.bold().monospacedDigit())
                            .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .contextMenu {
                        ForEach(RiderChatPlayer.speeds, id: \.self) { speed in
                            Button {
                                playback.setSpeed(speed)
                            } label: {
                                if playback.speed == speed { Label(label(speed), systemImage: "checkmark") }
                                else { Text(label(speed)) }
                            }
                        }
                    }
                    .accessibilityLabel("Скорость воспроизведения \(label(playback.speed))")
                    .accessibilityHint("Коснись для следующей скорости или удерживай для выбора")
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
    static let thumbnailDiameter: CGFloat = 144

    let url: URL
    let circle: Bool
    let message: UUID
    let title: String
    @ObservedObject var playback: RiderChatPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: UIImage?
    @State private var scrub: Double?
    @State private var lastAngle: Double?
    @GestureState private var draggingRing = false

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
                    if !active || (!playback.playing && scrub == nil) {
                        Button(action: play) {
                            Image(systemName: "play.fill").font(.headline)
                                .padding(14).background(.black.opacity(0.64), in: Circle()).foregroundStyle(.white)
                        }.buttonStyle(.plain).accessibilityLabel("Смотреть кружочек")
                    }
                }
                .frame(width: active ? 270 : Self.thumbnailDiameter, height: active ? 270 : Self.thumbnailDiameter)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(RiderTheme.accent.opacity(0.78), lineWidth: 2).allowsHitTesting(false) }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: active)
                .task(id: url) { await loadCover() }
                .onDisappear { stopScrub() }
                .onChange(of: active) { _, active in
                    if !active { stopScrub() }
                }
            } else {
                RiderVoiceMessage(url: url, playing: active && playback.playing,
                                  elapsed: active ? RiderChatPlayer.time(playback.position) : nil, play: play)
            }
        }
    }

    private var progressRing: some View {
        GeometryReader { area in
            let center = CGPoint(x: area.size.width / 2, y: area.size.height / 2)
            let radius = max(0, min(center.x, center.y) - 9)
            let angle = progress * 2 * Double.pi
            ZStack {
                Circle().strokeBorder(.white.opacity(0.32), lineWidth: 3).padding(8)
                Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(9)
                if scrub != nil {
                    Circle().fill(RiderChatCapture.blue)
                        .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
                        .frame(width: 14, height: 14)
                        .position(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
                        .allowsHitTesting(false)
                }
                if playback.duration > 0 {
                    Circle().strokeBorder(.clear, lineWidth: 26)
                        .contentShape(RiderScrubRing(), eoFill: true)
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($draggingRing) { _, dragging, _ in dragging = true }
                            .onChanged { moveScrub(to: $0.location, around: center) }
                            .onEnded {
                                moveScrub(to: $0.location, around: center)
                                stopScrub()
                            })
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: draggingRing) { _, dragging in
            if !dragging {
                Task { @MainActor in
                    await Task.yield()
                    if !draggingRing { stopScrub() }
                }
            }
        }
    }

    private func moveScrub(to point: CGPoint, around center: CGPoint) {
        let turns = atan2(Double(point.x - center.x), Double(center.y - point.y)) / (2 * .pi)
        if let lastAngle, let scrub {
            var delta = turns - lastAngle
            if delta > 0.5 { delta -= 1 }
            if delta < -0.5 { delta += 1 }
            self.scrub = min(playback.duration, max(0, scrub + delta * playback.duration))
        } else {
            playback.beginScrub()
            let fraction = turns < 0 ? turns + 1 : turns
            let nearEnd = progress > 0.94 && fraction < 0.04
            scrub = playback.duration * (nearEnd ? 1 : fraction)
        }
        lastAngle = turns
        if let scrub { playback.previewScrub(scrub) }
    }

    private func stopScrub() {
        guard scrub != nil else { return }
        if playback.track?.id == message { playback.endScrub() }
        lastAngle = nil
        scrub = nil
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

enum RiderChatWallpaper: String, Identifiable {
    case apricot, dune, breeze
    case afterglow, moonlight, nightPalms
    case lagoon, reef, tradeWind

    enum Collection {
        case light, dark, lagoon

        var options: [RiderChatWallpaper] {
            switch self {
            case .light: return [.apricot, .dune, .breeze]
            case .dark: return [.afterglow, .moonlight, .nightPalms]
            case .lagoon: return [.lagoon, .reef, .tradeWind]
            }
        }
    }

    enum Motif: Equatable { case coast, palms, kite }

    struct Scene {
        let sky: UInt32
        let horizon: UInt32
        let sea: UInt32
        let sun: UInt32
        let shore: UInt32
        let motif: Motif
        var night = false
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .apricot: return "Персиковый закат"
        case .dune: return "Тёплые дюны"
        case .breeze: return "Утренний бриз"
        case .afterglow: return "После заката"
        case .moonlight: return "Лунный прилив"
        case .nightPalms: return "Пальмы в сумерках"
        case .lagoon: return "Золотая лагуна"
        case .reef: return "Коралловый берег"
        case .tradeWind: return "Бирюзовый ветер"
        }
    }

    var scene: Scene {
        switch self {
        case .apricot:
            return Scene(sky: 0xF3CCD8, horizon: 0xFFBF9C, sea: 0xCF87A4, sun: 0xFFF1C3, shore: 0x874F77, motif: .coast)
        case .dune:
            return Scene(sky: 0xF7DFB3, horizon: 0xF8ECBD, sea: 0xA5C6AE, sun: 0xFFFADE, shore: 0x718A60, motif: .palms)
        case .breeze:
            return Scene(sky: 0xB7DDF9, horizon: 0xFFE3BD, sea: 0x93B9DA, sun: 0xFFF6CF, shore: 0x426EA2, motif: .kite)
        case .afterglow:
            return Scene(sky: 0x191932, horizon: 0x9A4E6C, sea: 0x241E40, sun: 0xFFB581, shore: 0x17142B, motif: .kite, night: true)
        case .moonlight:
            return Scene(sky: 0x10182F, horizon: 0x455883, sea: 0x142A47, sun: 0xE1ECFC, shore: 0x101D38, motif: .coast, night: true)
        case .nightPalms:
            return Scene(sky: 0x291B3B, horizon: 0x77517C, sea: 0x322449, sun: 0xE8B4CB, shore: 0x21192F, motif: .palms, night: true)
        case .lagoon:
            return Scene(sky: 0xB8F2E9, horizon: 0xF8D99C, sea: 0x54C4BA, sun: 0xFFF6BD, shore: 0x227F89, motif: .palms)
        case .reef:
            return Scene(sky: 0xF7CABA, horizon: 0xF8DFB7, sea: 0x64CEBE, sun: 0xFFF0C4, shore: 0x278F8D, motif: .coast)
        case .tradeWind:
            return Scene(sky: 0x7FD8D9, horizon: 0xC3F4DA, sea: 0x34B8B4, sun: 0xF0FCCE, shore: 0x1D7686, motif: .kite)
        }
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}

struct RiderChatStyle: DynamicProperty {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("rider.appearance") private var theme = RiderAppearance.lagoon
    @AppStorage("rider.chat.wallpaper.light") private var light = RiderChatWallpaper.apricot
    @AppStorage("rider.chat.wallpaper.dark") private var dark = RiderChatWallpaper.afterglow
    @AppStorage("rider.chat.wallpaper.lagoon") private var lagoon = RiderChatWallpaper.lagoon

    var isDark: Bool { theme == .dark || (theme != .light && scheme == .dark) }

    private var collection: RiderChatWallpaper.Collection {
        if theme == .lagoon { return .lagoon }
        return isDark ? .dark : .light
    }

    var options: [RiderChatWallpaper] { collection.options }

    var selection: Binding<RiderChatWallpaper> {
        switch collection {
        case .light: return $light
        case .dark: return $dark
        case .lagoon: return $lagoon
        }
    }

    var wallpaper: RiderChatWallpaper { selection.wrappedValue }
    var linkColor: Color { RiderChatWallpaper.color(isDark ? 0x81EFE2 : 0x005B61) }

    func bubble(mine: Bool) -> some View {
        let color = RiderChatWallpaper.color
        let tint = color(mine && wallpaper.scene.motif == .kite ? wallpaper.scene.sea : wallpaper.scene.horizon)
        let base = color(isDark ? (mine ? 0x19363F : 0x222432) : (mine ? 0xECF9F4 : 0xFFFCFA))
        let shape = RoundedRectangle(cornerRadius: 16)
        return shape.fill(base)
            .overlay {
                shape.fill(LinearGradient(colors: [.clear, tint.opacity(mine ? 0.25 : 0.13)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.strokeBorder(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
            }
            .allowsHitTesting(false)
    }
}

struct RiderChatBackdrop: View {
    let wallpaper: RiderChatWallpaper
    var dark = false

    var body: some View {
        let scene = wallpaper.scene
        let color = RiderChatWallpaper.color
        let focal = focalPoint(scene)
        ZStack {
            LinearGradient(stops: [
                .init(color: color(scene.sky), location: 0),
                .init(color: color(scene.horizon), location: 0.43),
                .init(color: color(scene.sea), location: 0.76),
                .init(color: color(scene.sea), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)

            RadialGradient(colors: [color(scene.sun).opacity(0.52), .clear],
                           center: UnitPoint(x: focal.x, y: focal.y), startRadius: 8, endRadius: 215)

            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let sun = CGPoint(x: size.width * focal.x, y: size.height * focal.y)
                let radius = min(size.width, size.height) * (wallpaper == .moonlight ? 0.083 : 0.116)
                let disc = CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: disc), with: .linearGradient(
                    Gradient(colors: [color(scene.sun), color(scene.sun).opacity(0.55)]),
                    startPoint: CGPoint(x: sun.x, y: disc.minY), endPoint: CGPoint(x: sun.x, y: disc.maxY)))

                if scene.night { drawStars(context, size: size, color: color(scene.sun)) }
                drawWater(context, size: size, sun: sun, scene: scene)
                drawShore(context, size: size, scene: scene)
                if scene.motif == .palms {
                    drawPalm(context, at: CGPoint(x: size.width * 0.86, y: size.height * 0.90),
                             scale: min(size.width, size.height) * 0.34, color: color(scene.shore))
                }
                if scene.motif == .kite {
                    drawKite(context, at: CGPoint(x: size.width * 0.21, y: size.height * 0.29),
                             scale: min(size.width, size.height) * 0.19, color: color(scene.shore))
                }
            }

            if dark && !scene.night {
                LinearGradient(colors: [color(0x101C2B).opacity(0.52), color(0x082D33).opacity(0.70)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func focalPoint(_ scene: RiderChatWallpaper.Scene) -> CGPoint {
        switch scene.motif {
        case .coast: return CGPoint(x: 0.34, y: 0.40)
        case .palms: return CGPoint(x: 0.38, y: 0.42)
        case .kite: return CGPoint(x: 0.73, y: 0.37)
        }
    }

    private func drawStars(_ context: GraphicsContext, size: CGSize, color: Color) {
        for index in 0..<19 {
            let x = CGFloat((index * 43 + 9) % 101) / 101 * size.width
            let y = CGFloat((index * 17 + 5) % 97) / 97 * size.height * 0.43
            let radius: CGFloat = index.isMultiple(of: 4) ? 1.7 : 0.9
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                         with: .color(color.opacity(index.isMultiple(of: 4) ? 0.54 : 0.32)))
        }
    }

    private func drawWater(_ context: GraphicsContext, size: CGSize, sun: CGPoint, scene: RiderChatWallpaper.Scene) {
        let width = size.width
        let height = size.height
        let color = RiderChatWallpaper.color(scene.sun)
        for index in 0..<12 {
            let row = CGFloat(index)
            let y = height * (0.54 + row * 0.026)
            let span = width * (0.07 + row * 0.017)
            let drift = width * CGFloat((index * 7) % 9 - 4) * 0.009
            let x = sun.x + drift
            var ripple = Path()
            ripple.move(to: CGPoint(x: x - span, y: y))
            ripple.addQuadCurve(to: CGPoint(x: x + span, y: y - height * 0.007),
                                control: CGPoint(x: x + span * 0.3, y: y - height * 0.013))
            context.stroke(ripple, with: .color(color.opacity(0.37 - Double(index) * 0.016)),
                           style: StrokeStyle(lineWidth: 1 + row * 0.15, lineCap: .round))
        }
    }

    private func drawShore(_ context: GraphicsContext, size: CGSize, scene: RiderChatWallpaper.Scene) {
        let width = size.width
        let height = size.height
        let color = RiderChatWallpaper.color(scene.shore)

        var headland = Path()
        headland.move(to: CGPoint(x: 0, y: height * 0.48))
        headland.addQuadCurve(to: CGPoint(x: width * 0.47, y: height * 0.55),
                             control: CGPoint(x: width * 0.17, y: height * 0.49))
        headland.addQuadCurve(to: CGPoint(x: width, y: height * 0.48),
                             control: CGPoint(x: width * 0.78, y: height * 0.57))
        headland.addQuadCurve(to: CGPoint(x: 0, y: height * 0.56),
                             control: CGPoint(x: width * 0.54, y: height * 0.66))
        headland.closeSubpath()
        context.fill(headland, with: .color(color.opacity(scene.night ? 0.42 : 0.24)))

        var sand = Path()
        sand.move(to: CGPoint(x: 0, y: height * 0.89))
        sand.addCurve(to: CGPoint(x: width, y: height * 0.77),
                      control1: CGPoint(x: width * 0.45, y: height * 1.02),
                      control2: CGPoint(x: width * 0.68, y: height * 0.77))
        context.stroke(sand, with: .color(RiderChatWallpaper.color(scene.sun).opacity(0.23)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        sand.addLine(to: CGPoint(x: width, y: height))
        sand.addLine(to: CGPoint(x: 0, y: height))
        sand.closeSubpath()
        context.fill(sand, with: .linearGradient(
            Gradient(colors: [color.opacity(0.12), color.opacity(0.49)]),
            startPoint: CGPoint(x: 0, y: height * 0.77), endPoint: CGPoint(x: 0, y: height)))
    }

    private func drawPalm(_ context: GraphicsContext, at base: CGPoint, scale: CGFloat, color: Color) {
        var palm = context
        palm.translateBy(x: base.x, y: base.y)
        palm.scaleBy(x: scale, y: scale)
        palm.opacity = 0.62
        let crown = CGPoint(x: -0.20, y: -1)
        var trunk = Path()
        trunk.move(to: .zero)
        trunk.addQuadCurve(to: crown, control: CGPoint(x: 0.10, y: -0.57))
        palm.stroke(trunk, with: .color(color), style: StrokeStyle(lineWidth: 0.059, lineCap: .round))

        let tips: [CGPoint] = [
            CGPoint(x: -0.83, y: -0.90), CGPoint(x: -0.63, y: -0.71),
            CGPoint(x: -0.56, y: -1.26), CGPoint(x: 0.07, y: -1.28),
            CGPoint(x: 0.35, y: -0.96), CGPoint(x: 0.17, y: -0.70)
        ]
        for tip in tips {
            let middle = (crown.x + tip.x) / 2
            var leaf = Path()
            leaf.move(to: crown)
            leaf.addQuadCurve(to: tip, control: CGPoint(x: middle, y: tip.y - 0.26))
            leaf.addQuadCurve(to: crown, control: CGPoint(x: middle, y: tip.y - 0.10))
            leaf.closeSubpath()
            palm.fill(leaf, with: .color(color))
        }
    }

    private func drawKite(_ context: GraphicsContext, at point: CGPoint, scale: CGFloat, color: Color) {
        var wind = context
        wind.translateBy(x: point.x, y: point.y)
        wind.rotate(by: .degrees(-19))
        wind.opacity = 0.65
        let glyph = EquipmentGlyph(kind: .kite)
        let frame = CGRect(x: -scale / 2, y: -scale / 2, width: scale, height: scale)
        wind.fill(glyph.path(in: frame), with: .color(color))
        var line = Path()
        line.move(to: CGPoint(x: scale * 0.17, y: scale * 0.38))
        line.addQuadCurve(to: CGPoint(x: -scale * 1.7, y: scale * 1.67),
                          control: CGPoint(x: -scale * 0.68, y: scale * 1.14))
        wind.stroke(line, with: .color(color.opacity(0.60)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }
}
