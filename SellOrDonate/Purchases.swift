import Combine
import Foundation
import StoreKit

@MainActor
final class Purchases: ObservableObject {
    static let proID = "com.hgsldswk.sellordonate.pro"
    static let trialID = "com.hgsldswk.sellordonate.trial"

    @Published private(set) var access: Entitlement?
    @Published private(set) var now = Date()
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published var message: String?

    let free: Bool
    private let test: Bool
    private let disk: LocalDisk
    private var updates: Task<Void, Never>?
    private var lookup = 0
    private var accessRevision = 0

    init(disk: LocalDisk, test: Bool, arguments: [String]) {
        self.disk = disk
        self.test = test
        free = Launch.isFree(arguments: arguments)
    }

    var hasPro: Bool { access?.hasPro(at: max(now, Date()), free: free) ?? free }

    func start(expired: Bool) async {
        guard access == nil else { return }
        let now = Date()
        var cached = await disk.readAccess() ?? Entitlement(firstOpen: now)
        cached.open(at: now, free: free)
        if test && expired { cached.proStartedAt = now.addingTimeInterval(-31 * 86400) }
        await disk.saveAccess(cached, revision: nextAccessRevision())
        access = cached
        self.now = now
        guard !test, !free else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    await self?.apply(transaction)
                }
            }
        }
        Task { await refresh() }
    }

    func tick() {
        guard var current = access else { return }
        now = Date()
        current.open(at: now, free: free)
        access = current
        let revision = nextAccessRevision()
        Task { await disk.saveAccess(current, revision: revision) }
    }

    var uiTestPrice: String? { test ? Currency.USD.money(Decimal(299) / 100) : nil }

    private func nextAccessRevision() -> Int {
        accessRevision += 1
        return accessRevision
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func load() async {
        guard !free, !test, !loading, products.count != 2 else { return }
        loading = true
        defer { loading = false }
        do {
            products = try await Product.products(for: [Self.proID, Self.trialID])
                .filter { $0.type == .nonConsumable }
            if products.count != 2 { message = L.t("purchase.loadError") }
        } catch {
            message = L.t("purchase.loadError")
        }
    }

    func buy(_ id: String) async {
        guard !busy, !test, !free, let product = product(id) else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = L.t("purchase.verifyError")
                    return
                }
                await apply(transaction)
            case .pending: message = L.t("purchase.pending")
            case .userCancelled: break
            @unknown default: message = L.t("purchase.error")
            }
        } catch {
            message = L.t("purchase.error")
        }
    }

    func restore() async {
        guard !busy, !test, !free else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh(explicit: true)
            message = access?.purchasedPro == true || access?.trialClaimedAt != nil
                ? L.t("purchase.restored") : L.t("purchase.noPurchases")
        } catch {
            message = L.t("purchase.restoreError")
        }
    }

    private func apply(_ transaction: StoreKit.Transaction) async {
        guard var current = access, [Self.proID, Self.trialID].contains(transaction.productID) else { return }
        lookup += 1
        if transaction.productID == Self.proID {
            current.purchasedPro = transaction.revocationDate == nil
        } else if transaction.revocationDate == nil {
            current.applyTrialReceipt(originalDate: transaction.originalPurchaseDate)
        }
        current.open(at: Date(), free: free)
        access = current
        await disk.saveAccess(current, revision: nextAccessRevision())
        await transaction.finish()
        await refresh()
    }

    private func refresh(explicit: Bool = false) async {
        lookup += 1
        let generation = lookup
        var pro = false
        var trial: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.proID { pro = true }
            if transaction.productID == Self.trialID {
                trial = min(transaction.originalPurchaseDate, trial ?? transaction.originalPurchaseDate)
            }
        }
        var revoked = false
        if !pro, case .verified(let latest)? = await StoreKit.Transaction.latest(for: Self.proID) {
            revoked = latest.revocationDate != nil
        }
        guard generation == lookup, var current = access else { return }
        if pro || revoked || explicit { current.purchasedPro = pro }
        if let trial { current.applyTrialReceipt(originalDate: trial) }
        current.open(at: Date(), free: free)
        access = current
        await disk.saveAccess(current, revision: nextAccessRevision())
    }
}
