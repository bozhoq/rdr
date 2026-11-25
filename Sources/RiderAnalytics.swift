import SwiftUI
import Charts

private enum RideDimension: String, CaseIterable {
    case kit = "Комплект", spot = "Спот", wind = "Ветер", kite = "Кайт", board = "Доска", month = "Месяц"

    func key(_ ride: RiderPublicRide) -> String? {
        func clean(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            return text
        }
        switch self {
        case .spot: return clean(ride.spot)
        case .kite: return clean(ride.kite)
        case .board: return clean(ride.board)
        case .kit:
            guard let kite = clean(ride.kite), let board = clean(ride.board) else { return nil }
            return kite + " / " + board
        case .wind:
            guard let wind = ride.windMS, wind.isFinite, wind >= 0 else { return nil }
            let low = Int(wind / 2) * 2
            return "\(low)–\(low + 2) м/с"
        case .month:
            let c = Calendar.current.dateComponents([.year, .month], from: ride.date)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        }
    }
}

private enum RideMeasure: String, CaseIterable {
    case hours = "Часы на воде", count = "Каталки", jumps = "Прыжки", mean = "Средняя высота", best = "Топ высота", hang = "Топ зависание", distance = "Топ дистанция"

    var unit: String {
        switch self {
        case .hours: return "ч"
        case .mean, .best, .distance: return "м"
        case .hang: return "с"
        case .count, .jumps: return ""
        }
    }

    func value(in rides: [RiderPublicRide]) -> Double? {
        switch self {
        case .hours: return rides.reduce(0) { $0 + $1.seconds } / 3600
        case .count: return Double(rides.count)
        case .jumps: return Double(rides.reduce(0) { $0 + $1.jumps })
        case .mean:
            let known = rides.filter { $0.heightSum != nil && $0.jumps > 0 }
            let count = known.reduce(0) { $0 + $1.jumps }
            return count > 0 ? known.compactMap(\.heightSum).reduce(0, +) / Double(count) : nil
        case .best: return rides.compactMap(\.height).max()
        case .hang: return rides.compactMap(\.airtime).max()
        case .distance: return rides.compactMap(\.distance).max()
        }
    }

    func display(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " " + unit)
    }
}

private struct RideGroup: Identifiable {
    let id: String
    let value: Double
    let count: Int
    static func make(_ rides: [RiderPublicRide], by dimension: RideDimension, measure: RideMeasure) -> [Self] {
        let known = rides.compactMap { ride in dimension.key(ride).map { ($0, ride) } }
        return Dictionary(grouping: known, by: { $0.0 }).compactMap { key, pairs in
            let group = pairs.map { $0.1 }
            guard let value = measure.value(in: group) else { return nil }
            return Self(id: key, value: value, count: group.count)
        }.sorted {
            if dimension == .wind || dimension == .month {
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
            if $0.value == $1.value { return $0.id < $1.id }
            return $0.value > $1.value
        }
    }
}

private struct FilterBounds: PreferenceKey {
    static var defaultValue: CGRect { .null }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct RiderAnalytics: View {
    let title: String
    let rides: [RiderPublicRide]
    @State private var dimension = RideDimension.spot
    @State private var measure = RideMeasure.hours
    @State private var days = 0
    @State private var selections: [RideDimension: String] = [:]
    @State private var filtersOpen = false
    @State private var filterBounds = CGRect.null

    private var filtered: [RiderPublicRide] {
        let cutoff = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
        return rides.filter { ride in
            (cutoff.map { ride.date >= $0 } ?? true) && selections.allSatisfy { $0.key.key(ride) == $0.value }
        }
    }

    var body: some View {
        let sample = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup(isExpanded: $filtersOpen) {
                    Picker("Период", selection: $days) {
                        Text("Всё время").tag(0)
                        Text("30 дней").tag(30)
                        Text("90 дней").tag(90)
                        Text("365 дней").tag(365)
                    }
                    ForEach([RideDimension.spot, .kit, .kite, .board, .wind], id: \.self) { axis in
                        let options = Set(rides.compactMap { axis.key($0) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                        Picker(axis.rawValue, selection: Binding(get: { selections[axis] ?? "" }, set: {
                            selections[axis] = $0.isEmpty ? nil : $0
                        })) {
                            Text("Все").tag("")
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if !selections.isEmpty || days != 0 {
                        Button("Сбросить фильтры") { selections = [:]; days = 0 }
                    }
                } label: {
                    Label(selections.isEmpty && days == 0 ? "Всё время · фильтры" : "Фильтры включены", systemImage: "line.3.horizontal.decrease")
                }.pickerStyle(.menu).lagoonCard()
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: FilterBounds.self, value: geometry.frame(in: .named("analytics")))
                    }
                }
                if sample.isEmpty {
                    ContentUnavailableView("Нет каталок", systemImage: "chart.bar", description: Text("Здесь появятся завершённые каталки, подходящие под фильтры."))
                } else {
                    if let start = sample.map(\.date).min(), let end = sample.map(\.date).max() {
                        Text("\(start.formatted(date: .abbreviated, time: .omitted)) — \(end.formatted(date: .abbreviated, time: .omitted)) · \(sample.count) каталок")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    RideBreakdown(title: "Время на комплектах", rides: sample, dimension: .kit, measure: .hours)
                    RideBreakdown(title: "Любимые споты", rides: sample, dimension: .spot, measure: .count)
                    RideBreakdown(title: "Ветер на каталках", rides: sample, dimension: .wind, measure: .count)
                    RideWindPlot(rides: sample)
                    RideBreakdown(title: "Высота по комплектам", rides: sample, dimension: .kit, measure: .mean)
                    RideBreakdown(title: "Высота по спотам", rides: sample, dimension: .spot, measure: .mean)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Своё сравнение").font(.title3.bold())
                        LabeledContent("Группировка") { axisPicker }
                        LabeledContent("Показатель") { measurePicker }
                        RideBreakdown(title: "\(measure.rawValue) · \(dimension.rawValue.lowercased())", rides: sample,
                                      dimension: dimension, measure: measure, compact: true)
                    }.lagoonCard()
                }
                Text("Подсказки даны для развлечения. По этой истории нельзя установить причину результата. Ветер указан на старте каталки, для ручного диапазона берётся его середина.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(16)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .coordinateSpace(name: "analytics")
        .onPreferenceChange(FilterBounds.self) { filterBounds = $0 }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("analytics")).onEnded { tap in
            if filtersOpen, !filterBounds.isNull, !filterBounds.contains(tap.location) {
                withAnimation(.easeOut(duration: 0.16)) { filtersOpen = false }
            }
        })
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var axisPicker: some View {
        Picker("Группировка", selection: $dimension) {
            ForEach(RideDimension.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden()
    }
    private var measurePicker: some View {
        Picker("Показатель", selection: $measure) {
            ForEach(RideMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden()
    }
}

private struct RideBreakdown: View {
    let title: String
    let rides: [RiderPublicRide]
    let dimension: RideDimension
    let measure: RideMeasure
    var compact = false
    @State private var expanded = false

    var body: some View {
        let groups = RideGroup.make(rides, by: dimension, measure: measure)
        let maxValue = groups.map(\.value).max() ?? 0
        let content = VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if groups.isEmpty {
                Text("Для этого сравнения пока нет замеров.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(expanded ? groups : Array(groups.prefix(5))) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.id).font(.subheadline)
                            Spacer(minLength: 8)
                            Text(measure.display(group.value)).font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                        GeometryReader { box in
                            Capsule().fill(.secondary.opacity(0.15)).overlay(alignment: .leading) {
                                Capsule().fill(RiderTheme.accent)
                                    .frame(width: box.size.width * CGFloat(maxValue > 0 ? group.value / maxValue : 0))
                            }
                        }.frame(height: 5).accessibilityHidden(true)
                    }.accessibilityElement(children: .combine)
                }
                if groups.count > 5 {
                    Button(expanded ? "Свернуть" : "Все группы · \(groups.count)") { expanded.toggle() }
                }
                if let best = groups.max(by: { $0.value < $1.value }) {
                    Text(observation(best, groups: groups)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if compact { content } else { content.lagoonCard() }
    }

    private func observation(_ best: RideGroup, groups: [RideGroup]) -> String {
        if groups.count == 1 { return "Одна группа в выборке · \(best.count) каталок. Для сравнения нужны другие условия." }
        if groups.filter({ $0.value == best.value }).count > 1 { return "Несколько групп делят первое место по этому показателю." }
        return "Лидер по показателю «\(measure.rawValue.lowercased())» — \(best.id) · \(best.count) каталок в группе."
    }
}

private struct RideWindPlot: View {
    let rides: [RiderPublicRide]
    var body: some View {
        let points = rides.filter { $0.windMS != nil && $0.height != nil }
        let buckets = Dictionary(grouping: points) { Int(($0.windMS ?? 0) / 2) }
        let bins = buckets.keys.sorted()
        VStack(alignment: .leading, spacing: 10) {
            Text("Высота и ветер").font(.headline)
            if points.isEmpty {
                Text("Нужна каталка с замерами высоты и ветра.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { ride in
                        if let wind = ride.windMS, let height = ride.height {
                            PointMark(x: .value("Ветер, м/с", wind), y: .value("Высота, м", height))
                                .foregroundStyle(RiderTheme.accent.opacity(0.7))
                                .accessibilityLabel("Ветер \(wind.formatted()) м/с, рекорд \(height.formatted()) м")
                        }
                    }
                    ForEach(bins, id: \.self) { bin in
                        if let bucket = buckets[bin], !bucket.isEmpty {
                            let mean = bucket.compactMap(\.height).reduce(0, +) / Double(bucket.count)
                            LineMark(x: .value("Ветер, м/с", Double(bin * 2 + 1)), y: .value("Средний рекорд, м", mean))
                                .foregroundStyle(RiderTheme.foam)
                        }
                    }
                }.chartXAxisLabel("Ветер, м/с").chartYAxisLabel("Высота, м").frame(height: 170)
                Text("Точка — лучший прыжок каталки. Линия — среднее этих рекордов в диапазонах ветра по 2 м/с. Каталок с обоими замерами: \(points.count).")
                    .font(.caption).foregroundStyle(.secondary)
                Text(bins.count < 2 ? "Пока слишком мало разных условий для сравнения." : "Выбери один комплект в фильтрах, чтобы сравнить его результаты при разном ветре.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.lagoonCard()
    }
}
