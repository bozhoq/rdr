import Charts
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EventDetailView: View {
    @ObservedObject var recorder: SessionRecorder
    let originalSession: SessionSummary
    @State var index: Int
    @State private var window: MotionWindow?
    @State private var error: String?
    @State private var selectedSeconds: Double?
    @State private var rotation = false
    @State private var retry = 0

    private var session: SessionSummary { recorder.history.first { $0.id == originalSession.id } ?? originalSession }
    private var candidates: [JumpCandidate] { session.jumpAnalysis?.candidates ?? [] }
    private var currentIndex: Int { min(max(0, index), max(0, candidates.count - 1)) }
    private var candidate: JumpCandidate? { candidates.isEmpty ? nil : candidates[currentIndex] }

    private func label(for candidate: JumpCandidate) -> JumpLabel {
        session.review?.label(for: candidate, version: session.jumpAnalysis?.detectorVersion ?? "") ?? .unreviewed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let candidate {
                    HStack {
                        Button { index = currentIndex - 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(currentIndex == 0).accessibilityLabel("Предыдущее событие")
                        Spacer()
                        Text("Событие \(currentIndex + 1) из \(candidates.count)").font(.headline)
                        Spacer()
                        Button { index = currentIndex + 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(currentIndex + 1 >= candidates.count).accessibilityLabel("Следующее событие")
                    }.buttonStyle(.bordered)
                    VStack(spacing: 12) {
                        LabeledContent("Момент", value: eventTimeText(candidate.startSeconds))
                        LabeledContent("Разгрузка", value: metric(candidate.unloadingSeconds, unit: "с", digits: 2))
                        TossHeightReadout(candidate: candidate, label: label(for: candidate))
                        LabeledContent("Минимальная нагрузка", value: metric(candidate.minimumLoadG, unit: "g", digits: 2))
                        LabeledContent("Импульс после события", value: metric(candidate.returnPeakG, unit: "g"))
                        if candidate.fastRotation { Label("Телефон сильно вращался", systemImage: "arrow.triangle.2.circlepath") }
                        if candidate.strongImpact { Label("Резкий удар или ловля телефона", systemImage: "exclamationmark.circle") }
                    }.lagoonCard()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Движение вокруг события").font(.headline)
                        Picker("Что показать", selection: $rotation) {
                            Text("Нагрузка").tag(false)
                            Text("Вращение").tag(true)
                        }.pickerStyle(.segmented)
                        if let window {
                            if window.points.isEmpty {
                                Text("В исходном логе нет подходящих измерений рядом с этим событием.").foregroundStyle(.secondary)
                            } else {
                                eventChart(window, candidate: candidate)
                                Text("Выделенная область — найденная разгрузка. По бокам показано до двух секунд контекста. Разрывы данных не соединяются.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if window.gaps > 0 || window.rejected > 0 {
                                    Text("Разрывов: \(window.gaps) · Отброшено измерений: \(window.rejected)")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } else if let error {
                            Text(error).foregroundStyle(.secondary)
                            Button("Повторить загрузку") { retry += 1 }
                        } else { ProgressView("Читаем измерения…") }
                    }.lagoonCard()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Что происходило на самом деле").font(.headline)
                        Picker("Ваша отметка", selection: Binding(
                            get: { label(for: candidate) },
                            set: { recorder.label(candidate.id, as: $0, in: session.id) }
                        )) {
                            ForEach(JumpLabel.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.disabled(recorder.analyzingSessionID == session.id)
                        Text("Отметка сохраняется сразу. Она помогает отличать прыжок человека от подброса телефона и движения чехла.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.lagoonCard()
                    if let markers = session.markers, !markers.isEmpty {
                        let nearby = markers.filter { abs($0.elapsedSeconds - candidate.startSeconds) <= 10 }
                        if !nearby.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Метки рядом · ±10 секунд").font(.headline)
                                ForEach(nearby) { marker in
                                    LabeledContent(marker.kind.title, value: eventTimeText(marker.elapsedSeconds))
                                }
                            }.lagoonCard()
                        }
                    }
                    Text("Разгрузка — участок со сниженной нагрузкой на телефон. Около 1 g соответствует покою, около 0 g — почти свободному падению телефона.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Событий нет", systemImage: "waveform", description: Text("Вернитесь в сводку и выполните разбор сессии."))
                }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Разбор события")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(candidate?.id.uuidString ?? "none")-\(retry)") { await load() }
    }

    private func eventChart(_ window: MotionWindow, candidate: JumpCandidate) -> some View {
        let selected = selectedSeconds.flatMap { seconds in
            window.points.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                RectangleMark(xStart: .value("Начало", candidate.startSeconds), xEnd: .value("Конец", candidate.endSeconds), yStart: nil, yEnd: nil)
                    .foregroundStyle(RiderTheme.accent.opacity(0.12))
                ForEach(window.points) { point in
                    LineMark(x: .value("Секунды", point.seconds), y: .value(rotation ? "рад/с" : "g", rotation ? point.rotation : point.loadG), series: .value("Участок", point.segment))
                        .foregroundStyle(RiderTheme.accent)
                    PointMark(x: .value("Секунды", point.seconds), y: .value(rotation ? "рад/с" : "g", rotation ? point.rotation : point.loadG))
                        .foregroundStyle(RiderTheme.accent).symbolSize(3)
                }
                if !rotation {
                    RuleMark(y: .value("Покой", 1)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [4]))
                }
                if let selected { RuleMark(x: .value("Выбрано", selected.seconds)).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: window.lower...window.upper)
            .chartXAxisLabel("Секунды от начала движения")
            .chartYAxisLabel(rotation ? "рад/с" : "g")
            .chartXSelection(value: $selectedSeconds)
            .frame(height: 220)
            if let selected {
                Text("\(eventTimeText(selected.seconds)) · \(metric(rotation ? selected.rotation : selected.loadG, unit: rotation ? "рад/с" : "g", digits: 2))")
                    .font(.subheadline.monospacedDigit())
            } else { Text("Проведите по графику, чтобы посмотреть измерение.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @MainActor private func load() async {
        window = nil; error = nil; selectedSeconds = nil
        guard let candidate else { return }
        let url = recorder.exportURL(for: session.id)
        let work = Task.detached(priority: .userInitiated) { try EventReplay.load(url: url, candidate: candidate) }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            window = value
        } catch is CancellationError { }
        catch { self.error = "Не удалось прочитать данные. \(error.localizedDescription)" }
    }
}

struct TossHeightReadout: View {
    let candidate: JumpCandidate
    let label: JumpLabel

    var body: some View {
        if let height = candidate.approximateTossHeightMeters(label: label) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Высота подброса", value: "≈ \(metric(height, unit: "м", digits: 2))")
                    .font(.headline)
                Text("Оценка по разгрузке, если телефон отпустили и поймали примерно на одном уровне.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if label == .bodyJump {
            LabeledContent("Высота прыжка", value: "Пока недоступна")
                .foregroundStyle(.secondary)
        }
    }
}

struct SessionCardPreview: View {
    let session: SessionSummary
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Карточка сессии: длительность, дистанция, скорость и ваши отметки прыжков")
                }
                if let file {
                    ShareLink(item: CardFile(url: file), preview: SharePreview("Моя сессия Rider")) {
                        Label("Поделиться карточкой", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(RiderTheme.action).controlSize(.large)
                    Text("PNG 1080 × 1440. На картинке нет координат, спота, названия сессии и личных заметок. Перед отправкой вы видите весь результат.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Повторить") { retry += 1 }
                } else { ProgressView("Готовим карточку…") }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Карточка сессии")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) { render() }
    }

    @MainActor private func render() {
        error = nil
        guard let cg = CardArtwork.render(SessionCardData(session: session)), let png = CardArtwork.png(cg) else {
            error = "Не удалось создать картинку. Попробуйте ещё раз."; return
        }
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Rider-card-\(UUID()).png")
            try png.write(to: file, options: .atomic)
            self.image = UIImage(cgImage: cg); self.file = file
        } catch { self.error = error.localizedDescription }
    }
}

private struct CardFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { SentTransferredFile($0.url) }
    }
}
