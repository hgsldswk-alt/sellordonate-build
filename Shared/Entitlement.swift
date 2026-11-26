import Foundation

struct Entitlement: Codable, Equatable {
    static let trialDuration: TimeInterval = 30 * 86400

    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var lastSeen: Date?

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialClaimedAt ?? local)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(Self.trialDuration) }

    func effectiveNow(_ now: Date) -> Date { max(now, lastSeen ?? now, trialStart) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || effectiveNow(now) < trialEnd
    }

    mutating func open(at now: Date, free: Bool) {
        if !free, proStartedAt == nil { proStartedAt = now }
        lastSeen = max(now, lastSeen ?? now)
    }

    mutating func applyTrialReceipt(originalDate: Date) {
        trialClaimedAt = min(originalDate, trialClaimedAt ?? originalDate)
    }
}
