import SwiftUI
import UIKit

@MainActor
struct ItemEditor: View {
    enum Mode: String { case name, sale, donation }

    struct Request: Identifiable {
        let item: DecisionItem
        let mode: Mode
        var id: String { item.id.uuidString + mode.rawValue }
    }

    enum Changes {
        case name(String)
        case sale(Decimal)
        case donation(Int, Int?)
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var primary: String
    @State private var invested: String
    @State private var busy = false
    @State private var error: String?
    let request: Request
    let save: (Changes) async -> Bool

    init(request: Request, save: @escaping (Changes) async -> Bool) {
        self.request = request
        self.save = save
        let item = request.item
        let value: String
        switch request.mode {
        case .name: value = item.name
        case .sale: value = item.actualNet.map(NumberInput.text) ?? ""
        case .donation: value = item.donationMinutes.map { String($0) } ?? ""
        }
        _primary = State(initialValue: value)
        _invested = State(initialValue: String(item.investedMinutes))
    }

    private var currency: Currency { request.item.input.currency }
    private var title: String { L.t("editor." + request.mode.rawValue) }

    private var changes: Changes? {
        switch request.mode {
        case .name:
            let name = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.count <= 80 ? .name(name) : nil
        case .sale:
            return NumberInput.parse(primary, scale: currency.scale, maximum: currency.maximum, signed: true).map(Changes.sale)
        case .donation:
            guard let spent = minutes(invested) else { return nil }
            if primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .donation(spent, nil) }
            return minutes(primary).map { .donation(spent, $0) }
        }
    }

    var body: some View {
        SheetFrame(title: title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(request.item.displayName).font(.headline)
                    switch request.mode {
                    case .name:
                        EditorField(title: L.t("editor.name"), id: "editor.name", value: $primary, keyboard: .default)
                            .focused($focused)
                    case .sale:
                        EditorField(title: L.f("field.withUnit", L.t("editor.actual"), currency.rawValue),
                                    id: "editor.actual", value: $primary, keyboard: .numbersAndPunctuation,
                                    note: L.t("editor.actualHelp"))
                            .focused($focused)
                    case .donation:
                        EditorField(title: L.t("editor.donationMinutes"), id: "editor.donationMinutes",
                                    value: $primary, keyboard: .numberPad, note: L.t("editor.donationHelp"))
                            .focused($focused)
                        EditorField(title: L.t("editor.invested"), id: "editor.invested",
                                    value: $invested, keyboard: .numberPad)
                    }
                    if let error { Caption(error) }
                    Button(L.t("action.save"), action: submit)
                        .buttonStyle(ActionStyle(filled: true))
                        .disabled(changes == nil || busy).accessibilityIdentifier("editor.save")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
        }
        .task { focused = true }
    }

    private func minutes(_ text: String) -> Int? {
        NumberInput.parse(text, scale: 0, maximum: 1440).map { NSDecimalNumber(decimal: $0).intValue }
    }

    private func submit() {
        guard let changes, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if await save(changes) { dismiss() }
            else { error = L.t("error.write") }
        }
    }
}

@MainActor
struct DonationTripView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var minutes = ""
    @State private var busy = false
    @State private var error: String?

    let items: [DecisionItem]
    let save: ([UUID: Int]) async -> Bool

    private var duration: Int? {
        NumberInput.parse(minutes, scale: 0, maximum: 1440).map { NSDecimalNumber(decimal: $0).intValue }
    }

    var body: some View {
        SheetFrame(title: L.t("trip.title")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Caption(L.t("trip.help"))
                    EditorField(title: L.t("trip.time"), id: "trip.time", value: $minutes, keyboard: .numberPad)
                    ForEach(items) { item in
                        Button {
                            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                        } label: {
                            Label(item.displayName, systemImage: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(QuietStyle()).accessibilityIdentifier("trip.item.\(item.ordinal)")
                    }
                    if let error { Caption(error) }
                    Button(L.t("action.save"), action: submit)
                        .buttonStyle(ActionStyle(filled: true))
                        .disabled(duration == nil || selected.count < 2 || busy)
                        .accessibilityIdentifier("trip.save")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
        }
    }

    private func submit() {
        let chosen = items.filter { selected.contains($0.id) }.sorted { $0.ordinal < $1.ordinal }
        guard let duration, chosen.count > 1, !busy else { return }
        let shares = SessionSummary.allocateTrip(duration, items: chosen.count)
        let allocation = Dictionary(uniqueKeysWithValues: zip(chosen.map(\.id), shares))
        busy = true
        Task {
            defer { busy = false }
            if await save(allocation) { dismiss() }
            else { error = L.t("error.write") }
        }
    }
}
