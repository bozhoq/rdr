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
        case spot, record, history
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SpotsView(recorder: recorder) { selectedTab = .record }
            }
            .tabItem { Label("Спот", systemImage: "mappin.and.ellipse") }
            .tag(Tab.spot)

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
    @State private var device = RecordingDevice.phone
    @State private var gear: GearField?
    @State private var showingTools = false
    @State private var confirmingStop = false
    @State private var showingSensorCheck = false
    @State private var markerKind = MarkerKind.walking

    private enum RecordingDevice: Hashable { case phone, watch }
    private enum GearField: String, Identifiable {
        case spot = "Спот"
        case kite = "Кайт"
        case board = "Доска"
        var id: Self { self }

        var key: WritableKeyPath<SessionSetup, String> {
            switch self {
            case .spot: return \.spot
            case .kite: return \.kite
            case .board: return \.board
            }
        }

        func choices(_ suggestions: SetupSuggestions) -> [String] {
            switch self {
            case .spot: return suggestions.spots
            case .kite: return suggestions.kites
            case .board: return suggestions.boards
            }
        }
    }

    var body: some View {
        Group {
            if let session = recorder.live {
                recording(session)
                    .toolbar(.hidden, for: .navigationBar, .tabBar)
            } else {
                preparation
                    .toolbar(.visible, for: .tabBar)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .sheet(item: $gear) { field in
            let suggestions = SetupSuggestions(history: recorder.history)
            if field == .spot {
                SpotChoice(setup: $recorder.draftSetup, spots: recorder.spots, recent: suggestions.spots)
            } else if field == .kite, usesKitePicker {
                KitePicker(setup: $recorder.draftSetup, recent: suggestions.kites)
            } else if field == .board {
                BoardPicker(setup: $recorder.draftSetup, recent: recorder.history)
            } else {
                GearChoice(title: gearTitle(field), initial: recorder.draftSetup[keyPath: field.key],
                           options: field.choices(suggestions)) { value in
                    recorder.draftSetup[keyPath: field.key] = value
                }
            }
        }
        .sheet(isPresented: $showingTools) {
            if let session = recorder.live { tools(session) }
        }
        .sheet(isPresented: $showingSensorCheck, onDismiss: recorder.cancelSensorCheck) {
            sensorCheck
        }
        .confirmationDialog("Завершить запись?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Завершить и сохранить", action: onStop)
            Button("Продолжить запись", role: .cancel) {}
        }
    }

    private var preparation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RDRWordmark().frame(maxWidth: .infinity)
                Text("Новая сессия").font(.largeTitle.bold())

                VStack(spacing: 0) {
                    VStack(spacing: 11) {
                        Picker("Режим записи", selection: $recorder.recordingMode) {
                            ForEach(RecordingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        if recorder.recordingMode == .battle {
                            ActivityFields(setup: $recorder.draftSetup, ridingOnly: true)
                            if recorder.draftSetup.placement == .hand {
                                Text("В руке измеряется подъём телефона до вершины и возврат.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 12)
                    if recorder.recordingMode == .battle {
                        Divider()
                        gearRow(.spot)
                        Divider()
                        gearRow(.kite)
                        Divider()
                        gearRow(.board)
                    }
                }.lagoonCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Устройство").font(.headline)
                    Picker("Устройство", selection: $device) {
                        Text("Телефон").tag(RecordingDevice.phone)
                        Text("Часы").tag(RecordingDevice.watch)
                    }.pickerStyle(.segmented)
                    if device == .watch {
                        Text("Для записи с часов нужна версия Rider для Apple Watch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.lagoonCard()

                Button(action: requestRecording) {
                    Text("Начать запись").font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(RiderTheme.action)
                .controlSize(.large)
                .disabled(device == .watch || !recorder.hasRecordingSensors || recorder.analyzingSessionID != nil)

                DisclosureGroup("Настройки записи") {
                    VStack(spacing: 15) {
                        if recorder.recordingMode == .battle {
                            Picker("Где телефон", selection: $recorder.draftSetup.placement) {
                                ForEach(PhonePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                        Toggle("Проверить датчики перед записью", isOn: $recorder.recalibrateNextSession)
                        locationControls
                    }.padding(.top, 12)
                }.lagoonCard()
                if !recorder.hasRecordingSensors { Text("Датчики записи пока недоступны.").foregroundStyle(.secondary) }
                if recorder.analyzingSessionID != nil { ProgressView("Разбираем сохранённую сессию…") }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .onChange(of: recorder.recordingMode, initial: true) { _, mode in
            if mode == .battle, !recorder.draftSetup.sport.isRiding { recorder.draftSetup.sport = .kite }
        }
    }

    private func requestRecording() {
        if recorder.needsSensorCheck { showingSensorCheck = true }
        else { recorder.start() }
    }

    private var sensorCheck: some View {
        NavigationStack {
            Form {
                Section("Калибровка") {
                    if recorder.sensorCheckRunning {
                        ProgressView("Не двигайте телефон 3 секунды")
                    } else if recorder.checkedCalibration != nil {
                        Label("Калибровка готова", systemImage: "checkmark.circle")
                    } else if let message = recorder.sensorCheckMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Button("Проверить снова", action: recorder.checkSensors).disabled(recorder.sensorCheckRunning)
                }
                if let sensors = recorder.checkedSensors {
                    Section("Датчики iPhone") {
                        LabeledContent("Акселерометр", value: sensors.accelerometer ? "Есть" : "Недоступен")
                        LabeledContent("Гироскоп", value: sensors.gyroscope ? "Есть" : "Недоступен")
                        LabeledContent("Движение", value: sensorStatus(sensors.deviceMotion, response: sensors.motionResponded))
                        LabeledContent("Барометр", value: sensorStatus(sensors.barometer, response: sensors.pressureResponded))
                        locationControls
                    }
                }
                Button("Начать запись") {
                    recorder.start()
                    showingSensorCheck = false
                }
                .disabled(recorder.sensorCheckRunning || recorder.checkedSensors == nil || !recorder.hasRecordingSensors)
            }
            .navigationTitle("Проверка датчиков")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { showingSensorCheck = false } } }
        }
        .tint(RiderTheme.accent)
        .onAppear(perform: recorder.checkSensors)
    }

    private func sensorStatus(_ available: Bool, response: Bool?) -> String {
        guard available else { return "Недоступен" }
        guard let response else { return "Проверяется" }
        return response ? "Есть данные" : "Нет ответа"
    }

    private func gearRow(_ field: GearField) -> some View {
        let setup = recorder.draftSetup
        let value = field == .kite ? setup.kiteTitle : field == .board ? setup.boardTitle : setup.spot
        return Button { gear = field } label: {
            HStack(spacing: 10) {
                Text(gearTitle(field)).font(.body.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value.isEmpty ? "Выбрать" : value).foregroundStyle(.secondary).lineLimit(2)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var usesKitePicker: Bool {
        let sport = recorder.draftSetup.sport
        return sport.usesKite || sport == .groundTest || sport == .unclassified
    }

    private func gearTitle(_ field: GearField) -> String {
        guard field == .kite else { return field.rawValue }
        if recorder.draftSetup.sport == .wing { return "Винг" }
        if recorder.draftSetup.sport == .windsurf { return "Парус" }
        return field.rawValue
    }

    private func recording(_ session: SessionSummary) -> some View {
        let minutes = Int(session.durationSeconds / 60)
        return VStack(spacing: 0) {
            Spacer(minLength: 10)
            Text(String(format: "%02d:%02d", minutes / 60, minutes % 60))
                .font(.system(size: 66, weight: .light, design: .monospaced))
                .minimumScaleFactor(0.5)
                .accessibilityLabel("Длительность записи")
                .accessibilityValue(durationText(session.durationSeconds))
                .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 22)
            recordingMetrics(session)
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                Button(recorder.voiceEnabled ? "Голос" : "Тишина", action: recorder.toggleVoice)
                    .font(.body.weight(.semibold))
                    .accessibilityValue(recorder.voiceEnabled ? "Включён" : "Выключен")
                Button { showingTools = true } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("Калибровка и метки")
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(.bottom, 16)
            StopRecordingSlider(onStop: onStop, accessibleStop: { confirmingStop = true })
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("REC").font(.caption.weight(.bold)).tracking(2)
            }
            .foregroundStyle(RiderTheme.foam)
            .accessibilityLabel("Идёт запись")
            .padding(.top, 14)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RiderTheme.lagoon.ignoresSafeArea())
    }

    private func recordingMetrics(_ session: SessionSummary) -> some View {
        let estimates = (session.liveJumpEstimates ?? [:]).values
        let height = estimates.compactMap(\.heightMeters).max()
        let airtime = estimates.map(\.airtimeSeconds).max()
        let distance = estimates.compactMap(\.distanceMeters).max()
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                recordingMetric("Топ высота", value: height, unit: "м")
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 56)
                recordingMetric(session.handSimulationTest == true ? "Время цикла" : "Топ зависание", value: airtime, unit: "с")
            }
            Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
            HStack(spacing: 0) {
                recordingMetric("Топ дистанция", value: distance, unit: "м")
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 56)
                recordingMetric("Топ скорость", value: session.maxSpeedMetersPerSecond.map { $0 * 3.6 }, unit: "км/ч", approximate: false)
            }
        }
    }

    private func recordingMetric(_ title: String, value: Double?, unit: String, approximate: Bool = true) -> some View {
        VStack(spacing: 6) {
            Text((approximate && value != nil ? "≈" : "") + metric(value, unit: unit))
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
            Text(title).font(.subheadline).foregroundStyle(RiderTheme.foam)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 5)
    }

    private func tools(_ session: SessionSummary) -> some View {
        NavigationStack {
            Form {
                Section("Калибровка телефона") {
                    if let calibration = session.motionCalibration {
                        if session.reusedMotionCalibration == true {
                            Label("Используется сохранённая калибровка", systemImage: "checkmark.circle")
                        }
                        CalibrationRows(calibration: calibration)
                    } else if recorder.isCalibrating {
                        ProgressView("Замрите на 3 секунды")
                    } else {
                        Button("Калибровать телефон", action: recorder.calibrateMotion)
                            .disabled(!recorder.motionIsRecent)
                        if let message = recorder.calibrationMessage { Text(message).foregroundStyle(.secondary) }
                    }
                }
                Section("Метки") {
                    Picker("Упражнение", selection: $markerKind) {
                        ForEach(MarkerKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Поставить метку") { recorder.addMarker(markerKind) }
                        .disabled(!recorder.motionIsRecent)
                    if let last = session.markers?.last {
                        LabeledContent(last.kind.title, value: eventTimeText(last.elapsedSeconds))
                    }
                }
                if let altitude = session.altitude {
                    Section("Барометр") { AltitudeRows(metrics: altitude, isRecording: true) }
                }
            }
            .navigationTitle("Запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingTools = false } } }
        }
    }

    @ViewBuilder private var locationControls: some View {
        if recorder.locationAuthorized {
            LabeledContent("GPS", value: "Доступен")
        } else if recorder.authorization == .notDetermined {
            Button("Разрешить геопозицию", action: recorder.requestLocation)
        } else if let settings = URL(string: UIApplication.openSettingsURLString) {
            Button("Открыть настройки GPS") { openURL(settings) }
        }
    }
}

struct RDRWordmark: View {
    var body: some View {
        Text("RDR")
            .font(.system(size: 27, weight: .black, design: .rounded))
            .tracking(2)
            .foregroundStyle(RiderTheme.accent)
            .accessibilityLabel("Rider")
    }
}

private struct GearChoice: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var draft: String
    let options: [String]
    let onSave: (String) -> Void

    init(title: String, initial: String, options: [String], onSave: @escaping (String) -> Void) {
        self.title = title
        _draft = State(initialValue: initial)
        self.options = options
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Введите название", text: $draft)
                    .onChange(of: draft) { _, value in if value.count > 100 { draft = String(value.prefix(100)) } }
                if !options.isEmpty {
                    Section("Недавние") {
                        ForEach(options, id: \.self) { value in
                            Button(value) { onSave(value); dismiss() }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RiderTheme.canvas.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                }
            }
        }
    }
}

private struct StopRecordingSlider: View {
    let onStop: () -> Void
    let accessibleStop: () -> Void
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - 66)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.18))
                Capsule().strokeBorder(.white.opacity(0.35))
                Text("Сдвинь для завершения")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 48).padding(.trailing, 12)
                    .opacity(Double(max(0.12, 1 - dragOffset / travel)))
                Circle()
                    .fill(RiderTheme.foam)
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "chevron.right").font(.headline).foregroundStyle(RiderTheme.action)
                    }
                    .contentShape(Circle())
                    .offset(x: min(travel, max(0, dragOffset)))
                    .gesture(DragGesture(minimumDistance: 8)
                        .updating($dragOffset) { value, state, _ in state = max(0, value.translation.width) }
                        .onEnded { value in if value.translation.width >= travel * 0.92 { onStop() } })
                    .padding(.leading, 8)
            }
        }
        .frame(height: 66)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Завершить запись")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { accessibleStop() }
    }
}

private struct HistoryView: View {
    @ObservedObject var recorder: SessionRecorder
    @State private var pendingDeletion: SessionSummary?
    @State private var search = ""
    @State private var activityFilter: SessionSport?
    @State private var styleFilter: KiteStyle?
    @State private var spotFilter: UUID?

    private var filtered: [SessionSummary] {
        recorder.history.filter { session in
            (activityFilter == nil || activityFilter == (session.setup?.sport ?? .unclassified)) &&
            (styleFilter == nil || styleFilter == session.setup?.kiteStyle) &&
            (spotFilter == nil || recorder.spots.first(where: { $0.id == spotFilter })?.matches(session.setup) == true) &&
            session.matches(search)
        }
    }

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
                        VStack(alignment: .leading, spacing: 10) {
                            if let title = session.review?.title, !title.isEmpty {
                                Text(title).font(.headline).lineLimit(2)
                            }
                            Text(session.startedAt, format: .dateTime.day().month(.wide).hour().minute())
                                .font(.headline)
                            if session.status == .interrupted {
                                Label("Запись прервана", systemImage: "exclamationmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let setup = session.setup {
                                Text([setup.activityTitle, setup.spot].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(RiderTheme.foam).lineLimit(2)
                            }
                            HStack(spacing: 16) {
                                Text(durationText(session.durationSeconds)).monospacedDigit()
                                if let analysis = session.jumpAnalysis { Text("Событий: \(analysis.candidates.count)") }
                            }.font(.subheadline.weight(.semibold)).foregroundStyle(RiderTheme.foam)
                        }
                        .foregroundStyle(.white)
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDeletion = session
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        .disabled(recorder.analyzingSessionID == session.id)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView("Нет подходящих сессий", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbarBackground(RiderTheme.canvas, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("История")
        .searchable(text: $search, prompt: "Название, спот, снаряжение, заметки")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Активность", selection: $activityFilter) {
                        Text("Все активности").tag(nil as SessionSport?)
                        ForEach(SessionSport.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    if activityFilter == nil || activityFilter?.supportsKiteStyle == true {
                        Picker("Стиль", selection: $styleFilter) {
                            Text("Все стили").tag(nil as KiteStyle?)
                            ForEach(KiteStyle.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                    }
                    if !recorder.spots.isEmpty {
                        Picker("Спот", selection: $spotFilter) {
                            Text("Все споты").tag(nil as UUID?)
                            ForEach(recorder.spots) { spot in Text(spot.name).tag(Optional(spot.id)) }
                        }
                    }
                } label: {
                    Label("Фильтры", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: activityFilter) { _, newFilter in
            if newFilter?.supportsKiteStyle == false { styleFilter = nil }
        }
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
            eventsSection
            Section {
                NavigationLink { RouteView(recorder: recorder, session: session) } label: {
                    Label("Маршрут", systemImage: "map")
                }
            }.listRowBackground(RiderTheme.surface)
            Section {
                DisclosureGroup("Подробнее") { sessionDetails }
            }.listRowBackground(RiderTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbarBackground(RiderTheme.canvas, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("Сессия")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingNotes) {
            NotesEditor(title: session.review?.title ?? "", notes: session.review?.notes ?? "") { title, notes in
                recorder.saveNotes(title: title, notes: notes, for: session.id)
            }
        }
        .sheet(isPresented: $editingSetup) {
            SetupEditor(setup: session.setup ?? SessionSetup(), recent: recorder.history, spots: recorder.spots) { recorder.saveSetup($0, for: session.id) }
        }
    }

    private var eventsSection: some View {
        Section {
            if recorder.analyzingSessionID == session.id {
                ProgressView("Разбираем запись…")
            } else if let analysis = session.jumpAnalysis {
                if analysis.candidates.isEmpty {
                    Text("Событий не найдено").foregroundStyle(.secondary)
                } else {
                    JumpHistoryTable(session: session, analysis: analysis) { index in
                        EventDetailView(recorder: recorder, originalSession: session, index: index, openDetails: true)
                    }
                }
            } else {
                analyzeButton("Найти события")
            }
        } header: {
            VStack(alignment: .leading, spacing: 13) {
                RDRWordmark().frame(maxWidth: .infinity)
                Text("История прыжков").font(.largeTitle.bold())
                    .textCase(nil).foregroundStyle(.primary)
            }.padding(.bottom, 5)
        }
        .listRowBackground(RiderTheme.surface)
    }

    private func analyzeButton(_ title: String) -> some View {
        Button(title) { Task { await recorder.analyze(session.id) } }
            .disabled(recorder.live != nil || recorder.analyzingSessionID != nil)
    }

    @ViewBuilder private var sessionDetails: some View {
        LabeledContent("Длительность", value: durationText(session.durationSeconds))
        MetricsRows(session: session)
        if let notes = session.review?.notes, !notes.isEmpty {
            Text(notes).textSelection(.enabled)
        }
        Button("Название и заметки") { editingNotes = true }
            .disabled(recorder.analyzingSessionID == session.id)

        LabeledContent("Активность", value: session.setup?.activityTitle ?? "Не указано")
        if let setup = session.setup {
            if !setup.spot.isEmpty { LabeledContent("Спот", value: setup.spot) }
            if !setup.kite.isEmpty {
                LabeledContent(setup.sport == .wing ? "Винг" : setup.sport == .windsurf ? "Парус" : "Кайт", value: setup.kiteTitle)
            }
            if !setup.boardTitle.isEmpty { LabeledContent("Доска / лыжи", value: setup.boardTitle) }
            LabeledContent("Где телефон", value: setup.placement.title)
        }
        Button("Изменить занятие и снаряжение") { editingSetup = true }
            .disabled(recorder.analyzingSessionID == session.id)
        if let setup = session.setup {
            Button("Использовать настройки для следующей сессии") {
                recorder.reuseSetup(setup)
                recorder.recordingMode = setup.sport.isRiding ? .battle : .test
                setupCopied = true
            }.disabled(recorder.live != nil)
            if setupCopied { Text("Настройки выбраны. Откройте вкладку «Запись».").font(.footnote).foregroundStyle(.secondary) }
        }

        DisclosureGroup("Диагностика") { diagnostics }
        if let markers = session.markers, !markers.isEmpty {
            DisclosureGroup("Метки упражнений") {
                ForEach(markers) { marker in
                    LabeledContent(marker.kind.title, value: eventTimeText(marker.elapsedSeconds))
                }
            }
        }
        if session.jumpAnalysis != nil, session.canReplayGroundEvents { analyzeButton("Повторить разбор") }

        NavigationLink { SessionCardPreview(session: session) } label: {
            Label("Карточка сессии", systemImage: "photo")
        }
        ShareLink(item: SessionResultExport(session: session), preview: SharePreview("Результаты Rider")) {
            Label("Экспортировать результат", systemImage: "square.and.arrow.up")
        }
        ShareLink(item: SessionExport(url: logURL), preview: SharePreview(logURL.lastPathComponent)) {
            Label("Экспортировать исходный лог", systemImage: "doc.text")
        }
        Text("В исходном логе могут быть координаты GPS.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var diagnostics: some View {
        LabeledContent("Измерений движения", value: session.motion.count.formatted())
        LabeledContent("Точек GPS", value: session.locationCount.formatted())
        LabeledContent("Средняя частота", value: metric(session.motion.averageHz, unit: "Гц"))
        LabeledContent("Наибольший интервал движения", value: metric(session.motion.longestIntervalSeconds.map { $0 * 1_000 }, unit: "мс"))
        LabeledContent("Интервалов больше 100 мс", value: session.motion.gapsOver100ms.formatted())
        if let gaps = session.jumpAnalysis?.discontinuities, gaps > 0 {
            LabeledContent("Разрывов в детекторе", value: gaps.formatted())
        }
        if let start = session.batteryAtStartPercent, let end = session.batteryAtCheckpointPercent {
            LabeledContent("Заряд", value: "\(start)% → \(end)%")
        }
        if let altitude = session.altitude {
            DisclosureGroup("Барометр") {
                AltitudeRows(metrics: altitude, isRecording: false)
                Text("Относительная высота от первого показания барометра.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let calibration = session.motionCalibration {
            DisclosureGroup("Калибровка телефона") {
                CalibrationRows(calibration: calibration)
                LabeledContent("Поправка", value: session.reusedMotionCalibration == true ? "Сохранённая, с начала" : "После \(eventTimeText(calibration.completedAtSeconds))")
            }
        }
    }

}

private struct CalibrationRows: View {
    let calibration: MotionCalibration

    var body: some View {
        LabeledContent("Частота движения", value: metric(calibration.frequencyHz, unit: "Гц"))
        LabeledContent("Смещение в покое", value: metric(calibration.verticalOffset, unit: "м/с²", digits: 3))
        LabeledContent("Шум в покое", value: metric(calibration.verticalNoise, unit: "м/с²", digits: 3))
    }
}

private struct AltitudeRows: View {
    let metrics: AltitudeMetrics
    let isRecording: Bool

    var body: some View {
        if !metrics.supported {
            LabeledContent("Барометр", value: "Недоступен")
        } else {
            LabeledContent("Замеров барометра", value: metrics.count.formatted())
            if metrics.stoppedWithError {
                Text("Запись барометра прервалась. Проверьте доступ к «Движению и фитнесу» в настройках iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if isRecording && metrics.count == 0 {
                Text("Ждём первое показание барометра").font(.footnote).foregroundStyle(.secondary)
            }
            if metrics.count > 0 {
                LabeledContent(isRecording && !metrics.stoppedWithError ? "Высота по барометру" : "Последняя высота по барометру",
                               value: metric(metrics.latestMeters, unit: "м"))
                if !isRecording {
                    LabeledContent("Минимум / максимум", value: "\(metric(metrics.lowestMeters, unit: "м")) / \(metric(metrics.highestMeters, unit: "м"))")
                    LabeledContent("Наибольший интервал", value: metric(metrics.longestIntervalSeconds, unit: "с", digits: 2))
                }
            }
        }
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
