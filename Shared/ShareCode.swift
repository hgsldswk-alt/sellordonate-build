import Foundation

struct ShareSettings: Codable, Equatable {
    var version = 1
    var currency: Currency
    var threshold: Decimal
    var minutes: Int
    var template: Template?

    struct Template: Codable, Equatable {
        var platform: Platform
        var basis: FeePreset.Basis
        var rate: Decimal
        var orderFee: Decimal

        init(_ preset: FeePreset) {
            platform = preset.platform
            basis = preset.basis
            rate = preset.rate
            orderFee = preset.orderFee
        }

        var preset: FeePreset {
            var result = FeePreset.standard(platform)
            result.basis = basis
            result.rate = rate
            result.orderFee = orderFee
            return result
        }
    }

    var isValid: Bool {
        version == 1 && threshold >= 0 && threshold <= currency.maximum &&
        threshold == currency.round(threshold) && (1...1440).contains(minutes) &&
        (template.map { $0.preset.currency == currency && $0.preset.isValid } ?? true)
    }

    init(currency: Currency, threshold: Decimal, minutes: Int, template: Template? = nil) {
        self.currency = currency
        self.threshold = threshold
        self.minutes = minutes
        self.template = template
    }
}

enum ShareCode {
    enum Failure: Error { case invalid }
    static let maximumBytes = 2048

    static func encode(_ settings: ShareSettings) throws -> String {
        guard settings.isValid else { throw Failure.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "SD1:" + (try encoder.encode(settings)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) throws -> ShareSettings {
        guard text.utf8.count <= maximumBytes else { throw Failure.invalid }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("SD1:") else { throw Failure.invalid }
        let payload = code.dropFirst(4)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        guard !payload.isEmpty, payload.allSatisfy({ alphabet.contains($0) }) else { throw Failure.invalid }
        let base = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base + String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "currency", "threshold", "minutes", "template"]) else {
            throw Failure.invalid
        }
        if let template = object["template"], !(template is NSNull) {
            guard let fields = template as? [String: Any],
                  Set(fields.keys) == ["platform", "basis", "rate", "orderFee"] else { throw Failure.invalid }
        }
        let settings = try JSONDecoder().decode(ShareSettings.self, from: data)
        guard settings.isValid else { throw Failure.invalid }
        return settings
    }
}
