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

enum GroundTestMode: String, CaseIterable {
    case normal, phoneToss, handSimulation

    var title: String {
        switch self {
        case .normal: return "Обычный"
        case .phoneToss: return "Подброс телефона"
        case .handSimulation: return "Имитация рукой"
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

    var activityTitle: String {
        guard sport.supportsKiteStyle, let kiteStyle else { return sport.title }
        return "\(sport.title) · \(kiteStyle.title)"
    }
    var cleaned: Self {
        var copy = self
        copy.spot = String(spot.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        copy.kite = String(kite.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        copy.board = String(board.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if !sport.supportsKiteStyle { copy.kiteStyle = nil }
        return copy
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
    let heightMeters: Double
    let airtimeSeconds: Double
    let distanceMeters: Double?
    var isPhoneToss: Bool?

    static func phoneToss(_ event: JumpCandidate) -> Self? {
        guard event.minimumLoadG.isFinite, (0...0.2).contains(event.minimumLoadG),
              let height = event.approximateTossHeightMeters(label: .phoneToss) else { return nil }
        return Self(heightMeters: height, airtimeSeconds: event.unloadingSeconds, distanceMeters: nil, isPhoneToss: true)
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

/// A supported lift of the phone is a barometric exercise, not a free-fall event.
struct HandSimulationDetector {
    static let version = "hand-practice-1"
    private var quiet: [Double] = []
    private var baseline: Double?
    private var previousTime: Double?
    private var lift: Lift?

    private struct Lift {
        let start: Double
        var lastRaised: Double
        var peak: Double
    }

    mutating func consume(_ sample: AltitudeSample) -> (JumpCandidate, Double)? {
        let time = sample.elapsedSinceFirstSampleSeconds, altitude = sample.relativeAltitudeMeters
        guard time.isFinite, altitude.isFinite else { return nil }
        if let previousTime, time <= previousTime || time - previousTime > 1.5 {
            self = Self()
        }
        previousTime = time
        if var lift, let baseline {
            if time - lift.start > 20 {
                self = Self()
                return nil
            }
            let relative = altitude - baseline
            if relative >= 0.28 {
                lift.lastRaised = time
                lift.peak = max(lift.peak, relative)
                self.lift = lift
            } else if relative <= 0.20 {
                self.lift = nil
                quiet = [altitude]
                self.baseline = nil
                guard (0.40...5).contains(lift.peak), lift.lastRaised - lift.start >= 0.65 else { return nil }
                return (JumpCandidate(startSeconds: lift.start, endSeconds: lift.lastRaised,
                                      minimumLoadG: 0, returnPeakG: 0, maximumRotationRadiansPerSecond: 0), lift.peak)
            }
            return nil
        }
        if let baseline, altitude - baseline >= 0.28 {
            lift = Lift(start: time, lastRaised: time, peak: altitude - baseline)
            quiet.removeAll()
            return nil
        }
        quiet.append(altitude)
        if quiet.count > 3 { quiet.removeFirst() }
        if quiet.count == 3, let low = quiet.min(), let high = quiet.max(), high - low <= 0.12 {
            baseline = quiet.reduce(0, +) / 3
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
