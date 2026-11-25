import Foundation

struct RiderTotals: Codable, Equatable {
    let sessions: Int
    let jumps: Int
    let height: Double?
    let airtime: Double?
    let seconds: Double

    init(_ history: [SessionSummary]) {
        let rides = history.filter { Self.isRide($0) }
        let events = rides.flatMap { Self.measuredJumps(in: $0) }
        sessions = rides.count
        jumps = events.count
        height = events.compactMap(\.heightMeters).max()
        airtime = events.compactMap(\.reportedAirtime).filter { $0.isFinite && $0 > 0 }.max()
        seconds = rides.reduce(0) { $0 + $1.durationSeconds }
    }

    fileprivate static func isRide(_ session: SessionSummary, includeRecording: Bool = false) -> Bool {
        (session.status != .recording || includeRecording) && session.setup?.sport.isRiding == true &&
            session.durationSeconds.isFinite && session.durationSeconds > 0 &&
            session.handSimulationTest != true && session.phoneTossTest != true && session.recordingMode != .test
    }

    fileprivate static func measuredJumps(in session: SessionSummary, includeRecording: Bool = false) -> [LiveJumpEstimate] {
        guard isRide(session, includeRecording: includeRecording), let analysis = session.jumpAnalysis else { return [] }
        return analysis.candidates.compactMap { candidate in
            guard let estimate = session.liveEstimate(for: candidate),
                  estimate.isPhoneToss != true, estimate.isHandLift != true,
                  let height = estimate.heightMeters, height.isFinite, height > 0 else { return nil }
            return estimate
        }
    }

    var timeOnWater: String {
        let minutes = Int(min(seconds / 60, Double(Int32.max)))
        let hours = minutes / 60
        return hours > 0 ? "\(hours) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
}

enum RiderRank: String, CaseIterable, Identifiable {
    case e = "E", d = "D", c = "C", b = "B", a = "A", s = "S"

    var id: Self { self }
    var threshold: Int {
        switch self {
        case .e: return 0
        case .d: return 100
        case .c: return 350
        case .b: return 800
        case .a: return 1600
        case .s: return 3000
        }
    }

    static func forPoints(_ points: Int) -> Self {
        allCases.last { points >= $0.threshold } ?? .e
    }

    var next: Self? { Self.allCases.first { $0.threshold > threshold } }
}

enum RiderMission: String, Codable, CaseIterable, Identifiable {
    case water15, water25, water35, water45, water60, water90
    case route1, route2, route3, route5, route8, route12
    case jumps1, jumps3, jumps5, jumps8, jumps12, jumps20
    case height2, height3, height4, height5, height6
    case air1, air15, air2, air25, air3

    static let minimumRideSeconds = 15 * 60
    var id: Self { self }

    enum Category: String, CaseIterable, Identifiable {
        case water, route, jumps, height, air

        var id: Self { self }
        var title: String {
            switch self {
            case .water: return "Время на воде"
            case .route: return "Маршрут"
            case .jumps: return "Количество прыжков"
            case .height: return "Высота"
            case .air: return "Время в воздухе"
            }
        }
        var icon: String {
            switch self {
            case .water: return "water.waves"
            case .route: return "map"
            case .jumps: return "bolt.fill"
            case .height: return "arrow.up"
            case .air: return "timer"
            }
        }

        func text(_ value: Double) -> String {
            let quantity = self == .route ? value / 1000 : value
            let rounded = (quantity * 10).rounded(.down) / 10
            let number = rounded.formatted(.number.precision(.fractionLength(0...1)))
            switch self {
            case .water: return number + " мин"
            case .route: return number + " км"
            case .jumps: return number
            case .height: return number + " м"
            case .air: return number + " с"
            }
        }
    }

    struct Rule {
        let category: Category
        let target: Double
        let points: Int
        let title: String

        var goal: String {
            category == .jumps ? category.text(target) + " прыжков от 2 м" : category.text(target)
        }
    }

    var rule: Rule {
        switch self {
        case .water15: return .init(category: .water, target: 15, points: 5, title: "Поймать ритм")
        case .water25: return .init(category: .water, target: 25, points: 8, title: "Разогреться")
        case .water35: return .init(category: .water, target: 35, points: 10, title: "Войти в поток")
        case .water45: return .init(category: .water, target: 45, points: 12, title: "Три четверти часа")
        case .water60: return .init(category: .water, target: 60, points: 15, title: "Мой час на воде")
        case .water90: return .init(category: .water, target: 90, points: 20, title: "Длинная каталка")
        case .route1: return .init(category: .route, target: 1000, points: 6, title: "Первый километр")
        case .route2: return .init(category: .route, target: 2000, points: 8, title: "Пара километров")
        case .route3: return .init(category: .route, target: 3000, points: 10, title: "Три по воде")
        case .route5: return .init(category: .route, target: 5000, points: 14, title: "Пятёрка по воде")
        case .route8: return .init(category: .route, target: 8000, points: 18, title: "Дальше по ветру")
        case .route12: return .init(category: .route, target: 12000, points: 22, title: "Длинный маршрут")
        case .jumps1: return .init(category: .jumps, target: 1, points: 6, title: "Первый полёт")
        case .jumps3: return .init(category: .jumps, target: 3, points: 9, title: "Три взлёта")
        case .jumps5: return .init(category: .jumps, target: 5, points: 12, title: "Воздушная пятёрка")
        case .jumps8: return .init(category: .jumps, target: 8, points: 15, title: "Восемь взлётов")
        case .jumps12: return .init(category: .jumps, target: 12, points: 20, title: "Дюжина в воздухе")
        case .jumps20: return .init(category: .jumps, target: 20, points: 25, title: "Двадцать взлётов")
        case .height2: return .init(category: .height, target: 2, points: 6, title: "Оторваться")
        case .height3: return .init(category: .height, target: 3, points: 8, title: "Три метра вверх")
        case .height4: return .init(category: .height, target: 4, points: 11, title: "Выше брызг")
        case .height5: return .init(category: .height, target: 5, points: 14, title: "Уровень окон")
        case .height6: return .init(category: .height, target: 6, points: 18, title: "Шесть над водой")
        case .air1: return .init(category: .air, target: 1, points: 6, title: "Секунда в воздухе")
        case .air15: return .init(category: .air, target: 1.5, points: 8, title: "Полторы в воздухе")
        case .air2: return .init(category: .air, target: 2, points: 10, title: "Две секунды тишины")
        case .air25: return .init(category: .air, target: 2.5, points: 13, title: "Поймать паузу")
        case .air3: return .init(category: .air, target: 3, points: 16, title: "Три секунды полёта")
        }
    }

    struct Metrics {
        let seconds: Int
        let scoringJumps: Int
        let height: Double?
        let airtime: Double?
        let distance: Double?

        init(seconds: Int, scoringJumps: Int, height: Double?, airtime: Double?, distance: Double?) {
            self.seconds = seconds
            self.scoringJumps = scoringJumps
            self.height = height
            self.airtime = airtime
            self.distance = distance
        }

        init(_ session: SessionSummary, measured: [LiveJumpEstimate]? = nil) {
            let seconds = session.durationSeconds.isFinite ? Int(max(0, min(session.durationSeconds, 28_800))) : 0
            let measured = measured ?? RiderTotals.measuredJumps(in: session, includeRecording: true).filter {
                (ApproachJumpDetector.minimumHeight...100).contains($0.heightMeters ?? 0)
            }
            let qualifying = measured.filter { ($0.heightMeters ?? 0) >= RiderSeasonProgress.minimumScoringHeight }
            let distance = session.gpsMetrics.flatMap { gps in
                gps.accepted >= 5 && (0...500_000).contains(gps.distanceMeters) ? gps.distanceMeters : nil
            }
            self.init(seconds: seconds, scoringJumps: min(qualifying.count, 100),
                      height: measured.compactMap(\.heightMeters).max(),
                      airtime: measured.compactMap(\.reportedAirtime).filter { (0.01...120).contains($0) }.max(),
                      distance: distance)
        }
    }

    func value(_ metrics: Metrics) -> Double? {
        switch rule.category {
        case .water: return Double(metrics.seconds) / 60
        case .route: return metrics.distance
        case .jumps: return Double(metrics.scoringJumps)
        case .height: return metrics.height
        case .air: return metrics.airtime
        }
    }

    func completed(_ metrics: Metrics) -> Bool {
        metrics.seconds >= Self.minimumRideSeconds && (value(metrics) ?? 0) >= rule.target
    }

    static func earned(in history: [SessionSummary]) -> Set<Self> {
        Set(history.compactMap { session in
            guard session.status == .finished, RiderTotals.isRide(session),
                  let mission = session.mission, mission.completed(Metrics(session)) else { return nil }
            return mission
        })
    }
}

struct RiderSessionHighlight {
    let title: String
    let detail: String
    let icon: String

    static func best(for session: SessionSummary, history: [SessionSummary]) -> Self? {
        guard session.status == .finished, RiderTotals.isRide(session) else { return nil }
        let earlier = history.filter { $0.id != session.id && $0.startedAt < session.startedAt &&
                                       $0.status == .finished && RiderTotals.isRide($0) }
        let minutes = RiderMission.Category.water.text(min(session.durationSeconds, Double(Int32.max)) / 60)
        if earlier.isEmpty {
            return .init(title: "Первая каталка в Rider", detail: minutes + " на воде", icon: "hand.wave.fill")
        }
        let previous = RiderTotals(earlier)
        if let best = RiderTotals.measuredJumps(in: session).compactMap(\.heightMeters).max(),
           best > (previous.height ?? 0) {
            let value = RiderMission.Category.height.text(best)
            return .init(title: previous.height == nil ? "Первый замеренный прыжок" : "Личный рекорд высоты",
                         detail: value, icon: "arrow.up.right")
        }
        if let milestone = [10, 25, 50, 100].last(where: { hours in
            let threshold = Double(hours * 3600)
            return previous.seconds < threshold && previous.seconds + session.durationSeconds >= threshold
        }) {
            return .init(title: "Уже \(milestone) ч на воде", detail: "За все каталки", icon: "hourglass")
        }
        if let setup = session.setup, !setup.spot.isEmpty,
           !earlier.contains(where: { old in
               guard let other = old.setup else { return false }
               if let a = setup.spotID, let b = other.spotID { return a == b }
               return setup.spot.localizedCaseInsensitiveCompare(other.spot) == .orderedSame
           }) {
            return .init(title: "Первая каталка на этом споте", detail: minutes + " на воде", icon: "mappin.circle.fill")
        }
        let inMonth = earlier.filter {
            Calendar.current.isDate($0.startedAt, equalTo: session.startedAt, toGranularity: .month)
        }
        if let longest = inMonth.map(\.durationSeconds).max(), session.durationSeconds > longest {
            return .init(title: "Самая длинная каталка месяца", detail: minutes + " на воде", icon: "clock.fill")
        }
        return .init(title: "Ещё одна каталка в копилку", detail: minutes + " на воде", icon: "water.waves")
    }
}

struct RiderSeasonProgress {
    static let minimumScoringHeight = 2.0

    struct Ride: Encodable, Equatable, Identifiable {
        let id: UUID
        let startedAt: TimeInterval
        let seconds: Int
        let jumps: Int
        let scoringJumps: Int
        let height: Double?
        let airtime: Double?
        let mission: RiderMission?
        let missionDistance: Double?

        var missionPoints: Int {
            guard let mission else { return 0 }
            let metrics = RiderMission.Metrics(seconds: seconds, scoringJumps: scoringJumps, height: height,
                                               airtime: airtime, distance: missionDistance)
            return mission.completed(metrics) ? mission.rule.points : 0
        }
    }

    let year: Int
    let rides: [Ride]

    let followers: Int

    private var seconds: Int { rides.reduce(0) { $0 + $1.seconds } }
    private var jumps: Int { rides.reduce(0) { $0 + $1.jumps } }
    var achievements: [RiderAchievement] {
        RiderAchievement.milestones(sessions: rides.count, seconds: Double(seconds), jumps: jumps,
                                    height: rides.compactMap(\.height).max(), airtime: rides.compactMap(\.airtime).max(),
                                    followers: followers)
    }
    var achievementPoints: Int { achievements.filter(\.unlocked).reduce(0) { $0 + $1.seasonBonus } }
    var points: Int {
        let qualifying = rides.reduce(0) { $0 + $1.scoringJumps }
        return seconds / 60 + qualifying * 5 + achievementPoints + rides.reduce(0) { $0 + $1.missionPoints }
    }
    var rank: RiderRank { .forPoints(points) }
    var fraction: Double {
        guard let next = rank.next else { return 1 }
        return Double(points - rank.threshold) / Double(next.threshold - rank.threshold)
    }

    init(_ history: [SessionSummary], at now: Date, followers: Int = 0) {
        self.followers = followers
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        let season = calendar.dateInterval(of: .year, for: now)
        year = calendar.component(.year, from: now)
        var seen = Set<UUID>()
        rides = history.compactMap { session in
            guard let season, session.startedAt >= season.start, session.startedAt < season.end,
                  session.startedAt <= now, session.status == .finished, RiderTotals.isRide(session),
                  seen.insert(session.id).inserted else { return nil }
            let measured = RiderTotals.measuredJumps(in: session).filter {
                (ApproachJumpDetector.minimumHeight...100).contains($0.heightMeters ?? 0)
            }
            let metrics = RiderMission.Metrics(session, measured: measured)
            return Ride(id: session.id, startedAt: session.startedAt.timeIntervalSince1970,
                        seconds: metrics.seconds, jumps: min(measured.count, 100),
                        scoringJumps: metrics.scoringJumps, height: metrics.height, airtime: metrics.airtime,
                        mission: session.mission, missionDistance: session.mission?.rule.category == .route ? metrics.distance : nil)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

enum RiderTopPeriod: String, CaseIterable, Identifiable {
    case all, today, yesterday, week, month

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "За всё время"
        case .today: return "Сегодня"
        case .yesterday: return "Вчера"
        case .week: return "Эта неделя"
        case .month: return "Этот месяц"
        }
    }

    func interval(at now: Date, timeZone: TimeZone = .current) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        switch self {
        case .all: return nil
        case .today: return calendar.dateInterval(of: .day, for: now)
        case .yesterday:
            guard let earlier = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: earlier)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: return calendar.dateInterval(of: .month, for: now)
        }
    }
}

enum RiderTopMetric: String, CaseIterable, Identifiable {
    case height, airtime, distance, rank

    var id: Self { self }
    var title: String {
        switch self {
        case .height: return "Высота (м)"
        case .airtime: return "Время полёта (с)"
        case .distance: return "Дистанция в полёте (м)"
        case .rank: return "Ранг"
        }
    }
    var unit: String {
        switch self {
        case .rank: return "ПТС"
        case .airtime: return "с"
        case .height, .distance: return "м"
        }
    }

    func value(height: Double?, airtime: Double?, distance: Double?) -> Double? {
        switch self {
        case .height: return height
        case .airtime: return airtime
        case .distance: return distance
        case .rank: return nil
        }
    }
}

struct RiderJumpScore: Codable, Equatable {
    let id: UUID
    let spotID: UUID?
    let spot: String?
    let startedAt: TimeInterval
    let height: Double
    let airtime: Double?
    let distance: Double?
    let kite: String?
    let board: String?

    func value(for metric: RiderTopMetric) -> Double? {
        metric.value(height: height, airtime: airtime, distance: distance)
    }

    static func records(in history: [SessionSummary]) -> [Self] {
        history.compactMap { session in
            let jumps = RiderTotals.measuredJumps(in: session)
            guard let height = jumps.compactMap(\.heightMeters).max() else { return nil }
            let airtime = jumps.compactMap(\.reportedAirtime).filter { $0.isFinite && $0 > 0 }.max()
            let distance = jumps.compactMap(\.distanceMeters).filter { $0.isFinite && $0 > 0 }.max()
            let setup = session.setup?.cleaned
            let name = setup?.spot
            let kite = setup?.kiteTitle
            let board = setup?.boardTitle
            return Self(id: session.id, spotID: setup?.spotID,
                        spot: name?.isEmpty == false ? name : nil,
                        startedAt: session.startedAt.timeIntervalSince1970,
                        height: height, airtime: airtime, distance: distance,
                        kite: kite?.isEmpty == false ? kite : nil,
                        board: board?.isEmpty == false ? board : nil)
        }
    }

    static func best(for metric: RiderTopMetric, in records: [Self]) -> Self? {
        records.filter { $0.value(for: metric) != nil }.min { lhs, rhs in
            let left = lhs.value(for: metric) ?? 0
            let right = rhs.value(for: metric) ?? 0
            if left != right { return left > right }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct RiderAchievement: Identifiable {
    let id: String
    let title: String
    let icon: String
    let goal: String
    let value: Double
    let target: Double

    var unlocked: Bool { value >= target }
    var progress: Double { min(1, max(0, value / target)) }

    var seasonBonus: Int {
        switch id {
        case "first-session", "first-follower": return 20
        case "three-seconds", "ten-followers": return 40
        case "five-meters": return 60
        case "ten-hours", "fifty-jumps": return 80
        case "ten-meters", "fifty-followers": return 120
        case "fifty-hours": return 200
        default: return 0
        }
    }

    static func milestones(_ totals: RiderTotals, followers: Int = 0) -> [Self] {
        milestones(sessions: totals.sessions, seconds: totals.seconds, jumps: totals.jumps,
                   height: totals.height, airtime: totals.airtime, followers: followers)
    }

    fileprivate static func milestones(sessions: Int, seconds: Double, jumps: Int, height: Double?,
                                       airtime: Double?, followers: Int) -> [Self] {
        let hours = seconds / 3600
        return [
            Self(id: "first-session", title: "Первый галс", icon: "wind", goal: "1 каталка", value: Double(sessions), target: 1),
            Self(id: "ten-hours", title: "Гидрик прижился", icon: "water.waves", goal: "10 часов на воде", value: hours, target: 10),
            Self(id: "fifty-hours", title: "Прописка на споте", icon: "clock.fill", goal: "50 часов на воде", value: hours, target: 50),
            Self(id: "five-meters", title: "Заглянул в окна второго этажа", icon: "arrow.up.right", goal: "Прыжок от 5 м", value: height ?? 0, target: 5),
            Self(id: "ten-meters", title: "Там, где крыши", icon: "arrow.up.to.line", goal: "Прыжок от 10 м", value: height ?? 0, target: 10),
            Self(id: "three-seconds", title: "Забыл приземлиться", icon: "timer", goal: "Зависание от 3 с", value: airtime ?? 0, target: 3),
            Self(id: "fifty-jumps", title: "Земля, приём", icon: "bolt.fill", goal: "50 прыжков с высотой", value: Double(jumps), target: 50),
            Self(id: "first-follower", title: "Первый зритель", icon: "person.badge.plus", goal: "1 подписчик", value: Double(followers), target: 1),
            Self(id: "ten-followers", title: "Фан-клуб на берегу", icon: "person.2.fill", goal: "10 подписчиков", value: Double(followers), target: 10),
            Self(id: "fifty-followers", title: "Весь спот смотрит", icon: "person.3.fill", goal: "50 подписчиков", value: Double(followers), target: 50)
        ]
    }
}

enum SessionSport: String, Codable, CaseIterable {
    case unclassified, kite, snowkite, kitefoil, wing, windsurf, groundTest
    var title: String {
        switch self {
        case .unclassified: return "Не указан"
        case .kite: return "Кайтсёрфинг"
        case .snowkite: return "Сноукайтинг"
        case .kitefoil: return "Кайтфойл"
        case .wing: return "Вингфойл"
        case .windsurf: return "Виндсёрфинг"
        case .groundTest: return "Тест на земле"
        }
    }
    var isRiding: Bool { self != .unclassified && self != .groundTest }
    var usesKite: Bool { self == .kite || self == .snowkite || self == .kitefoil }
    var supportsKiteStyle: Bool { self == .kite || self == .snowkite }
}

enum KiteStyle: String, Codable, CaseIterable {
    case bigAir, wakestyle

    var title: String { self == .bigAir ? "Биг-эйр" : "Вейкстайл" }
}

enum RecordingMode: String, CaseIterable, Codable {
    case test, battle

    var title: String {
        switch self {
        case .test: return "Тест режим"
        case .battle: return "Боевой режим"
        }
    }
}

enum PhonePlacement: String, Codable, CaseIterable {
    case unspecified, chest, waist, pocket, board, hand, other
    var title: String {
        switch self {
        case .unspecified: return "Не указано"
        case .chest: return "На груди"
        case .waist: return "На поясе"
        case .pocket: return "В кармане"
        case .board: return "На доске"
        case .hand: return "В руке"
        case .other: return "Другое"
        }
    }
}

struct SessionSetup: Codable {
    var sport: SessionSport = .unclassified
    var spot = ""
    var kite = ""
    var board = ""
    var placement: PhonePlacement = .unspecified
    var kiteStyle: KiteStyle?
    var spotID: UUID?
    var kiteAreaSquareMeters: Double?
    var boardDetails: BoardSelection?

    var kiteTitle: String {
        guard !kite.isEmpty, let area = kiteAreaSquareMeters else { return kite }
        return "\(kite) · \(Self.kiteAreaTitle(area))"
    }

    var boardTitle: String { boardDetails?.title ?? board }

    static let kiteAreas = (6...34).map { Double($0) / 2 }

    static func kiteAreaTitle(_ area: Double) -> String {
        "\(area.formatted(.number.precision(.fractionLength(0...1)))) м²"
    }

    mutating func selectKite(_ name: String, area: Double?) {
        kite = name
        kiteAreaSquareMeters = area
    }

    mutating func selectBoard(_ selection: BoardSelection) {
        board = selection.title
        boardDetails = selection
    }

    mutating func clearEquipment() {
        selectKite("", area: nil)
        board = ""
        boardDetails = nil
    }

    mutating func selectSpot(_ selected: RiderSpot) {
        spot = selected.name
        spotID = selected.id
    }

    mutating func setSpotName(_ name: String) {
        if spot != name { spotID = nil }
        spot = name
    }

    var forRecording: Self {
        var next = self
        next.sport = .kite
        next.kiteStyle = .bigAir
        next.placement = .chest
        return next.cleaned
    }

    var activityTitle: String {
        guard sport.supportsKiteStyle, let kiteStyle else { return sport.title }
        return "\(sport.title) · \(kiteStyle.title)"
    }
    var cleaned: Self {
        var copy = self
        copy.spot = String(spot.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        copy.kite = String(kite.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        copy.board = String(board.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if copy.kite.isEmpty || sport == .wing || sport == .windsurf ||
            !Self.kiteAreas.contains(kiteAreaSquareMeters ?? 0) { copy.kiteAreaSquareMeters = nil }
        if !sport.supportsKiteStyle { copy.kiteStyle = nil }
        return copy
    }
}

struct GearPreset: Codable, Identifiable {
    let id: UUID
    let name: String
    private let kite: String
    private let kiteArea: Double?
    private let board: String
    private let boardDetails: BoardSelection?

    static func canSave(_ setup: SessionSetup) -> Bool {
        !setup.cleaned.kite.isEmpty && !setup.cleaned.boardTitle.isEmpty
    }

    init?(name: String, setup: SessionSetup) {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        let setup = setup.forRecording
        guard !title.isEmpty, Self.canSave(setup) else { return nil }
        id = UUID()
        self.name = title
        kite = setup.kite
        kiteArea = setup.kiteAreaSquareMeters
        board = setup.board
        boardDetails = setup.boardDetails
    }

    var subtitle: String {
        let setup = applying(to: SessionSetup())
        return "\(setup.kiteTitle) / \(setup.boardTitle)"
    }

    func applying(to setup: SessionSetup) -> SessionSetup {
        var next = setup
        next.selectKite(kite, area: kiteArea)
        next.board = board
        next.boardDetails = boardDetails
        return next
    }

    func matches(_ setup: SessionSetup) -> Bool {
        let setup = setup.cleaned
        return kite.caseInsensitiveCompare(setup.kite) == .orderedSame && kiteArea == setup.kiteAreaSquareMeters &&
            (boardDetails?.title ?? board).caseInsensitiveCompare(setup.boardTitle) == .orderedSame
    }
}

struct BoardSelection: Codable, Hashable {
    let brand: String
    let model: String
    let size: String?

    init?(brand: String, model: String, size: String? = nil) {
        self.brand = String(brand.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        self.model = String(model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let dimensions = size?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.size = dimensions.isEmpty ? nil : String(dimensions.prefix(40))
        guard !self.brand.isEmpty || !self.model.isEmpty else { return nil }
    }

    var title: String {
        let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        return [name, size].compactMap { $0 }.joined(separator: " · ")
    }
}

struct RiderSpot: Codable, Identifiable, Hashable {
    struct AccessPoint: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        var latitude: Double
        var longitude: Double
        var notes: String?
    }
    var accessPoints: [AccessPoint]?
    let id: UUID
    var name: String
    let latitude: Double
    let longitude: Double
    let notes: String?
    let windyLink: URL?
    var region: String?
    var locality: String?
    var areaOnly: Bool?
    var source: URL?
    var mapLink: URL?
    var waterBearing: Int?

    init?(id: UUID = UUID(), name: String, latitude: String, longitude: String, notes: String = "", windyLink: String = "", mapLink: URL? = nil) {
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        func coordinate(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        guard !cleaned.isEmpty, let lat = coordinate(latitude), let lon = coordinate(longitude),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        self.id = id
        self.name = cleaned
        self.latitude = lat
        self.longitude = lon
        self.notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        let link = URL(string: windyLink.trimmingCharacters(in: .whitespacesAndNewlines))
        self.windyLink = link?.scheme == "https" && link?.host == "windy.app" ? link : nil
        self.mapLink = mapLink
    }

    func matches(_ setup: SessionSetup?) -> Bool {
        guard let setup else { return false }
        if let id = setup.spotID { return includes(id) }
        return matchesName(setup.spot)
    }

    func includes(_ other: UUID) -> Bool {
        id == other || accessPoints?.contains { $0.id == other } == true
    }

    func matchesName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([name] + (accessPoints ?? []).map(\.name)).contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var yandexURL: URL? {
        if let mapLink, mapLink.scheme == "https", mapLink.host == "yandex.ru",
           mapLink.path == "/maps" || mapLink.path.hasPrefix("/maps/") {
            return mapLink
        }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "yandex.ru"
        url.path = "/maps/"
        url.queryItems = [URLQueryItem(name: "ll", value: "\(longitude),\(latitude)"),
                          URLQueryItem(name: "text", value: "\(latitude), \(longitude)"),
                          URLQueryItem(name: "z", value: "15")]
        return url.url
    }

    var routeAppURL: URL? {
        var url = URLComponents()
        url.scheme = "yandexmaps"
        url.host = "build_route_on_map"
        url.path = "/"
        url.queryItems = [URLQueryItem(name: "lat_to", value: String(latitude)),
                          URLQueryItem(name: "lon_to", value: String(longitude))]
        return url.url
    }

    var routeWebURL: URL? {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "yandex.ru"
        url.path = "/maps/"
        url.queryItems = [URLQueryItem(name: "mode", value: "routes"),
                          URLQueryItem(name: "rtext", value: "~\(latitude),\(longitude)"),
                          URLQueryItem(name: "rtt", value: "auto")]
        return url.url
    }
}

enum SpotRoadTravel {
    static func durationLabel(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, (0...604800).contains(seconds) else { return nil }
        if seconds < 60 { return "1 мин" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes) мин" }
        if remainder == 0 { return "\(hours) ч" }
        return "\(hours) ч \(remainder) мин"
    }
}

enum StarterSpots {
    static let infoKey = "RiderStarterSpots"

    private struct Entry: Decodable {
        let accessPoints: [RiderSpot.AccessPoint]?
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double
        let notes: String?
        let mapLink: String?
        let region: String?
        let locality: String?
        let areaOnly: Bool?
        let source: String?
    }

    static func load(from bundle: Bundle = .main) -> [RiderSpot] {
        guard let list = bundle.object(forInfoDictionaryKey: infoKey) else { return [] }
        return decode(list)
    }

    static func decode(_ list: Any) -> [RiderSpot] {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0),
              let entries = try? PropertyListDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            var spot = RiderSpot(id: entry.id, name: entry.name, latitude: String(entry.latitude), longitude: String(entry.longitude),
                      notes: entry.notes ?? "", mapLink: entry.mapLink.flatMap { URL(string: $0) })
            spot?.accessPoints = entry.accessPoints
            spot?.region = entry.region
            spot?.locality = entry.locality
            spot?.areaOnly = entry.areaOnly
            spot?.source = entry.source.flatMap { URL(string: $0) }
            return spot
        }
    }

    static func merge(saved: [RiderSpot], catalogue: [RiderSpot]) -> [RiderSpot] {
        let byID = Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = catalogue.filter { $0.accessPoints != nil }
        let retained = saved.filter { old in !groups.contains { $0.id != old.id && $0.includes(old.id) } }
        var result = retained.map { old in
            var spot = old
            if let entry = byID[old.id] {
                spot.region = entry.region
                spot.locality = entry.locality
                spot.areaOnly = entry.areaOnly
                spot.source = entry.source
            }
            return spot
        }
        for entry in catalogue where !result.contains(where: { spot in
            if entry.accessPoints != nil { return spot.id == entry.id }
            return spot.id == entry.id || spot.name.caseInsensitiveCompare(entry.name) == .orderedSame ||
                (abs(spot.latitude - entry.latitude) < 0.0001 && abs(spot.longitude - entry.longitude) < 0.0001)
        }) {
            result.append(entry)
        }
        for entry in groups {
            guard let i = result.firstIndex(where: { $0.id == entry.id }) else { continue }
            if result[i].accessPoints == nil { result[i].name = entry.name }
            let prior = result[i].accessPoints ?? []
            result[i].accessPoints = entry.accessPoints?.map { point in
                var p = prior.first(where: { $0.id == point.id }) ?? point
                if let savedPoint = saved.first(where: { $0.id == point.id && $0.accessPoints == nil }) {
                    p.latitude = savedPoint.latitude
                    p.longitude = savedPoint.longitude
                    p.notes = savedPoint.notes
                }
                return p
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct SpotForecast: Decodable {
    let timezone: String
    private let hourly: Hourly

    struct Hour: Identifiable {
        let time: Date
        let speed: Double
        let gust: Double?
        let direction: Double?
        let temperature: Double?
        var weatherCode: Int?
        var daylight: Bool?
        var id: Date { time }

        var condition: (name: String, icon: String) {
            switch weatherCode {
            case 0: return daylight == false ? ("Ясно", "moon.stars") : ("Солнечно", "sun.max")
            case 1, 2: return ("Переменная облачность", daylight == false ? "cloud.moon" : "cloud.sun")
            case 3: return ("Пасмурно", "cloud")
            case 45, 48: return ("Туман", "cloud.fog")
            case 51, 53, 55: return ("Морось", "cloud.drizzle")
            case 56, 57, 66, 67: return ("Ледяные осадки", "cloud.sleet")
            case 61, 63, 65: return ("Дождь", "cloud.rain")
            case 80, 81, 82: return ("Ливень", "cloud.heavyrain")
            case 71, 73, 75, 77, 85, 86: return ("Снег", "cloud.snow")
            case 95, 96, 99: return ("Гроза", "cloud.bolt.rain")
            default: return ("Нет данных", "questionmark.circle")
            }
        }

    }

    private struct Hourly: Decodable {
        let time: [Double]
        let speed: [Double?]
        let gust: [Double?]?
        let direction: [Double?]?
        let temperature: [Double?]?
        let weatherCode: [Int?]?
        let isDay: [Int?]?

        enum CodingKeys: String, CodingKey {
            case time
            case speed = "wind_speed_10m"
            case gust = "wind_gusts_10m"
            case direction = "wind_direction_10m"
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    static func requestURL(for spot: RiderSpot) -> URL? {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.open-meteo.com"
        url.path = "/v1/forecast"
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(spot.latitude)),
            URLQueryItem(name: "longitude", value: String(spot.longitude)),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m,temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "wind_speed_unit", value: "kn"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return url.url
    }

    func hours(near now: Date) -> [Hour] {
        allHours.filter { $0.time.timeIntervalSince(now) > -3600 }
    }

    private var allHours: [Hour] {
        func value(_ items: [Double?], at i: Int) -> Double? {
            guard items.indices.contains(i), let number = items[i], number.isFinite, number >= 0 else { return nil }
            return number
        }
        return hourly.time.enumerated().compactMap { index, timestamp in
            guard timestamp.isFinite, let speed = value(hourly.speed, at: index) else { return nil }
            let time = Date(timeIntervalSince1970: timestamp)
            let temperatures = hourly.temperature ?? []
            let temperature = temperatures.indices.contains(index) ? temperatures[index] : nil
            return Hour(time: time, speed: speed, gust: value(hourly.gust ?? [], at: index),
                        direction: value(hourly.direction ?? [], at: index), temperature: temperature,
                        weatherCode: hourly.weatherCode.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                        daylight: hourly.isDay.flatMap { $0.indices.contains(index) ? $0[index] : nil }.map { $0 == 1 })
        }.sorted { $0.time < $1.time }
    }

    static func windArrow(_ direction: Double?) -> String {
        guard let direction, direction.isFinite, (0...360).contains(direction) else { return "—" }
        return ["↓","↙","←","↖","↑","↗","→","↘"][Int((direction / 45).rounded()) % 8]
    }

    static func shoreWind(from direction: Double?, waterBearing: Int?) -> String? {
        guard let direction, (0...360).contains(direction),
              let waterBearing, (0..<360).contains(waterBearing) else { return nil }
        // A wind direction is where it blows from. Wind from the open-water side blows toward shore.
        let difference = abs(direction - Double(waterBearing))
        let angle = min(difference, 360 - difference)
        switch angle {
        case ..<67.5: return "К берегу"
        case ...112.5: return "Вдоль берега"
        default: return "От берега"
        }
    }

    enum WindLevel: Equatable {
        case calm, light, medium, strong

        static func average(_ speed: Double) -> Self {
            switch speed {
            case ..<4: return .calm
            case ..<8: return .light
            case ..<10: return .medium
            default: return .strong
            }
        }

        static func gust(_ speed: Double) -> Self {
            if speed > 13 { return .strong }
            return speed >= 9 ? .medium : .light
        }

        var description: String {
            switch self {
            case .calm: return "Штиль"
            case .light: return "Обнаружен лайтвинд"
            case .medium: return "Обнаружен средний ветер"
            case .strong: return "Обнаружен сильный ветер"
            }
        }
    }

    struct SearchRadius: Equatable {
        let kilometers: Double

        init?(text: String) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized) else { return nil }
            self.init(kilometers: value)
        }

        init?(kilometers: Double) {
            guard kilometers.isFinite, kilometers > 0 else { return nil }
            self.kilometers = kilometers
        }

        func contains(distanceMeters: Double) -> Bool {
            distanceMeters >= 0 && distanceMeters.isFinite && distanceMeters / 1000 <= kilometers
        }
    }

    enum RankingDay: Int {
        case today = 0
        case tomorrow = 1

        var title: String {
            self == .today ? "Лучший спот на сегодня" : "Лучший спот на завтра"
        }

        func visibleWindows(at date: Date, calendar: Calendar = .current) -> [Window] {
            if self == .tomorrow { return Window.allCases }
            let hour = calendar.component(.hour, from: date)
            return Window.allCases.filter { hour < $0.endHour }
        }

        static func forEveningSwitch(at date: Date, calendar: Calendar = .current) -> Self {
            calendar.component(.hour, from: date) >= 20 ? .tomorrow : .today
        }
    }

    enum Window: Int, CaseIterable, Identifiable {
        case morning = 7
        case lateMorning = 10
        case afternoon = 13
        case evening = 16

        var id: Int { rawValue }
        var endHour: Int { self == .evening ? 20 : rawValue + 3 }
        var title: String { String(format: "%02d:00–%02d:00", rawValue, endHour) }

        // Divide the hourly readings without repeating boundary hours. Include the final 20:00 reading.
        var forecastHours: Range<Int> { rawValue..<(self == .evening ? endHour + 1 : endHour) }
    }

    struct WindowSummary {
        let meanWind: Double
        let maxGust: Double?
        let meanTemperature: Double?
        let thunder: Bool
        let hours: Int

        var windLevel: WindLevel { .average(meanWind) }
        var gustLevel: WindLevel? { maxGust.map(WindLevel.gust) }

        fileprivate init?(_ hours: [Hour]) {
            guard !hours.isEmpty else { return nil }
            let scale = SessionWind.metersPerSecondPerKnot
            let temperatures = hours.compactMap(\.temperature)
            meanWind = hours.reduce(0) { $0 + $1.speed } * scale / Double(hours.count)
            maxGust = hours.compactMap(\.gust).max().map { $0 * scale }
            meanTemperature = temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count)
            thunder = hours.contains { [95, 96, 99].contains($0.weatherCode ?? -1) }
            self.hours = hours.count
        }
    }

    struct RankedSpot: Identifiable {
        let spot: RiderSpot
        let weather: WindowSummary
        var id: UUID { spot.id }
    }

    struct Ranking: Identifiable {
        let window: Window
        let spots: [RankedSpot]
        var id: Window { window }
    }

    func windowSummaries(for day: RankingDay = .today, relativeTo now: Date) -> [Window: WindowSummary] {
        guard let zone = TimeZone(identifier: timezone) else { return [:] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let target = calendar.date(byAdding: .day, value: day.rawValue, to: now) else { return [:] }
        let readings = allHours.filter { calendar.isDate($0.time, inSameDayAs: target) }
        let byHour = Dictionary(grouping: readings) { calendar.component(.hour, from: $0.time) }
        var summaries: [Window: WindowSummary] = [:]
        for window in Window.allCases {
            summaries[window] = WindowSummary(window.forecastHours.flatMap { byHour[$0] ?? [] })
        }
        return summaries
    }

    struct FavoriteWindow {
        let spot: RiderSpot
        let start: Date
        let end: Date
        let timezone: TimeZone
        let weather: WindowSummary

        func dayTitle(relativeTo now: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timezone
            return calendar.isDate(start, inSameDayAs: now) ? "Сегодня" : "Завтра"
        }
    }

    static func nearestWindWindow(after now: Date, forecasts: [(RiderSpot, SpotForecast)]) -> FavoriteWindow? {
        forecasts.compactMap { spot, forecast in
            forecast.nextWindWindow(for: spot, after: now)
        }.min {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.weather.meanWind != $1.weather.meanWind { return $0.weather.meanWind > $1.weather.meanWind }
            if $0.weather.hours != $1.weather.hours { return $0.weather.hours > $1.weather.hours }
            return $0.spot.name < $1.spot.name
        }
    }

    private func nextWindWindow(for spot: RiderSpot, after now: Date) -> FavoriteWindow? {
        guard let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        let remaining = hours(near: now)
        for day in [now, tomorrow] {
            let dayHours = remaining.filter { calendar.isDate($0.time, inSameDayAs: day) }
            for window in Window.allCases {
                guard let end = calendar.date(bySettingHour: window.endHour, minute: 0, second: 0, of: day), end > now else { continue }
                let readings = dayHours.filter { window.forecastHours.contains(calendar.component(.hour, from: $0.time)) }
                guard let first = readings.first else { continue }
                let start = max(now, first.time)
                guard end.timeIntervalSince(start) >= 3600,
                      let weather = WindowSummary(readings), weather.windLevel != .calm else { continue }
                return FavoriteWindow(spot: spot, start: start, end: end, timezone: zone, weather: weather)
            }
        }
        return nil
    }

    static func rankings(for day: RankingDay = .today, relativeTo now: Date,
                         forecasts: [(RiderSpot, SpotForecast)]) -> [Ranking] {
        var byWindow: [Window: [RankedSpot]] = [:]
        for (spot, forecast) in forecasts {
            for (window, summary) in forecast.windowSummaries(for: day, relativeTo: now) {
                byWindow[window, default: []].append(RankedSpot(spot: spot, weather: summary))
            }
        }
        return Window.allCases.map { window in
            let sorted = (byWindow[window] ?? []).sorted {
                if $0.weather.meanWind != $1.weather.meanWind { return $0.weather.meanWind > $1.weather.meanWind }
                if $0.weather.hours != $1.weather.hours { return $0.weather.hours > $1.weather.hours }
                if $0.spot.name != $1.spot.name { return $0.spot.name < $1.spot.name }
                return $0.id.uuidString < $1.id.uuidString
            }
            return Ranking(window: window, spots: Array(sorted.prefix(5)))
        }
    }

    static func compass(_ direction: Double?) -> String {
        guard let direction, direction.isFinite, (0...360).contains(direction) else { return "—" }
        let points = ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
        return points[Int((direction / 45).rounded()) % points.count]
    }
}

enum KiteCatalog {
    struct Brand: Identifiable {
        let name: String
        let models: [String]
        let alias: String
        var id: String { name }

        init(_ name: String, _ models: [String], alias: String = "") {
            self.name = name
            self.models = models.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            self.alias = alias
        }

        func matches(_ query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || name.localizedStandardContains(query) || alias.localizedStandardContains(query)
        }
    }

    // Current and recent named models with a manual entry for other releases.
    static let brands = [
        Brand("Airush", ["Lift V3", "Lift V4", "Lift Team V4", "Lithium V13", "Lithium V14", "Lithium Team V13", "Lithium Team V14", "Razor V11", "Ultra V5", "Ultra Team DS V5"]),
        Brand("Cabrinha", ["2027 Drifter", "Drifter Apex", "Moto Apex", "Moto X Apex", "Moto X Lite", "Moto XL Apex", "Nitro Apex", "Switchblade Apex", "Switchblade Design Works"], alias: "Кабрина Кэбринья Кабринья"),
        Brand("CORE", ["Air", "Air Pro", "Free", "GTS4", "GTS5", "GTS6", "Nexus", "Nexus 2", "Nexus 3", "Nexus 4", "Pace", "Pace Pro", "Section 2", "Section 3", "Section 4", "XLITE", "XR4", "XR5", "XR6", "XR7", "XR8", "XR X", "XR Pro", "XR Pro 2"], alias: "Кор Коре"),
        Brand("CrazyFly", ["Hyper", "Sculp"], alias: "Крейзифлай"),
        Brand("Duotone", ["Dice SLS", "Evo", "Evo Concept Blue", "Evo D/LAB", "Evo SLS", "Juice", "Juice D/LAB", "Mono", "Neo", "Neo Concept Blue", "Neo D/LAB", "Neo SLS", "Rebel D/LAB", "Rebel SLS", "Rebel SLS Concept Blue", "Vegas", "Vegas Concept Blue"], alias: "Дуотон Дюотон"),
        Brand("Eleveight", ["FS V8", "OS V7", "PS V10", "RS V10", "RS+ V4", "RS Pro V2", "Stratos+", "WS V10"], alias: "Элевейт"),
        Brand("Epic Kites", ["Infinity", "Junior Pro", "Renegade", "Screamer", "Screamer 7G", "Surf"]),
        Brand("F-ONE", ["Addikt", "Addikt TEC", "Bandit", "Bandit Brainchild", "Banger QuadX", "Breeze", "Breeze TEC", "Diablo", "Trigger Brainchild", "Trigger TEC", "WTF?!"], alias: "Фон Ф-Уан"),
        Brand("FLYSURFER", ["ERA 2", "HELI", "HYBRID 2", "PEAK 6", "SONIC 5", "SOUL 4", "STOKE 4", "SUPERSONIC", "VMG 3"], alias: "Флайсёрфер Флайсерфер"),
        Brand("GA Kites", ["IQ", "Max", "One", "Pact", "Pure", "Spark"], alias: "Gaastra Гаастра"),
        Brand("GIN Kiteboarding", ["Marabou V2", "Spirit"]),
        Brand("GONG", ["Ayto", "Ayto Aramid", "Display", "Elips", "Strutless", "Strutless Revo", "Unik", "Vertigo", "Vertigo Aramid"], alias: "Гонг"),
        Brand("Harlem", ["Flow", "Hadlow Pro", "Peak", "Thrive", "Thrive LiteX", "Thrive V2"], alias: "Харлем"),
        Brand("Naish", ["Boxer [Q]Series", "Hunt [Q]Series", "Pivot", "Pivot [Q]Series", "Pivot [Q]Series LW", "Pivot LTD", "Pivot NVision", "Psycho [Q]Series", "Psycho NVision", "Torch", "Xeon"], alias: "Нэш Наиш"),
        Brand("North", ["Carve", "Code Zero", "Code Zero Pro", "Orbit", "Orbit Ultra", "Pioneer Trainer", "Pulse", "Reach", "Reach Ultra"], alias: "Норт"),
        Brand("Ozone", ["Alpha V3 Ultra-X", "Catalyst V5", "Chrono", "Edge V12", "Edge VT", "Edge VT Ultra-X", "Enduro", "EXP V2", "Explore V3", "Hyperlink V4", "Ignition V3", "Mach1", "R1 V5", "Reflex", "Reo V7", "Reo V7 Ultra-X", "Subzero V1", "Subzero V2", "Uno V2", "Vortex V2 Ultra-X", "Zephyr V8 Ultra-X"], alias: "Озон"),
        Brand("ParAAvis", ["Fancy", "Ion 2", "Ion 4", "JKS", "Octane 2", "Q 2", "Smile 3"], alias: "Параавис ПараАвис"),
        Brand("PLKB", ["Aero V2", "Escape", "Gambit", "Hook V4", "Ibex", "Lynx", "Nova V2", "Raw", "Swell V5", "Synergy"], alias: "Peter Lynn Питер Линн"),
        Brand("Reedin", ["HyperModel", "MasterModel", "SuperModel A.F.T.", "SuperModel HTF", "WhisperModel"], alias: "Ридин"),
        Brand("RRD", ["Gold Obsession Y30", "Gold Religion Y30", "Obsession Y31", "Passion Y31", "Religion Y32"], alias: "РРД"),
        Brand("Slingshot", ["Code 95", "Code NXT", "Code V2", "Machine V3", "RPX", "UFO V4"], alias: "Слингшот"),
        Brand("Spleene", ["BIG", "HAZE", "PUNK"], alias: "Сплин"),
        Brand("Takoon", ["Furia V2", "Furia V3", "One Light V2", "Wook V2"], alias: "Такун"),
        Brand("Ventum", ["Mute", "Xcite V3", "Xplore V3"])
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

enum BoardCatalog {
    struct Model: Identifiable {
        let name: String
        let sizes: [String]
        var id: String { name }

        init(_ name: String, _ sizes: [String], unit: String = "см") {
            self.name = name
            self.sizes = sizes.map { $0.replacingOccurrences(of: ".", with: ",") + " " + unit }
        }
    }

    struct Brand: Identifiable {
        let name: String
        let models: [Model]
        let alias: String
        var id: String { name }

        init(_ name: String, _ alias: String, _ models: [Model]) {
            self.name = name
            self.alias = alias
            self.models = models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        func matches(_ query: String) -> Bool {
            query.isEmpty || name.localizedStandardContains(query) || alias.localizedStandardContains(query)
        }
    }

    private static let jaime = ["133 × 40", "136 × 41", "139 × 42", "142 × 43"]
    private static let teamSeries = ["136 × 40", "140 × 41.5", "144 × 43"]
    private static let select = ["135 × 39", "138 × 40", "141 × 41", "144 × 42"]
    private static let atmos = ["136 × 40", "138 × 41", "141 × 42", "144 × 43"]
    private static let trax = ["135 × 39", "136 × 40.5", "137 × 42", "139 × 43", "140 × 45"]

    static let brands = [
        Brand("Desperado", "Десперадо", [
            Model("BigGun", ["150 × 50"]), Model("Heartbeat Carbon Pro", []), Model("HeXed Carbon", []), Model("Shotgun", ["133 × 39", "136 × 40", "140 × 41.5", "144 × 43"])
        ]),
        Brand("Molokov Craft Boards", "Молоков", [Model("Splash", ["135 × 41"])]),
        Brand("MDAY", "МД Мдэй Мдей M-Day MD", [Model("Play (2025)", ["133", "136", "139", "142"]), Model("Chillian (2025)", [])]),
        Brand("Ozone", "Озон", [
            Model("Code V5", ["130 × 38", "133 × 39", "135 × 40", "138 × 41", "141 × 42", "144 × 43"]),
            Model("Torque V4", ["136 × 40", "138 × 41", "140 × 42", "142 × 43", "144 × 44"])
        ]),
        Brand("Naish", "Нэш Найш", ["Alana", "Alana NVision", "Drive", "Monarch", "Monarch NVision", "Motion", "Motion NVision", "RPT", "Traverse EJ Pro"].map { Model($0, []) }),
        Brand("FLYSURFER", "Флайсерфер", [Model("Radical 8", ["132 × 40", "138 × 42.5", "144 × 44.5"])]),
        Brand("Lieuwe", "Льюве", [Model("Shotgun", ["125 × 38", "130 × 39", "133 × 40", "136 × 40.5", "138 × 41", "141 × 42"]), Model("Shotgun Air", ["133 × 40", "136 × 40.5", "138 × 41", "141 × 42", "144 × 43"])]),
        Brand("Brunotti", "Брунотти", [Model("Dimension 79", []), Model("Lvl 79 Uni", [])]),
        Brand("Cabrinha", "Кабрина Кабринья", [
            Model("Ace (2025)", ["120 × 35", "126 × 36.5", "133 × 38.5", "135 × 40", "138 × 41.5", "141 × 43", "145 × 44.5"]),
            Model("Spectrum (2026)", ["136 × 41", "140 × 42", "144 × 43", "148 × 44", "152 × 44"]),
            Model("Xcal (2026)", ["135 × 41", "138 × 42", "141 × 43"])
        ]),
        Brand("CORE", "Кор Коре", [
            Model("Choice 3", ["133 × 40", "135 × 41", "137 × 41.5", "139 × 42", "141 × 42.5", "144 × 43.5", "147 × 45"]),
            Model("Choice 5", ["133 × 40", "135 × 41", "137 × 41.5", "139 × 42", "141 × 42.5", "144 × 43.5"]),
            Model("Era", ["134 × 40", "136 × 40.5", "138 × 41", "142 × 42", "146 × 44", "152 × 48"]),
            Model("Era LW", ["154 × 46", "159 × 47"]),
            Model("Fusion 7", ["133 × 39.5", "135 × 40.5", "137 × 41.5", "139 × 42", "141 × 42.5", "144 × 43.5"])
        ]),
        Brand("Duotone", "Дуотон Дюотон", [
            Model("Jaime", jaime), Model("Jaime SLS", jaime),
            Model("Gambler (2024)", ["151 × 43"]),
            Model("Select Concept Blue (2024)", select), Model("Select SLS (2024)", select),
            Model("Team Series", teamSeries), Model("Team Series SLS", teamSeries),
            Model("Team Series Big Air SLS (2026)", ["136 × 40", "139 × 41"])
        ]),
        Brand("F-ONE", "Фон Ф-Уан", [
            Model("TRAX", ["132 × 37", "133 × 38", "136 × 40.5", "137 × 42"]),
            Model("TRAX Carbon", trax), Model("TRAX Lite Tech", trax),
            Model("WTF?!", ["127 × 37", "130 × 39", "136 × 41.5", "138 × 42", "140 × 42.5"]),
            Model("ONE", ["138 × 40", "140 × 42", "148 × 45", "150 × 48"]),
            Model("BIG ONE", ["160 × 45", "164 × 48"])
        ]),
        Brand("North", "Норт", [
            Model("Atmos (2026)", atmos), Model("Atmos Pro (2026)", atmos), Model("Atmos Ultra (2026)", atmos),
            Model("Prime (2022)", ["133 × 39", "136 × 40", "138 × 41", "141 × 42", "144 × 43", "148 × 44", "152 × 45"]),
            Model("Trace (2025)", ["145 × 45", "155 × 46"])
        ]),
        Brand("Slingshot", "Слингшот", [Model("Misfit V11 Carbon", ["137", "143", "147"])]),
    ]
}

struct RouteMetrics: Codable, Sendable {
    var version = "gps-1"
    var accepted = 0
    var rejected = 0
    var segments = 0
    var distanceMeters = 0.0
    var maxSpeedMetersPerSecond: Double?
}

struct RoutePoint: Identifiable, Sendable {
    let id: Int
    let segment: Int
    let speedSegment: Int
    let sample: LocationSample
    let speed: Double?
}

struct LiveJumpEstimate: Codable {
    let heightMeters: Double?
    let airtimeSeconds: Double
    var distanceMeters: Double?
    var isPhoneToss: Bool?
    var isHandLift: Bool?
    var inertialLift: Bool?
    var assumesLevelLanding: Bool?
    var apexSeconds: Double?
    var pushRiseMeters: Double?
    var estimatedFlightStart: Double?
    var estimatedFlightEnd: Double?
    var distanceFromSpeed: Bool?
    enum DistanceIssue: String, Codable { case insufficientCoverage, lowAccuracy }
    var distanceIssue: DistanceIssue?
    var pressureAssisted: Bool?
    var measuredFlightSeconds: Double?
    var reportedAirtime: Double? {
        if let start = estimatedFlightStart, let end = estimatedFlightEnd, end > start { return end - start }
        return approachExcursion == true ? measuredFlightSeconds : airtimeSeconds
    }
    var approachExcursion: Bool?
    var crossedStartLevel: Bool?
    var floorPeakMeters: Double?
    var floorReferenceMeters: Double?

    static func phoneToss(_ event: JumpCandidate) -> Self? {
        guard event.minimumLoadG.isFinite, (0...0.2).contains(event.minimumLoadG),
              let height = event.approximateTossHeightMeters(label: .phoneToss) else { return nil }
        return Self(heightMeters: height, airtimeSeconds: event.unloadingSeconds, distanceMeters: nil, isPhoneToss: true)
    }

    static func riding(_ flight: RidingJumpDetector.Flight, altitude: [AltitudeSample],
                       gps: [RoutePoint], motionClock: Date?, allowLevelLandingEstimate: Bool = true,
                       motionPeak: VerticalTrajectory.Peak? = nil) -> Self {
        let event = flight.event
        let start = event.startSeconds, end = event.endSeconds
        if let peak = flight.approachPeak {
            // Short arcs can be measured using motion alone. At longer durations
            // independent pressure around the apex must corroborate the integrated rise.
            let before = altitude.filter { (start - 2.8...start).contains($0.elapsedSinceFirstSampleSeconds) }.suffix(2)
            let nearApex = altitude.filter {
                (start...end).contains($0.elapsedSinceFirstSampleSeconds) && abs($0.elapsedSinceFirstSampleSeconds - peak.time) <= 1.1
            }
            let baseline = before.map(\.relativeAltitudeMeters).reduce(0, +) / Double(max(1, before.count))
            let corroborated = before.count == 2 && before.allSatisfy { abs($0.relativeAltitudeMeters - baseline) <= 0.3 } &&
                nearApex.contains { abs($0.relativeAltitudeMeters - baseline - peak.height) <= max(0.5, 0.25 * peak.height) }
            let measured: Double? = flight.pressureAssisted || end - start <= 4.5 || corroborated ? peak.height : nil
            let airtime = flight.flightWindow.map { $0.upperBound - $0.lowerBound } ?? (end - start)
            return Self(heightMeters: measured, airtimeSeconds: airtime,
                        distanceMeters: nil,
                        inertialLift: true, apexSeconds: peak.time, estimatedFlightStart: flight.flightWindow?.lowerBound,
                        estimatedFlightEnd: flight.flightWindow?.upperBound, pressureAssisted: flight.pressureAssisted, approachExcursion: true,
                        crossedStartLevel: flight.crossedStartLevel)
        }
        let corroborated = ridingHeight(flight, altitude: altitude)
        // For long arcs require independent pressure support before accepting drift-prone integration.
        let anchored = motionPeak.flatMap { peak -> VerticalTrajectory.Peak? in
            if let corroborated {
                return abs(peak.height - corroborated) <= max(0.25, 0.25 * corroborated) ? peak : nil
            }
            return end - start <= 2.5 ? peak : nil
        }
        let approximate = anchored == nil && allowLevelLandingEstimate && corroborated == nil &&
            !pressureShowsLevelChange(start: start, end: end, altitude: altitude)
            ? flight.levelLandingHeight : nil
        return Self(heightMeters: anchored?.height ?? corroborated ?? approximate, airtimeSeconds: event.unloadingSeconds,
                    distanceMeters: gpsDistance(start: start, end: end, gps: gps, motionClock: motionClock),
                    inertialLift: anchored == nil ? nil : true, assumesLevelLanding: approximate == nil ? nil : true,
                    apexSeconds: anchored?.time, pushRiseMeters: anchored?.pushRise)
    }

    private static func pressureShowsLevelChange(start: Double, end: Double, altitude: [AltitudeSample]) -> Bool {
        let before = altitude.filter { $0.elapsedSinceFirstSampleSeconds >= start - 2.5
            && $0.elapsedSinceFirstSampleSeconds <= start }.suffix(2)
        let after = altitude.filter { $0.elapsedSinceFirstSampleSeconds >= end + 0.15
            && $0.elapsedSinceFirstSampleSeconds <= end + 3 }.prefix(2)
        guard before.count == 2, after.count == 2, let pre = before.first, let preLast = before.last,
              let post = after.first, let postLast = after.last,
              abs(pre.relativeAltitudeMeters - preLast.relativeAltitudeMeters) <= 0.15,
              abs(post.relativeAltitudeMeters - postLast.relativeAltitudeMeters) <= 0.15 else { return false }
        let beforeHeight = (pre.relativeAltitudeMeters + preLast.relativeAltitudeMeters) * 0.5
        let afterHeight = (post.relativeAltitudeMeters + postLast.relativeAltitudeMeters) * 0.5
        return abs(afterHeight - beforeHeight) > 0.30
    }

    private static func ridingHeight(_ flight: RidingJumpDetector.Flight, altitude: [AltitudeSample]) -> Double? {
        guard !flight.trajectory.isEmpty else { return nil }
        let start = flight.event.startSeconds, end = flight.event.endSeconds
        guard start.isFinite, end.isFinite, end > start,
              flight.settledHeight.isFinite, flight.residualVelocity.isFinite,
              flight.trajectory.allSatisfy({ $0.time.isFinite && $0.height.isFinite }),
              altitude.allSatisfy({ $0.elapsedSinceFirstSampleSeconds.isFinite && $0.relativeAltitudeMeters.isFinite }),
              zip(altitude, altitude.dropFirst()).allSatisfy({ pair in pair.0.elapsedSinceFirstSampleSeconds < pair.1.elapsedSinceFirstSampleSeconds }) else { return nil }
        let before = altitude.filter { (start - 3...start).contains($0.elapsedSinceFirstSampleSeconds) }.suffix(2)
        let after = altitude.filter { (end + 0.15...end + 3).contains($0.elapsedSinceFirstSampleSeconds) }.prefix(2)
        guard before.count == 2, after.count == 2, let beforeLast = before.last, let afterFirst = after.first,
              start - beforeLast.elapsedSinceFirstSampleSeconds <= 1.6,
              afterFirst.elapsedSinceFirstSampleSeconds - end <= 1.6 else { return nil }
        let baseline = before.map(\.relativeAltitudeMeters).reduce(0, +) / 2
        let landed = after.map(\.relativeAltitudeMeters).reduce(0, +) / 2
        guard before.allSatisfy({ abs($0.relativeAltitudeMeters - baseline) <= 0.20 }),
              after.allSatisfy({ abs($0.relativeAltitudeMeters - landed) <= 0.20 }),
              abs(landed - baseline) <= 0.6 else { return nil }

        let peak = flight.trajectory.filter { $0.time <= end }.map(\.height).max() ?? 0
        let drift = flight.settledHeight - (landed - baseline)
        let duration = (flight.trajectory.last?.time ?? end) - start
        guard duration > 0, abs(flight.residualVelocity) <= 1.3,
              abs(drift) <= max(0.45, 0.20 * peak) else { return nil }
        let corrected = flight.trajectory.prefix { $0.time <= end }.map { point in
            RidingJumpDetector.Point(time: point.time, height: point.height - drift * (point.time - start) / duration)
        }
        guard let maximum = corrected.map(\.height).max(), (0.25...35).contains(maximum) else { return nil }
        let inFlight = altitude.filter {
            $0.elapsedSinceFirstSampleSeconds > start + 0.15 && $0.elapsedSinceFirstSampleSeconds < end - 0.15
        }
        guard inFlight.contains(where: { $0.relativeAltitudeMeters - baseline >= max(0.15, maximum * 0.2) }) else { return nil }
        for sample in inFlight {
            guard let point = corrected.min(by: { abs($0.time - sample.elapsedSinceFirstSampleSeconds) < abs($1.time - sample.elapsedSinceFirstSampleSeconds) }),
                  abs(point.height - (sample.relativeAltitudeMeters - baseline)) <= max(0.75, maximum * 0.35) else { return nil }
        }
        return maximum
    }

    static func measure(_ event: JumpCandidate, altitude: [AltitudeSample], gps: [RoutePoint],
                        motionClock: Date?) -> Self? {
        let start = event.startSeconds, end = event.endSeconds
        // Sparse pressure samples can only support a coarse estimate for a
        // well-bracketed peak. A hill or sustained elevation is not a jump.
        let before = altitude.filter { (start - 3...start).contains($0.elapsedSinceFirstSampleSeconds) }.suffix(2)
        let during = altitude.filter { $0.elapsedSinceFirstSampleSeconds > start && $0.elapsedSinceFirstSampleSeconds < end }
        guard before.count == 2, let first = before.first, let last = before.last,
              start - last.elapsedSinceFirstSampleSeconds <= 1.3,
              last.elapsedSinceFirstSampleSeconds - first.elapsedSinceFirstSampleSeconds <= 1.35,
              abs(first.relativeAltitudeMeters - last.relativeAltitudeMeters) <= 0.30,
              during.count >= 2, let peak = during.map(\.relativeAltitudeMeters).max() else { return nil }
        let baseline = (first.relativeAltitudeMeters + last.relativeAltitudeMeters) / 2
        let height = peak - baseline
        guard (0.6...35).contains(height), during.filter({ $0.relativeAltitudeMeters - baseline >= 0.50 }).count >= 2,
              let returned = altitude.first(where: {
                  (end...end + 2.5).contains($0.elapsedSinceFirstSampleSeconds) && abs($0.relativeAltitudeMeters - baseline) <= 0.40
              }) else { return nil }
        let window = altitude.filter { (first.elapsedSinceFirstSampleSeconds...returned.elapsedSinceFirstSampleSeconds).contains($0.elapsedSinceFirstSampleSeconds) }
        guard zip(window, window.dropFirst()).allSatisfy({ pair in
            let interval = pair.1.elapsedSinceFirstSampleSeconds - pair.0.elapsedSinceFirstSampleSeconds
            return interval > 0 && interval <= 1.35
        }) else { return nil }

        return Self(heightMeters: height, airtimeSeconds: event.unloadingSeconds,
                    distanceMeters: gpsDistance(start: start, end: end, gps: gps, motionClock: motionClock))
    }

    /// Integrate horizontal speed between the actual takeoff and return times.
    /// Speeds on both sides must bracket the interval in one continuous GPS segment.
    static func speedDistance(start: Double, end: Double, gps: [RoutePoint], motionClock: Date?) -> Double? {
        guard let motionClock, let fixes = flightFixes(start: start, end: end, gps: gps, motionClock: motionClock) else { return nil }
        let from = motionClock.addingTimeInterval(start)
        var meters = 0.0, uncertainty = 0.0
        for (a, b) in zip(fixes, fixes.dropFirst()) {
            let t0 = a.sample.timestamp.timeIntervalSince(from), t1 = b.sample.timestamp.timeIntervalSince(from)
            let dt = t1 - t0, lo = max(0, t0), hi = min(end - start, t1)
            guard hi > lo, a.speedSegment == b.speedSegment,
                  let v0 = a.speed, let v1 = b.speed, (0...60).contains(v0), (0...60).contains(v1),
                  let e0 = a.sample.speedAccuracyMetersPerSecond, let e1 = b.sample.speedAccuracyMetersPerSecond,
                  (0...3).contains(e0), (0...3).contains(e1) else { return nil }
            let fraction = ((lo + hi) / 2 - t0) / dt
            meters += (v0 + (v1 - v0) * fraction) * (hi - lo)
            // Integrate the error bound too. A fast ride can have a solid signal
            // even when the absolute speed uncertainty exceeds 1.25 m/s.
            uncertainty += max(0.15, e0 + (e1 - e0) * fraction) * (hi - lo)
        }
        return meters >= 1 && uncertainty <= meters * 0.35 ? meters : nil
    }

    private static func flightFixes(start: Double, end: Double, gps: [RoutePoint], motionClock: Date?) -> ArraySlice<RoutePoint>? {
        guard let motionClock, start.isFinite, end.isFinite, end > start else { return nil }
        let from = motionClock.addingTimeInterval(start), to = motionClock.addingTimeInterval(end)
        guard let first = gps.lastIndex(where: { $0.sample.timestamp <= from }),
              let last = gps.firstIndex(where: { $0.sample.timestamp >= to }), first < last else { return nil }
        let fixes = gps[first...last]
        for (a, b) in zip(fixes, fixes.dropFirst()) {
            let dt = b.sample.timestamp.timeIntervalSince(a.sample.timestamp)
            guard dt > 0, dt <= 2.2, a.segment == b.segment else { return nil }
        }
        return fixes
    }

    static func gpsDistance(start: Double, end: Double, gps: [RoutePoint], motionClock: Date?) -> Double? {
        guard let motionClock, let fixes = flightFixes(start: start, end: end, gps: gps, motionClock: motionClock) else { return nil }
        func position(_ time: Double, between a: LocationSample, and b: LocationSample) -> LocationSample {
            let date = motionClock.addingTimeInterval(time)
            let f = date.timeIntervalSince(a.timestamp) / b.timestamp.timeIntervalSince(a.timestamp)
            let delta = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            return LocationSample(timestamp: date, latitude: a.latitude + (b.latitude - a.latitude) * f,
                                  longitude: a.longitude + delta * f,
                                  horizontalAccuracyMeters: (1 - f) * a.horizontalAccuracyMeters + f * b.horizontalAccuracyMeters,
                                  speedMetersPerSecond: nil, speedAccuracyMetersPerSecond: nil)
        }
        let i = fixes.startIndex, j = fixes.endIndex - 1
        let a = position(start, between: fixes[i].sample, and: fixes[i + 1].sample)
        let b = position(end, between: fixes[j - 1].sample, and: fixes[j].sample)
        let separation = RouteFilter.distance(a, b)
        let uncertainty = a.horizontalAccuracyMeters + b.horizontalAccuracyMeters
        return separation >= 1 && uncertainty <= separation * 0.5 ? separation : nil
    }

    static func distanceIssue(start: Double, end: Double, gps: [RoutePoint], motionClock: Date?) -> DistanceIssue {
        flightFixes(start: start, end: end, gps: gps, motionClock: motionClock) == nil ? .insufficientCoverage : .lowAccuracy
    }

    static func spokenHeight(_ height: Double) -> String? {
        guard height.isFinite, (0...100).contains(height) else { return nil }
        let tenths = Int((height * 10).rounded()), whole = tenths / 10, digit = tenths % 10
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .spellOut
        let cardinal = formatter.string(from: NSNumber(value: whole)) ?? String(whole)
        let endsInOne = whole % 10 == 1 && whole % 100 != 11
        if digit == 0 {
            let few = (2...4).contains(whole % 10) && !(12...14).contains(whole % 100)
            return "\(cardinal) \(endsInOne ? "метр" : few ? "метра" : "метров")"
        }
        let feminine = whole % 100 != 11 && whole % 10 == 1 ? "одна" : whole % 100 != 12 && whole % 10 == 2 ? "две" : nil
        let spokenWhole = feminine.map { whole < 10 ? $0 : cardinal.split(separator: " ").dropLast().joined(separator: " ") + " " + $0 } ?? cardinal
        let fractions = ["", "одна десятая", "две десятых", "три десятых", "четыре десятых", "пять десятых", "шесть десятых", "семь десятых", "восемь десятых", "девять десятых"]
        return "\(spokenWhole) \(endsInOne ? "целая" : "целых") \(fractions[digit]) метра"
    }
}

/// Resolve overlapping observations once, after delayed pressure samples arrive.
struct RideJumpQueue {
    private var flights: [(flight: RidingJumpDetector.Flight, gpsApproach: Bool)] = []
    private var lastEnd = -Double.infinity

    mutating func add(_ flight: RidingJumpDetector.Flight, gpsApproach: Bool) {
        guard flight.event.startSeconds >= lastEnd else { return }
        flights.append((flight, gpsApproach))
        flights.sort { $0.flight.event.startSeconds < $1.flight.event.startSeconds }
    }

    mutating func resolve(through time: Double, finishing: Bool, vertical: [VerticalTrajectory.Sample],
                          altitude: [AltitudeSample], gps: [RoutePoint], motionClock: Date?, holdingFrom: Double? = nil)
        -> [(JumpCandidate, LiveJumpEstimate)] {
        var results: [(JumpCandidate, LiveJumpEstimate)] = []
        while let first = flights.first {
            let end = first.flight.event.endSeconds
            let group = flights.prefix { $0.flight.event.startSeconds < end }
            let last = group.map { $0.flight.event.endSeconds }.max() ?? end
            guard finishing || (time >= last + 3 && !(holdingFrom.map { last >= $0 } ?? false)) else { break }
            var best: (event: JumpCandidate, estimate: LiveJumpEstimate, priority: Int)?
            for item in group {
                let flight = item.flight
                let peak = flight.approachPeak == nil ? VerticalTrajectory.flightPeak(
                    flight.event, samples: vertical, levelLandingCheck: flight.levelLandingHeight) : nil
                let estimate = LiveJumpEstimate.riding(flight, altitude: altitude, gps: gps, motionClock: motionClock, motionPeak: peak)
                guard let height = estimate.heightMeters, height.isFinite, height >= ApproachJumpDetector.minimumHeight else { continue }
                let priority = flight.pressureAssisted ? 4 : flight.crossedStartLevel ? 3 : flight.approachPeak != nil ? 1 : (item.gpsApproach ? 2 : 0)
                if best == nil || priority > best!.priority { best = (flight.event, estimate, priority) }
            }
            if var chosen = best {
                let start = chosen.estimate.estimatedFlightStart ?? chosen.event.startSeconds
                let end = chosen.estimate.estimatedFlightEnd ?? chosen.event.endSeconds
                if let path = LiveJumpEstimate.speedDistance(start: start, end: end, gps: gps, motionClock: motionClock) {
                    chosen.estimate.distanceMeters = path
                    chosen.estimate.distanceFromSpeed = true
                } else {
                    chosen.estimate.distanceMeters = LiveJumpEstimate.gpsDistance(start: start, end: end, gps: gps, motionClock: motionClock)
                    if chosen.estimate.distanceMeters == nil {
                        chosen.estimate.distanceIssue = LiveJumpEstimate.distanceIssue(start: start, end: end, gps: gps, motionClock: motionClock)
                    }
                }
                best = chosen
            }
            flights.removeFirst(group.count)
            if let best {
                results.append((best.event, best.estimate))
                lastEnd = best.event.endSeconds
                flights.removeAll { $0.flight.event.startSeconds < lastEnd }
            }
        }
        return results
    }
}

/// Measures a complete vertical excursion of the phone. A stable vertical
/// velocity supplies an anchor even while the phone moves horizontally.
/// Integrates gravity-aligned acceleration, retaining the trajectory through its apex.
/// The hand-lift fixtures and the live rider estimator exercise the same integrator.
struct VerticalTrajectory {
    struct Sample {
        let time: Double
        let acceleration: Double
    }
    struct Peak {
        let height: Double
        let time: Double
        var pushRise: Double? = nil
    }
    private(set) var velocity = 0.0
    private(set) var height = 0.0

    mutating func advance(acceleration: Double, interval: Double) {
        let next = velocity + acceleration * interval
        height += (velocity + next) * interval * 0.5
        velocity = next
    }

    func correctedHeight(elapsed: Double, duration: Double, residualVelocity: Double, closure: Double) -> Double {
        let fraction = elapsed / duration
        return height - residualVelocity * elapsed * fraction * 0.5
            - closure * fraction * fraction * (3 - 2 * fraction)
    }

    // Look for a quiet vertical window before the push and after the landing.
    // Lateral motion is allowed. Never integrate across a missing sensor interval.
    private static func anchor(_ samples: [Sample], nearTakeoff: Bool) -> Double? {
        guard !samples.isEmpty else { return nil }
        let ordered = nearTakeoff ? Array(samples.reversed()) : samples
        var window: [Sample] = []
        for sample in ordered {
            window.append(sample)
            window.removeAll { abs($0.time - sample.time) > 0.40 }
            guard let edge = window.first, abs(sample.time - edge.time) >= 0.35, window.count >= 20 else { continue }
            let n = Double(window.count)
            let mean = window.reduce(0.0) { $0 + $1.acceleration } / n
            let power = window.reduce(0.0) { $0 + $1.acceleration * $1.acceleration } / n
            if abs(mean) <= 0.35 && power < 0.8 * 0.8 {
                return window[window.count / 2].time
            }
        }
        return nil
    }

    static func flightPeak(_ event: JumpCandidate, samples: [Sample], levelLandingCheck: Double? = nil) -> Peak? {
        let start = event.startSeconds, end = event.endSeconds
        guard start < end, end - start <= 15.5 else { return nil }
        let nearby = samples.filter { $0.time >= start - 2.5 && $0.time <= end + 2 }
        guard let left = anchor(nearby.filter { $0.time < start }, nearTakeoff: true),
              let right = anchor(nearby.filter { $0.time > end }, nearTakeoff: false) else { return nil }
        let track = nearby.filter { $0.time >= left && $0.time <= right }
        let duration = right - left
        var path = Self()
        var positions: [(time: Double, path: Self)] = []
        var preparation = [(time: left, path: path)]
        for (a, b) in zip(track, track.dropFirst()) {
            let dt = b.time - a.time
            guard dt > 0, dt <= 0.05, a.acceleration.isFinite, b.acceleration.isFinite else { return nil }
            path.advance(acceleration: (a.acceleration + b.acceleration) * 0.5, interval: dt)
            if b.time <= start { preparation.append((b.time, path)) }
            if (start...end).contains(b.time) { positions.append((b.time, path)) }
        }
        // Both anchors approximate zero vertical speed. Their heights can differ.
        guard abs(path.velocity) <= 0.60, let takeoff = positions.first, let landing = positions.last,
              abs(takeoff.time - start) < 0.001, abs(landing.time - end) < 0.001 else { return nil }
        func level(_ point: (time: Double, path: Self)) -> Double {
            point.path.correctedHeight(elapsed: point.time - left, duration: duration,
                                       residualVelocity: path.velocity, closure: 0)
        }
        guard let apex = positions.max(by: { level($0) < level($1) }) else { return nil }
        let height = level(apex) - level(takeoff)
        let fraction = (apex.time - start) / (end - start)
        guard (0.06...35).contains(height), (0.08...0.92).contains(fraction),
              level(apex) - level(landing) >= 0.04 else { return nil }
        if abs(path.velocity) > 0.45 {
            // Compare the more uncertain anchored solution with an independently constrained
            // short-flight trajectory. Bound the apex error from the endpoint speed mismatch.
            guard let check = levelLandingCheck, check.isFinite,
                  abs(path.velocity) * (apex.time - start) <= 0.16,
                  abs(check - height) <= 0.12 else { return nil }
        }
        let baseline = preparation.filter { start - $0.time <= 1.2 }.map(level).min()
        return Peak(height: height, time: apex.time, pushRise: baseline.map { max(0, level(takeoff) - $0) })
    }
}

struct MovingHeightDetector {
    enum Phase { case searching, rising, descending, returning }

    struct Measurement {
        let event: JumpCandidate
        let height: Double
        let apexSeconds: Double
    }

    private struct Point {
        let time: Double
        let acceleration: Double
        let velocity: Double
        let load: Double
        let spin: Double
    }

    private struct Anchor {
        let time: Double
        let lastTime: Double
        let velocity: Double
        let acceleration: Double
    }

    private struct Excursion {
        var samples: [Point]
        let bias: Double
        var stoppedSince: Double?
        var lastAnalysis = -Double.infinity
        var liveVelocity = 0.0
        var liveHeight = 0.0
        var livePeak = 0.0
        var hasDescended = false

        mutating func append(_ point: Point) {
            if let last = samples.last {
                let dt = point.time - last.time
                let next = liveVelocity + ((point.acceleration + last.acceleration) * 0.5 - bias) * dt
                liveHeight += (liveVelocity + next) * 0.5 * dt
                liveVelocity = next
                livePeak = max(livePeak, liveHeight)
                if livePeak >= 0.4 && liveVelocity < -0.15 { hasDescended = true }
            }
            samples.append(point)
        }

        func measurement() -> Measurement? {
            guard let first = samples.first, let last = samples.last else { return nil }
            let duration = last.time - first.time
            guard duration >= 0.8, abs(liveVelocity) <= 0.45, hasDescended else { return nil }
            // Confirm that an approximately level return is supported before
            // applying endpoint drift corrections. A shelf ascent fails here.
            let closure = liveHeight - liveVelocity * duration * 0.5
            guard abs(closure) <= 0.4 else { return nil }
            var path = VerticalTrajectory()
            var peak = 0.0
            var lowest = 0.0
            var apex = first.time
            for (before, after) in zip(samples, samples.dropFirst()) {
                let dt = after.time - before.time
                path.advance(acceleration: (before.acceleration + after.acceleration) * 0.5 - bias, interval: dt)
                let corrected = path.correctedHeight(elapsed: after.time - first.time, duration: duration,
                                                     residualVelocity: liveVelocity, closure: closure)
                lowest = min(lowest, corrected)
                if corrected > peak {
                    peak = corrected
                    apex = after.time
                }
            }
            let end = last.time - 0.2
            guard (0.4...4).contains(peak), lowest >= -0.3,
                  (0.15...0.85).contains((apex - first.time) / duration),
                  stoppedSince != nil, end > apex else { return nil }
            let event = JumpCandidate(startSeconds: first.time, endSeconds: end,
                                      minimumLoadG: samples.map(\.load).min() ?? 1,
                                      returnPeakG: samples.map(\.load).max() ?? 1,
                                      maximumRotationRadiansPerSecond: samples.map(\.spin).max() ?? 0)
            return Measurement(event: event, height: peak, apexSeconds: apex)
        }
    }

    private(set) var phase = Phase.searching
    private(set) var lastMeasurement: Measurement?
    private var previous: Point?
    private var recent: [Point] = []
    private var verticalWindow: [Point] = []
    private var anchor: Anchor?
    private var excursion: Excursion?
    private var estimatedBias: Double?

    mutating func process(_ sample: MotionSample, calibration: MotionCalibration?) -> Measurement? {
        let time = sample.elapsedSinceFirstSampleSeconds
        let acceleration = calibration.map {
            -$0.correctedVertical(sample.verticalAccelerationMetersPerSecondSquared, at: time)
        } ?? sample.upwardAcceleration
        let a = sample.accelerationG, g = sample.gravityG, r = sample.rotationRadiansPerSecond
        let load = sqrt(pow(a.x + g.x, 2) + pow(a.y + g.y, 2) + pow(a.z + g.z, 2))
        let spin = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        guard time.isFinite, time >= 0, acceleration.isFinite, load.isFinite, spin.isFinite else {
            self = Self()
            return nil
        }
        if let previous, time <= previous.time || time - previous.time > 0.05 {
            self = Self()
        }
        let previousVelocity = previous?.velocity ?? 0
        let dt = previous.map { time - $0.time } ?? 0
        let velocity = previousVelocity + ((previous?.acceleration ?? acceleration) + acceleration) * dt * 0.5
        let point = Point(time: time, acceleration: acceleration, velocity: velocity, load: load, spin: spin)
        previous = point
        recent.append(point)
        recent.removeAll { time - $0.time > 3.5 }
        verticalWindow.append(point)
        verticalWindow.removeAll { time - $0.time > 0.4 }

        let stable = verticalAnchor()
        if estimatedBias == nil, let stable { estimatedBias = stable.acceleration }
        if excursion == nil {
            if let anchor, time - anchor.lastTime < 3, velocity - anchor.velocity > 0.15 {
                let bias = calibration == nil ? (estimatedBias ?? anchor.acceleration) : 0
                var track = Excursion(samples: [], bias: bias)
                for sample in recent where sample.time >= anchor.time { track.append(sample) }
                excursion = track
                phase = .rising
            } else if let stable, abs(stable.acceleration) < 0.15 || anchor == nil {
                anchor = stable
            }
            return nil
        }

        guard let start = excursion?.samples.first?.time, time - start <= 18 else {
            excursion = nil
            anchor = stable
            phase = .searching
            return nil
        }
        excursion?.append(point)
        if let track = excursion, track.livePeak >= 0.4, track.liveVelocity < -0.15 { phase = .descending }
        guard let stable else {
            excursion?.stoppedSince = nil
            return nil
        }
        if excursion?.stoppedSince == nil { excursion?.stoppedSince = time }
        guard let stopped = excursion?.stoppedSince, time - stopped >= 0.2,
              let analyzed = excursion?.lastAnalysis, time - analyzed >= 0.2 else { return nil }
        excursion?.lastAnalysis = time
        guard let measured = excursion?.measurement() else { return nil }
        phase = .returning
        lastMeasurement = measured
        excursion = nil
        anchor = stable
        return measured
    }

    private func verticalAnchor() -> Anchor? {
        guard let first = verticalWindow.first, let last = verticalWindow.last,
              verticalWindow.count > 20, last.time - first.time >= 0.35 else { return nil }
        let count = Double(verticalWindow.count)
        let meanVelocity = verticalWindow.reduce(0.0) { $0 + $1.velocity } / count
        let meanAcceleration = verticalWindow.reduce(0.0) { $0 + $1.acceleration } / count
        let variance = verticalWindow.reduce(0.0) { $0 + pow($1.velocity - meanVelocity, 2) } / count
        guard variance < 0.08 * 0.08, abs(meanAcceleration) < 0.5 else { return nil }
        return Anchor(time: first.time, lastTime: last.time, velocity: meanVelocity, acceleration: meanAcceleration)
    }
}

struct HandSimulationDetector {
    static let version = "hand-practice-6"
    private var quiet: [Double] = []
    private var baseline: Double?
    private var returnTolerance = 0.28
    private var previousTime: Double?
    private var lift: Lift?
    private var movingHeight = MovingHeightDetector()
    var lastMotionApexSeconds: Double? { movingHeight.lastMeasurement?.apexSeconds }

    private struct Lift {
        let start: Double
        var peak: Double
        var returnTime: Double?
        var returnAltitude: Double?
    }

    mutating func processMotion(_ sample: MotionSample, calibration: MotionCalibration? = nil)
        -> (event: JumpCandidate, height: Double)? {
        guard let measurement = movingHeight.process(sample, calibration: calibration) else { return nil }
        return (measurement.event, measurement.height)
    }

    mutating func resetPressure() {
        quiet.removeAll()
        baseline = nil
        previousTime = nil
        lift = nil
    }

    mutating func consume(_ sample: AltitudeSample) -> (JumpCandidate, Double)? {
        let time = sample.elapsedSinceFirstSampleSeconds, altitude = sample.relativeAltitudeMeters
        guard time.isFinite, time >= 0, altitude.isFinite, sample.pressureKilopascals.isFinite,
              sample.pressureKilopascals > 0 else {
            lift = nil; baseline = nil; quiet.removeAll(); previousTime = nil
            return nil
        }
        if let previousTime, time <= previousTime || time - previousTime > 3.2 {
            lift = nil; baseline = nil; quiet.removeAll()
        }
        previousTime = time
        if var lift, let baseline {
            if time - lift.start > 75 || abs(altitude - baseline) > 5 {
                self.lift = nil; self.baseline = nil; quiet.removeAll()
                return nil
            }
            let relative = altitude - baseline
            lift.peak = max(lift.peak, relative)
            let tolerance = max(returnTolerance, min(0.60, lift.peak * 0.24))
            if relative <= tolerance, lift.peak - relative >= 0.25 {
                let nearBaseline = relative <= returnTolerance
                let settlingTime = nearBaseline ? 0.5 : 2.0
                let variation = nearBaseline ? 0.16 : 0.10
                if let returned = lift.returnTime, let prior = lift.returnAltitude,
                   !nearBaseline || prior - baseline <= returnTolerance,
                   abs(prior - altitude) <= variation, time - returned >= settlingTime {
                    self.lift = nil
                    quiet = [prior, altitude]
                    self.baseline = nil
                    guard (0.40...4).contains(lift.peak), returned - lift.start >= 0.65,
                          relative >= -max(0.40, lift.peak * 0.2) else { return nil }
                    return (JumpCandidate(startSeconds: lift.start, endSeconds: returned,
                                          minimumLoadG: 0, returnPeakG: 0, maximumRotationRadiansPerSecond: 0), lift.peak)
                }
                if lift.returnAltitude.map({ abs($0 - altitude) > variation ||
                    (nearBaseline && $0 - baseline > returnTolerance) }) ?? true {
                    lift.returnTime = time
                    lift.returnAltitude = altitude
                }
            } else {
                lift.returnTime = nil
                lift.returnAltitude = nil
            }
            self.lift = lift
            return nil
        }
        if let baseline, altitude - baseline >= returnTolerance + 0.04 {
            lift = Lift(start: time, peak: altitude - baseline)
            quiet.removeAll()
            return nil
        }
        quiet.append(altitude)
        if quiet.count > 3 { quiet.removeFirst() }
        if quiet.count == 3, let low = quiet.min(), let high = quiet.max(), high - low <= 0.30 {
            // Re-anchor after walking or lowering the phone. Keep the original
            // baseline through a gradual rise so slow lifts are not erased.
            let center = quiet.reduce(0, +) / 3
            if baseline == nil || center <= (baseline ?? center) + 0.025 {
                baseline = center
                returnTolerance = min(0.38, 0.26 + high - low)
            }
        }
        return nil
    }
}

/// The same quality filter is used live, during replay and for GPX export.
/// Thresholds remove obvious GPS failures; they are not a claim of GPS accuracy.
struct RouteFilter {
    private(set) var metrics = RouteMetrics()
    private var previous: LocationSample?
    private var anchor: LocationSample?
    private var lastTimestamp: Date?
    private var speedSegment = 0

    mutating func breakContinuity() {
        previous = nil
        anchor = nil
        speedSegment += 1
    }

    mutating func accept(_ sample: LocationSample, notBefore start: Date) -> RoutePoint? {
        guard sample.timestamp.timeIntervalSince1970.isFinite,
              sample.timestamp >= start,
              lastTimestamp.map({ sample.timestamp > $0 }) ?? true else {
            metrics.rejected += 1
            breakContinuity()
            return nil
        }
        lastTimestamp = sample.timestamp
        guard sample.latitude.isFinite, sample.longitude.isFinite,
              (-90...90).contains(sample.latitude), (-180...180).contains(sample.longitude),
              sample.horizontalAccuracyMeters.isFinite,
              (0...30).contains(sample.horizontalAccuracyMeters) else {
            metrics.rejected += 1
            breakContinuity()
            return nil
        }
        if let previous {
            let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
            if dt > 15 {
                breakContinuity()
            } else if Self.distance(previous, sample) / dt > 60 {
                // Reject the jump, then start afresh on the next valid fix.
                metrics.rejected += 1
                breakContinuity()
                return nil
            }
        }
        if previous == nil {
            metrics.segments += 1
            speedSegment += 1
        }
        if let anchor {
            let distance = Self.distance(anchor, sample)
            if distance >= 5 {
                metrics.distanceMeters += distance
                self.anchor = sample
            }
        } else { anchor = sample }
        previous = sample
        let speed: Double?
        if let value = sample.speedMetersPerSecond, value.isFinite, (0...60).contains(value),
           let accuracy = sample.speedAccuracyMetersPerSecond, accuracy.isFinite, (0...3).contains(accuracy) {
            speed = value
            metrics.maxSpeedMetersPerSecond = max(metrics.maxSpeedMetersPerSecond ?? 0, value)
        } else {
            speed = nil
            speedSegment += 1
        }
        metrics.accepted += 1
        return RoutePoint(id: metrics.accepted, segment: metrics.segments, speedSegment: speedSegment, sample: sample, speed: speed)
    }

    static func distance(_ a: LocationSample, _ b: LocationSample) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians
        let dLon = (b.longitude - a.longitude) * radians
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

struct RouteAnalysis: Sendable {
    let points: [RoutePoint]
    let metrics: RouteMetrics
    let malformedLines: Int

    /// Bound drawing work while keeping endpoints and all discontinuities.
    /// Each segment is sampled independently, so simplification cannot join gaps.
    var displaySegments: [[RoutePoint]] {
        let groups = Dictionary(grouping: points, by: \.segment)
        let step = max(1, Int(ceil(Double(points.count) / 2500)))
        let keys = groups.keys.sorted()
        let groupStep = max(1, Int(ceil(Double(keys.count) / 500)))
        return stride(from: 0, to: keys.count, by: groupStep).compactMap { index in
            let key = keys[index]
            guard let group = groups[key], let last = group.last else { return nil }
            var sampled = stride(from: 0, to: group.count, by: step).map { group[$0] }
            if sampled.last?.id != last.id { sampled.append(last) }
            return sampled
        }
    }

    var displaySpeedPoints: [RoutePoint] {
        let groups = Dictionary(grouping: points.filter { $0.speed != nil }, by: \.speedSegment)
        let step = max(1, Int(ceil(Double(points.count) / 1500)))
        let keys = groups.keys.sorted()
        let groupStep = max(1, Int(ceil(Double(keys.count) / 500)))
        return stride(from: 0, to: keys.count, by: groupStep).flatMap { index -> [RoutePoint] in
            let key = keys[index]
            let group = groups[key] ?? []
            // Keep extrema of each bucket: a short speed peak remains visible.
            return stride(from: 0, to: group.count, by: step).flatMap { start -> [RoutePoint] in
                let bucket = Array(group[start..<min(start + step, group.count)])
                let chosen = [bucket.first!, bucket.min { ($0.speed ?? 0) < ($1.speed ?? 0) }!,
                              bucket.max { ($0.speed ?? 0) < ($1.speed ?? 0) }!, bucket.last!]
                return Dictionary(grouping: chosen, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
            }
        }
    }
}

enum RouteReplay {
    private struct Header: Decodable { let type: String }
    private struct Entry: Decodable { let data: LocationSample }
    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "В записи больше 200 000 точек GPS. Разделите её на более короткие сессии." }
    }

    static func analyze(url: URL, startedAt: Date) throws -> RouteAnalysis {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var buffer = Data()
        var points: [RoutePoint] = []
        var filter = RouteFilter()
        var malformed = 0
        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            do {
                let header = try decoder.decode(Header.self, from: line)
                if header.type == "location" {
                    let sample = try decoder.decode(Entry.self, from: line).data
                    if let point = filter.accept(sample, notBefore: startedAt) { points.append(point) }
                } else if header.type == "event" {
                    // Any event may represent lost permission or GPS failure.
                    // Breaking is conservative and never invents distance.
                    filter.breakContinuity()
                }
            } catch {
                malformed += 1
                filter.breakContinuity()
            }
            if points.count > 200_000 { throw Failure.tooLarge }
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                try consume(Data(buffer[..<end]))
                buffer.removeSubrange(...end)
            }
            if buffer.count > 1_048_576 { throw CocoaError(.fileReadCorruptFile) }
        }
        if !buffer.isEmpty { try consume(buffer) }
        return RouteAnalysis(points: points, metrics: filter.metrics, malformedLines: malformed)
    }
}

enum GPXExport {
    static func escape(_ value: String) -> String {
        let legal = String(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        })
        return legal.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    static func write(_ route: RouteAnalysis, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rider-route-\(UUID()).gpx")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Rider\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(escape(name))</name>"
        var segment: Int?
        for point in route.points {
            if point.segment != segment {
                if segment != nil { xml += "</trkseg>" }
                xml += "<trkseg>"
                segment = point.segment
            }
            let sample = point.sample
            let coordinate = String(format: "lat=\"%.8f\" lon=\"%.8f\"", locale: Locale(identifier: "en_US_POSIX"), sample.latitude, sample.longitude)
            xml += "<trkpt \(coordinate)><time>\(formatter.string(from: sample.timestamp))</time></trkpt>\n"
        }
        if segment != nil { xml += "</trkseg>" }
        xml += "</trk></gpx>"
        try Data(xml.utf8).write(to: url, options: .atomic)
        return url
    }
}

struct RiderProgress {
    let sessions: [SessionSummary]
    var duration: Double { sessions.reduce(0) { $0 + max(0, $1.durationSeconds) } }
    var distance: Double { sessions.reduce(0) { $0 + max(0, $1.gpsMetrics?.distanceMeters ?? $1.distanceMeters ?? 0) } }
    var maximumSpeed: Double? {
        sessions.compactMap { $0.gpsMetrics != nil ? $0.gpsMetrics?.maxSpeedMetersPerSecond : $0.maxSpeedMetersPerSecond }
            .filter { $0.isFinite && (0...60).contains($0) }.max()
    }
    var confirmedJumps: Int {
        sessions.reduce(0) { total, session in
            guard let analysis = session.jumpAnalysis, let review = session.review else { return total }
            return total + analysis.candidates.filter { review.label(for: $0, version: analysis.detectorVersion) == .bodyJump }.count
        }
    }
    init(history: [SessionSummary], since: Date? = nil) {
        sessions = history.filter { session in
            session.setup?.sport.isRiding == true && session.status != .recording &&
            (since.map { session.startedAt >= $0 } ?? true)
        }
    }
}
