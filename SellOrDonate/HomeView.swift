import SwiftUI
import StoreKit

@MainActor
struct HomeView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var purchases: Purchases
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focus: Field?
    @State private var showingList = false
    @State private var page: Page?
    @State private var earliestReview = Date()
    @State private var loadedPaywall = false

    private enum Field: String, CaseIterable, Hashable {
        case price, fee, shipping, minutes, threshold
        var title: String { L.t("field." + rawValue) }
    }

    private enum Page: String, Identifiable {
        case presets, fees, importCode, paywall
        var id: String { rawValue }
    }

    private var draft: CalculationDraft { workspace.state.draft }
    private var result: CalculationResult? { draft.input.flatMap(Calculator.calculate) }

    var body: some View {
        NavigationStack {
            Group {
                if workspace.ready && purchases.access != nil {
                    calculator
                } else if let error = workspace.error {
                    VStack(spacing: 12) {
                        Text(error)
                        Button(L.t("action.retry")) { Task { await workspace.load() } }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("storage.retry")
                    }
                    .padding(20)
                } else {
                    ProgressView().accessibilityLabel(L.t("storage.loading"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingList) {
                SessionView(workspace: workspace, purchases: purchases)
            }
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accentText)
        .sheet(item: $page, onDismiss: deferReview) { value in
            switch value {
            case .presets: PresetView(workspace: workspace, purchases: purchases)
            case .fees: FeeDetailsView(workspace: workspace)
            case .importCode: ImportView(workspace: workspace, purchases: purchases)
            case .paywall: PaywallView(purchases: purchases)
            }
        }
        .task {
            let flags = ProcessInfo.processInfo.arguments
            async let work: Void = workspace.load()
            await purchases.start(expired: flags.contains("-expired"))
            await work
            if workspace.test, flags.contains("-paywall"), !loadedPaywall {
                loadedPaywall = true
                page = .paywall
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if scenePhase == .active { purchases.tick() }
            }
        }
        .task(id: needsFeeConversion) {
            if needsFeeConversion {
                _ = await workspace.commit { state in
                    state.reuseFeeValues()
                    return true
                }
            }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active { purchases.tick() }
            else { Task { await workspace.flushDraft() } }
        }
        .onChange(of: showingList) { _, _ in deferReview() }
        .onChange(of: focus) { _, _ in deferReview() }
        .task(id: ReviewTrigger(eligible: mayReview, after: earliestReview)) { await reviewIfReady() }
    }

    private var calculator: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    resultCard
                    field(.price, currency: draft.currency.rawValue)
                    if typeSize.isAccessibilitySize {
                        field(.fee)
                        field(.shipping)
                        field(.minutes, currency: L.t("unit.minutes"))
                        field(.threshold, currency: L.t("unit.hour"))
                    } else {
                        HStack(spacing: 8) { field(.fee); field(.shipping) }
                        HStack(spacing: 8) { field(.minutes, currency: L.t("unit.minutes")); field(.threshold, currency: L.t("unit.hour")) }
                    }
                    HStack(alignment: .center) {
                        Caption(L.t(result == nil ? "home.timeHelp" : "home.choiceHelp"))
                        Spacer()
                        Button(L.t("fee.details")) { open(.fees) }
                            .buttonStyle(QuietStyle()).accessibilityIdentifier("home.feeDetails")
                    }
                    if focus == nil { addButtons }
                    if workspace.canUndoInCurrentSession() {
                        Button(L.t("action.undo")) {
                            deferReview()
                            Task { await workspace.undoLast() }
                        }
                            .buttonStyle(QuietStyle()).accessibilityIdentifier("home.undo")
                    }
                    if workspace.state.parked[draft.currency.rawValue] != nil {
                        Button(L.t("home.restoreDraft")) {
                            Task { _ = await workspace.commit { $0.restoreParkedDraft() } }
                        }.buttonStyle(QuietStyle()).accessibilityIdentifier("home.restoreDraft")
                    }
                    if let error = workspace.error { Caption(error).accessibilityIdentifier("home.error") }
                    tools
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let active = focus { keyboardBar(active) }
        }
    }

    private var header: some View {
        HStack {
            Text(L.t("app.name"))
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 10)
            Button(L.t("session.list")) {
                focus = nil
                showingList = true
            }
            .buttonStyle(QuietStyle())
            .accessibilityIdentifier("home.list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .frame(maxWidth: 560)
    }

    private var recommendation: String {
        guard let result else { return L.t(draft.price.isEmpty ? "home.enterPrice" : "home.checkFields") }
        return L.t(result.recommendation == .sell ? "recommend.sell" : "recommend.donate")
    }

    private var explanation: String {
        guard let result else {
            return L.f("home.thresholdNote", draft.currency.money(draft.amount(draft.threshold) ?? draft.currency.defaultThreshold))
        }
        if result.net <= 0 { return L.t("result.noNet") }
        return L.f("result." + result.relation.rawValue, draft.currency.money(draft.amount(draft.threshold) ?? 0))
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(L.t("home.recommendation"))
            Text(recommendation)
                .font(result == nil ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                .accessibilityIdentifier("home.recommendation")
                .accessibilityAddTraits(.isHeader)
            Caption(explanation)
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 12) {
                metric(L.t("result.net"), value: result.map { draft.currency.money($0.net) }, id: "home.net")
                metric(L.t("result.hourly"), value: result.map {
                    L.f("format.hourly", draft.currency.money($0.hourly))
                }, id: "home.hourly")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .panel(tinted: true)
    }

    private func metric(_ title: String, value: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Caption(title)
            Text(value ?? L.t("value.empty")).font(.title3.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.72).accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ field: Field, currency: String? = nil) -> some View {
        let title = currency.map { L.f("field.withUnit", field.title, $0) } ?? field.title
        let font = (field == .price ? Font.title2 : .body).weight(.semibold).monospacedDigit()
        return VStack(alignment: .leading, spacing: 1) {
            Caption(field == .price ? title : field.title)
            HStack(spacing: 4) {
                if field != .minutes {
                    Text(draft.currency.symbol).font(font).accessibilityHidden(true)
                }
                TextField(field == .price ? L.t("home.amountPlaceholder") : field.title, text: binding(field))
                    .font(font)
                    .keyboardType(field == .minutes ? .numberPad : .decimalPad)
                    .focused($focus, equals: field)
                    .frame(minHeight: 44)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("field." + field.rawValue)
                if field == .minutes || field == .threshold, let currency {
                    Caption(currency).accessibilityHidden(true)
                }
                if field == .fee, let preset = draft.preset {
                    Caption(L.t(preset.platform.titleKey))
                }
            }
            if invalid(field) { Caption(L.t(field == .minutes ? "error.minutes" : "error.amount")) }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: field == .price ? 66 : 55, alignment: .leading)
        .panel()
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(field == .price || focus == field ? Palette.accent : Color.clear)
            .allowsHitTesting(false))
    }

    private func binding(_ field: Field) -> Binding<String> {
        Binding {
            switch field {
            case .price: return draft.price
            case .fee:
                if let preset = draft.preset {
                    return NumberInput.text(preset.fee(price: draft.amount(draft.price) ?? 0,
                        buyerShipping: draft.amount(draft.buyerShipping) ?? 0, extraBase: draft.amount(draft.extraBase) ?? 0))
                }
                return draft.fee
            case .shipping: return draft.shipping
            case .minutes: return draft.minutes
            case .threshold: return draft.threshold
            }
        } set: { value in
            workspace.changeDraft { draft in
                switch field {
                case .price: draft.price = value
                case .fee: draft.preset = nil; draft.fee = value
                case .shipping: draft.shipping = value
                case .minutes: draft.minutes = value
                case .threshold: draft.threshold = value
                }
            }
        }
    }

    private func invalid(_ field: Field) -> Bool {
        switch field {
        case .price: return !draft.price.isEmpty && draft.amount(draft.price) == nil
        case .fee: return draft.preset == nil && draft.amount(draft.fee) == nil
        case .shipping: return draft.amount(draft.shipping) == nil
        case .minutes: return draft.duration == nil
        case .threshold: return draft.amount(draft.threshold) == nil
        }
    }

    private var addButtons: some View {
        HStack(spacing: 8) {
            addButton(.sell, key: "home.addSell", recommendation: .sell)
            addButton(.donate, key: "home.addDonate", recommendation: .donate)
        }
    }

    private func addButton(_ destination: Destination, key: String,
                           recommendation: CalculationResult.Recommendation) -> some View {
        let id = draft.id
        return Button(L.t(key)) {
            Task {
                if await workspace.add(destination, id: id) { focus = .price }
            }
        }
        .buttonStyle(ActionStyle(filled: result?.recommendation == recommendation))
        .disabled(result == nil || workspace.busy)
        .accessibilityIdentifier(destination == .sell ? "home.addSell" : "home.addDonate")
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(L.t("presets.title")) { open(.presets) }
                    .accessibilityIdentifier("home.presets")
                Spacer(minLength: 6)
                Button(L.t("import.title")) { open(.importCode) }
                    .accessibilityIdentifier("home.import")
            }
            if !purchases.free && purchases.access?.purchasedPro != true {
                Button(L.t("purchase.title")) { open(.paywall) }.accessibilityIdentifier("home.paywall")
            }
        }
        .buttonStyle(QuietStyle())
    }

    private func keyboardBar(_ field: Field) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text(result.map { _ in L.f("home.keyboardResult", recommendation) } ?? recommendation)
                    .font(.footnote.weight(.semibold)).foregroundStyle(Palette.accentText)
                    .accessibilityIdentifier("home.keyboardResult")
                Spacer(minLength: 0)
                if let index = Field.allCases.firstIndex(of: field), index + 1 < Field.allCases.count {
                    Button(L.t("action.next")) { focus = Field.allCases[index + 1] }
                        .accessibilityIdentifier("keyboard.next")
                }
                Button(L.t("action.done")) { focus = nil }.accessibilityIdentifier("keyboard.done")
            }
            if result != nil { addButtons.padding(.bottom, 6) }
        }
        .padding(.horizontal, 15)
        .buttonStyle(QuietStyle())
        .background(.regularMaterial)
    }

    private func open(_ target: Page) {
        focus = nil
        page = target
        deferReview()
    }

    private func deferReview() { earliestReview = Date().addingTimeInterval(4) }

    private struct ReviewTrigger: Equatable {
        var eligible: Bool
        var after: Date
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    private var needsFeeConversion: Bool {
        workspace.ready && purchases.access != nil && !purchases.hasPro &&
            !workspace.busy && workspace.error == nil && workspace.state.hasReusablePresets
    }

    private var mayReview: Bool {
        workspace.ready && purchases.access != nil && !workspace.test && !workspace.busy &&
        workspace.error == nil && !showingList && page == nil && focus == nil && scenePhase == .active &&
        workspace.state.review.canRequest(version: version, now: Date(), items: workspace.state.allItems)
    }

    private func reviewIfReady() async {
        guard mayReview else { return }
        let delay = max(2, earliestReview.timeIntervalSinceNow)
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard mayReview, !Task.isCancelled else { return }
        let version = version
        if await workspace.commit({ state in
            state.review = ReviewHistory(version: version, date: Date())
            return true
        }), focus == nil, page == nil, !showingList, scenePhase == .active {
            requestReview()
        }
    }
}
