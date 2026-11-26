import SwiftUI

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var state: LocalState
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var exportingCSV = false
    @Published var error: String?
    @Published var shareRequested = false

    let test: Bool
    let disk: LocalDisk
    private let args: [String]
    private var revision = 0
    private var lastDraftWrite: Task<Void, Never>?
    @Published private var undo: Undo?

    private enum Undo {
        case added(DeclutterSession.ID, DecisionItem.ID, CalculationDraft)
        case imported(CalculationDraft, [String: [CalculationDraft]], [String: CalculationDraft]?)
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        args = arguments
        test = arguments.contains("-ui-testing")
        disk = LocalDisk(test: test)
        state = LocalState()
    }

    func load() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await disk.load(reset: args.contains("-reset")) ?? LocalState()
            if test { applyFixtures() }
            error = nil
            ready = true
        } catch {
            self.error = L.t("error.read")
        }
    }

    func changeDraft(_ change: (inout CalculationDraft) -> Void) {
        guard ready, !busy else { return }
        change(&state.draft)
        let snapshot = state
        let currentRevision = nextRevision()
        lastDraftWrite = Task {
            do {
                try await disk.save(snapshot, revision: currentRevision)
                if currentRevision == revision { self.error = nil }
            } catch {
                if currentRevision == revision { self.error = L.t("error.write") }
            }
        }
    }

    func flushDraft() async { await lastDraftWrite?.value }

    func exportCSV(_ session: DeclutterSession) async -> ActivityPayload? {
        guard !exportingCSV else { return nil }
        exportingCSV = true
        defer { exportingCSV = false }
        shareRequested = false
        do {
            let bytes = await Task.detached { Data(CSVExport.contents(session).utf8) }.value
            let url = try await disk.export(bytes, filename: "declutter.csv")
            if test {
                shareRequested = true
                return nil
            }
            return ActivityPayload(items: [url])
        } catch {
            self.error = L.t("error.export")
            return nil
        }
    }

    var completionTime: Date {
        if test, let seconds = Launch.value("-example-time", in: args).flatMap(Double.init), seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return Date()
    }

    func commit(_ change: (inout LocalState) -> Bool) async -> Bool {
        guard ready, !busy else { return false }
        var next = state
        guard change(&next) else { return false }
        busy = true
        defer { busy = false }
        do {
            try await disk.save(next, revision: nextRevision())
            state = next
            error = nil
            return true
        } catch {
            self.error = L.t("error.write")
            return false
        }
    }

    func add(_ destination: Destination, id: UUID) async -> Bool {
        let draft = state.draft
        let session = state.current.id
        guard await commit({ $0.add(id: id, to: destination) }) else { return false }
        undo = .added(session, id, draft)
        return true
    }

    func apply(_ settings: ShareSettings, premium: Bool) async -> Bool {
        let previous = state.draft
        let parked = state.parked
        let defaults = state.defaultsByCurrency
        guard await commit({ state in
            state.changeCurrency(settings.currency, empty: true)
            state.draft.threshold = NumberInput.text(settings.threshold)
            state.draft.minutes = String(settings.minutes)
            if let template = settings.template {
                if premium {
                    state.draft.preset = template.preset
                } else {
                    let price = state.draft.amount(state.draft.price) ?? 0
                    let buyer = state.draft.amount(state.draft.buyerShipping) ?? 0
                    let extra = state.draft.amount(state.draft.extraBase) ?? 0
                    state.draft.preset = nil
                    let fee = template.preset.fee(price: price, buyerShipping: buyer, extraBase: extra)
                    state.draft.fee = NumberInput.text(min(fee, state.draft.currency.maximum))
                }
            }
            return true
        }) else { return false }
        undo = .imported(previous, parked, defaults)
        return true
    }

    func undoLast() async {
        guard let undo else { return }
        let applied = await commit { state in
            switch undo {
            case .added(let session, let id, let previous):
                guard state.current.id == session,
                      let index = state.current.items.firstIndex(where: { $0.id == id && !$0.status.completed }) else {
                    return false
                }
                state.current.items.remove(at: index)
                if state.draft.currency == previous.currency, state.draft.price.isEmpty {
                    state.draft = previous
                } else {
                    state.park(previous)
                }
            case .imported(let previous, let parked, let defaults):
                if !state.draft.price.isEmpty &&
                    (state.draft.currency != previous.currency || state.draft.price != previous.price) {
                    let changed = state.draft
                    state.parked = parked
                    state.park(changed)
                } else {
                    state.parked = parked
                }
                state.defaultsByCurrency = defaults
                state.draft = previous
            }
            return true
        }
        if applied { self.undo = nil }
    }

    func canUndoInCurrentSession() -> Bool {
        switch undo {
        case .added(let session, let item, _):
            return session == state.current.id && state.current.items.contains { $0.id == item && !$0.status.completed }
        case .imported: return true
        case nil: return false
        }
    }

    private func nextRevision() -> Int {
        revision += 1
        return revision
    }

    private func applyFixtures() {
        if let currency = Launch.value("-currency", in: args).flatMap(Currency.init(rawValue:)) {
            state.changeCurrency(currency)
        }
        if args.contains("-example-list"), state.current.items.isEmpty {
            let count = Launch.value("-example-count", in: args).flatMap(Int.init) ?? 10
            for index in 0..<max(0, min(count, 100)) {
                state.draft.price = index < 3 ? "62" : "12"
                let destination: Destination = index < 3 ? .sell : .donate
                let id = state.draft.id
                guard state.add(id: id, to: destination) else { continue }
                _ = state.current.items[0].update(destination == .sell ? .sold : .donated,
                                                  actual: destination == .sell ? 62 : nil,
                                                  donated: destination == .donate ? 4 : nil, now: completionTime)
                state.recordCompletion(id)
            }
            if args.contains("-example-history") { state.startSession() }
        }
        if let sample = Launch.value("-example-price", in: args) { state.draft.price = sample }
        if args.contains("-example-fees") {
            state.draft.shipping = "8"
            state.draft.preset = FeePreset.standard(state.draft.currency == .CNY ? .xianyu : .ebay)
        }
    }
}
