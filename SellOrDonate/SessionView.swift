import SwiftUI

@MainActor
struct SessionView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var purchases: Purchases
    var archivedID: UUID? = nil

    @State private var filter: Destination?
    @State private var editor: ItemEditor.Request?
    @State private var routeItem: DecisionItem?
    @State private var showingRoutes = false
    @State private var showHistory = false
    @State private var showTrip = false
    @State private var showPaywall = false
    @State private var share: ShareChoice?
    @State private var attachment: ActivityPayload?
    @State private var milestoneNotice: Int?

    private var milestoneCount: Int {
        Set(workspace.state.allItems.filter { $0.status.soldOrDonated }.map(\.id)).count
    }
    private var archived: Bool { archivedID != nil }
    private var session: DeclutterSession {
        guard let archivedID else { return workspace.state.current }
        return workspace.state.past.first { $0.id == archivedID } ?? DeclutterSession()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                SessionTotals(summary: session.summary, heading: L.t("session.completed"))
                    .accessibilityIdentifier("session.summary")
                if !archived { quickActions }
                filters
                if visibleItems.isEmpty { Caption(L.t("session.empty")).padding(.vertical, 15) }
                ForEach(visibleItems) { item in row(item) }
                if !archived { secondaryActions }
                if let error = workspace.error { Caption(error) }
                if workspace.shareRequested {
                    Text(L.t("share.requested")).accessibilityIdentifier("share.requested")
                }
            }
            .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle(L.t(archived ? "session.archived" : "session.current"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L.t("session.csv")) {
                    let selected = session
                    Task {
                        if let payload = await workspace.exportCSV(selected) { attachment = payload }
                    }
                }
                .disabled(session.items.isEmpty || workspace.exportingCSV)
                .accessibilityIdentifier("session.csv")
            }
        }
        .onAppear {
            workspace.shareRequested = false
            announce(workspace.state.unlockedMilestones)
        }
        .onChange(of: workspace.state.unlockedMilestones) { _, values in announce(values) }
        .onChange(of: workspace.busy) { _, busy in
            if !busy && workspace.error == nil { announce(workspace.state.unlockedMilestones) }
        }
        .onChange(of: milestoneCount) { _, _ in announce(workspace.state.unlockedMilestones) }
        .onChange(of: purchases.hasPro) { _, _ in announce(workspace.state.unlockedMilestones) }
        .sheet(item: $editor) { request in
            ItemEditor(request: request) { changes in
                await save(changes, id: request.item.id)
            }
        }
        .sheet(isPresented: $showTrip) {
            DonationTripView(items: session.items.filter { $0.status == .donate }) { allocations in
                let now = workspace.completionTime
                return await workspace.commit { state in
                    guard allocations.keys.allSatisfy({ id in
                        state.current.items.contains { $0.id == id && $0.status == .donate }
                    }) else { return false }
                    for index in state.current.items.indices {
                        let id = state.current.items[index].id
                        guard let minutes = allocations[id] else { continue }
                        let invested = state.current.items[index].investedMinutes
                        if state.current.items[index].update(.donated, invested: invested, donated: minutes, now: now) {
                            state.recordCompletion(id)
                        }
                    }
                    return true
                }
            }
        }
        .sheet(item: $share) { selection in
            SharePreview(workspace: workspace, purchases: purchases, choice: selection)
        }
        .sheet(item: $attachment) { payload in ActivitySheet(items: payload.items) }
        .sheet(isPresented: $showPaywall) { PaywallView(purchases: purchases) }
        .navigationDestination(isPresented: $showHistory) { HistoryView(workspace: workspace, purchases: purchases) }
    }

    private var visibleItems: [DecisionItem] {
        if let filter { return session.items.filter { $0.status == filter } }
        return session.items
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.hasCompletedItems {
                Button(L.t("share.results")) { share = ShareChoice(session: session, milestone: nil) }
                    .buttonStyle(ActionStyle(filled: true)).accessibilityIdentifier("session.share")
            }
            let milestones = LocalState.milestones.filter {
                workspace.state.unlockedMilestones.contains($0) && milestoneCount >= $0 && ($0 == 10 || purchases.hasPro)
            }
            if let milestoneNotice, milestones.contains(milestoneNotice) {
                Caption(L.f("milestone.reached", String(milestoneNotice))).accessibilityIdentifier("session.milestoneNotice")
            }
            if !milestones.isEmpty {
                HStack(spacing: 8) {
                    ForEach(milestones, id: \.self) { count in
                        Button(L.f("milestone.button", String(count))) {
                            var total = session
                            total.items = workspace.state.allItems
                            share = ShareChoice(session: total, milestone: count)
                        }
                        .buttonStyle(ActionStyle())
                        .accessibilityIdentifier("session.milestone.\(count)")
                    }
                }
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterButton(nil, key: "session.all", id: "all")
                ForEach(Destination.allCases, id: \.rawValue) { value in
                    filterButton(value, key: value.titleKey, id: value.rawValue)
                }
            }
        }
    }

    private func filterButton(_ value: Destination?, key: String, id: String) -> some View {
        Button(L.t(key)) { filter = value }
            .buttonStyle(ActionStyle(filled: filter == value))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(filter == value ? .isSelected : [])
            .accessibilityIdentifier("session.filter." + id)
    }

    private func row(_ item: DecisionItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayName).font(.headline).accessibilityIdentifier("item.name.\(item.ordinal)")
                Spacer(minLength: 8)
                Caption(L.t(item.status.titleKey))
                    .accessibilityIdentifier("item.status.\(item.ordinal)")
            }
            Caption(L.f("item.estimate", item.input.currency.money(item.estimate.net), String(item.input.minutes)))
            if let actual = item.actualNet { Caption(L.f("item.received", item.input.currency.money(actual))) }
            if let minutes = item.savedMinutes { Caption(L.f("item.saved", durationText(minutes))) }
            if let date = item.completedAt {
                Caption(date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityIdentifier("item.date.\(item.ordinal)")
            }
            if !archived { rowActions(item) }
        }.padding(.horizontal, 12).padding(.top, 11).padding(.bottom, archived ? 11 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
    }

    private func rowActions(_ item: DecisionItem) -> some View {
        HStack(spacing: 8) {
            Button(L.t("item.route")) {
                routeItem = item
                showingRoutes = true
            }
            .accessibilityIdentifier("item.route.\(item.ordinal)")
            .confirmationDialog(L.t("item.route"), isPresented: Binding(
                get: { showingRoutes && routeItem?.id == item.id },
                set: { if !$0, routeItem?.id == item.id { showingRoutes = false } })) {
                routeButtons(item)
            }
            if item.status == .sell || item.status == .sold {
                editButton(item.status == .sell ? "item.recordSale" : "item.editSale", item: item, mode: .sale)
            }
            if item.status == .donate || item.status == .donated {
                editButton(item.status == .donate ? "item.markDonated" : "item.editDonation", item: item, mode: .donation)
            }
            Menu {
                Button(L.t("item.rename")) { editor = ItemEditor.Request(item: item, mode: .name) }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle()).accessibilityLabel(L.t("item.more"))
            }.accessibilityIdentifier("item.more.\(item.ordinal)")
        }.buttonStyle(QuietStyle())
    }

    @ViewBuilder private func routeButtons(_ item: DecisionItem) -> some View {
        if item.status != .sell { routeButton(.sell, key: "item.moveSell", item: item) }
        if item.status != .donate { routeButton(.donate, key: "item.moveDonate", item: item) }
        if item.status != .sold { editButton("status.sold", item: item, mode: .sale) }
        if item.status != .donated { editButton("status.donated", item: item, mode: .donation) }
        if item.status != .discarded { routeButton(.discarded, key: "status.discarded", item: item) }
    }

    private func routeButton(_ status: Destination, key: String, item: DecisionItem) -> some View {
        Button(L.t(key)) {
            Task {
                let now = workspace.completionTime
                _ = await workspace.commit { state in
                    guard let index = state.current.items.firstIndex(where: { $0.id == item.id }),
                          state.current.items[index].status == item.status else { return false }
                    let invested = state.current.items[index].investedMinutes
                    return state.current.items[index].update(status, invested: invested, now: now)
                }
            }
        }.accessibilityIdentifier("item.move." + status.rawValue)
    }

    private func editButton(_ key: String, item: DecisionItem, mode: ItemEditor.Mode) -> some View {
        Button(L.t(key)) { editor = ItemEditor.Request(item: item, mode: mode) }
            .accessibilityIdentifier("item.\(mode.rawValue).\(item.ordinal)")
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 3) {
            if session.items.filter({ $0.status == .donate }).count > 1 {
                Button(L.t("trip.title")) { showTrip = true }.accessibilityIdentifier("session.trip")
            }
            HStack {
                Button(L.t("session.history")) { showHistory = true }.accessibilityIdentifier("session.history")
                Spacer()
                Button(L.t("session.new")) {
                    guard purchases.hasPro else { showPaywall = true; return }
                    Task {
                        if await workspace.commit({ $0.startSession(); return true }) { filter = nil }
                    }
                }
                .disabled(session.items.isEmpty)
                .accessibilityIdentifier("session.new")
            }
        }.buttonStyle(QuietStyle())
    }

    private func announce(_ values: Set<Int>) {
        let unseen = values.subtracting(workspace.state.announcedMilestones)
            .filter { milestoneCount >= $0 && ($0 == 10 || purchases.hasPro) }
        guard let newest = unseen.max(), !archived, !workspace.busy, workspace.error == nil else { return }
        Task {
            if await workspace.commit({ state in
                let pending = unseen.subtracting(state.announcedMilestones)
                guard !pending.isEmpty else { return false }
                state.announcedMilestones.formUnion(pending)
                return true
            }) { milestoneNotice = newest }
        }
    }

    private func save(_ changes: ItemEditor.Changes, id: UUID) async -> Bool {
        let now = workspace.completionTime
        return await workspace.commit { state in
            guard let index = state.current.items.firstIndex(where: { $0.id == id }) else { return false }
            switch changes {
            case .name(let name):
                state.current.items[index].name = name
                return true
            case .sale(let actual):
                guard state.current.items[index].update(.sold, actual: actual, now: now) else { return false }
            case .donation(let invested, let donated):
                guard state.current.items[index].update(.donated, invested: invested, donated: donated, now: now) else { return false }
            }
            state.recordCompletion(id)
            return true
        }
    }
}

func durationText(_ minutes: Int) -> String {
    if minutes < 60 { return L.f("format.minutes", String(minutes)) }
    let hours = rounded(Decimal(minutes) / 60, scale: 1)
    return L.f("format.hours", NumberInput.text(hours))
}

@MainActor
private struct HistoryView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var purchases: Purchases
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var attachment: ActivityPayload?

    private var rowLayout: AnyLayout {
        if typeSize.isAccessibilitySize { return AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) }
        return AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if purchases.hasPro && !workspace.state.past.isEmpty {
                    SessionTotals(summary: SessionSummary(items: workspace.state.allItems),
                                  heading: L.t("session.allLists"))
                        .accessibilityIdentifier("history.totals")
                }
                if workspace.state.past.isEmpty { Caption(L.t("session.noHistory")) }
                ForEach(workspace.state.past) { past in
                    rowLayout {
                        NavigationLink {
                            SessionView(workspace: workspace, purchases: purchases, archivedID: past.id)
                        } label: {
                            HStack {
                                Text(past.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Spacer(minLength: 4)
                                Caption(L.f("session.itemCount", String(past.items.count)))
                                Image(systemName: "chevron.right")
                            }
                            .frame(minHeight: 44)
                        }.accessibilityIdentifier("history.session")
                        Button(L.t("session.csv")) {
                            Task {
                                if let payload = await workspace.exportCSV(past) { attachment = payload }
                            }
                        }
                        .buttonStyle(QuietStyle())
                        .disabled(past.items.isEmpty || workspace.exportingCSV)
                        .accessibilityIdentifier("history.csv")
                    }.padding(9).panel()
                }
                if let error = workspace.error { Caption(error) }
                if workspace.shareRequested {
                    Text(L.t("share.requested")).accessibilityIdentifier("share.requested")
                }
            }.padding(20)
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle(L.t("session.history"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $attachment) { payload in ActivitySheet(items: payload.items) }
    }
}

private struct SessionTotals: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let summary: SessionSummary
    let heading: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { counts }
            } else {
                HStack(alignment: .top, spacing: 10) { counts }
            }
            statistic(L.t("session.savedTime"), value: durationText(summary.savedMinutes))
            ForEach(summary.income.keys.sorted { $0.rawValue < $1.rawValue }) { currency in
                HStack {
                    Caption(L.f("session.incomeCurrency", currency.rawValue))
                    Spacer()
                    Text(currency.money(summary.income[currency, default: 0]))
                        .font(.body.weight(.semibold).monospacedDigit())
                }
            }
            if summary.missingDonationTime > 0 {
                Caption(L.f("session.missingTime", String(summary.missingDonationTime)))
            }
        }.padding(14).panel(tinted: true)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var counts: some View {
        statistic(L.t("status.sold"), value: String(summary.sold))
        statistic(L.t("status.donated"), value: String(summary.donated))
        statistic(L.t("status.discarded"), value: String(summary.discarded))
    }

    private func statistic(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(label)
            Text(value).font(.title3.weight(.bold).monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
