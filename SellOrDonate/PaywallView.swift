import SwiftUI

@MainActor
struct PaywallView: View {
    @ObservedObject var purchases: Purchases

    var body: some View {
        SheetFrame(title: L.t("purchase.title")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.t("purchase.headline")).font(.largeTitle.weight(.bold))
                            .accessibilityIdentifier("paywall.title")
                        Text(status).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(15).panel(tinted: true)
                    VStack(alignment: .leading, spacing: 11) {
                        Label(L.t("purchase.platforms"), systemImage: "slider.horizontal.3")
                        Label(L.t("purchase.sessions"), systemImage: "tray.full")
                        Label(L.t("purchase.cards"), systemImage: "photo.on.rectangle")
                    }
                    .padding(.vertical, 2)
                    Caption(L.t("purchase.kept"))
                    Caption(L.t("purchase.noRenewal"))
                    if let message = purchases.message { Caption(message).accessibilityIdentifier("paywall.message") }
                    if !purchases.free && purchases.access?.purchasedPro != true {
                        buyButtons
                    }
                }.padding(20)
            }
        }.task { await purchases.load() }
    }

    private var status: String {
        guard let access = purchases.access else { return L.t("storage.loading") }
        if access.purchasedPro || purchases.free { return L.t("purchase.unlocked") }
        if !purchases.hasPro { return L.t("purchase.expired") }
        let seconds = access.trialEnd.timeIntervalSince(access.effectiveNow(purchases.now))
        let days = max(1, Int(ceil(seconds / 86400)))
        return L.f("purchase.remaining", String(days))
    }

    private var buyButtons: some View {
        VStack(spacing: 4) {
            Button(buttonTitle) {
                Task { await purchases.buy(Purchases.proID) }
            }
            .buttonStyle(ActionStyle(filled: true))
            .disabled(purchases.busy || purchases.product(Purchases.proID) == nil)
            .accessibilityIdentifier("paywall.buy")
            if purchases.access?.trialClaimedAt == nil && purchases.hasPro {
                Button(L.t("purchase.claim")) { Task { await purchases.buy(Purchases.trialID) } }
                    .buttonStyle(QuietStyle())
                    .disabled(purchases.busy || purchases.product(Purchases.trialID) == nil)
                    .accessibilityIdentifier("paywall.trial")
            }
            Button(L.t("purchase.restore")) { Task { await purchases.restore() } }
                .buttonStyle(QuietStyle()).disabled(purchases.busy)
                .accessibilityIdentifier("paywall.restore")
            if !purchases.loading && !purchases.busy && purchases.product(Purchases.proID) == nil && purchases.message != nil {
                Button(L.t("action.retry")) { Task { await purchases.load() } }
                    .buttonStyle(QuietStyle()).accessibilityIdentifier("paywall.retry")
            }
        }
    }

    private var buttonTitle: String {
        if let price = purchases.product(Purchases.proID)?.displayPrice ?? purchases.uiTestPrice { return L.f("purchase.buy", price) }
        return L.t(purchases.loading ? "storage.loading" : "purchase.oneTime")
    }
}
