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
        case record, history
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
        }
        .tint(RiderTheme.accent)
        .alert("Запись сессии", isPresented: Binding(
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

                    Button(action: onStop) {
                        Label("Завершить запись", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    locationControls
                        .lagoonCard()
                    Button(action: recorder.start) {
                        Label("Начать запись", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RiderTheme.action)
                    .controlSize(.large)
                    .disabled(!recorder.motionAvailable)

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
                List(recorder.history) { session in
                    NavigationLink {
                        SessionDetail(session: session, logURL: recorder.exportURL(for: session.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
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
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDeletion = session
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                    .listRowBackground(RiderTheme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .toolbarBackground(RiderTheme.canvas, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("История")
        .confirmationDialog("Удалить сессию и её лог?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { session in
            Button("Удалить", role: .destructive) { recorder.delete(session.id) }
            Button("Отмена", role: .cancel) {}
        }
    }
}

private struct SessionDetail: View {
    let session: SessionSummary
    let logURL: URL

    var body: some View {
        List {
            Section("Сессия") {
                if session.status == .interrupted {
                    Label("Запись прервана. Показаны сохранённые данные.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Длительность", value: durationText(session.durationSeconds))
                MetricsRows(session: session)
            }
            .listRowBackground(RiderTheme.surface)
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
                ShareLink(item: SessionExport(url: logURL), preview: SharePreview(logURL.lastPathComponent)) {
                    Label("Экспортировать лог", systemImage: "square.and.arrow.up")
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
    }
}

private enum RiderTheme {
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

private extension View {
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
        LabeledContent("Дистанция по GPS", value: metric(session.distanceMeters.map { $0 / 1_000 }, unit: "км", digits: 2))
        LabeledContent("Макс. скорость по GPS", value: metric(session.maxSpeedMetersPerSecond.map { $0 * 3.6 }, unit: "км/ч"))
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

private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

private func metric(_ value: Double?, unit: String, digits: Int = 1) -> String {
    guard let value else { return "—" }
    let number = value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "ru_RU")))
    return "\(number) \(unit)"
}
