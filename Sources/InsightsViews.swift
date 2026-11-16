import Charts
import CoreTransferable
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct ActivityFields: View {
    @Binding var setup: SessionSetup
    var ridingOnly = false

    var body: some View {
        Picker("Активность", selection: $setup.sport) {
            ForEach(SessionSport.allCases.filter { !ridingOnly || $0.isRiding }, id: \.self) { Text($0.title).tag($0) }
        }
        .onChange(of: setup.sport) { _, activity in
            if !activity.supportsKiteStyle { setup.kiteStyle = nil }
            if activity == .wing || activity == .windsurf { setup.kiteAreaSquareMeters = nil }
        }
        if setup.sport.supportsKiteStyle {
            Picker("Стиль", selection: $setup.kiteStyle) {
                Text("Не указан").tag(nil as KiteStyle?)
                ForEach(KiteStyle.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
        }
    }
}

struct KitePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var setup: SessionSetup
    let recent: [String]
    @State private var brandSearch = ""

    var body: some View {
        NavigationStack {
            List {
                if brandSearch.isEmpty, !recent.isEmpty {
                    Section("Недавние") {
                        ForEach(recent, id: \.self) { kite in
                            NavigationLink(kite) { sizeChoice(kite) }
                        }
                    }
                }
                if brandSearch.isEmpty, !setup.kite.isEmpty {
                    NavigationLink("Изменить размер текущего кайта") { sizeChoice(setup.kite) }
                }
                Section("Бренды") {
                    ForEach(KiteCatalog.brands.filter { $0.matches(brandSearch) }) { brand in
                        NavigationLink(brand.name) {
                            KiteModels(brand: brand, choose: choose)
                        }
                    }
                }
                NavigationLink("Ввести кайт вручную") { KiteManualEntry(value: setup.kite, choose: choose) }
                if !setup.kite.isEmpty { Button("Убрать выбранный кайт") { choose("", nil) } }
            }
            .searchable(text: $brandSearch, prompt: "Поиск бренда")
            .navigationTitle("Кайт")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .tint(RiderTheme.accent)
    }

    private func choose(_ value: String, _ area: Double?) {
        setup.selectKite(String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), area: area)
        dismiss()
    }

    private func sizeChoice(_ kite: String) -> KiteSizeChoice {
        KiteSizeChoice(name: kite, current: kite == setup.kite ? setup.kiteAreaSquareMeters : nil, choose: choose)
    }
}

private struct KiteModels: View {
    let brand: KiteCatalog.Brand
    let choose: (String, Double?) -> Void
    @State private var search = ""

    var body: some View {
        List {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            ForEach(brand.models.filter { query.isEmpty || $0.localizedStandardContains(query) }, id: \.self) { model in
                NavigationLink(model) {
                    KiteSizeChoice(name: "\(brand.name) \(model)", choose: choose)
                }
            }
            NavigationLink("Другой вариант \(brand.name)") {
                KiteManualEntry(value: brand.name + " ", choose: choose)
            }
        }
        .searchable(text: $search, prompt: "Поиск модели")
        .navigationTitle(brand.name)
    }
}

private struct KiteManualEntry: View {
    @State var value: String
    let choose: (String, Double?) -> Void

    var body: some View {
        Form {
            TextField("Бренд и модель", text: $value)
                .onChange(of: value) { _, text in if text.count > 100 { value = String(text.prefix(100)) } }
            NavigationLink("Далее · размер кайта") { KiteSizeChoice(name: value, choose: choose) }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.navigationTitle("Указать вручную")
    }
}

private struct KiteSizeChoice: View {
    let name: String
    var current: Double?
    let choose: (String, Double?) -> Void

    var body: some View {
        List {
            Section(name) {
                ForEach(SessionSetup.kiteAreas, id: \.self) { area in
                    Button {
                        choose(name, area)
                    } label: {
                        HStack {
                            Text(SessionSetup.kiteAreaTitle(area))
                            Spacer()
                            if current == area { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Button("Без размера") { choose(name, nil) }
        }.navigationTitle("Размер кайта")
    }
}

struct BoardPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var setup: SessionSetup
    let recent: [SessionSummary]
    @State private var search = ""

    private var recentBoards: [BoardSelection] {
        var seen: Set<BoardSelection> = []
        let entries = recent.compactMap { session -> BoardSelection? in
            guard let previous = session.setup else { return nil }
            return previous.boardDetails ?? BoardSelection(brand: "", model: previous.board)
        }
        return Array(entries.filter { seen.insert($0).inserted }.prefix(8))
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty, !recentBoards.isEmpty {
                    Section("Недавние") {
                        ForEach(recentBoards, id: \.self) { board in Button(board.title) { choose(board) } }
                    }
                }
                Section("Бренды") {
                    ForEach(BoardCatalog.brands.filter { $0.matches(search) }) { brand in
                        NavigationLink(brand.name) { BoardModels(brand: brand, choose: choose) }
                    }
                }
                NavigationLink("Указать доску или лыжи вручную") {
                    BoardManualEntry(brand: setup.boardDetails?.brand ?? "",
                                     model: setup.boardDetails?.model ?? setup.board,
                                     size: setup.boardDetails?.size ?? "", choose: choose)
                }
                if !setup.boardTitle.isEmpty {
                    Button("Убрать выбранную доску") {
                        setup.board = ""
                        setup.boardDetails = nil
                        dismiss()
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск бренда доски")
            .navigationTitle("Доска / лыжи")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }.tint(RiderTheme.accent)
    }

    private func choose(_ board: BoardSelection) {
        setup.selectBoard(board)
        dismiss()
    }
}

private struct BoardModels: View {
    let brand: BoardCatalog.Brand
    let choose: (BoardSelection) -> Void
    @State private var search = ""

    var body: some View {
        List {
            ForEach(brand.models.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { model in
                NavigationLink(model.name) { BoardSizes(brand: brand.name, model: model, choose: choose) }
            }
            NavigationLink("Другая модель") { BoardManualEntry(brand: brand.name, choose: choose) }
        }
        .searchable(text: $search, prompt: "Поиск модели доски")
        .navigationTitle(brand.name)
    }
}

private struct BoardSizes: View {
    let brand: String
    let model: BoardCatalog.Model
    let choose: (BoardSelection) -> Void

    var body: some View {
        List {
            Section("\(brand) \(model.name)") {
                ForEach(model.sizes, id: \.self) { size in Button(size) { select(size) } }
            }
            NavigationLink("Другой размер") {
                BoardManualEntry(brand: brand, model: model.name, sizeOnly: true, choose: choose)
            }
            Button("Без размера") { select(nil) }
        }.navigationTitle("Размер доски")
    }

    private func select(_ size: String?) {
        if let board = BoardSelection(brand: brand, model: model.name, size: size) { choose(board) }
    }
}

private struct BoardManualEntry: View {
    @State var brand = ""
    @State var model = ""
    @State var size = ""
    var sizeOnly = false
    let choose: (BoardSelection) -> Void

    var body: some View {
        let board = BoardSelection(brand: brand, model: model, size: size)
        Form {
            if !sizeOnly {
                TextField("Бренд", text: $brand)
                TextField("Модель", text: $model)
            }
            TextField("Размер, например 136 × 41 см", text: $size)
            Button("Сохранить") { if let board { choose(board) } }
                .disabled(board == nil)
        }.navigationTitle(sizeOnly ? "Другой размер" : "Указать вручную")
    }
}

struct SetupFields: View {
    @Binding var setup: SessionSetup
    var recent: [SessionSummary] = []
    var spots: [RiderSpot] = []
    @State private var showingKitePicker = false
    @State private var showingSpotPicker = false
    @State private var showingBoardPicker = false
    var body: some View {
        let suggestions = SetupSuggestions(history: recent)
        ActivityFields(setup: $setup)
        Button { showingSpotPicker = true } label: {
            LabeledContent("Спот", value: setup.spot.isEmpty ? "Выбрать" : setup.spot)
        }.sheet(isPresented: $showingSpotPicker) {
            SpotChoice(setup: $setup, spots: spots, recent: suggestions.spots)
        }
        if setup.sport == .wing || setup.sport == .windsurf {
            TextField(setup.sport == .wing ? "Винг" : "Парус", text: $setup.kite)
                .onChange(of: setup.kite) { _, value in setup.kite = String(value.prefix(100)) }
        } else {
            Button { showingKitePicker = true } label: {
                LabeledContent("Кайт", value: setup.kite.isEmpty ? "Выбрать" : setup.kiteTitle)
            }.sheet(isPresented: $showingKitePicker) {
                KitePicker(setup: $setup, recent: suggestions.kites)
            }
        }
        Button { showingBoardPicker = true } label: {
            LabeledContent("Доска / лыжи", value: setup.boardTitle.isEmpty ? "Выбрать" : setup.boardTitle)
        }.sheet(isPresented: $showingBoardPicker) {
            BoardPicker(setup: $setup, recent: recent)
        }
        Picker("Где телефон", selection: $setup.placement) {
            ForEach(PhonePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

struct SetupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var setup: SessionSetup
    var recent: [SessionSummary] = []
    var spots: [RiderSpot] = []
    @State private var failed = false
    let onSave: (SessionSetup) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section { SetupFields(setup: $setup, recent: recent, spots: spots) }
                footer: { Text("Тесты на земле и сессии без указанного занятия не входят в статистику катания. Положение телефона помогает разбирать реальные движения чехла.") }
                .listRowBackground(RiderTheme.surface)
                if failed { Text("Не удалось сохранить. Попробуйте ещё раз.").foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(RiderTheme.canvas.ignoresSafeArea())
            .navigationTitle("Занятие и снаряжение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { if onSave(setup) { dismiss() } else { failed = true } }
                }
            }
        }
        .tint(RiderTheme.accent)
        .interactiveDismissDisabled()
    }
}

struct RouteView: View {
    @ObservedObject var recorder: SessionRecorder
    let session: SessionSummary
    @State private var route: RouteAnalysis?
    @State private var gpx: URL?
    @State private var error: String?
    @State private var selectedTime: Date?
    @State private var retry = 0
    @State private var mapSegments: [[RoutePoint]] = []
    @State private var speedPoints: [RoutePoint] = []
    @State private var satellite = false
    @State private var camera: MapCameraPosition = .automatic
    private var selectedPoint: RoutePoint? {
        selectedTime.flatMap { time in speedPoints.min { abs($0.sample.timestamp.timeIntervalSince(time)) < abs($1.sample.timestamp.timeIntervalSince(time)) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let route {
                    if route.points.isEmpty {
                        ContentUnavailableView("Маршрут не записан", systemImage: "location.slash", description: Text("В этой сессии нет точек GPS с достаточной точностью. Данные движения и события сохранены отдельно."))
                    } else {
                        Picker("Карта", selection: $satellite) {
                            Text("Схема").tag(false)
                            Text("Спутник").tag(true)
                        }.pickerStyle(.segmented)
                        routeMap(route)
                        Button("Показать весь маршрут") { camera = .automatic }
                        VStack(spacing: 12) {
                            LabeledContent("Дистанция GPS", value: metric(route.metrics.distanceMeters / 1000, unit: "км", digits: 2))
                            LabeledContent("Макс. скорость GPS", value: metric(route.metrics.maxSpeedMetersPerSecond.map { $0 * 3.6 }, unit: "км/ч"))
                        }.lagoonCard()
                    }
                    DisclosureGroup("Подробнее") {
                        routeDetails(route)
                    }.lagoonCard()
                } else if let error {
                    ContentUnavailableView("Не удалось открыть маршрут", systemImage: "exclamationmark.circle", description: Text(error))
                    Button("Повторить") { retry += 1 }.buttonStyle(.bordered)
                } else {
                    ProgressView("Читаем маршрут из записи…").frame(maxWidth: .infinity).padding(.top, 50)
                }
            }.padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Маршрут")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) { await load() }
    }

    private func routeDetails(_ route: RouteAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Точек принято / отброшено", value: "\(route.metrics.accepted) / \(route.metrics.rejected)")
            LabeledContent("Участков маршрута", value: route.metrics.segments.formatted())
            if !route.points.isEmpty { speedChart(route) }
            if let gpx {
                ShareLink(item: GPXFile(url: gpx), preview: SharePreview("Маршрут Rider")) {
                    Label("Экспортировать GPX", systemImage: "square.and.arrow.up")
                }
                Text("GPX содержит координаты и время маршрута.").font(.footnote).foregroundStyle(.secondary)
            }
            if route.malformedLines > 0 {
                LabeledContent("Повреждённых строк в логе", value: route.malformedLines.formatted())
            }
        }.padding(.top, 10)
    }

    private func routeMap(_ route: RouteAnalysis) -> some View {
        let segments = mapSegments
        return Map(position: $camera) {
            ForEach(segments.indices, id: \.self) { index in
                MapPolyline(coordinates: segments[index].map { CLLocationCoordinate2D(latitude: $0.sample.latitude, longitude: $0.sample.longitude) })
                    .stroke(RiderTheme.action, lineWidth: 4)
            }
            if let first = route.points.first {
                Marker("Старт", systemImage: "play.fill", coordinate: CLLocationCoordinate2D(latitude: first.sample.latitude, longitude: first.sample.longitude))
                    .tint(RiderTheme.action)
            }
            if let last = route.points.last, route.points.count > 1 {
                Marker("Финиш", systemImage: "flag.checkered", coordinate: CLLocationCoordinate2D(latitude: last.sample.latitude, longitude: last.sample.longitude))
                    .tint(.indigo)
            }
            if let selected = selectedPoint {
                Annotation("Выбранная скорость", coordinate: CLLocationCoordinate2D(latitude: selected.sample.latitude, longitude: selected.sample.longitude)) {
                    Image(systemName: "scope").font(.title2.bold()).foregroundStyle(.white).padding(6)
                        .background(RiderTheme.action, in: Circle()).shadow(radius: 3)
                }
            }
        }
        .mapStyle(satellite ? .imagery(elevation: .flat) : .standard(elevation: .flat))
        .mapControls { MapCompass(); MapScaleView() }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityLabel("Маршрут сессии, старт и финиш")
    }

    private func speedChart(_ route: RouteAnalysis) -> some View {
        let points = speedPoints
        let selected = selectedPoint
        return VStack(alignment: .leading, spacing: 12) {
            Text("Скорость · км/ч").font(.headline)
            if points.isEmpty {
                Text("Нет надёжных измерений скорости.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Время", point.sample.timestamp), y: .value("км/ч", (point.speed ?? 0) * 3.6), series: .value("Участок", point.speedSegment))
                            .foregroundStyle(RiderTheme.accent)
                        PointMark(x: .value("Время", point.sample.timestamp), y: .value("км/ч", (point.speed ?? 0) * 3.6))
                            .foregroundStyle(RiderTheme.accent).symbolSize(6)
                    }
                    if let selected {
                        RuleMark(x: .value("Выбрано", selected.sample.timestamp)).foregroundStyle(.secondary)
                    }
                }
                .chartXSelection(value: $selectedTime)
                .chartYAxisLabel("км/ч")
                .frame(height: 190)
                if let selected {
                    Text("\(selected.sample.timestamp.formatted(date: .omitted, time: .standard)) · \(metric(selected.speed.map { $0 * 3.6 }, unit: "км/ч"))")
                        .font(.subheadline.monospacedDigit())
                    Button("Показать точку на карте") {
                        camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: selected.sample.latitude, longitude: selected.sample.longitude), span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)))
                    }.font(.subheadline)
                } else {
                    Text("Проведите по графику, чтобы выбрать ближайшее измерение.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.lagoonCard()
    }

    @MainActor private func load() async {
        error = nil
        let url = recorder.exportURL(for: session.id)
        let start = session.startedAt
        let task = Task.detached(priority: .userInitiated) {
            let result = try RouteReplay.analyze(url: url, startedAt: start)
            try Task.checkCancellation()
            let file = result.points.isEmpty ? nil : try GPXExport.write(result, name: "Rider \(start.formatted(date: .numeric, time: .shortened))")
            return (result, file, result.displaySegments, result.displaySpeedPoints)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            route = result.0
            gpx = result.1
            mapSegments = result.2
            speedPoints = result.3
            recorder.saveGPSMetrics(result.0.metrics, for: session.id)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct GPXFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "gpx") ?? .xml) { value in
            SentTransferredFile(value.url)
        }
    }
}

struct ProgressViewRider: View {
    @ObservedObject var recorder: SessionRecorder
    @State private var recent = true
    private var progress: RiderProgress {
        RiderProgress(history: recorder.history, since: recent ? Calendar.current.date(byAdding: .day, value: -30, to: Date()) : nil)
    }

    var body: some View {
        let data = progress
        List {
            Section {
                Picker("Период", selection: $recent) {
                    Text("30 дней").tag(true)
                    Text("Всё время").tag(false)
                }.pickerStyle(.segmented)
            }.listRowBackground(RiderTheme.surface)
            Section("Катание") {
                LabeledContent("Сессий", value: data.sessions.count.formatted())
                LabeledContent("Время", value: durationText(data.duration))
                LabeledContent("Дистанция GPS", value: metric(data.distance / 1000, unit: "км", digits: 2))
                LabeledContent("Макс. скорость GPS", value: metric(data.maximumSpeed.map { $0 * 3.6 }, unit: "км/ч"))
                LabeledContent("Прыжков отмечено вами", value: data.confirmedJumps.formatted())
            }.listRowBackground(RiderTheme.surface)
            if data.sessions.isEmpty {
                Section {
                    Text("Здесь появится статистика кайтсёрфинга, сноукайтинга и винга. Укажите занятие перед записью или в сводке старой сессии.")
                }.listRowBackground(RiderTheme.surface)
            } else {
                Section("Снаряжение · время") {
                    let groups = Dictionary(grouping: data.sessions, by: { session in
                        let kite = session.setup?.kite ?? ""
                        return kite.isEmpty ? "Без указанного кайта / винга" : kite
                    })
                    ForEach(groups.keys.sorted(), id: \.self) { gear in
                        LabeledContent(gear, value: durationText(groups[gear, default: []].reduce(0) { $0 + $1.durationSeconds }))
                    }
                }.listRowBackground(RiderTheme.surface)
                Section("Последние сессии катания") {
                    ForEach(Array(data.sessions.prefix(10))) { session in
                        NavigationLink { SessionDetail(recorder: recorder, originalSession: session) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.setup?.spot.isEmpty == false ? session.setup!.spot : session.setup?.sport.title ?? "Сессия")
                                Text(session.startedAt, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.listRowBackground(RiderTheme.surface)
            }
            Section {
                Text("Тесты на земле и записи без указанного занятия исключены. Прерванные сессии учитываются по сохранённой части. Прыжки здесь — ваши отметки, а не подтверждение точности детектора. Старые GPS-итоги уточняются после открытия маршрута.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(RiderTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Прогресс")
    }
}
