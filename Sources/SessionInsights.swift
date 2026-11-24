import Foundation

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
        if next.placement == .hand { next.placement = .unspecified }
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
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let notes: String?
    let windyLink: URL?
    var region: String?
    var locality: String?
    var areaOnly: Bool?
    var source: URL?
    var mapLink: URL?

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
        if let id = setup.spotID { return self.id == id }
        return name.caseInsensitiveCompare(setup.spot.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
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

enum StarterSpots {
    static let infoKey = "RiderStarterSpots"

    private struct Entry: Decodable {
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
            spot?.region = entry.region
            spot?.locality = entry.locality
            spot?.areaOnly = entry.areaOnly
            spot?.source = entry.source.flatMap { URL(string: $0) }
            return spot
        }
    }

    static func merge(saved: [RiderSpot], catalogue: [RiderSpot]) -> [RiderSpot] {
        let byID = Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = saved.map { old in
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
            spot.id == entry.id || spot.name.caseInsensitiveCompare(entry.name) == .orderedSame ||
                (abs(spot.latitude - entry.latitude) < 0.0001 && abs(spot.longitude - entry.longitude) < 0.0001)
        }) {
            result.append(entry)
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
        var id: Date { time }
    }

    private struct Hourly: Decodable {
        let time: [Double]
        let speed: [Double?]
        let gust: [Double?]
        let direction: [Double?]
        let temperature: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case speed = "wind_speed_10m"
            case gust = "wind_gusts_10m"
            case direction = "wind_direction_10m"
            case temperature = "temperature_2m"
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
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m,temperature_2m"),
            URLQueryItem(name: "wind_speed_unit", value: "kn"),
            URLQueryItem(name: "forecast_hours", value: "25"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return url.url
    }

    func hours(near now: Date) -> [Hour] {
        func value(_ items: [Double?], at i: Int) -> Double? {
            guard items.indices.contains(i), let number = items[i], number.isFinite, number >= 0 else { return nil }
            return number
        }
        return hourly.time.enumerated().compactMap { index, timestamp in
            guard timestamp.isFinite, let speed = value(hourly.speed, at: index) else { return nil }
            let time = Date(timeIntervalSince1970: timestamp)
            guard time.timeIntervalSince(now) > -3600 else { return nil }
            let temperatures = hourly.temperature ?? []
            let temperature = temperatures.indices.contains(index) ? temperatures[index] : nil
            return Hour(time: time, speed: speed, gust: value(hourly.gust, at: index),
                        direction: value(hourly.direction, at: index), temperature: temperature)
        }.sorted { $0.time < $1.time }
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
    let distanceMeters: Double?
    var isPhoneToss: Bool?
    var isHandLift: Bool?
    var inertialLift: Bool?
    var assumesLevelLanding: Bool?
    var apexSeconds: Double?
    var pushRiseMeters: Double?

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

    static func gpsDistance(start: Double, end: Double, gps: [RoutePoint], motionClock: Date?) -> Double? {
        if let motionClock {
            let fixes = gps.filter { $0.sample.horizontalAccuracyMeters <= 5 }
            let entry = motionClock.addingTimeInterval(start), exit = motionClock.addingTimeInterval(end)
            if let a = fixes.min(by: { abs($0.sample.timestamp.timeIntervalSince(entry)) < abs($1.sample.timestamp.timeIntervalSince(entry)) }),
               let b = fixes.min(by: { abs($0.sample.timestamp.timeIntervalSince(exit)) < abs($1.sample.timestamp.timeIntervalSince(exit)) }),
               a.segment == b.segment, a.sample.timestamp < b.sample.timestamp,
               abs(a.sample.timestamp.timeIntervalSince(entry)) <= 0.75,
               abs(b.sample.timestamp.timeIntervalSince(exit)) <= 0.75 {
                let separation = RouteFilter.distance(a.sample, b.sample)
                if separation >= a.sample.horizontalAccuracyMeters + b.sample.horizontalAccuracyMeters {
                    return separation
                }
            }
        }
        return nil
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

    static func flightPeak(_ event: JumpCandidate, samples: [Sample]) -> Peak? {
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
        guard abs(path.velocity) <= 0.45, let takeoff = positions.first, let landing = positions.last,
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
