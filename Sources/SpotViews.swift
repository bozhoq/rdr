import CoreLocation
import Charts
import ImageIO
import PhotosUI
import SafariServices
import SwiftUI
import UIKit

struct SpotsView: View {
    @ObservedObject var recorder: SessionRecorder
    let goToRecording: () -> Void
    @State private var adding = false
    @State private var pendingDelete: RiderSpot?

    var body: some View {
        List {
            NavigationLink {
                BestSpotsToday(recorder: recorder, goToRecording: goToRecording)
            } label: { Label("Лучший спот на сегодня", systemImage: "wind") }
            Section("Избранные споты") {
                let favorites = recorder.spots.filter { recorder.favoriteSpots.contains($0.id) }
                if favorites.isEmpty { Text("Нажмите звезду в карточке спота").foregroundStyle(.secondary) }
                ForEach(favorites) { spot in spotRow(spot) }
            }
            SpotGroups(spots: recorder.spots, add: { adding = true }) { spot in spotRow(spot) }
        }
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Спот")
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
    @Environment(\.openURL) private var openURL
    @ObservedObject var recorder: SessionRecorder
    let original: RiderSpot
    let goToRecording: () -> Void
    @State private var editing = false
    @State private var routeUnavailable = false

    private var spot: RiderSpot { recorder.spots.first(where: { $0.id == original.id }) ?? original }
    private var sessions: [SessionSummary] { recorder.history.filter { spot.matches($0.setup) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                titleCard
                SpotRecords(recorder: recorder, sessions: sessions)
                SpotWeather(spot: spot)
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
        .alert("Маршрут не открылся", isPresented: $routeUnavailable) {
            Button("ОК", role: .cancel) {}
        }
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(spot.name).font(.largeTitle.bold())
            if spot.areaOnly == true { Text("Ориентир района. Точка старта пока не уточнена.").font(.footnote) }
            if let source = spot.source { Link("Источник координат", destination: source).font(.footnote) }
            Button(action: openRoute) {
                Label(spot.areaOnly == true ? "Показать район на карте" : "Маршрут к споту", systemImage: "location.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 42)
            }.buttonStyle(.borderedProminent).tint(RiderTheme.action)
            Button {
                recorder.chooseSpot(spot)
                goToRecording()
            } label: {
                Text("Выбрать для записи").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(RiderTheme.accent).disabled(recorder.live != nil)
        }.lagoonCard()
    }

    private func openRoute() {
        if spot.areaOnly == true, let url = spot.yandexURL { openURL(url); return }
        guard let app = spot.routeAppURL, let web = spot.routeWebURL else { return }
        openURL(app) { opened in
            if !opened { openURL(web) { routeUnavailable = !$0 } }
        }
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

private struct BestSpotsToday: View {
    @ObservedObject var recorder: SessionRecorder
    let goToRecording: () -> Void
    @State private var region = ""
    @State private var revision = 0
    @State private var loading = false
    @State private var checked = 0
    @State private var total = 0
    @State private var results: [Ranked] = []
    private var regions: [String] { Set(recorder.spots.compactMap(\.region)).sorted() }

    private struct Ranked: Identifiable {
        let spot: RiderSpot
        let day: SpotForecast.Day
        var id: UUID { spot.id }
    }

    var body: some View {
        List {
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
                if let best = results.first {
                    Text(SpotForecast.Day.description(for: best.day.meanWind))
                        .font(.headline).foregroundStyle(RiderTheme.accent)
                }
                ForEach(results) { item in
                    NavigationLink {
                        SpotDetailView(recorder: recorder, original: item.spot, goToRecording: goToRecording)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.spot.name).font(.headline)
                            Text("Средний ветер " + metric(item.day.meanWind, unit: "м/с", digits: 1)).font(.subheadline)
                            Text(SpotForecast.Day.description(for: item.day.meanWind)).font(.caption)
                            Text("Порывы до " + metric(item.day.maxGust, unit: "м/с") + " · " + metric(item.day.meanTemperature, unit: "°C", digits: 0)).font(.caption)
                            Text("07:00–20:00 · часов с прогнозом \(item.day.hours) из 14").font(.caption)
                            if item.day.thunder { Label("В прогнозе гроза", systemImage: "cloud.bolt.rain").font(.caption) }
                            if item.spot.areaOnly == true { Text("Ориентир района").font(.caption) }
                        }
                    }
                }
                if results.isEmpty {
                    Text(checked == 0 ? "Прогнозы не загрузились." : "Нет почасовых данных о ветре за 07:00–20:00.")
                }
                Text("Прогноз получен для \(checked) из \(total) спотов").font(.footnote)
                Button("Обновить прогноз") { revision += 1 }
            }
            DisclosureGroup("Как выбираем") {
                Text("Сравниваем средний ветер по доступным часам с 07:00 до 20:00 включительно по местному времени спота. Выше спот с более сильным средним ветром. При равенстве выбираем более полный прогноз. Порывы и грозы указаны отдельно.")
            }
            Link("Прогноз Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
        }
        .navigationTitle("Лучший спот на сегодня")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if region.isEmpty && recorder.usableFix == nil { recorder.locateSpot() } }
        .task(id: recorder.previewFix?.timestamp) {
            guard region.isEmpty, let fix = recorder.usableFix else { return }
            let mark = try? await CLGeocoder().reverseGeocodeLocation(fix, preferredLocale: Locale(identifier: "ru_RU")).first
            guard !Task.isCancelled, region.isEmpty else { return }
            let names = [mark?.administrativeArea, mark?.locality].compactMap { $0?.lowercased() }
            if let match = regions.first(where: { r in names.contains { $0.contains(r.lowercased()) } }) {
                region = match
            } else if let nearby = nearbyRegion(fix, within: 80000) { region = nearby }
        }
        .task(id: "\(region)/\(revision)") { await compare() }
    }

    private func nearbyRegion(_ fix: CLLocation, within radius: Double) -> String? {
        recorder.spots.compactMap { spot -> (String, Double)? in
            guard let name = spot.region else { return nil }
            let meters = fix.distance(from: CLLocation(latitude: spot.latitude, longitude: spot.longitude))
            return meters <= radius ? (name, meters) : nil
        }.min(by: { $0.1 < $1.1 })?.0
    }

    @MainActor private func compare() async {
        results = []
        checked = 0
        total = 0
        guard !region.isEmpty else { loading = false; return }
        loading = true
        let candidates = recorder.spots.filter { spot in
            if let name = spot.region { return name == region }
            return nearbyRegion(CLLocation(latitude: spot.latitude, longitude: spot.longitude), within: 30000) == region
        }
        let now = Date()
        var fetched = 0
        var ranks: [Ranked] = []
        for offset in stride(from: 0, to: candidates.count, by: 4) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: (RiderSpot, SpotForecast?).self) { group in
                for spot in candidates[offset..<min(offset + 4, candidates.count)] {
                    group.addTask { (spot, try? await SpotForecast.fetch(for: spot)) }
                }
                for await (spot, data) in group {
                    guard let data else { continue }
                    fetched += 1
                    if let day = data.daySummary(today: now) {
                        ranks.append(Ranked(spot: spot, day: day))
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }
        let sorted = ranks.sorted {
            if $0.day.meanWind != $1.day.meanWind { return $0.day.meanWind > $1.day.meanWind }
            if $0.day.hours != $1.day.hours { return $0.day.hours > $1.day.hours }
            if $0.spot.name != $1.spot.name { return $0.spot.name < $1.spot.name }
            return $0.id.uuidString < $1.id.uuidString
        }
        results = Array(sorted.prefix(3))
        checked = fetched
        total = candidates.count
        loading = false
    }
}

private extension SpotForecast {
    static func fetch(for spot: RiderSpot) async throws -> SpotForecast {
        guard let url = requestURL(for: spot) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

private struct SpotWeather: View {
    let spot: RiderSpot
    @State private var forecast: SpotForecast?
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Прогноз ветра").font(.headline)
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
