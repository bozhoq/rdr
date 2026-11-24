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
    @State private var riderPath: [RiderDestination] = []
    @StateObject private var social = RiderSocialStore()

    private enum Tab: Hashable {
        case feed, spot, record, tops, rider
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { RiderFeedView() }
                .tabItem { Label("Лента", systemImage: "rectangle.stack") }
                .tag(Tab.feed)

            NavigationStack {
                SpotsView(recorder: recorder) { selectedTab = .record }
            }
            .tabItem { Label("Спот", systemImage: "mappin.and.ellipse") }
            .tag(Tab.spot)

            NavigationStack {
                RecordingView(recorder: recorder) {
                    recorder.stop()
                    riderPath = [.statistics]
                    selectedTab = .rider
                }
            }
            .tabItem { Label("Запись", systemImage: "waveform") }
            .tag(Tab.record)

            NavigationStack { RiderTopsView(recorder: recorder) }
                .tabItem { Label("Топы", systemImage: "trophy") }
                .tag(Tab.tops)

            NavigationStack(path: $riderPath) {
                RiderProfileView(recorder: recorder)
                    .navigationDestination(for: RiderDestination.self) { destination in
                        switch destination {
                        case .statistics: PersonalStatsView(recorder: recorder)
                        }
                    }
            }
            .tabItem { Label("Райдер", systemImage: "person.crop.circle") }
            .tag(Tab.rider)

        }
        .environmentObject(social)
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

private struct GearPresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recorder: SessionRecorder
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if !recorder.gearPresets.isEmpty {
                    Section("Мои комплекты") {
                        ForEach(recorder.gearPresets) { preset in
                            Button {
                                recorder.useGearPreset(preset)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.headline)
                                    Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Удалить", role: .destructive) { recorder.deleteGearPreset(preset) }
                            }
                        }
                    }
                }
                Button { creating = true } label: {
                    Label("Добавить комплект", systemImage: "plus")
                }
                Button("Запись без комплекта") {
                    recorder.clearGearPreset()
                    dismiss()
                }
            }
            .navigationTitle("Комплекты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .navigationDestination(isPresented: $creating) {
                GearPresetEditor(recorder: recorder, didSave: { dismiss() })
            }
        }
        .tint(RiderTheme.accent)
    }
}

private struct GearPresetEditor: View {
    @ObservedObject var recorder: SessionRecorder
    let didSave: () -> Void
    @State private var name = ""
    @State private var equipment = SessionSetup(sport: .kite)
    @State private var showingKites = false
    @State private var showingBoards = false
    @State private var saveFailed = false

    var body: some View {
        Form {
            TextField("Название комплекта", text: $name)
                .onChange(of: name) { _, _ in saveFailed = false }
            Button { showingKites = true } label: {
                LabeledContent("Кайт", value: equipment.kiteTitle.isEmpty ? "Выбрать" : equipment.kiteTitle)
            }
            Button { showingBoards = true } label: {
                LabeledContent("Доска", value: equipment.boardTitle.isEmpty ? "Выбрать" : equipment.boardTitle)
            }
            Button("Сохранить комплект") {
                if recorder.saveGearPreset(named: name, equipment: equipment) { didSave() }
                else { saveFailed = true }
            }
            .disabled(!GearPreset.canSave(equipment) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saveFailed {
                Text("Такое название или сочетание кайта и доски уже сохранено.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Новый комплект")
        .sheet(isPresented: $showingKites) {
            KitePicker(setup: $equipment, recent: SetupSuggestions(history: recorder.history).kites)
        }
        .sheet(isPresented: $showingBoards) {
            BoardPicker(setup: $equipment, recent: recorder.history)
        }
    }
}

private struct RecordingView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var recorder: SessionRecorder
    let onStop: () -> Void
    @State private var device = RecordingDevice.phone
    @State private var choosingSpot = false
    @State private var showingPresets = false
    @State private var newGPSPoint = false
    @State private var showingTools = false
    @State private var confirmingStop = false
    @State private var showingSensorCheck = false
    @State private var markerKind = MarkerKind.walking

    private enum RecordingDevice: Hashable { case phone, watch }
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
        .sheet(isPresented: $choosingSpot) {
            SpotChoice(setup: Binding(get: { recorder.draftSetup }, set: { selection in
                recorder.draftSetup = selection
                if recorder.automaticConditions {
                    recorder.automaticSpotOverride = selection.spot.isEmpty ? nil : selection.spot
                }
            }), spots: recorder.spots, recent: SetupSuggestions(history: recorder.history).spots)
        }
        .sheet(isPresented: $showingPresets) {
            GearPresetsView(recorder: recorder)
        }
        .sheet(isPresented: $newGPSPoint) {
            SpotEditor(original: nil, suggested: recorder.usableFix?.coordinate) { spot in
                guard recorder.saveSpot(spot) else { return false }
                recorder.draftSetup.selectSpot(spot)
                recorder.automaticSpotOverride = spot.name
                return true
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

                VStack(spacing: 0) {
                    Picker("Спот и ветер", selection: $recorder.automaticConditions) {
                        Text("Автоматически").tag(true)
                        Text("Вручную").tag(false)
                    }.pickerStyle(.segmented).padding(.vertical, 12)
                    if recorder.automaticConditions {
                        if let chosen = recorder.automaticSpotOverride {
                            Button(chosen) { choosingSpot = true }
                        } else if recorder.locating {
                            ProgressView("Получаем координаты…")
                        } else if let fix = recorder.usableFix, let nearest = recorder.nearestSpot(to: fix) {
                            LabeledContent("Спот", value: nearest.name)
                        } else if recorder.attemptedLocation || recorder.authorization == .denied || recorder.authorization == .restricted {
                            Text("Не удалось определить ближайший спот, пожалуйста, укажите спот самостоятельно")
                            Button("Выбрать спот") { choosingSpot = true }
                            Button("Добавить мой спот") { newGPSPoint = true }
                        } else {
                            Button("Определить спот по GPS", action: recorder.locateSpot)
                        }
                    } else {
                        Button { choosingSpot = true } label: {
                            LabeledContent("Спот", value: recorder.draftSetup.spot.isEmpty ? "Выбрать" : recorder.draftSetup.spot)
                        }.padding(.vertical, 10)
                        Divider()
                        Picker("Ветер", selection: $recorder.manualWind) {
                            Text("Не указан").tag(ManualWindRange?.none)
                            ForEach(ManualWindRange.allCases) { range in Text(range.title).tag(Optional(range)) }
                        }.pickerStyle(.menu)
                        Picker("Откуда дует", selection: $recorder.manualDirection) {
                            Text("Не указано").tag(Int?.none)
                            ForEach(0..<8, id: \.self) { i in
                                let bearing = Double(i * 45)
                                Text(SpotForecast.compass(bearing) + " " + SpotForecast.windArrow(bearing)).tag(Optional(i * 45))
                            }
                        }.pickerStyle(.menu)
                        if !recorder.manualWindValid { Text("Укажите диапазон ветра.").font(.footnote) }
                    }
                    Divider()
                    Button { showingPresets = true } label: {
                        LabeledContent("Комплект", value: recorder.gearPresets.first(where: {
                            $0.matches(recorder.draftSetup)
                        })?.name ?? "Выбрать или сохранить")
                    }.padding(.vertical, 11)
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
                .disabled(device == .watch || (!recorder.automaticConditions && !recorder.manualWindValid) || !recorder.hasRecordingSensors || recorder.analyzingSessionID != nil)

                if !recorder.hasRecordingSensors { Text("Датчики записи пока недоступны.").foregroundStyle(.secondary) }
                if recorder.analyzingSessionID != nil { ProgressView("Разбираем сохранённую сессию…") }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .onChange(of: recorder.automaticConditions) { _, _ in recorder.automaticSpotOverride = nil }
        .task(id: recorder.automaticConditions) {
            if recorder.automaticConditions && recorder.locationAuthorized { recorder.locateSpot() }
        }
    }

    private func requestRecording() {
        showingSensorCheck = true
    }

    private var sensorCheck: some View {
        NavigationStack {
            Form {
                Section("Калибровка") {
                    Text("Положите телефон плашмя на неподвижную поверхность на 5 секунд. После проверки закрепите его на груди и начните запись.")
                    if recorder.sensorCheckRunning {
                        ProgressView("Проверяем датчики 5 секунд")
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
                .disabled(!recorder.readyToStart || !recorder.hasRecordingSensors)
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
        let airtime = estimates.filter { session.handSimulationTest == true || $0.isHandLift != true }.map(\.airtimeSeconds).max()
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

private struct PersonalStatsView: View {

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

                List {

                    if !recorder.gearPresets.isEmpty {

                        Section {

                            DisclosureGroup("По комплектам") {

                                ForEach(recorder.gearPresets) { preset in

                                    let totals = RiderTotals(recorder.history.filter { $0.setup.map(preset.matches) == true })

                                    DisclosureGroup(preset.name) {

                                        Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)

                                        LabeledContent("Сессии", value: String(totals.sessions))

                                        LabeledContent("Часы на воде", value: totals.timeOnWater)

                                        LabeledContent("Топ прыжок", value: metric(totals.height, unit: "м"))

                                    }

                                }

                            }

                        }

                    }

                    Section("Сессии") {

                        ForEach(filtered) { session in

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

                    }

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

        .navigationTitle("Личная статистика")

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

        if let wind = session.wind {
            LabeledContent(wind.source, value: wind.title)
            if let gust = wind.gust { LabeledContent("Порывы", value: metric(gust * SessionWind.metersPerSecondPerKnot, unit: "м/с")) }
        } else if session.automaticConditions == true { Text("Прогноз на старте недоступен").font(.footnote) }
        LabeledContent("Активность", value: session.setup?.activityTitle ?? "Не указано")
        if let setup = session.setup {
            if !setup.spot.isEmpty { LabeledContent("Спот", value: setup.spot) }
            if !setup.kite.isEmpty {
                LabeledContent(setup.sport == .wing ? "Винг" : setup.sport == .windsurf ? "Парус" : "Кайт", value: setup.kiteTitle)
            }
            if !setup.boardTitle.isEmpty { LabeledContent("Доска", value: setup.boardTitle) }
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
    static let canvas = adaptive(light: 0xD6F6F2, dark: 0x052D32)
    static let surface = adaptive(light: 0xF6FFFD, dark: 0x0B4043)
    static let border = adaptive(light: 0xB5E4DE, dark: 0x285554)
    static let accent = adaptive(light: 0x00797C, dark: 0x64EDDD)
    static let action = Color(uiColor: rgb(0x00797C))
    static let foam = Color(uiColor: rgb(0xDDFCF6))
    static let lagoon = LinearGradient(
        colors: [Color(uiColor: rgb(0x006E86)), Color(uiColor: rgb(0x008B85))],
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
