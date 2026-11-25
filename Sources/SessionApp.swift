import CoreTransferable
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct SessionApp: App {
    @UIApplicationDelegateAdaptor(RiderSOSAppDelegate.self) private var sosDelegate
    @ObservedObject private var sos = RiderSOSService.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = SessionRecorder()
    @AppStorage("rider.appearance") private var theme = RiderAppearance.lagoon
    @AppStorage("rider.textSize") private var textSize = 0
    @Environment(\.dynamicTypeSize) private var systemSize
    private var chosenSize: DynamicTypeSize {
        if systemSize.isAccessibilitySize { return systemSize }
        switch textSize { case 1: return .medium; case 2: return .large; case 3: return .xLarge; case 4: return .xxLarge; default: return systemSize }
    }

    var body: some Scene {
        WindowGroup {
            Tabs(recorder: recorder)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .preferredColorScheme(theme.scheme)
                .environment(\.dynamicTypeSize, chosenSize)
                .onChange(of: scenePhase) { _, phase in recorder.sceneChanged(phase) }
                .task(id: scenePhase) {
                    guard scenePhase == .active, RiderCommunity.endpoint != nil else { return }
                    await sos.refreshAuthorization()
                    while !Task.isCancelled {
                        if sos.available { recorder.refreshSOSFix() }
                        do { try await Task.sleep(for: .seconds(55)) }
                        catch { break }
                    }
                }
                .sheet(item: $sos.inbox) { inbox in
                    if let id = inbox.selected, inbox.outgoing { RiderSOSOutgoing(id: id) }
                    else { RiderSOSInbox(selected: inbox.selected) }
                }
        }
    }
}

private struct Tabs: View {
    @Environment(\.scenePhase) private var phase
    @AppStorage("rider.announcedRankYear") private var announcedYear = 0
    @AppStorage("rider.announcedRankThreshold") private var announcedThreshold = 0
    @State private var promotion: (previous: RiderRank, current: RiderRank)?

    private struct RankProgress: Equatable {
        let year: Int
        let threshold: Int
    }

    private struct StatisticsTrigger: Equatable {
        let update: RiderStatisticsUpdate
        let refresh: Int
        let active: Bool
        let refreshWindow: Int
    }
    @ObservedObject var recorder: SessionRecorder
    @State private var selectedTab = Tab.record
    @AppStorage("rider.profilePhoto") private var profilePhoto = Data()
    @State private var tabAvatar: UIImage?
    @State private var riderPath: [RiderDestination] = []
    @StateObject private var social = RiderSocialStore()

    private static func avatarIcon(_ data: Data) -> UIImage? {
        guard !data.isEmpty, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let side: CGFloat = 26
        let scale = side / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }

    private static let rideIcon: UIImage = {
        let size = CGSize(width: 31, height: 25)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let ctx = renderer.cgContext
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(1.7)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.addPath(EquipmentGlyph(kind: .kite).path(in: CGRect(x: 0, y: 1, width: 21, height: 23)).cgPath)
            ctx.move(to: CGPoint(x: 26, y: 20))
            ctx.addLine(to: CGPoint(x: 26, y: 5))
            ctx.move(to: CGPoint(x: 22, y: 9))
            ctx.addLine(to: CGPoint(x: 26, y: 5))
            ctx.addLine(to: CGPoint(x: 30, y: 9))
            ctx.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }()

    private enum Tab: Hashable {
        case feed, spot, record, tops, rider
    }

    private var statisticsMonitor: some View {
        TimelineView(.everyMinute) { context in
            let now = max(context.date, Date())
            let progress = social.progress(recorder.history, at: now)
            let active = phase == .active
            let trigger = StatisticsTrigger(update: RiderStatisticsUpdate(recorder.history, at: now),
                                            refresh: social.statisticsRefresh, active: active,
                                            refreshWindow: Int(now.timeIntervalSince1970 / 300))
            Color.clear
                .onChange(of: RankProgress(year: progress.year, threshold: progress.rank.threshold), initial: true) { _, status in
                    observeRank(status)
                }
                .task(id: trigger) {
                    guard active, RiderCommunity.endpoint != nil else { return }
                    do {
                        let current = try await RiderCommunity.statisticsCredit()
                        guard !Task.isCancelled else { return }
                        let changed = lastSyncedStatistics != trigger.update
                        let credit = changed ? try await RiderCommunity.syncStatistics(trigger.update) : current
                        guard !Task.isCancelled else { return }
                        let changedCredit = social.seasonCredit != credit
                        if changedCredit { social.seasonCredit = credit }
                        if changed { lastSyncedStatistics = trigger.update }
                        if changed || changedCredit { social.statisticsSynced += 1 }
                    } catch RiderCommunity.Rejection.forbidden {
                        if !Task.isCancelled {
                            social.seasonCredit = nil
                            lastSyncedStatistics = nil
                        }
                    } catch { /* Retry at the next refresh or when the ride history changes. */ }
                }
        }
        .accessibilityHidden(true)
    }

    private func observeRank(_ status: RankProgress) {
        if announcedYear != status.year {
            announcedYear = status.year
            announcedThreshold = status.threshold
            promotion = nil
        } else if status.threshold > announcedThreshold {
            promotion = (.forPoints(announcedThreshold), .forPoints(status.threshold))
            announcedThreshold = status.threshold
        }
    }

    @State private var lastSyncedStatistics: RiderStatisticsUpdate?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { RiderFeedView(recorder: recorder) }
                .tabItem { Label("Лента", systemImage: "rectangle.stack") }
                .tag(Tab.feed)

            NavigationStack {
                SpotsView(recorder: recorder) { selectedTab = .record }
            }
            .tabItem { Label("Спот", systemImage: "mappin.and.ellipse") }
            .tag(Tab.spot)

            NavigationStack {
                RecordingView(recorder: recorder) {
                    guard let id = recorder.live?.id else { return }
                    recorder.stop()
                    guard recorder.history.contains(where: { $0.id == id && $0.status == .finished }) else { return }
                    riderPath = [.session(id)]
                    selectedTab = .rider
                }
            }
            .tabItem { Label { Text("Каталка") } icon: { Image(uiImage: Self.rideIcon) } }
            .tag(Tab.record)

            NavigationStack { RiderTopsView(recorder: recorder) }
                .tabItem { Label("Топы", systemImage: "trophy") }
                .tag(Tab.tops)

            NavigationStack(path: $riderPath) {
                RiderProfileView(recorder: recorder)
                    .navigationDestination(for: RiderDestination.self) { destination in
                        switch destination {
                        case .statistics: PersonalStatsView(recorder: recorder)
                        case let .session(id):
                            if let session = recorder.history.first(where: { $0.id == id }) {
                                SessionDetail(recorder: recorder, originalSession: session)
                            }
                        }
                    }
            }
            .tabItem {
                Label {
                    Text("Райдер")
                } icon: {
                    if let tabAvatar { Image(uiImage: tabAvatar).renderingMode(.original) }
                    else { Image(systemName: "person.crop.circle") }
                }
            }
            .tag(Tab.rider)

        }
        .onChange(of: profilePhoto, initial: true) { _, data in
            tabAvatar = Self.avatarIcon(data)
        }
        .background { statisticsMonitor }
        .overlay {
            if let promotion {
                RiderRankPromotion(previous: promotion.previous, current: promotion.current) { self.promotion = nil }
            }
        }
        .modifier(RiderSocialAlerts())
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
    @AppStorage("rider.nextSecretMission") private var missionOffer = ""
    @State private var skipMission = false

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

                secretGoal

                Button(action: startRide) {
                    Text("Начать каталку").font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(RiderTheme.action)
                .controlSize(.large)
                .disabled(device == .watch || (!recorder.automaticConditions && !recorder.manualWindValid) || !recorder.hasRecordingSensors || recorder.analyzingSessionID != nil)

                Button {
                    recorder.checkSensors()
                    showingSensorCheck = true
                } label: {
                    Label("Калибровать датчики", systemImage: "scope").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(device == .watch)

                RiderSOSReadiness(recorder: recorder).lagoonCard()

                if !recorder.hasRecordingSensors { Text("Датчики записи пока недоступны.").foregroundStyle(.secondary) }
                if recorder.analyzingSessionID != nil { ProgressView("Разбираем сохранённую сессию…") }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .task {
            prepareSecretGoal()
            await RiderSOSService.shared.refreshAuthorization(prompt: true)
            if RiderCommunity.endpoint != nil, recorder.locationAuthorized, recorder.usableFix == nil {
                recorder.locateSpot()
            }
        }
        .onChange(of: recorder.history.count) { _, _ in prepareSecretGoal() }
        .onChange(of: recorder.automaticConditions) { _, _ in recorder.automaticSpotOverride = nil }
        .task(id: recorder.automaticConditions) {
            if recorder.automaticConditions && recorder.locationAuthorized { recorder.locateSpot() }
        }
    }

    @ViewBuilder private var secretGoal: some View {
        if let mission = RiderMission(rawValue: missionOffer) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RiderMissionSticker(mission: mission, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Случайная цель").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(mission.rule.title).font(.headline)
                        Text("\(mission.rule.goal) · +\(mission.rule.points) ПТС").font(.caption)
                            .foregroundStyle(RiderTheme.accent)
                    }
                }
                Toggle("Взять задание на каталку", isOn: Binding(get: { !skipMission }, set: { skipMission = !$0 }))
                    .font(.subheadline)
            }
            .lagoonCard()
        }
    }

    private func prepareSecretGoal() {
        guard recorder.live == nil else { return }
        let earned = RiderMission.earned(in: recorder.history)
        if let offered = RiderMission(rawValue: missionOffer), !earned.contains(offered) { return }
        missionOffer = RiderMission.draw(excluding: earned)?.rawValue ?? ""
    }

    private func startRide() {
        recorder.start(mission: skipMission ? nil : RiderMission(rawValue: missionOffer))
        if recorder.live != nil {
            missionOffer = ""
            skipMission = false
        }
    }

    private var sensorCheck: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Положите iPhone горизонтально и оставьте на 5 секунд.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let sensors = recorder.checkedSensors {
                        VStack(spacing: 20) {
                            sensorProgress("Акселерометр", icon: "waveform.path.ecg", available: sensors.accelerometer && sensors.deviceMotion,
                                           percent: recorder.motionCheckPercent)
                            sensorProgress("Гироскоп", icon: "gyroscope", available: sensors.gyroscope && sensors.deviceMotion,
                                           percent: recorder.motionCheckPercent)
                            sensorProgress("Барометр", icon: "barometer", available: sensors.barometer,
                                           percent: min(100, recorder.pressureCheckSamples * 100 / 3))
                        }.lagoonCard()
                    }
                    if let message = recorder.sensorCheckMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    } else if recorder.checkedCalibration != nil {
                        Label("Калибровка сохранена", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(RiderTheme.accent)
                    }
                    if !recorder.sensorCheckRunning {
                        Button("Проверить снова", action: recorder.checkSensors).buttonStyle(.bordered)
                    }
                    Button {
                        startRide()
                        if recorder.live != nil { showingSensorCheck = false }
                    } label: {
                        Text("Начать каталку").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(RiderTheme.action)
                    .disabled(!recorder.hasRecordingSensors || (!recorder.automaticConditions && !recorder.manualWindValid))
                }.padding(20)
            }
            .background(RiderTheme.canvas.ignoresSafeArea())
            .navigationTitle("Калибровка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showingSensorCheck = false } } }
        }
        .tint(RiderTheme.accent)
    }

    private func sensorProgress(_ name: String, icon: String, available: Bool, percent: Int) -> some View {
        VStack(spacing: 8) {
            HStack {
                Label(name, systemImage: icon).font(.headline)
                Spacer()
                if available {
                    Text("\(percent)%").font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(RiderTheme.accent)
                } else { Text("Недоступен").font(.caption).foregroundStyle(.secondary) }
            }
            if available {
                ProgressView(value: Double(percent), total: 100)
                    .tint(RiderTheme.accent)
                    .animation(.easeOut(duration: 0.12), value: percent)
                if !recorder.sensorCheckRunning && percent < 100 {
                    Text(percent == 0 ? "Нет данных" : "Проверка не завершена")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
            if let mission = session.mission {
                RiderMissionProgress(mission: mission, metrics: RiderMission.Metrics(session))
                    .padding(.top, 14)
            }
            Spacer(minLength: 18)
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
            RiderSOSControl(recorder: recorder, session: session)
                .padding(.top, 8)
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
        let airtime = estimates.filter { session.handSimulationTest == true || $0.isHandLift != true }.compactMap(\.reportedAirtime).max()
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

                                RiderRideCard(date: session.startedAt, title: session.review?.title) {

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

        .navigationTitle("Мои каталки")

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
            if let highlight = RiderSessionHighlight.best(for: session, history: recorder.history) {
                RiderSessionFinish(session: session, highlight: highlight, spots: recorder.spots, presets: recorder.gearPresets,
                                   unlocked: RiderMission.firstCompletions(in: recorder.history).contains { $0.id == session.id })
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                let jumps = session.jumpAnalysis?.candidates.compactMap { session.liveEstimate(for: $0) } ?? []
                HStack(alignment: .top, spacing: 4) {
                    sessionRecord("Топ прыжок", icon: "arrow.up", value: jumps.compactMap(\.heightMeters).max(), unit: "м")
                    sessionRecord("Топ дистанция", icon: "arrow.left.and.right", value: jumps.compactMap(\.distanceMeters).max(), unit: "м")
                    sessionRecord("Топ завис", icon: "stopwatch", value: jumps.compactMap(\.reportedAirtime).max(), unit: "с")
                }.padding(.vertical, 4)
            }.listRowBackground(RiderTheme.surface)
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
        }
        .listRowBackground(RiderTheme.surface)
    }

    private func sessionRecord(_ title: String, icon: String, value: Double?, unit: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(RiderTheme.accent).accessibilityHidden(true)
            Text(metric(value, unit: unit)).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(metric(value, unit: unit))
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

struct RiderSecretAchievements: View {
    let completed: [SessionSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Секретные").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if completed.isEmpty {
                Label("Здесь появятся секретные ачивки с каталок.", systemImage: "sparkles")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lagoonCard()
            }
            ForEach(completed) { session in
                if let mission = session.mission {
                    HStack(spacing: 12) {
                        RiderMissionSticker(mission: mission, size: 41)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mission.rule.title).font(.subheadline.bold())
                            Text(session.startedAt, format: .dateTime.day().month().year())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 5)
                        Text("+\(mission.rule.points) ПТС").font(.caption.bold().monospacedDigit())
                            .foregroundStyle(RiderTheme.accent)
                    }
                    .lagoonCard()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RiderMissionSticker: View {
    let mission: RiderMission
    let size: CGFloat
    var earned = true

    private var tint: Color {
        switch mission.rule.category {
        case .water: return Color(red: 0.39, green: 0.94, blue: 0.82)
        case .route: return Color(red: 0.60, green: 0.87, blue: 1)
        case .jumps: return Color(red: 1, green: 0.81, blue: 0.38)
        case .height: return Color(red: 0.91, green: 0.72, blue: 1)
        case .air: return Color(red: 1, green: 0.65, blue: 0.54)
        }
    }

    var body: some View {
        ZStack {
            Image(systemName: "seal.fill").font(.system(size: size, weight: .medium))
                .foregroundStyle(earned ? tint : Color.secondary.opacity(0.22))
            Image(systemName: earned ? mission.rule.category.icon : "lock")
                .font(.system(size: size * 0.31, weight: .bold))
                .foregroundStyle(earned ? Color(red: 0.04, green: 0.20, blue: 0.23) : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct RiderMissionProgress: View {
    let mission: RiderMission
    let metrics: RiderMission.Metrics

    var body: some View {
        let value = mission.value(metrics)
        let targetMet = (value ?? 0) >= mission.rule.target
        let confirmed = mission.completed(metrics)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(mission.rule.title, systemImage: confirmed ? "checkmark.seal.fill" : mission.rule.category.icon)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if confirmed {
                    Text("+\(mission.rule.points) ПТС")
                } else if targetMet {
                    Text("После 15 мин записи")
                } else if let value {
                    Text("\(mission.rule.category.text(value)) / \(mission.rule.category.text(mission.rule.target))")
                } else {
                    Text(mission.rule.category == .route ? "Ждём GPS" : mission.rule.goal)
                }
            }
            .font(.caption2.monospacedDigit())
            ProgressView(value: min(1, (value ?? 0) / mission.rule.target)).tint(RiderTheme.foam)
        }
        .padding(10)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }
}

private struct RiderSessionFinish: View {
    let session: SessionSummary
    let highlight: RiderSessionHighlight
    let spots: [RiderSpot]
    let presets: [GearPreset]
    let unlocked: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var draft: Draft?
    @State private var renderFailed = false

    private struct Draft: Identifiable {
        let id = UUID()
        let image: Data
    }

    private var success: RiderMission? {
        guard let mission = session.mission, mission.completed(RiderMission.Metrics(session)) else { return nil }
        return mission
    }

    private var shareText: String {
        let parts = [highlight.title, highlight.detail,
                     success.map { unlocked ? "\($0.rule.title) · +\($0.rule.points) ПТС" : $0.rule.title }]
        return parts.compactMap { $0 }.joined(separator: " · ") + " · Rider"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            artwork
            if let mission = session.mission, success == nil {
                failedMission(mission)
                    .padding(.horizontal, 5)
            }
            ViewThatFits {
                HStack { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .padding(.horizontal, 5)
            if renderFailed { Text("Не удалось подготовить картинку для поста.").font(.footnote).foregroundStyle(.secondary) }
        }
        .task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.58)) { revealed = true }
        }
        .sheet(item: $draft) { draft in
            RiderPostComposer(spots: spots, presets: presets, artwork: draft.image, caption: shareText)
        }
    }

    private var artwork: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RIDER").font(.caption.bold().monospaced()).tracking(3).foregroundStyle(RiderTheme.foam)
                Spacer()
                Image(systemName: highlight.icon).font(.title3.weight(.semibold)).foregroundStyle(RiderTheme.foam)
            }
            Text(highlight.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            Text(highlight.detail).font(.subheadline.weight(.medium)).foregroundStyle(RiderTheme.foam)
            if let mission = success {
                HStack(spacing: 11) {
                    RiderMissionSticker(mission: mission, size: 47)
                        .scaleEffect(reduceMotion || revealed ? 1 : 0.68)
                        .rotationEffect(.degrees(reduceMotion || revealed ? -8 : -28))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mission.rule.title).font(.subheadline.bold())
                        Text(unlocked ? "Секретная ачивка открыта" : "Задание выполнено").font(.caption).foregroundStyle(RiderTheme.foam)
                    }
                    Spacer(minLength: 4)
                    if unlocked {
                        Text("+\(mission.rule.points) ПТС")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(Color(red: 1, green: 0.87, blue: 0.55))
                    }
                }
                .padding(9)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        Button(action: compose) { Label("Создать пост", systemImage: "square.and.pencil") }
            .buttonStyle(.borderless)
        ShareLink(item: shareText) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            .buttonStyle(.borderless)
    }

    private func failedMission(_ mission: RiderMission) -> some View {
        let metrics = RiderMission.Metrics(session)
        let actual = mission.value(metrics)
        let message: String
        if let actual {
            if actual >= mission.rule.target {
                message = "Цель выполнена за \(RiderMission.Category.water.text(Double(metrics.seconds) / 60)). Для бонуса нужно 15 мин."
            } else {
                message = "\(mission.rule.category.text(actual)) из \(mission.rule.goal)"
            }
        } else {
            message = mission.rule.category == .route ? "Не хватило данных GPS" : "Пока без замера"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Label(mission.rule.title, systemImage: "flag").font(.subheadline.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor private func compose() {
        let renderer = ImageRenderer(content: artwork
            .environment(\.dynamicTypeSize, .large)
            .padding(14)
            .frame(width: 360, height: 360)
            .background(Color(red: 0.02, green: 0.20, blue: 0.26)))
        renderer.scale = 3
        guard let image = renderer.uiImage,
              let data = image.jpegData(compressionQuality: 0.76), data.count <= 390_000 else {
            renderFailed = true
            return
        }
        renderFailed = false
        draft = Draft(image: data)
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
    private static var branded: Bool {
        (UserDefaults.standard.string(forKey: "rider.appearance") ?? "lagoon") == "lagoon"
    }
    static var canvas: Color { branded ? adaptive(light: 0xD6F6F2, dark: 0x052D32) : Color(uiColor: .systemGroupedBackground) }
    static var surface: Color { branded ? adaptive(light: 0xF6FFFD, dark: 0x0B4043) : Color(uiColor: .secondarySystemGroupedBackground) }
    static let border = adaptive(light: 0xB5E4DE, dark: 0x285554)
    static let accent = adaptive(light: 0x00797C, dark: 0x64EDDD)
    static let action = Color(uiColor: rgb(0x00797C))
    static let gold = adaptive(light: 0x916108, dark: 0xFFD768)
    static let silver = adaptive(light: 0x5B6776, dark: 0xD9E5F0)
    static let bronze = adaptive(light: 0x914719, dark: 0xEBA978)
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
