import CoreLocation
import Charts
import ImageIO
import MapKit
import PhotosUI
import SafariServices
import SwiftUI
import UIKit

struct SpotsView: View {
    @ObservedObject var recorder: SessionRecorder
    let goToRecording: () -> Void
    @State private var adding = false
    @State private var pendingDelete: RiderSpot?
    @State private var forecastRefresh = 0

    private var favorites: [RiderSpot] { recorder.spots.filter { recorder.favoriteSpots.contains($0.id) } }

    var body: some View {
        List {
            TimelineView(.everyMinute) { context in
                let day = SpotForecast.RankingDay.forEveningSwitch(at: context.date)
                NavigationLink {
                    BestSpotsToday(recorder: recorder, goToRecording: goToRecording)
                } label: { Label(day.title, systemImage: "wind") }
            }
            if !favorites.isEmpty {
                Section("Ближайшее окно в избранном") {
                    FavoriteWindRow(spots: favorites, recorder: recorder, goToRecording: goToRecording)
                        .id(forecastRefresh)
                }
            }
            Section("Избранные споты") {
                if favorites.isEmpty { Text("Нажмите звезду в карточке спота").foregroundStyle(.secondary) }
                ForEach(favorites) { spot in spotRow(spot) }
            }
            SpotGroups(spots: recorder.spots, add: { adding = true }) { spot in spotRow(spot) }
        }
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Спот")
        .refreshable { await MainActor.run { forecastRefresh += 1 } }
        .sheet(isPresented: $adding) { SpotEditor(original: nil, save: recorder.saveSpot) }
        .alert("Удалить личный спот?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { spot in
            Button("Удалить", role: .destructive) { recorder.deletePersonalSpot(spot) }
            Button("Отмена", role: .cancel) {}
        } message: { spot in Text(spot.name + ". Записанные сессии сохранятся.") }
    }

    private func spotRow(_ spot: RiderSpot) -> some View {
        NavigationLink {
            SpotDetailView(recorder: recorder, original: spot, goToRecording: goToRecording)
        } label: { Text(spot.name) }
        .swipeActions(allowsFullSwipe: false) {
            if spot.region == nil {
                Button("Удалить", role: .destructive) { pendingDelete = spot }
            }
            Button { recorder.toggleFavorite(spot) } label: {
                Label(recorder.favoriteSpots.contains(spot.id) ? "Открепить" : "В избранное", systemImage: "star")
            }.tint(RiderTheme.action)
        }
    }
}

private struct FavoriteWindRow: View {
    let spots: [RiderSpot]
    @ObservedObject var recorder: SessionRecorder
    let goToRecording: () -> Void
    @State private var forecasts: [(RiderSpot, SpotForecast)]?

    var body: some View {
        Group {
            content
        }
        .task(id: spots) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let forecasts {
            if forecasts.isEmpty {
                Text("Прогноз для избранного недоступен").foregroundStyle(.secondary)
            } else {
                TimelineView(.everyMinute) { context in
                    if let window = SpotForecast.nearestWindWindow(after: context.date, forecasts: forecasts) {
                        NavigationLink {
                            SpotDetailView(recorder: recorder, original: window.spot, goToRecording: goToRecording)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(window.spot.name).font(.headline)
                                Text(timeLabel(window) + " · " + metric(window.weather.meanWind, unit: "м/с"))
                                    .font(.subheadline).foregroundStyle(RiderTheme.accent)
                                if let gust = window.weather.maxGust {
                                    Text("Порывы до " + metric(gust, unit: "м/с")).font(.caption)
                                }
                                if window.weather.thunder {
                                    Label("В прогнозе гроза", systemImage: "cloud.bolt.rain").font(.caption)
                                }
                            }
                        }
                    } else {
                        Text("Сегодня и завтра в загруженных прогнозах нет окна с ветром от 4 м/с")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ProgressView("Смотрим прогноз избранных спотов")
        }
    }

    private func timeLabel(_ window: SpotForecast.FavoriteWindow) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = window.timezone
        formatter.dateFormat = "dd.MM HH:mm"
        let start = formatter.string(from: window.start)
        formatter.dateFormat = "HH:mm"
        return start + "–" + formatter.string(from: window.end)
    }

    @MainActor private func load() async {
        forecasts = nil
        let fetched = await SpotForecast.fetchAvailable(for: spots)
        guard !Task.isCancelled else { return }
        forecasts = fetched
    }
}

private struct SpotGroups<Row: View>: View {
    let spots: [RiderSpot]
    var add: (() -> Void)? = nil
    @ViewBuilder let row: (RiderSpot) -> Row

    var body: some View {
        let mine = spots.filter { $0.region == nil }
        Section("Мои споты") {
            if let add { Button(action: add) { Label("Добавить спот", systemImage: "plus") } }
            if mine.isEmpty { Text("Пока нет личных спотов").foregroundStyle(.secondary) }
            ForEach(mine) { row($0) }
        }
        let regions = Dictionary(grouping: spots.filter { $0.region != nil }, by: { $0.region ?? "" })
        ForEach(regions.keys.sorted(), id: \.self) { region in
            DisclosureGroup(region) {
                let areas = Dictionary(grouping: regions[region] ?? [], by: { $0.locality ?? "Другие споты" })
                ForEach(areas.keys.sorted(), id: \.self) { area in
                    DisclosureGroup(area) {
                        ForEach(areas[area] ?? []) { spot in row(spot) }
                    }
                }
            }
        }.listRowBackground(RiderTheme.surface)
    }
}

struct SpotChoice: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var setup: SessionSetup
    let spots: [RiderSpot]
    var recent: [String] = []
    @State private var manual: String?

    var body: some View {
        NavigationStack {
            Form {
                SpotGroups(spots: spots) { spot in
                    Button(spot.name) { setup.selectSpot(spot); dismiss() }
                }
                let recentNames = recent.filter { candidate in !spots.contains { $0.name.caseInsensitiveCompare(candidate) == .orderedSame } }
                if !recentNames.isEmpty {
                    Section("Недавние") {
                        ForEach(recentNames, id: \.self) { name in Button(name) { saveName(name) } }
                    }
                }
                Section {
                    TextField("Название спота", text: Binding(get: { manual ?? setup.spot }, set: { manual = $0 }))
                    Button("Указать название") { saveName(manual ?? setup.spot) }
                }
            }
            .navigationTitle("Выбрать спот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .tint(RiderTheme.accent)
    }

    private func saveName(_ name: String) {
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if let saved = spots.first(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            setup.selectSpot(saved)
        } else { setup.setSpotName(cleaned) }
        dismiss()
    }
}

struct SpotEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: RiderSpot?
    let save: (RiderSpot) -> Bool
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var notes: String
    @State private var windyLink: String
    @State private var waterBearing: Int?
    @State private var duplicate = false
    @State private var showingMap = false

    init(original: RiderSpot?, suggested: CLLocationCoordinate2D? = nil, save: @escaping (RiderSpot) -> Bool) {
        self.original = original
        self.save = save
        _name = State(initialValue: original?.name ?? "")
        _latitude = State(initialValue: original.map { String($0.latitude) } ?? suggested.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: original.map { String($0.longitude) } ?? suggested.map { String($0.longitude) } ?? "")
        _notes = State(initialValue: original?.notes ?? "")
        _windyLink = State(initialValue: original?.windyLink?.absoluteString ?? "")
        _waterBearing = State(initialValue: original?.waterBearing)
    }

    private var candidate: RiderSpot? {
        guard var candidate = RiderSpot(id: original?.id ?? UUID(), name: name, latitude: latitude,
                                        longitude: longitude, notes: notes, windyLink: windyLink) else { return nil }
        if let original, candidate.latitude == original.latitude, candidate.longitude == original.longitude {
            candidate.mapLink = original.mapLink
        }
        candidate.region = original?.region
        candidate.locality = original?.locality
        candidate.areaOnly = original?.areaOnly
        candidate.source = original?.source
        candidate.waterBearing = waterBearing
        return candidate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    TextField("Широта, например 55.7558", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Долгота, например 37.6173", text: $longitude).keyboardType(.numbersAndPunctuation)
                    if candidate != nil { Button("Проверить в Яндекс Картах") { showingMap = true } }
                } footer: {
                    Text("Широта от −90 до 90, долгота от −180 до 180. Можно использовать точку или запятую.")
                }
                Section("О споте") {
                    TextField("Заход, покрытие, парковка", text: $notes, axis: .vertical).lineLimit(2...5)
                    TextField("Ссылка на спот в Windy.app", text: $windyLink).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !windyLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, candidate?.windyLink == nil {
                        Text("Нужна HTTPS-ссылка с windy.app.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Сторона открытой воды", selection: $waterBearing) {
                        Text("Не указано").tag(Int?.none)
                        ForEach(0..<8, id: \.self) { i in
                            Text(SpotForecast.compass(Double(i * 45))).tag(Optional(i * 45))
                        }
                    }
                } footer: {
                    Text("Представьте, что стоите на точке старта. Выберите, в какую сторону от вас открытая вода. По этому ориентиру Rider покажет направление ветра относительно берега.")
                }
                if duplicate { Text("Спот с таким названием уже есть.").foregroundStyle(.red) }
            }
            .navigationTitle(original == nil ? "Добавить спот" : "Изменить спот")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let candidate else { return }
                        if save(candidate) { dismiss() } else { duplicate = true }
                    }
                    .disabled(candidate == nil || (!windyLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && candidate?.windyLink == nil))
                }
            }
            .sheet(isPresented: $showingMap) {
                if let url = candidate?.yandexURL { SpotBrowser(url: url).ignoresSafeArea() }
            }
        }
        .tint(RiderTheme.accent)
    }
}

private struct SpotBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct SpotDetailView: View {
    @ObservedObject var recorder: SessionRecorder
    let original: RiderSpot
    let goToRecording: () -> Void
    @State private var editing = false

    private var spot: RiderSpot { recorder.spots.first(where: { $0.id == original.id }) ?? original }
    private var sessions: [SessionSummary] { recorder.history.filter { spot.matches($0.setup) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                titleCard
                SpotRecords(recorder: recorder, sessions: sessions)
                SpotWeather(spot: spot, editShore: { editing = true })
                SpotGallery(spotID: spot.id)
                if let notes = spot.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("О споте").font(.headline)
                        Text(notes).textSelection(.enabled)
                    }.lagoonCard()
                }
                sessionActivity
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Спот")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { recorder.toggleFavorite(spot) } label: {
                    Image(systemName: recorder.favoriteSpots.contains(spot.id) ? "star.fill" : "star")
                }.accessibilityLabel(recorder.favoriteSpots.contains(spot.id) ? "Убрать из избранного" : "В избранное")
                Button("Изменить") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { SpotEditor(original: spot, save: recorder.saveSpot) }
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(spot.name).font(.largeTitle.bold())
            if spot.areaOnly == true { Text("Ориентир района. Точка старта пока не уточнена.").font(.footnote) }
            if let source = spot.source { Link("Источник координат", destination: source).font(.footnote) }
            SpotRouteButton(spot: spot, fullWidth: true)
                .buttonStyle(.borderedProminent).tint(RiderTheme.action)
            Button {
                recorder.chooseSpot(spot)
                goToRecording()
            } label: {
                Text("Выбрать для записи").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(RiderTheme.accent).disabled(recorder.live != nil)
        }.lagoonCard()
    }

    private var sessionActivity: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Мои сессии").font(.headline)
            if sessions.isEmpty {
                Text("Записей на этом споте пока нет.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Всего", value: sessions.count.formatted())
                DisclosureGroup("Активность за последние 12 месяцев") {
                    SpotMonthChart(sessions: sessions).padding(.top, 10)
                }
                DisclosureGroup("Все сессии на споте") {
                    ForEach(sessions) { session in
                        NavigationLink {
                            SessionDetail(recorder: recorder, originalSession: session)
                        } label: {
                            Text(session.startedAt, format: .dateTime.day().month(.wide).year().hour().minute())
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                        }
                    }
                }
            }
        }.lagoonCard()
    }
}

private struct SpotRecords: View {
    @ObservedObject var recorder: SessionRecorder
    let sessions: [SessionSummary]

    private struct Record: Identifiable {
        let title: String
        let unit: String
        let approximate: Bool
        let best: (SessionSummary, Double)?
        var id: String { title }
    }

    private var records: [Record] {
        let rides = sessions.filter { $0.status == .finished && $0.setup?.sport.isRiding == true }
        let jumps = rides.flatMap { session in
            (session.jumpAnalysis?.candidates ?? []).compactMap { candidate -> (SessionSummary, LiveJumpEstimate)? in
                guard let estimate = session.liveEstimate(for: candidate),
                      estimate.isPhoneToss != true, estimate.isHandLift != true else { return nil }
                return (session, estimate)
            }
        }
        func bestJump(_ measure: (LiveJumpEstimate) -> Double?) -> (SessionSummary, Double)? {
            jumps.compactMap { pair in measure(pair.1).map { (pair.0, $0) } }.max { $0.1 < $1.1 }
        }
        let speeds = rides.compactMap { session in session.maxSpeedMetersPerSecond.map { (session, $0 * 3.6) } }
        return [
            Record(title: "Лучший прыжок", unit: "м", approximate: true, best: bestJump { $0.heightMeters }),
            Record(title: "Зависание", unit: "с", approximate: true, best: bestJump { $0.airtimeSeconds }),
            Record(title: "Дистанция прыжка", unit: "м", approximate: true, best: bestJump { $0.distanceMeters }),
            Record(title: "Топ скорость", unit: "км/ч", approximate: false, best: speeds.max { $0.1 < $1.1 })
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Твои рекорды на споте").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(records) { record in
                    if let (session, value) = record.best {
                        NavigationLink {
                            SessionDetail(recorder: recorder, originalSession: session)
                        } label: { tile(record, value: value) }.buttonStyle(.plain)
                    } else { tile(record, value: nil) }
                }
            }
        }.lagoonCard()
    }

    private func tile(_ record: Record, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((record.approximate && value != nil ? "≈ " : "") + metric(value, unit: record.unit))
                .font(.title2.bold()).foregroundStyle(RiderTheme.accent).lineLimit(1).minimumScaleFactor(0.6)
            Text(record.title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(10)
        .background(RiderTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SpotMonthChart: View {
    let sessions: [SessionSummary]

    var body: some View {
        let calendar = Calendar.current
        let current = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let months = (-11...0).compactMap { calendar.date(byAdding: .month, value: $0, to: current) }
        let counts = Dictionary(grouping: sessions.compactMap { calendar.dateInterval(of: .month, for: $0.startedAt)?.start }, by: { $0 })
        Chart(months, id: \.self) { month in
            BarMark(x: .value("Месяц", month, unit: .month), y: .value("Сессии", counts[month]?.count ?? 0))
                .foregroundStyle(RiderTheme.accent)
        }.frame(height: 150)
    }
}

private struct SpotRouteButton: View {
    @Environment(\.openURL) private var openURL
    let spot: RiderSpot
    var fullWidth = false
    @State private var routeUnavailable = false

    var body: some View {
        let title = fullWidth ? "Маршрут к споту" : "Построить маршрут"
        return Button(action: openRoute) {
            Label(spot.areaOnly == true ? "Показать район на карте" : title, systemImage: "location.fill")
                .font(fullWidth ? .headline : .subheadline.weight(.semibold))
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 42 : 28)
        }
        .alert("Маршрут не открылся", isPresented: $routeUnavailable) {
            Button("ОК", role: .cancel) {}
        }
    }

    private func openRoute() {
        if spot.areaOnly == true, let url = spot.yandexURL {
            openURL(url) { opened in routeUnavailable = !opened }
        } else if let app = spot.routeAppURL, let web = spot.routeWebURL {
            openURL(app) { opened in
                if !opened { openURL(web) { routeUnavailable = !$0 } }
            }
        } else {
            routeUnavailable = true
        }
    }
}

private struct BestSpotsToday: View {
    @ObservedObject var recorder: SessionRecorder
    let goToRecording: () -> Void
    @State private var region = ""
    @State private var revision = 0
    @State private var loading = false
    @State private var checked = 0
    @State private var total = 0
    @State private var results: [SpotForecast.Ranking] = []
    @State private var expandedWindows: Set<SpotForecast.Window> = []
    @State private var travelTimes: [RiderSpot: TravelTime] = [:]
    @State private var lastTravelOrigin: Date?

    private enum TravelTime {
        case estimated(String, provider: String)
        case unavailable
    }

    private struct TravelBatch: Hashable {
        let timestamp: Date?
        let spots: [RiderSpot]
    }
    private var regions: [String] { Set(recorder.spots.compactMap(\.region)).sorted() }

    var body: some View {
        TimelineView(.everyMinute) { context in
            rankingList(now: context.date, day: SpotForecast.RankingDay.forEveningSwitch(at: context.date))
        }
    }

    private func rankingList(now: Date, day: SpotForecast.RankingDay) -> some View {
        let dayStart = Calendar.current.startOfDay(for: now)
        let origin = routeOrigin(at: now)
        let batch = TravelBatch(timestamp: origin?.timestamp, spots: visibleRouteTargets)
        return List {
            Picker("Регион", selection: $region) {
                Text("Выберите регион").tag("")
                ForEach(regions, id: \.self) { Text($0).tag($0) }
            }
            if region.isEmpty {
                if recorder.locating { ProgressView("Определяем регион") }
                else { Button("Определить регион по GPS") { recorder.locateSpot() } }
            } else if loading {
                ProgressView("Сравниваем прогнозы")
            } else {
                if results.contains(where: { !$0.spots.isEmpty }) {
                    if origin == nil && !batch.spots.isEmpty {
                        locationRow
                    }
                    ForEach(results) { ranking in
                        Section {
                            if let best = ranking.spots.first {
                                rankedLink(best, in: ranking.window, origin: origin)
                                if ranking.spots.count > 1 {
                                    DisclosureGroup("Другие споты в данном временном промежутке", isExpanded: expansion(for: ranking.window)) {
                                        ForEach(ranking.spots.dropFirst()) { item in
                                            rankedLink(item, in: ranking.window, origin: origin)
                                        }
                                    }
                                }
                            } else {
                                Text("Прогноз недоступен").foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(ranking.window.title)
                                .font(.title2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(RiderTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 6)
                        }
                    }
                } else {
                    Text(checked == 0 ? "Прогнозы не загрузились." : "Нет почасовых данных о ветре за 07:00–20:00.")
                }
                Text("Прогноз получен для \(checked) из \(total) спотов").font(.footnote)
                Button("Обновить прогноз") {
                    revision += 1
                    if recorder.locationAuthorized && !recorder.locating { recorder.locateSpot() }
                }
            }
            DisclosureGroup("Как выбираем") {
                Text("С 07:00 до 20:00 по местному времени сравниваем средний ветер отдельно для каждого окна. При равенстве выше спот с более полным прогнозом. Порывы показываем по максимуму за окно.")
            }
            Link("Прогноз Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
        }
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle(day.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if recorder.usableFix == nil && !recorder.locating && (region.isEmpty || recorder.locationAuthorized) {
                recorder.locateSpot()
            }
        }
        .task(id: batch) {
            if let origin { await loadTravelTimes(origin: origin, spots: batch.spots) }
        }
        .task(id: recorder.previewFix?.timestamp) {
            guard region.isEmpty, let fix = recorder.usableFix else { return }
            let mark = try? await CLGeocoder().reverseGeocodeLocation(fix, preferredLocale: Locale(identifier: "ru_RU")).first
            guard !Task.isCancelled, region.isEmpty else { return }
            let names = [mark?.administrativeArea, mark?.locality].compactMap { $0?.lowercased() }
            if let match = regions.first(where: { r in names.contains { $0.contains(r.lowercased()) } }) {
                region = match
            } else if let nearby = nearbyRegion(fix, within: 80000) { region = nearby }
        }
        .task(id: "\(region)/\(revision)/\(dayStart.timeIntervalSince1970)/\(day.rawValue)") {
            await compare(for: day, relativeTo: now)
        }
    }

    private func rankedLink(_ item: SpotForecast.RankedSpot, in window: SpotForecast.Window, origin: CLLocation?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                SpotDetailView(recorder: recorder, original: item.spot, goToRecording: goToRecording)
            } label: {
                let weather = item.weather
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.spot.name).font(.headline)
                    windPill(weather.windLevel.description, level: weather.windLevel == .calm ? .calm : .light)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { windMetrics(weather) }
                        VStack(alignment: .leading, spacing: 6) { windMetrics(weather) }
                    }
                    if let temperature = weather.meanTemperature {
                        Text("Средняя температура " + metric(temperature, unit: "°C", digits: 0))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if weather.hours < window.forecastHours.count {
                        Text("Прогноз за \(weather.hours) из \(window.forecastHours.count) ч")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if weather.thunder { Label("В прогнозе гроза", systemImage: "cloud.bolt.rain").font(.caption) }
                    if item.spot.areaOnly == true { Text("Ориентир района").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            travelRow(for: item.spot, origin: origin)
        }
        .padding(.vertical, 4)
    }

    private func travelRow(for spot: RiderSpot, origin: CLLocation?) -> some View {
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                travelText(for: spot, origin: origin).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                SpotRouteButton(spot: spot).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                travelText(for: spot, origin: origin)
                SpotRouteButton(spot: spot)
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(RiderTheme.accent)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(RiderTheme.accent.opacity(0.38))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func travelText(for spot: RiderSpot, origin: CLLocation?) -> some View {
        if spot.areaOnly == true {
            Text("Точка старта уточняется")
        } else if let origin {
            switch lastTravelOrigin == origin.timestamp ? travelTimes[spot] : nil {
            case .estimated(let label, let provider):
                VStack(alignment: .leading, spacing: 2) {
                    Text("До спота: около \(label)")
                    Text(provider).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .unavailable:
                Text("Время в пути недоступно")
            case nil:
                Text("Считаем дорогу…")
            }
        } else {
            Text("Нужна геопозиция")
        }
    }

    @ViewBuilder private var locationRow: some View {
        if recorder.locating {
            ProgressView("Уточняем геопозицию для расчёта дороги")
        } else if recorder.authorization == .denied || recorder.authorization == .restricted {
            Text("Для расчёта дороги разрешите Rider доступ к геопозиции в настройках iPhone.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Button("Определить геопозицию для расчёта дороги", action: recorder.locateSpot)
        }
    }

    private func routeOrigin(at now: Date) -> CLLocation? {
        guard recorder.locationAuthorized, let fix = recorder.previewFix,
              abs(fix.timestamp.timeIntervalSince(now)) <= 5 * 60 else { return nil }
        return fix
    }

    private func expansion(for window: SpotForecast.Window) -> Binding<Bool> {
        Binding(get: { expandedWindows.contains(window) }, set: { expanded in
            if expanded { expandedWindows.insert(window) }
            else { expandedWindows.remove(window) }
        })
    }

    private var visibleRouteTargets: [RiderSpot] {
        var seen: Set<UUID> = []
        return results.flatMap { ranking in
            ranking.spots.prefix(expandedWindows.contains(ranking.window) ? ranking.spots.count : 1)
        }.map(\.spot).filter { $0.areaOnly != true && seen.insert($0.id).inserted }
    }

    @MainActor private func loadTravelTimes(origin: CLLocation, spots: [RiderSpot]) async {
        if lastTravelOrigin != origin.timestamp {
            travelTimes = [:]
            lastTravelOrigin = origin.timestamp
        }
        let pending = spots.filter { travelTimes[$0] == nil }
        guard !pending.isEmpty, !Task.isCancelled else { return }

        if RiderCommunity.endpoint != nil {
            let matrix = try? await RiderCommunity.routeDurations(latitude: origin.coordinate.latitude,
                                                                  longitude: origin.coordinate.longitude, to: pending)
            guard !Task.isCancelled, lastTravelOrigin == origin.timestamp else { return }
            if let matrix {
                for (spot, seconds) in zip(pending, matrix) {
                    if let label = seconds.flatMap(SpotRoadTravel.durationLabel) {
                        travelTimes[spot] = .estimated(label, provider: "Яндекс Карты")
                    }
                }
            }
        }

        let source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        for spot in pending {
            guard !Task.isCancelled else { return }
            if travelTimes[spot] != nil { continue }
            let destination = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
            let request = MKDirections.Request()
            request.source = source
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .automobile
            let directions = MKDirections(request: request)
            let time = await withTaskCancellationHandler {
                try? await directions.calculateETA().expectedTravelTime
            } onCancel: {
                directions.cancel()
            }
            guard !Task.isCancelled, lastTravelOrigin == origin.timestamp else { return }
            travelTimes[spot] = time.flatMap(SpotRoadTravel.durationLabel)
                .map { .estimated($0, provider: "Apple Maps") } ?? .unavailable
        }
    }

    @ViewBuilder private func windMetrics(_ weather: SpotForecast.WindowSummary) -> some View {
        windMetric("Скорость ветра", speed: weather.meanWind, level: weather.windLevel)
        windMetric("Порывы до", speed: weather.maxGust, level: weather.gustLevel ?? .calm)
    }

    private func windMetric(_ label: String, speed: Double?, level: SpotForecast.WindLevel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            windPill(metric(speed, unit: "м/с"), level: level).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func windPill(_ text: String, level: SpotForecast.WindLevel) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(level == .calm ? Color.secondary : Color.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(windFill(level), in: Capsule())
    }

    private func windFill(_ level: SpotForecast.WindLevel) -> Color {
        switch level {
        case .calm: return RiderTheme.canvas
        case .light: return Color(red: 0.80, green: 0.95, blue: 0.82)
        case .medium: return Color(red: 0.69, green: 0.91, blue: 0.36)
        case .strong: return Color(red: 1.0, green: 0.61, blue: 0.59)
        }
    }

    private func nearbyRegion(_ fix: CLLocation, within radius: Double) -> String? {
        recorder.spots.compactMap { spot -> (String, Double)? in
            guard let name = spot.region else { return nil }
            let meters = fix.distance(from: CLLocation(latitude: spot.latitude, longitude: spot.longitude))
            return meters <= radius ? (name, meters) : nil
        }.min(by: { $0.1 < $1.1 })?.0
    }

    @MainActor private func compare(for day: SpotForecast.RankingDay, relativeTo now: Date) async {
        results = []
        checked = 0
        total = 0
        guard !region.isEmpty else { loading = false; return }
        loading = true
        let candidates = recorder.spots.filter { spot in
            if let name = spot.region { return name == region }
            return nearbyRegion(CLLocation(latitude: spot.latitude, longitude: spot.longitude), within: 30000) == region
        }
        let forecasts = await SpotForecast.fetchAvailable(for: candidates)
        guard !Task.isCancelled else { return }
        results = SpotForecast.rankings(for: day, relativeTo: now, forecasts: forecasts)
        checked = forecasts.count
        total = candidates.count
        loading = false
    }
}

private extension SpotForecast {
    static func fetchAvailable(for spots: [RiderSpot]) async -> [(RiderSpot, SpotForecast)] {
        var forecasts: [(RiderSpot, SpotForecast)] = []
        for offset in stride(from: 0, to: spots.count, by: 4) {
            if Task.isCancelled { break }
            let batch = spots[offset..<min(offset + 4, spots.count)]
            await withTaskGroup(of: (RiderSpot, SpotForecast?).self) { group in
                for spot in batch { group.addTask { (spot, try? await fetch(for: spot)) } }
                for await (spot, forecast) in group {
                    if let forecast { forecasts.append((spot, forecast)) }
                }
            }
        }
        return forecasts
    }

    static func fetch(for spot: RiderSpot) async throws -> SpotForecast {
        guard let url = requestURL(for: spot) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

private struct SpotWeather: View {
    let spot: RiderSpot
    let editShore: () -> Void
    @State private var forecast: SpotForecast?
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Прогноз ветра").font(.headline)
            if spot.waterBearing == nil {
                Button("Указать направление к воде", action: editShore).font(.caption)
            }
            if let forecast {
                let hours = forecast.hours(near: Date())
                if hours.isEmpty {
                    Text("На ближайшее время прогноза нет.").foregroundStyle(.secondary)
                } else {
                    let clock = localClock(timezone: forecast.timezone)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(hours.prefix(24))) { hour in
                                VStack(spacing: 6) {
                                    Text(clock.string(from: hour.time)).font(.caption.weight(.medium))
                                    Text(metric(hour.speed * SessionWind.metersPerSecondPerKnot, unit: "м/с")).font(.headline).foregroundStyle(RiderTheme.accent)
                                    Text("Порывы \(metric(hour.gust.map { $0 * SessionWind.metersPerSecondPerKnot }, unit: "м/с"))").font(.caption2)
                                    Label(hour.condition.name, systemImage: hour.condition.icon).font(.caption2)
                                    Text(SpotForecast.compass(hour.direction) + " " + SpotForecast.windArrow(hour.direction) + " · " + metric(hour.temperature, unit: "°C", digits: 0))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if hour.speed > 0, let shore = SpotForecast.shoreWind(from: hour.direction, waterBearing: spot.waterBearing) {
                                        Text(shore).font(.caption2.weight(.semibold)).foregroundStyle(RiderTheme.accent)
                                    }
                                }.padding(9)
                                    .frame(minWidth: 86)
                                    .background(RiderTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            } else if failed {
                Text("Прогноз не загрузился.").foregroundStyle(.secondary)
                Button("Повторить") { retry += 1 }
            } else {
                ProgressView("Загружаем прогноз")
            }
            HStack {
                if let source = URL(string: "https://open-meteo.com/") { Link("Open-Meteo", destination: source).font(.caption) }
                Spacer()
                if let link = spot.windyLink { Link("Windy.app", destination: link).font(.caption) }
            }
        }.lagoonCard()
        .task(id: "\(spot.latitude),\(spot.longitude),\(retry)") { await load() }
    }

    private func localClock(timezone: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }

    @MainActor private func load() async {
        forecast = nil
        failed = false
        do {
            let decoded = try await SpotForecast.fetch(for: spot)
            try Task.checkCancellation()
            forecast = decoded
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct SpotGallery: View {
    let spotID: UUID
    @State private var chosen: [PhotosPickerItem] = []
    @State private var items: [URL] = []
    @State private var photoError = false
    @State private var importing = false
    @State private var zoom: URL?
    @State private var removingPicture = false
    private let cap = 6

    private var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("SpotPhotos", isDirectory: true)
            .appendingPathComponent(spotID.uuidString, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Фотографии").font(.headline)
            if !items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(items, id: \.self) { file in
                            if let image = UIImage(contentsOfFile: file.path) {
                                Button { zoom = file } label: {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 178, height: 112).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain).accessibilityLabel("Открыть фотографию спота")
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if items.count < cap {
                PhotosPicker(selection: $chosen, maxSelectionCount: max(1, cap - items.count), matching: .images) {
                    Label("Добавить фото", systemImage: "photo")
                }.disabled(importing)
            }
            if importing { ProgressView("Сохраняем фото") }
            if photoError { Text("Не удалось сохранить или убрать фото.").foregroundStyle(.secondary).font(.footnote) }
        }
        .lagoonCard()
        .onAppear(perform: reload)
        .onChange(of: chosen) { _, picks in
            guard !picks.isEmpty else { return }
            importing = true
            Task { await importPhotos(picks) }
        }
        .sheet(isPresented: Binding(get: { zoom != nil }, set: { if !$0 { zoom = nil } })) {
            NavigationStack {
                if let zoom, let image = UIImage(contentsOfFile: zoom.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RiderTheme.canvas.ignoresSafeArea())
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .destructive) { removingPicture = true } label: {
                                    Image(systemName: "trash").accessibilityLabel("Убрать фото со спота")
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) { Button("Готово") { self.zoom = nil } }
                        }
                        .confirmationDialog("Убрать фото со спота?", isPresented: $removingPicture) {
                            Button("Убрать фото", role: .destructive) { remove(zoom) }
                        }
                }
            }
        }
    }

    private func reload() {
        items = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func remove(_ picture: URL) {
        photoError = false
        do {
            try FileManager.default.removeItem(at: picture)
            zoom = nil
            reload()
        } catch {
            photoError = true
            zoom = nil
        }
    }

    @MainActor private func importPhotos(_ picks: [PhotosPickerItem]) async {
        defer {
            reload()
            chosen = []
            importing = false
        }
        photoError = false
        for pick in picks.prefix(max(0, cap - items.count)) {
            do {
                guard let data = try await pick.loadTransferable(type: Data.self), data.count <= 35_000_000,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 1400
                      ] as CFDictionary),
                      let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.83) else {
                    photoError = true
                    continue
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let prefix = Int(Date().timeIntervalSince1970 * 1000)
                let file = directory.appendingPathComponent("\(prefix)-\(UUID()).jpg")
                try jpeg.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { photoError = true }
        }
    }
}
