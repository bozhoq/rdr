import Charts
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct JumpHistoryTable<Destination: View>: View {
    let session: SessionSummary
    let analysis: JumpAnalysis
    @ViewBuilder let destination: (Int) -> Destination
    @State private var sort = Column.time
    @State private var ascending = true

    private enum Column: String, CaseIterable {
        case height = "Высота", airtime = "Завис.", distance = "Дистанция", time = "Время"

        var accessibilityName: String { self == .airtime ? "Зависание" : rawValue }
    }

    private struct Row: Identifiable {
        let index: Int
        let event: JumpCandidate
        let height: Double?
        let airtime: Double?
        let distance: Double?
        var id: UUID { event.id }

        func value(for column: Column) -> Double? {
            switch column {
            case .height: return height
            case .airtime: return airtime
            case .distance: return distance
            case .time: return event.startSeconds
            }
        }
    }

    private var rows: [Row] {
        analysis.candidates.enumerated().map { index, event in
            let label = session.review?.label(for: event, version: analysis.detectorVersion) ?? .unreviewed
            let estimate = session.liveEstimate(for: event)
            let manualToss = session.handSimulationTest == true ? nil : event.approximateTossHeightMeters(label: label)
            return Row(index: index, event: event, height: estimate?.heightMeters ?? manualToss,
                       airtime: estimate?.isHandLift == true && session.handSimulationTest != true ? nil : estimate?.reportedAirtime ?? manualToss.map { _ in event.unloadingSeconds }, distance: estimate?.distanceMeters)
        }.sorted { first, second in
            switch (first.value(for: sort), second.value(for: sort)) {
            case let (a?, b?) where a != b: return ascending ? a < b : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return first.index < second.index
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("№").frame(width: 22)
            ForEach(Column.allCases, id: \.self) { column in
                Button {
                    if sort == column { ascending.toggle() }
                    else { sort = column; ascending = column == .time }
                } label: {
                    Text(column.rawValue + (sort == column ? (ascending ? " ↑" : " ↓") : ""))
                        .lineLimit(1).minimumScaleFactor(0.60)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(sort == column ? RiderTheme.accent : .secondary)
                .accessibilityLabel("Сортировать: \(column.accessibilityName)")
                .accessibilityValue(sort == column ? (ascending ? "По возрастанию" : "По убыванию") : "")
            }
        }
        .font(.caption.weight(.semibold))
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))

        ForEach(rows) { row in
            NavigationLink { destination(row.index) } label: {
                HStack(spacing: 4) {
                    Text((row.index + 1).formatted()).foregroundStyle(RiderTheme.accent).frame(width: 22)
                    tableCell(row.height, unit: "м")
                    tableCell(row.airtime, unit: "с")
                    tableCell(row.distance, unit: "м")
                    Text(eventTimeText(row.event.startSeconds)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.65)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Событие \(row.index + 1), \(eventTimeText(row.event.startSeconds))")
            .accessibilityValue("Высота \(tableValue(row.height, unit: "м")), зависание \(tableValue(row.airtime, unit: "с")), дистанция \(tableValue(row.distance, unit: "м"))")
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        }
    }

    private func tableValue(_ value: Double?, unit: String) -> String {
        value.map { "≈\(metric($0, unit: unit))" } ?? "—"
    }

    private func tableCell(_ value: Double?, unit: String) -> some View {
        Text(tableValue(value, unit: unit))
            .frame(maxWidth: .infinity)
    }
}

struct EventDetailView: View {
    @ObservedObject var recorder: SessionRecorder
    let originalSession: SessionSummary
    @State var index: Int
    @State private var window: MotionWindow?
    @State private var error: String?
    @State private var selectedSeconds: Double?
    @State private var signal: Signal = .load
    @State private var retry = 0
    @State private var showingDetails = false

    init(recorder: SessionRecorder, originalSession: SessionSummary, index: Int, openDetails: Bool = false) {
        self.recorder = recorder
        self.originalSession = originalSession
        _index = State(initialValue: index)
        _showingDetails = State(initialValue: openDetails)
    }

    private enum Signal: Hashable {
        case load, rotation, vertical

        var unit: String {
            switch self {
            case .load: return "g"
            case .rotation: return "рад/с"
            case .vertical: return "м/с²"
            }
        }
    }

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
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Момент", value: eventTimeText(candidate.startSeconds))
                        if session.handSimulationTest != true {
                            Picker("Что происходило", selection: Binding(
                                get: { label(for: candidate) },
                                set: { recorder.label(candidate.id, as: $0, in: session.id) }
                            )) {
                                ForEach(JumpLabel.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.disabled(recorder.analyzingSessionID == session.id)
                        }
                        if let estimate = session.liveEstimate(for: candidate) {
                            LabeledContent(estimate.isHandLift == true ? "Подъём телефона" : estimate.isPhoneToss == true ? "Высота подброса" : "Высота",
                                           value: estimate.heightMeters.map { "≈ \(metric($0, unit: "м"))" } ?? "—")
                            LabeledContent(session.handSimulationTest == true || estimate.isHandLift == true || (estimate.approachExcursion == true && estimate.estimatedFlightStart == nil) ? "Время выше исходного уровня" : estimate.isPhoneToss == true ? "Полёт телефона" : "Зависание",
                                           value: "≈ \(metric(estimate.estimatedFlightStart == nil ? estimate.airtimeSeconds : estimate.reportedAirtime, unit: "с"))")
                            LabeledContent("Дистанция", value: metric(estimate.distanceMeters, unit: "м"))
                            Text(estimateExplanation(estimate)).font(.footnote).foregroundStyle(.secondary)
                            if estimate.isHandLift != true, estimate.approachExcursion != true, estimate.heightMeters != nil, session.jumpAnalysis?.detectorVersion.hasPrefix("ride-") == true {
                                Text(session.setup?.placement == .board
                                     ? "Отсчёт — поверхность в месте отрыва. Датчик на доске измеряет подъём точки крепления."
                                     : "Высота над поверхностью в месте отрыва оценена по движению крепления. На груди она совпадает с подъёмом доски при одинаковой позе в момент отрыва и на вершине. Подтягивание ног меняет просвет под доской.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            TossHeightReadout(candidate: candidate, label: label(for: candidate))
                        }
                    }.lagoonCard()

                    DisclosureGroup("Подробнее", isExpanded: $showingDetails) {
                        diagnostics(candidate)
                    }.lagoonCard()

                } else {
                    ContentUnavailableView("Событий нет", systemImage: "waveform", description: Text("Вернитесь в сводку и выполните разбор сессии."))
                }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Разбор события")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(candidate?.id.uuidString ?? "none")-\(showingDetails)-\(retry)") {
            if showingDetails { await load() }
        }
    }

    private func estimateExplanation(_ estimate: LiveJumpEstimate) -> String {
        if estimate.pressureAssisted == true {
            return "Долгое зависание. Барометр подтвердил подъём и снижение, датчики движения уточнили высоту и время возврата."
        }
        if estimate.approachExcursion == true {
            return estimate.crossedStartLevel == true
                ? "Подъём телефона от уровня подхода до вершины. Конец — первое пересечение уровня старта на снижении."
                : "Подъём телефона от уровня подхода до вершины. Возврат подтверждён по стабилизации вертикальной скорости."
        }
        if estimate.assumesLevelLanding == true {
            return "Оценка по движению. Предполагает отрыв и приземление на одной высоте."
        }
        if estimate.isHandLift == true && session.handSimulationTest != true {
            return "Зафиксированы подъём и возврат телефона. Время в воздухе не подтверждено."
        }
        if estimate.inertialLift == true && session.handSimulationTest != true {
            return "Высота от отрыва до вершины по вертикальному движению закреплённого телефона."
        }
        if estimate.inertialLift == true { return "Приблизительная высота по движению телефона." }
        if session.handSimulationTest == true || estimate.isHandLift == true { return "Барометр замеряет подъём телефона и время выше исходного уровня." }
        if estimate.isPhoneToss == true { return "Оценка по времени полёта, если телефон отпустили и поймали примерно на одном уровне." }
        if estimate.heightMeters == nil { return "Приземление зафиксировано. Данных для оценки высоты недостаточно." }
        return "Экспериментальная оценка по движению и барометру."
    }

    private func diagnostics(_ candidate: JumpCandidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let estimate = session.liveEstimate(for: candidate), let reference = estimate.floorReferenceMeters {
                LabeledContent("Начальная отметка", value: metric(reference, unit: "м", digits: 2))
                LabeledContent("Пик телефона над полом", value: metric(estimate.floorPeakMeters, unit: "м", digits: 2))
            }
            if let estimate = session.liveEstimate(for: candidate), let push = estimate.pushRiseMeters, let flight = estimate.heightMeters {
                LabeledContent("Подъём телефона до отрыва", value: metric(push, unit: "м", digits: 2))
                LabeledContent("От отрыва до вершины", value: metric(flight, unit: "м", digits: 2))
                LabeledContent("Весь подъём телефона", value: metric(push + flight, unit: "м", digits: 2))
            }
            if let estimate = session.liveEstimate(for: candidate), let start = estimate.estimatedFlightStart, let end = estimate.estimatedFlightEnd {
                LabeledContent("Начало подъёма", value: eventTimeText(start))
                LabeledContent("Возврат", value: eventTimeText(end))
            }
            if let estimate = session.liveEstimate(for: candidate) {
                if let issue = estimate.distanceIssue {
                    LabeledContent("Дистанция", value: issue == .lowAccuracy ? "Недостаточная точность GPS" : "Нет непрерывного GPS на всём прыжке")
                } else if estimate.distanceMeters != nil {
                    LabeledContent("Дистанция", value: estimate.distanceFromSpeed == true ? "По скорости GPS" : "По координатам GPS")
                }
            }
            if let apex = session.liveEstimate(for: candidate)?.apexSeconds {
                LabeledContent("Вершина", value: eventTimeText(apex))
                LabeledContent("Подъём до вершины", value: metric(apex - candidate.startSeconds, unit: "с"))
            }
            if session.handSimulationTest != true {
                LabeledContent(session.jumpAnalysis?.detectorVersion.hasPrefix("ride-") == true ? "Интервал детектора" : "Разгрузка",
                               value: metric(candidate.unloadingSeconds, unit: "с", digits: 2))
                LabeledContent("Минимальная нагрузка", value: metric(candidate.minimumLoadG, unit: "g", digits: 2))
                LabeledContent("Пик после события", value: metric(candidate.returnPeakG, unit: "g"))
                if candidate.fastRotation { Label("Телефон сильно вращался", systemImage: "arrow.triangle.2.circlepath") }
                if candidate.strongImpact { Label("Резкий удар или ловля телефона", systemImage: "exclamationmark.circle") }
            }

            Picker("График", selection: $signal) {
                Text("Нагрузка").tag(Signal.load)
                Text("Вращение").tag(Signal.rotation)
                Text("Вертикаль").tag(Signal.vertical)
            }.pickerStyle(.segmented)
            if let window {
                if window.points.isEmpty {
                    Text("Рядом с событием нет подходящих измерений.").foregroundStyle(.secondary)
                } else {
                    eventChart(window, candidate: candidate)
                    if window.gaps > 0 || window.rejected > 0 {
                        Text("Разрывов: \(window.gaps) · Отброшено измерений: \(window.rejected)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Повторить загрузку") { retry += 1 }
            } else { ProgressView("Читаем измерения…") }

            let nearby = (session.markers ?? []).filter { abs($0.elapsedSeconds - candidate.startSeconds) <= 10 }
            if !nearby.isEmpty {
                Text("Метки рядом").font(.headline)
                ForEach(nearby) { marker in
                    LabeledContent(marker.kind.title, value: eventTimeText(marker.elapsedSeconds))
                }
            }
            Text(graphExplanation)
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(.top, 12)
    }


    private func eventChart(_ window: MotionWindow, candidate: JumpCandidate) -> some View {
        let calibration = session.motionCalibration
        let correctionStartsAt = calibration?.completedAtSeconds ?? .infinity
        func value(_ point: MotionWindowPoint) -> Double {
            switch signal {
            case .load: return point.loadG
            case .rotation: return point.rotation
            case .vertical:
                return calibration?.correctedVertical(point.verticalAcceleration, at: point.seconds) ?? point.verticalAcceleration
            }
        }
        let selected = selectedSeconds.flatMap { seconds in
            window.points.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                RectangleMark(xStart: .value("Начало", candidate.startSeconds), xEnd: .value("Конец", candidate.endSeconds), yStart: nil, yEnd: nil)
                    .foregroundStyle(RiderTheme.accent.opacity(0.12))
                ForEach(window.points) { point in
                    LineMark(x: .value("Секунды", point.seconds), y: .value(signal.unit, value(point)),
                             series: .value("Участок", point.segment * 2 + (signal == .vertical && point.seconds > correctionStartsAt ? 1 : 0)))
                        .foregroundStyle(RiderTheme.accent)
                    PointMark(x: .value("Секунды", point.seconds), y: .value(signal.unit, value(point)))
                        .foregroundStyle(RiderTheme.accent).symbolSize(3)
                }
                if signal != .rotation {
                    RuleMark(y: .value("Покой", signal == .load ? 1.0 : 0.0)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [4]))
                }
                if let selected { RuleMark(x: .value("Выбрано", selected.seconds)).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: window.lower...window.upper)
            .chartXAxisLabel("Секунды от начала движения")
            .chartYAxisLabel(signal.unit)
            .chartXSelection(value: $selectedSeconds)
            .frame(height: 220)
            if let selected {
                Text("\(eventTimeText(selected.seconds)) · \(metric(value(selected), unit: signal.unit, digits: 2))")
                    .font(.subheadline.monospacedDigit())
            } else { Text("Проведите по графику, чтобы посмотреть измерение.").font(.footnote).foregroundStyle(.secondary) }
            if signal == .vertical {
                Text(calibration.map { "Поправка нуля действует после \(eventTimeText($0.completedAtSeconds))." } ?? "Вертикальное ускорение без поправки нуля.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var graphExplanation: String {
        if session.handSimulationTest == true { return "Выделен подъём, обнаруженный барометром." }
        if session.jumpAnalysis?.detectorVersion.hasPrefix("ride-") == true { return "Выделен интервал от отрыва до начала приземления." }
        return "Выделенный участок — разгрузка. Около 1 g соответствует покою, около 0 g — почти свободному падению телефона."
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
