import Foundation

enum Currency: String, Codable, CaseIterable, Identifiable, Hashable {
    case USD, CNY, EUR, GBP, TWD, HKD, JPY, CAD, AUD

    var id: String { rawValue }
    var scale: Int { self == .JPY ? 0 : 2 }
    var maximum: Decimal { scale == 0 ? 999_999 : Decimal(99_999_999) / 100 }
    var defaultThreshold: Decimal {
        switch self {
        case .CNY: return 60
        case .USD, .EUR, .GBP: return 15
        case .TWD: return 200
        case .HKD: return 65
        case .JPY: return 1500
        case .CAD, .AUD: return 20
        }
    }

    static var local: Currency { Locale.current.currency.flatMap { Currency(rawValue: $0.identifier) } ?? .USD }

    func round(_ value: Decimal) -> Decimal { rounded(value, scale: scale) }

    var symbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        return formatter.currencySymbol ?? rawValue
    }

    func money(_ number: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        formatter.maximumFractionDigits = scale
        formatter.minimumFractionDigits = scale
        return formatter.string(from: NSDecimalNumber(decimal: number)) ?? "\(rawValue) \(number)"
    }
}

func rounded(_ value: Decimal, scale: Int) -> Decimal {
    var source = value
    var result = Decimal()
    NSDecimalRound(&result, &source, scale, .plain)
    return result
}

enum NumberInput {
    static func parse(_ text: String, scale: Int, maximum: Decimal, signed: Bool = false,
                      locale: Locale = .current) -> Decimal? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= 16 else { return nil }
        var digits = ""
        var decimalSeen = false
        var fraction = 0
        var count = 0
        for character in source {
            if let digit = character.wholeNumberValue, (0...9).contains(digit),
               character.unicodeScalars.count == 1,
               character.unicodeScalars.first?.properties.numericType == .decimal {
                digits += String(digit)
                count += 1
                if decimalSeen { fraction += 1 }
            } else if [".", ",", "．", "，", "٫", locale.decimalSeparator ?? "."].contains(String(character)),
                      !decimalSeen, scale > 0 {
                decimalSeen = true
                if digits.isEmpty || digits == "-" { digits += "0" }
                digits += "."
            } else if signed, digits.isEmpty, ["-", "−", "－"].contains(character) {
                digits = "-"
            } else {
                return nil
            }
        }
        guard count > 0, fraction <= scale,
              let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")),
              abs(value) <= maximum else { return nil }
        return value
    }

    static func text(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale.current)
    }
}

enum Platform: String, Codable, CaseIterable, Identifiable, Hashable {
    case ebay, vinted, poshmark, xianyu
    var id: String { rawValue }
    var titleKey: String { "platform." + rawValue }
    var currency: Currency { self == .xianyu ? .CNY : .USD }
    var checkedOn: String { "2026-11-23" }
    var source: String {
        switch self {
        case .ebay: return "https://www.ebay.com/help/selling/fees-credit-invoices/selling-fees?id=4822"
        case .vinted: return "https://www.vinted.com/help/14/26-selling-step-by-step"
        case .poshmark: return "https://poshmark.com/terms"
        case .xianyu: return "https://h5.m.goofish.com/wow/moyu/moyu-project/doc/pages/8b7AzFnc5pp2"
        }
    }
}

struct FeePreset: Codable, Equatable {
    enum Basis: String, Codable, CaseIterable, Hashable {
        case item, shipping, adjusted
        var titleKey: String { "basis." + rawValue }
    }

    var platform: Platform
    var currency: Currency
    var source: String
    var checkedOn: String
    var basis: Basis
    var rate: Decimal
    var orderFee: Decimal = 0
    var threshold: Decimal? = nil
    var alternateRate: Decimal? = nil
    var belowFee: Decimal? = nil
    var cap: Decimal? = nil

    static func standard(_ platform: Platform) -> FeePreset {
        var preset = FeePreset(platform: platform, currency: platform.currency, source: platform.source,
                               checkedOn: platform.checkedOn, basis: .item, rate: 0)
        switch platform {
        case .ebay:
            preset.basis = .adjusted
            preset.rate = Decimal(136) / 1000
            preset.threshold = 7_500
            preset.alternateRate = Decimal(235) / 10_000
            preset.orderFee = Decimal(4) / 10
            preset.belowFee = Decimal(3) / 10
        case .vinted:
            break
        case .poshmark:
            preset.rate = Decimal(20) / 100
            preset.threshold = 15
            preset.belowFee = Decimal(295) / 100
        case .xianyu:
            preset.basis = .shipping
            preset.rate = Decimal(6) / 1000
            preset.cap = 60
        }
        return preset
    }

    func fee(price: Decimal, buyerShipping: Decimal, extraBase: Decimal) -> Decimal {
        let base: Decimal
        switch basis {
        case .item: base = price
        case .shipping: base = price + buyerShipping
        case .adjusted: base = price + buyerShipping + extraBase
        }

        var fee = base * rate + orderFee
        switch platform {
        case .ebay:
            if let threshold, let alternateRate, base > threshold {
                fee = threshold * rate + (base - threshold) * alternateRate + orderFee
            }
            if base <= 10, let belowFee { fee += belowFee - orderFee }
        case .poshmark:
            if let threshold, base < threshold, let belowFee { fee = belowFee + orderFee }
        case .vinted, .xianyu:
            break
        }
        if let cap { fee = min(fee, cap) }
        return currency.round(fee)
    }

    var isValid: Bool {
        currency == platform.currency && !source.isEmpty && !checkedOn.isEmpty &&
        [rate, alternateRate ?? 0].allSatisfy { $0 >= 0 && $0 <= 1 && $0 == rounded($0, scale: 4) } &&
        [orderFee, threshold ?? 0, belowFee ?? 0, cap ?? 0].allSatisfy {
            $0 >= 0 && $0 <= currency.maximum && $0 == currency.round($0)
        }
    }
}

struct CalculationInput: Codable, Equatable {
    var currency: Currency
    var price: Decimal
    var buyerShipping: Decimal = 0
    var additionalFeeBase: Decimal = 0
    var sellerShipping: Decimal = 0
    var manualFee: Decimal = 0
    var preset: FeePreset? = nil
    var minutes: Int
    var threshold: Decimal
}

struct CalculationResult: Codable, Equatable {
    enum Recommendation: String, Codable { case sell, donate }
    enum ThresholdRelation: String, Codable { case below, near, met }

    var fee: Decimal
    var net: Decimal
    var hourly: Decimal
    var recommendation: Recommendation
    var relation: ThresholdRelation
}

enum Calculator {
    static func calculate(_ input: CalculationInput) -> CalculationResult? {
        let currency = input.currency
        guard (1...1440).contains(input.minutes),
              [input.price, input.buyerShipping, input.additionalFeeBase, input.sellerShipping,
               input.manualFee, input.threshold].allSatisfy({
                  $0 >= 0 && $0 <= currency.maximum && $0 == currency.round($0)
              }),
              input.preset.map({ $0.currency == currency && $0.isValid }) ?? true else { return nil }
        let fee = input.preset?.fee(price: input.price, buyerShipping: input.buyerShipping,
                                    extraBase: input.additionalFeeBase) ?? input.manualFee
        let net = currency.round(input.price + input.buyerShipping - fee - currency.round(input.sellerShipping))
        let weightedNet = net * 60
        let hours = currency.round(weightedNet / Decimal(input.minutes))
        let meets = weightedNet >= input.threshold * Decimal(input.minutes)
        return CalculationResult(fee: fee, net: net, hourly: hours,
            recommendation: net > 0 && meets ? .sell : .donate,
            relation: meets ? .met : (hours == input.threshold ? .near : .below))
    }
}

extension FeePreset {
    private enum CodingKeys: String, CodingKey {
        case platform, currency, source, checkedOn, basis, rate, orderFee, threshold, alternateRate, belowFee, cap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try c.decode(Currency.self, forKey: .currency)
        func rate(_ k: CodingKeys) throws -> Decimal? { try c.decodeIfPresent(Decimal.self, forKey: k).map { rounded($0, scale: 4) } }
        func money(_ k: CodingKeys) throws -> Decimal? { try c.decodeIfPresent(Decimal.self, forKey: k).map { currency.round($0) } }
        self.init(platform: try c.decode(Platform.self, forKey: .platform), currency: currency,
                  source: try c.decode(String.self, forKey: .source), checkedOn: try c.decode(String.self, forKey: .checkedOn),
                  basis: try c.decode(Basis.self, forKey: .basis), rate: try rate(.rate) ?? 0,
                  orderFee: try money(.orderFee) ?? 0, threshold: try money(.threshold),
                  alternateRate: try rate(.alternateRate), belowFee: try money(.belowFee), cap: try money(.cap))
    }
}
