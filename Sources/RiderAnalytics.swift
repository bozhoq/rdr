import SwiftUI

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
            return ride.windMS.flatMap(RideWindBand.init)?.title
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
        case .best: return rides.compactMap(\.height).filter { $0.isFinite && $0 > 0 }.max()
        case .hang: return rides.compactMap(\.airtime).max()
        case .distance: return rides.compactMap(\.distance).max()
        }
    }

    func display(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " " + unit)
    }
}


private struct RideWindBand: Hashable, Comparable {
    let low: Int

    init?(_ wind: Double) {
        guard wind.isFinite, (0...150).contains(wind) else { return nil }
        low = Int(wind) / 2 * 2
    }

    var title: String { "\(low)–\(low + 2) м/с" }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.low < rhs.low }
}

private struct RideFilter: Equatable {
    var period = Period.all
    var values: [RideDimension: String] = [:]

    enum Period: String, CaseIterable, Identifiable {
        case all = "Всё время", month = "30 дней", quarter = "90 дней", year = "12 месяцев"
        var id: Self { self }
        var days: Int? {
            switch self { case .all: return nil; case .month: return 30; case .quarter: return 90; case .year: return 365 }
        }
    }

    var count: Int { values.count + (period == .all ? 0 : 1) }

    func apply(to rides: [RiderPublicRide], excluding axis: RideDimension? = nil) -> [RiderPublicRide] {
        let cutoff = period.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        return rides.filter { ride in
            (cutoff.map { ride.date >= $0 } ?? true) &&
                values.allSatisfy { $0.key == axis || $0.key.key(ride) == $0.value }
        }
    }
}

struct RiderAnalytics: View {
    let title: String
    let rides: [RiderPublicRide]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if rides.isEmpty {
                    ContentUnavailableView("Нет каталок", systemImage: "chart.bar",
                        description: Text("Закончи каталку, чтобы здесь появилась статистика."))
                } else {
                    overview
                    AnalyticsCard(title: "Высота при разном ветре", icon: "wind",
                                  help: "Сравни типичную высоту и лучший прыжок по диапазонам. Выбери один спот и комплект, чтобы условия были ближе.",
                                  rides: rides, axes: [.spot, .kit]) { sample in
                        RideWindComparison(rides: sample)
                    }
                    AnalyticsCard(title: "Динамика по месяцам", icon: "chart.line.uptrend.xyaxis",
                                  help: "Посмотри, меняется ли результат по месяцам. Переключись на часы или прыжки, чтобы сопоставить прогресс с накатом.",
                                  rides: rides, axes: [.spot, .kit, .wind]) { sample in
                        RideComparisonControls(rides: sample, defaultAxis: .month, defaultMeasure: .best, selectableAxis: false)
                    }
                    AnalyticsCard(title: "Накат на комплектах", icon: "sailboat",
                                  help: "Узнай, на чём ты проводишь больше времени. Фильтр по ветру показывает, какие комплекты чаще идут в дело в этих условиях.",
                                  rides: rides, axes: [.spot, .wind]) { sample in
                        RideBars(rides: sample, by: .kit, measure: .hours, shares: true)
                    }
                    AnalyticsCard(title: "Накат по спотам", icon: "mappin.and.ellipse",
                                  help: "Сравни, где ты бываешь чаще. Фильтр по комплекту помогает вспомнить, какое снаряжение ты берёшь на каждый спот.",
                                  rides: rides, axes: [.kit, .wind]) { sample in
                        RideBars(rides: sample, by: .spot, measure: .count, shares: true)
                    }
                    AnalyticsCard(title: "Своё сравнение", icon: "slider.horizontal.3",
                                  help: "Сравни, например, доски по средней высоте или споты по времени на воде. Смотри на число каталок рядом с каждым результатом.",
                                  rides: rides, axes: [.spot, .kit, .kite, .board, .wind]) { sample in
                        RideComparisonControls(rides: sample, defaultAxis: .board, defaultMeasure: .mean)
                    }
                }
            }.padding(12)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Все каталки").font(.headline)
            Text("\(rides.count.formatted()) каталок · \(durationText(rides.reduce(0) { $0 + $1.seconds })) на воде")
                .font(.subheadline).monospacedDigit()
            Text("\(rides.reduce(0) { $0 + $1.jumps }.formatted()) прыжков с замером высоты")
                .font(.caption).foregroundStyle(.secondary)
        }.lagoonCard()
    }
}

private struct AnalyticsCard<Content: View>: View {
    let title: String
    let icon: String
    let help: String
    let rides: [RiderPublicRide]
    let axes: [RideDimension]
    @ViewBuilder let content: ([RiderPublicRide]) -> Content
    @State private var filter = RideFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: icon).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 3)
                filters
            }
            if filter.count > 0 {
                Text(([filter.period.rawValue] + axes.compactMap { filter.values[$0] }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            content(filter.apply(to: rides))
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.lagoonCard()
    }

    private var filters: some View {
        Menu {
            Picker("Период", selection: $filter.period) {
                ForEach(RideFilter.Period.allCases) { period in Text(period.rawValue).tag(period) }
            }
            ForEach(axes, id: \.self) { axis in
                let options = Set(filter.apply(to: rides, excluding: axis).compactMap { axis.key($0) })
                    .union(filter.values[axis].map { [$0] } ?? [])
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if !options.isEmpty {
                    Picker(axis.rawValue, selection: Binding(get: { filter.values[axis] ?? "" }, set: {
                        filter.values[axis] = $0.isEmpty ? nil : $0
                    })) {
                        Text("Все").tag("")
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            if filter.count > 0 { Button("Сбросить фильтры") { filter = RideFilter() } }
        } label: {
            Label(filter.count == 0 ? "Фильтры" : "Фильтры · \(filter.count)", systemImage: "line.3.horizontal.decrease")
                .font(.caption.weight(.semibold)).labelStyle(.iconOnly)
                .frame(width: 40, height: 38)
                .background(filter.count > 0 ? RiderTheme.accent.opacity(0.22) : RiderTheme.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .tint(RiderTheme.accent)
    }
}

private struct RideWindComparison: View {
    let rides: [RiderPublicRide]

    private struct Band: Identifiable {
        let id: RideWindBand
        let heights: [Double]
        var best: Double { heights[heights.count - 1] }
        var median: Double {
            let middle = heights.count / 2
            return heights.count.isMultiple(of: 2) ? (heights[middle - 1] + heights[middle]) / 2 : heights[middle]
        }
    }

    var body: some View {
        let pairs = rides.compactMap { ride -> (RideWindBand, Double)? in
            guard let wind = ride.windMS, let band = RideWindBand(wind),
                  let height = ride.height, height.isFinite, height > 0 else { return nil }
            return (band, height)
        }
        let rows = Dictionary(grouping: pairs, by: { $0.0 }).map { band, group in
            Band(id: band, heights: group.map { $0.1 }.sorted())
        }.sorted { $0.id < $1.id }
        let maxHeight = rows.map(\.best).max() ?? 0
        let comparable = rows.filter { $0.heights.count >= 3 }
        if rows.isEmpty {
            Text("Нет каталок, где записаны и ветер, и высота прыжка.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            if comparable.count >= 2, let leader = comparable.max(by: { $0.median < $1.median }),
               let lowest = comparable.map(\.median).min(), leader.median - lowest >= 0.1 {
                Text("Типичный максимум выше при \(leader.id.title) · \(RideMeasure.best.display(leader.median))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(RiderTheme.accent)
            } else {
                Text(comparable.count >= 2 ? "Типичная высота в этих диапазонах близка." : "Для сравнения нужно по 3 каталки хотя бы в двух диапазонах.")
                    .font(.subheadline.weight(.medium))
            }
            HStack {
                Label("Типично", systemImage: "capsule.fill")
                    .foregroundStyle(RiderTheme.accent)
                Label("Рекорд", systemImage: "line.diagonal")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(pairs.count) из \(rides.count) каталок")
            }.font(.caption2)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.id.title).fontWeight(.semibold)
                        Spacer()
                        Text(row.heights.count >= 3 ? RideMeasure.best.display(row.median) : "—")
                        Text(" / \(RideMeasure.best.display(row.best))").foregroundStyle(.secondary)
                    }.font(.subheadline).monospacedDigit()
                    GeometryReader { box in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.12))
                            Capsule().fill(.secondary.opacity(0.5)).frame(width: box.size.width * CGFloat(row.best / maxHeight))
                            if row.heights.count >= 3 {
                                Capsule().fill(RiderTheme.accent).frame(width: box.size.width * CGFloat(row.median / maxHeight))
                            }
                        }
                    }.frame(height: 6).accessibilityHidden(true)
                    Text("\(row.heights.count) каталок" + (row.heights.count < 3 ? " · мало данных" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            Text("«Типично» — медиана лучших прыжков каждой каталки. Ветер берётся на старте записи, для ручного диапазона — его середина.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RideComparisonControls: View {
    let rides: [RiderPublicRide]
    var selectableAxis: Bool
    @State private var axis: RideDimension
    @State private var measure: RideMeasure

    init(rides: [RiderPublicRide], defaultAxis: RideDimension, defaultMeasure: RideMeasure, selectableAxis: Bool = true) {
        self.rides = rides
        self.selectableAxis = selectableAxis
        _axis = State(initialValue: defaultAxis)
        _measure = State(initialValue: defaultMeasure)
    }

    var body: some View {
        HStack {
            if selectableAxis {
                Picker("Группировка", selection: $axis) {
                    ForEach(RideDimension.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }
            Picker("Показатель", selection: $measure) {
                ForEach(RideMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden()
        }.pickerStyle(.menu).tint(RiderTheme.accent)
        RideBars(rides: rides, by: axis, measure: measure)
    }
}

private struct RideBars: View {
    let rides: [RiderPublicRide]
    let by: RideDimension
    let measure: RideMeasure
    var shares = false
    @State private var expanded = false

    private struct Row: Identifiable {
        let id: String
        let value: Double
        let sample: Int
    }

    var body: some View {
        let paired = rides.compactMap { ride in by.key(ride).map { ($0, ride) } }
        let rows = Dictionary(grouping: paired, by: { $0.0 }).compactMap { key, pairs -> Row? in
            let contributing = pairs.map { $0.1 }.filter { measure.value(in: [$0]) != nil }
            guard let value = measure.value(in: contributing), value.isFinite, value >= 0, !contributing.isEmpty else { return nil }
            return Row(id: key, value: value, sample: contributing.count)
        }.sorted { a, b in
            if by == .month { return a.id > b.id }
            if by == .wind { return a.id.localizedStandardCompare(b.id) == .orderedAscending }
            return a.value == b.value ? a.id.localizedStandardCompare(b.id) == .orderedAscending : a.value > b.value
        }
        let largest = rows.map(\.value).max() ?? 0
        let total = rows.reduce(0) { $0 + $1.value }
        let coverage = rows.reduce(0) { $0 + $1.sample }
        if rows.isEmpty {
            Text("Для этого сравнения пока нет данных.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            ForEach(expanded ? rows : Array(rows.prefix(5))) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(label(row.id)).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(measure.display(row.value)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    GeometryReader { box in
                        Capsule().fill(.secondary.opacity(0.14)).overlay(alignment: .leading) {
                            Capsule().fill(RiderTheme.accent).frame(width: box.size.width * CGFloat(largest > 0 ? row.value / largest : 0))
                        }
                    }.frame(height: 5).accessibilityHidden(true)
                    if shares && total > 0 {
                        Text((row.value / total).formatted(.percent.precision(.fractionLength(0))) + " от учтённых · \(row.sample) каталок")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("\(row.sample) каталок").font(.caption2).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
            if rows.count > 5 {
                Button(expanded ? "Свернуть" : "Показать все · \(rows.count)") { expanded.toggle() }.font(.caption)
            }
            if coverage < rides.count {
                Text("Учтено \(coverage) из \(rides.count) каталок. У остальных нет нужных данных.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ key: String) -> String {
        guard by == .month else { return key }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return key }
        return date.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }
}
