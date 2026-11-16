import CoreTransferable
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct SessionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = SessionRecorder()

    var body: some Scene {
        WindowGroup {
            Tabs(recorder: recorder)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .onChange(of: scenePhase) { _, phase in recorder.sceneChanged(phase) }
        }
    }
}

private struct Tabs: View {
    @ObservedObject var recorder: SessionRecorder
    @State private var selectedTab = Tab.record

    private enum Tab: Hashable {
        case record, history, progress
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                RecordingView(recorder: recorder) {
                    recorder.stop()
                    selectedTab = .history
                }
            }
            .tabItem { Label("Запись", systemImage: "waveform") }
            .tag(Tab.record)

            NavigationStack {
                HistoryView(recorder: recorder)
            }
            .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }
            .tag(Tab.history)

            NavigationStack { ProgressViewRider(recorder: recorder) }
                .tabItem { Label("Прогресс", systemImage: "chart.bar.fill") }
                .tag(Tab.progress)
        }
        .tint(RiderTheme.accent)
        .alert("Rider", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }
}

private struct RecordingView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var recorder: SessionRecorder
    let onStop: () -> Void
    @State private var markerKind = MarkerKind.walking
    @State private var confirmingStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                recordingPanel
                if let session = recorder.live {
                    VStack(spacing: 12) {
                        LabeledContent("Измерений движения", value: session.motion.count.formatted())
                        LabeledContent("Точек GPS", value: session.locationCount.formatted())
                        MetricsRows(session: session)
                    }
                    .lagoonCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Возможные прыжки", systemImage: "figure.jumprope")
                            .font(.headline)
                        Text("\(session.jumpAnalysis?.candidates.count ?? 0)")
                            .font(.largeTitle.bold())
                            .foregroundStyle(RiderTheme.accent)
                        Text("Экспериментальный детектор. Движение чехла и подбрасывание телефона тоже могут дать событие.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .lagoonCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Упражнение", selection: $markerKind) {
                            ForEach(MarkerKind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        Button {
                            recorder.addMarker(markerKind)
                        } label: {
                            Label("Поставить метку", systemImage: "flag.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RiderTheme.action)
                        .controlSize(.large)
                        .disabled(!recorder.motionIsRecent)
                        if let last = session.markers?.last {
                            Text("Метка \(session.markers?.count ?? 0): \(last.kind.title) · \(eventTimeText(last.elapsedSeconds))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(RiderTheme.accent)
                        }
                        Text("Нажмите перед упражнением. Метка отмечает момент, но не подтверждает прыжок.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .lagoonCard()

                    Button { confirmingStop = true } label: {
                        Label("Завершить запись", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Занятие и снаряжение").font(.headline)
                        SetupFields(setup: $recorder.draftSetup, recent: recorder.history)
                        Text("Настройки запомнятся для следующего старта. Тесты на земле не входят в статистику катания.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.lagoonCard()
                    locationControls
                        .lagoonCard()
                    Button(action: recorder.start) {
                        Label("Начать запись", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RiderTheme.action)
                    .controlSize(.large)
                    .disabled(!recorder.motionAvailable || recorder.analyzingSessionID != nil)

                    if recorder.analyzingSessionID != nil {
                        Text("Разбираем сохранённую сессию…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !recorder.motionAvailable {
                        Label("Для записи движения нужен iPhone с доступными датчиками.", systemImage: "iphone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbarBackground(RiderTheme.canvas, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("Сессия")
        .confirmationDialog("Завершить запись?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Завершить и сохранить", action: onStop)
            Button("Продолжить запись", role: .cancel) {}
        }
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = recorder.live {
                Label("Идёт запись", systemImage: "record.circle.fill")
                    .font(.headline)
                    .foregroundStyle(RiderTheme.foam)
                Text(durationText(session.durationSeconds))
                    .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Длительность записи")
                    .accessibilityValue(durationText(session.durationSeconds))
                Text(recorder.motionIsRecent ? "Данные движения поступают" : "Ожидание данных движения")
                    .font(.subheadline)
                    .foregroundStyle(RiderTheme.foam)
            } else {
                Image(systemName: "water.waves")
                    .font(.title2)
                    .foregroundStyle(RiderTheme.foam)
                    .accessibilityHidden(true)
                Text("Новая сессия")
                    .font(.largeTitle.bold())
                Text("Перед стартом закрепите iPhone на теле в гермочехле.")
                    .font(.subheadline)
                    .foregroundStyle(RiderTheme.foam)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(RiderTheme.lagoon)
        }
    }

    @ViewBuilder private var locationControls: some View {
        if recorder.locationAuthorized {
            Label("GPS доступен", systemImage: "location.fill")
                .font(.subheadline)
                .foregroundStyle(RiderTheme.accent)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Запись без GPS", systemImage: "location.slash")
                    .font(.headline)
                    .foregroundStyle(RiderTheme.accent)
                Text("Разрешите геопозицию для записи маршрута, скорости и проверки записи при блокировке экрана.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if recorder.authorization == .notDetermined {
                    Button("Разрешить геопозицию", action: recorder.requestLocation)
                } else if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Открыть настройки") { openURL(settings) }
                }
            }
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var recorder: SessionRecorder
    @State private var pendingDeletion: SessionSummary?
    @State private var search = ""

    private var filtered: [SessionSummary] { recorder.history.filter { $0.matches(search) } }

    var body: some View {
        Group {
            if recorder.history.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Сессий пока нет")
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(RiderTheme.accent)
                    }
                } description: {
                    Text("Завершите запись, чтобы увидеть сводку и выгрузить лог.")
                }
            } else {
                List(filtered) { session in
                    NavigationLink {
                        SessionDetail(recorder: recorder, originalSession: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = session.review?.title, !title.isEmpty {
                                Text(title).font(.headline).lineLimit(2)
                            }
                            Text(session.startedAt, format: .dateTime.day().month(.wide).year().hour().minute())
                                .font(.headline)
                            if session.status == .interrupted {
                                Label("Запись прервана", systemImage: "exclamationmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(durationText(session.durationSeconds))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(RiderTheme.accent)
                            if let setup = session.setup {
                                Text([setup.sport.title, setup.spot].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(RiderTheme.accent).lineLimit(2)
                            }
                            if let analysis = session.jumpAnalysis {
                                Text("Событий: \(analysis.candidates.count) · Отмечено: \(reviewedCount(session))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDeletion = session
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        .disabled(recorder.analyzingSessionID == session.id)
                    }
                    .listRowBackground(RiderTheme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .overlay {
                    if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbarBackground(RiderTheme.canvas, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("История")
        .searchable(text: $search, prompt: "Название, спот, снаряжение, заметки")
        .confirmationDialog("Удалить сессию и её лог?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { session in
            Button("Удалить", role: .destructive) { recorder.delete(session.id) }
            Button("Отмена", role: .cancel) {}
        }
    }
}

struct SessionDetail: View {
    @ObservedObject var recorder: SessionRecorder
    let originalSession: SessionSummary
    @State private var editingNotes = false
    @State private var editingSetup = false
    @State private var setupCopied = false

    private var session: SessionSummary {
        recorder.history.first { $0.id == originalSession.id } ?? originalSession
    }
    private var logURL: URL { recorder.exportURL(for: session.id) }

    var body: some View {
        List {
            Section("Сессия") {
                if session.status == .interrupted {
                    Label("Запись прервана. Показаны сохранённые данные.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Длительность", value: durationText(session.durationSeconds))
                MetricsRows(session: session)
                if let title = session.review?.title, !title.isEmpty {
                    LabeledContent("Название", value: title)
                }
                if let notes = session.review?.notes, !notes.isEmpty {
                    Text(notes).textSelection(.enabled)
                }
                Button("Название и заметки") { editingNotes = true }
                    .disabled(recorder.analyzingSessionID == session.id)
            }
            .listRowBackground(RiderTheme.surface)
            Section("Маршрут и условия") {
                NavigationLink { RouteView(recorder: recorder, session: session) } label: {
                    Label("Карта, скорость и GPX", systemImage: "map")
                }
                LabeledContent("Занятие", value: session.setup?.sport.title ?? "Не указано")
                if let setup = session.setup {
                    if !setup.spot.isEmpty { LabeledContent("Спот", value: setup.spot) }
                    if !setup.kite.isEmpty { LabeledContent("Кайт / винг", value: setup.kite) }
                    if !setup.board.isEmpty { LabeledContent("Доска / лыжи", value: setup.board) }
                    LabeledContent("Где телефон", value: setup.placement.title)
                }
                Button("Изменить занятие и снаряжение") { editingSetup = true }
                    .disabled(recorder.analyzingSessionID == session.id)
                if let setup = session.setup {
                    Button("Использовать настройки для следующей сессии") {
                        recorder.reuseSetup(setup)
                        setupCopied = true
                    }.disabled(recorder.live != nil)
                    if setupCopied { Text("Настройки выбраны. Откройте вкладку «Запись».").font(.footnote).foregroundStyle(.secondary) }
                }
            }.listRowBackground(RiderTheme.surface)
            Section {
                if let analysis = session.jumpAnalysis {
                    LabeledContent("Найдено событий", value: analysis.candidates.count.formatted())
                    LabeledContent("Отмечено вами", value: "\(reviewedCount(session)) из \(analysis.candidates.count)")
                    if analysis.candidates.isEmpty {
                        Text("Подходящих эпизодов не найдено. Это не доказывает, что прыжков не было.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(analysis.candidates.enumerated()), id: \.element.id) { index, candidate in
                        VStack(alignment: .leading, spacing: 8) {
                            CandidateRow(index: index, candidate: candidate, label: Binding(
                                get: { session.review?.label(for: candidate, version: analysis.detectorVersion) ?? .unreviewed },
                                set: { recorder.label(candidate.id, as: $0, in: session.id) }
                            ))
                            NavigationLink { EventDetailView(recorder: recorder, originalSession: session, index: index) } label: {
                                Label("График и разбор события", systemImage: "waveform.path")
                            }
                        }.disabled(recorder.analyzingSessionID == session.id)
                    }
                    if analysis.discontinuities > 0 {
                        Text("Разрывов данных: \(analysis.discontinuities). События через разрывы не объединяются.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Эта сессия записана до появления детектора. Её можно разобрать сейчас.")
                        .foregroundStyle(.secondary)
                }
                if recorder.analyzingSessionID == session.id {
                    ProgressView("Разбираем запись…")
                } else {
                    Button(session.jumpAnalysis == nil ? "Найти возможные прыжки" : "Повторить разбор") {
                        Task { await recorder.analyze(session.id) }
                    }
                    .disabled(recorder.live != nil || recorder.analyzingSessionID != nil)
                }
            } header: {
                Text("Возможные прыжки · эксперимент")
            } footer: {
                Text("Разгрузка — участок со сниженной нагрузкой на телефон, а не измеренное время полёта. Высота пока не рассчитывается. Время события отсчитывается от первого измерения движения. Разбор выполняется на iPhone.")
            }
            .listRowBackground(RiderTheme.surface)
            if let markers = session.markers, !markers.isEmpty {
                Section {
                    ForEach(markers) { marker in
                        LabeledContent(marker.kind.title, value: eventTimeText(marker.elapsedSeconds))
                    }
                } header: { Text("Метки упражнений") }
                footer: { Text("Момент нажатия по последнему измерению движения. Это ориентир для разбора, а не автоматическое определение упражнения.") }
                .listRowBackground(RiderTheme.surface)
            }
            Section("Диагностика") {
                LabeledContent("Измерений движения", value: session.motion.count.formatted())
                LabeledContent("Точек GPS", value: session.locationCount.formatted())
                LabeledContent("Средняя частота", value: metric(session.motion.averageHz, unit: "Гц"))
                LabeledContent("Наибольший интервал", value: metric(session.motion.longestIntervalSeconds.map { $0 * 1_000 }, unit: "мс"))
                LabeledContent("Интервалов больше 100 мс", value: session.motion.gapsOver100ms.formatted())
                if let start = session.batteryAtStartPercent, let end = session.batteryAtCheckpointPercent {
                    LabeledContent("Заряд", value: "\(start)% → \(end)%")
                }
            }
            .listRowBackground(RiderTheme.surface)
            Section {
                NavigationLink { SessionCardPreview(session: session) } label: {
                    Label("Карточка сессии для отправки", systemImage: "photo")
                }
                ShareLink(item: SessionResultExport(session: session), preview: SharePreview("Результаты Rider")) {
                    Label("Экспортировать результат", systemImage: "square.and.arrow.up")
                        .foregroundStyle(RiderTheme.accent)
                }
            } footer: {
                Text("Найденные события, ваши отметки, название и заметки. GPS-координаты автоматически не добавляются.")
            }
            .listRowBackground(RiderTheme.surface)
            Section {
                ShareLink(item: SessionExport(url: logURL), preview: SharePreview(logURL.lastPathComponent)) {
                    Label("Экспортировать исходный лог", systemImage: "doc.text")
                        .foregroundStyle(RiderTheme.accent)
                }
            } footer: {
                Text("Если во время сессии был доступен GPS, файл содержит координаты.")
            }
            .listRowBackground(RiderTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbarBackground(RiderTheme.canvas, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("Сводка")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingNotes) {
            NotesEditor(title: session.review?.title ?? "", notes: session.review?.notes ?? "") { title, notes in
                recorder.saveNotes(title: title, notes: notes, for: session.id)
            }
        }
        .sheet(isPresented: $editingSetup) {
            SetupEditor(setup: session.setup ?? SessionSetup(), recent: recorder.history) { recorder.saveSetup($0, for: session.id) }
        }
    }
}

private struct CandidateRow: View {
    let index: Int
    let candidate: JumpCandidate
    @Binding var label: JumpLabel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Событие \(index + 1) · \(eventTimeText(candidate.startSeconds))")
                .font(.headline)
                .foregroundStyle(RiderTheme.accent)
            Text("Разгрузка: \(metric(candidate.unloadingSeconds, unit: "с", digits: 2))")
            if candidate.fastRotation {
                Label("Сильное вращение телефона", systemImage: "arrow.triangle.2.circlepath").font(.footnote)
            }
            if candidate.strongImpact {
                Label("Резкий удар или ловля телефона", systemImage: "exclamationmark.circle").font(.footnote)
            }
            Picker("Что происходило", selection: $label) {
                ForEach(JumpLabel.allCases, id: \.self) { label in
                    Text(label.title).tag(label)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Отметка для события \(index + 1)")
        }
        .padding(.vertical, 4)
    }
}

private struct NotesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var title: String
    @State var notes: String
    let onSave: (String, String) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Например, тест на прогулке", text: $title)
                        .onChange(of: title) { _, value in title = String(value.prefix(100)) }
                }
                .listRowBackground(RiderTheme.surface)
                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Заметки о сессии")
                        .onChange(of: notes) { _, value in notes = String(value.prefix(4000)) }
                } header: { Text("Заметки") }
                footer: { Text("Какие движения делали, где закреплён телефон и насколько свободно он двигался. До 4000 символов.") }
                .listRowBackground(RiderTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(RiderTheme.canvas.ignoresSafeArea())
            .navigationTitle("О сессии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { if onSave(title, notes) { dismiss() } }
                }
            }
        }
        .tint(RiderTheme.accent)
        .interactiveDismissDisabled()
    }
}

private func reviewedCount(_ session: SessionSummary) -> Int {
    guard let analysis = session.jumpAnalysis, let review = session.review else { return 0 }
    return analysis.candidates.filter { review.label(for: $0, version: analysis.detectorVersion) != .unreviewed }.count
}

enum RiderTheme {
    static let canvas = adaptive(light: 0xE1F7F4, dark: 0x092626)
    static let surface = adaptive(light: 0xF6FFFD, dark: 0x113837)
    static let border = adaptive(light: 0xB5E4DE, dark: 0x285554)
    static let accent = adaptive(light: 0x006F70, dark: 0x6CE5CE)
    static let action = Color(uiColor: rgb(0x006F70))
    static let foam = Color(uiColor: rgb(0xDDFCF6))
    static let lagoon = LinearGradient(
        colors: [Color(uiColor: rgb(0x005C87)), Color(uiColor: rgb(0x006F73))],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            rgb(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: 1
        )
    }
}

extension View {
    func lagoonCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(RiderTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct MetricsRows: View {
    let session: SessionSummary

    var body: some View {
        LabeledContent("Дистанция по GPS", value: metric((session.gpsMetrics.map { $0.accepted > 0 ? $0.distanceMeters : nil } ?? session.distanceMeters).map { $0 / 1_000 }, unit: "км", digits: 2))
        LabeledContent("Макс. скорость по GPS", value: metric((session.gpsMetrics != nil ? session.gpsMetrics?.maxSpeedMetersPerSecond : session.maxSpeedMetersPerSecond).map { $0 * 3.6 }, unit: "км/ч"))
    }
}

private struct SessionExport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) {
            SentTransferredFile($0.url)
        }
    }
}

private struct SessionResultExport: Transferable {
    let session: SessionSummary

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            SentTransferredFile(try SessionReport.write(item.session))
        }
    }
}

func eventTimeText(_ seconds: Double) -> String {
    let tenths = Int((seconds * 10).rounded())
    return String(format: "%02d:%02d,%d", tenths / 600, tenths / 10 % 60, tenths % 10)
}

func durationText(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

func metric(_ value: Double?, unit: String, digits: Int = 1) -> String {
    guard let value else { return "—" }
    let number = value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "ru_RU")))
    return "\(number) \(unit)"
}
