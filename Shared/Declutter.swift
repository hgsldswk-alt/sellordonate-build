import Foundation

struct CalculationDraft: Codable, Equatable {
    var id = UUID()
    var currency: Currency
    var price = ""
    var fee = "0"
    var buyerShipping = "0"
    var extraBase = "0"
    var shipping = "0"
    var minutes = "25"
    var threshold: String
    var preset: FeePreset?

    init(currency: Currency) {
        self.currency = currency
        self.threshold = NumberInput.text(currency.defaultThreshold)
    }

    func amount(_ text: String) -> Decimal? {
        NumberInput.parse(text, scale: currency.scale, maximum: currency.maximum)
    }

    var duration: Int? {
        NumberInput.parse(minutes, scale: 0, maximum: 1440).map { NSDecimalNumber(decimal: $0).intValue }
            .flatMap { $0 > 0 ? $0 : nil }
    }

    var input: CalculationInput? {
        guard let price = amount(price), let buyerShipping = amount(buyerShipping),
              let extraBase = amount(extraBase), let shipping = amount(shipping),
              let fee = amount(fee), let minutes = duration, let threshold = amount(threshold) else { return nil }
        return CalculationInput(currency: currency, price: price, buyerShipping: buyerShipping,
                                additionalFeeBase: extraBase, sellerShipping: shipping, manualFee: fee,
                                preset: preset, minutes: minutes, threshold: threshold)
    }

    func withManualFee() -> Self {
        guard preset != nil else { return self }
        var result = self
        if let input, let calculation = Calculator.calculate(input) {
            result.fee = NumberInput.text(min(calculation.fee, currency.maximum))
        }
        result.preset = nil
        return result
    }

    mutating func next() {
        id = UUID()
        price = ""
    }
}

enum Destination: String, Codable, CaseIterable, Hashable {
    case sell, donate, sold, donated, discarded

    var titleKey: String { "status." + rawValue }
    var soldOrDonated: Bool { self == .sold || self == .donated }
    var completed: Bool { soldOrDonated || self == .discarded }
}

struct DecisionItem: Codable, Equatable, Identifiable {
    var id: UUID
    var ordinal: Int
    var name = ""
    var input: CalculationInput
    var estimate: CalculationResult
    var status: Destination
    var actualNet: Decimal?
    var investedMinutes = 0
    var donationMinutes: Int?
    var completedAt: Date?
    var completionDay: String?

    var displayName: String { name.isEmpty ? L.f("item.number", String(ordinal)) : name }
    var savedMinutes: Int? {
        guard status == .donated, let donationMinutes else { return nil }
        return max(0, input.minutes - investedMinutes - donationMinutes)
    }

    mutating func update(_ destination: Destination, actual: Decimal? = nil, invested: Int = 0,
                         donated: Int? = nil, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard (0...1440).contains(invested),
              donated.map({ (0...1440).contains($0) }) ?? true else { return false }
        if destination == .sold {
            guard let actual, abs(actual) <= input.currency.maximum,
                  actual == input.currency.round(actual) else { return false }
        }
        if destination.completed {
            if status != destination || completedAt == nil {
                completedAt = now
                let date = calendar.dateComponents([.year, .month, .day], from: now)
                completionDay = "\(date.year ?? 0)-\(date.month ?? 0)-\(date.day ?? 0)"
            }
        } else {
            completedAt = nil
            completionDay = nil
        }
        status = destination
        actualNet = destination == .sold ? actual : nil
        investedMinutes = invested
        donationMinutes = destination == .donated ? donated : nil
        return true
    }
}

struct DeclutterSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var startedAt = Date()
    var items: [DecisionItem] = []
    var nextOrdinal = 1

    var hasCompletedItems: Bool { items.contains { $0.status.completed } }
    var summary: SessionSummary { SessionSummary(items: items) }
}

struct SessionSummary {
    var sold = 0
    var donated = 0
    var discarded = 0
    var savedMinutes = 0
    var missingDonationTime = 0
    var income: [Currency: Decimal] = [:]

    var completed: Int { sold + donated + discarded }

    init(items: [DecisionItem]) {
        for item in items {
            switch item.status {
            case .sold:
                sold += 1
                income[item.input.currency, default: 0] += item.actualNet ?? 0
            case .donated:
                donated += 1
                if let minutes = item.savedMinutes { savedMinutes += minutes } else { missingDonationTime += 1 }
            case .discarded:
                discarded += 1
            case .sell, .donate:
                break
            }
        }
    }

    static func allocateTrip(_ minutes: Int, items: Int) -> [Int] {
        guard minutes >= 0, items > 0 else { return [] }
        return (0..<items).map { minutes / items + ($0 < minutes % items ? 1 : 0) }
    }
}

struct ReviewHistory: Codable, Equatable {
    var version: String?
    var date: Date?

    func canRequest(version: String, now: Date, items: [DecisionItem]) -> Bool {
        let completed = items.filter { $0.status.soldOrDonated }
        let days = Set(completed.compactMap(\.completionDay)).count
        return (days >= 3 || (completed.count >= 10 && days >= 2)) &&
            self.version != version && (date.map { now.timeIntervalSince($0) >= 120 * 86400 } ?? true)
    }
}

struct LocalState: Codable, Equatable {
    static let version = 1
    static let milestones = [10, 50, 100]

    var draft: CalculationDraft
    var parked: [String: [CalculationDraft]] = [:]
    var defaultsByCurrency: [String: CalculationDraft]?
    var personal: [String: FeePreset] = [:]
    var current = DeclutterSession()
    var past: [DeclutterSession] = []
    var completedIDs: Set<UUID> = []
    var unlockedMilestones: Set<Int> = []
    var announcedMilestones: Set<Int> = []
    var review = ReviewHistory()

    init(currency: Currency = .local) { draft = CalculationDraft(currency: currency) }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        draft = try values.decode(CalculationDraft.self, forKey: .draft)
        if let legacy = try? values.decode([String: CalculationDraft].self, forKey: .parked) {
            parked = legacy.mapValues { [$0] }
        } else {
            parked = try values.decodeIfPresent([String: [CalculationDraft]].self, forKey: .parked) ?? [:]
        }
        defaultsByCurrency = try values.decodeIfPresent([String: CalculationDraft].self, forKey: .defaultsByCurrency)
        personal = try values.decodeIfPresent([String: FeePreset].self, forKey: .personal) ?? [:]
        current = try values.decodeIfPresent(DeclutterSession.self, forKey: .current) ?? DeclutterSession()
        past = try values.decodeIfPresent([DeclutterSession].self, forKey: .past) ?? []
        let completed = Set(allItems.filter { $0.status.soldOrDonated }.map(\.id))
        completedIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .completedIDs) ?? completed
        unlockedMilestones = try values.decodeIfPresent(Set<Int>.self, forKey: .unlockedMilestones) ??
            Set(Self.milestones.filter { $0 <= completedIDs.count })
        announcedMilestones = try values.decodeIfPresent(Set<Int>.self, forKey: .announcedMilestones) ?? []
        review = try values.decodeIfPresent(ReviewHistory.self, forKey: .review) ?? ReviewHistory()
    }

    var allItems: [DecisionItem] { current.items + past.flatMap(\.items) }

    mutating func changeCurrency(_ currency: Currency, empty: Bool = false) {
        guard currency != draft.currency else { return }
        var cleared = draft
        cleared.next()
        if defaultsByCurrency == nil { defaultsByCurrency = [:] }
        defaultsByCurrency?[draft.currency.rawValue] = cleared
        park(draft)
        draft = defaultsByCurrency?[currency.rawValue] ?? CalculationDraft(currency: currency)
        if !empty { _ = restoreParkedDraft() }
        if empty { draft.next() }
    }

    mutating func add(id: UUID, to destination: Destination) -> Bool {
        guard id == draft.id, destination == .sell || destination == .donate,
              !current.items.contains(where: { $0.id == id }),
              let input = draft.input, let estimate = Calculator.calculate(input) else { return false }
        current.items.insert(DecisionItem(id: id, ordinal: current.nextOrdinal, input: input,
                                         estimate: estimate, status: destination), at: 0)
        current.nextOrdinal += 1
        if draft.preset != nil { draft.fee = NumberInput.text(min(estimate.fee, draft.currency.maximum)) }
        draft.next()
        return true
    }

    var hasReusablePresets: Bool {
        draft.preset != nil || parked.values.joined().contains { $0.preset != nil } ||
            defaultsByCurrency?.values.contains { $0.preset != nil } == true
    }

    mutating func reuseFeeValues() {
        draft = draft.withManualFee()
        parked = parked.mapValues { $0.map { $0.withManualFee() } }
        defaultsByCurrency = defaultsByCurrency?.mapValues { $0.withManualFee() }
    }

    mutating func recordCompletion(_ id: UUID) {
        guard completedIDs.insert(id).inserted, Self.milestones.contains(completedIDs.count) else { return }
        unlockedMilestones.insert(completedIDs.count)
    }

    mutating func startSession(now: Date = Date()) {
        guard !current.items.isEmpty else { return }
        past.insert(current, at: 0)
        current = DeclutterSession(startedAt: now)
    }

    mutating func park(_ saved: CalculationDraft) {
        guard !saved.price.isEmpty else { return }
        let key = saved.currency.rawValue
        var drafts = parked[key, default: []]
        drafts.removeAll { $0.id == saved.id }
        drafts.append(saved)
        parked[key] = drafts
    }

    mutating func restoreParkedDraft() -> Bool {
        let key = draft.currency.rawValue
        guard var drafts = parked[key], let saved = drafts.popLast() else { return false }
        if !draft.price.isEmpty {
            drafts.removeAll { $0.id == draft.id }
            drafts.insert(draft, at: 0)
        }
        parked[key] = drafts.isEmpty ? nil : drafts
        draft = saved
        return true
    }
}

enum StateArchive {
    struct Envelope: Codable {
        let version: Int
        let state: LocalState
    }
    enum Failure: Error { case unsupportedVersion }

    static func encode(_ state: LocalState) throws -> Data {
        try JSONEncoder().encode(Envelope(version: LocalState.version, state: state))
    }

    static func decode(_ data: Data) throws -> LocalState {
        let decoder = JSONDecoder()
        let versioned = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let versioned else { throw Failure.unsupportedVersion }
        if let version = versioned["version"] as? Int {
            guard version == LocalState.version || version == 0 else { throw Failure.unsupportedVersion }
            return try decoder.decode(Envelope.self, from: data).state
        }
        guard versioned["version"] == nil, versioned["draft"] != nil else { throw Failure.unsupportedVersion }
        return try decoder.decode(LocalState.self, from: data)
    }
}

enum CSVExport {
    static func contents(_ session: DeclutterSession) -> String {
        let headers = ["name", "status", "currency", "price", "buyerShipping", "fee", "shipping",
                       "net", "minutes", "actual", "invested", "donationMinutes", "savedMinutes", "date"]
        let header = headers.map { cell(L.t("csv." + $0)) }.joined(separator: ",")
        let iso = ISO8601DateFormatter()
        let rows = session.items.reversed().map { item in
            let fields: [String] = [
                cell(item.displayName), cell(L.t(item.status.titleKey)), item.input.currency.rawValue,
                decimal(item.input.price), decimal(item.input.buyerShipping), decimal(item.estimate.fee),
                decimal(item.input.sellerShipping), decimal(item.estimate.net), String(item.input.minutes),
                item.actualNet.map(decimal) ?? "", String(item.investedMinutes),
                item.donationMinutes.map { String($0) } ?? "", item.savedMinutes.map { String($0) } ?? "",
                item.completedAt.map { iso.string(from: $0) } ?? ""
            ]
            return fields.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    private static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    private static func cell(_ value: String) -> String {
        let significant = value.drop(while: { $0.isWhitespace || $0.isNewline || ($0.asciiValue ?? 255) < 32 })
        let formula = significant.first.map { "=+-@＝＋－＠".contains($0) } ?? false
        let control = value.first.map { "\t\r\n".contains($0) } ?? false
        let protected = formula || control ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
