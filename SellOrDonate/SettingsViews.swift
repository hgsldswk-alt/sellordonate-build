import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct PresetView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var edit: Platform?
    @State private var pending: Choice?
    @State private var confirmSwitch = false
    @State private var paywall = false

    private enum Choice: Identifiable {
        case currency(Currency)
        case preset(FeePreset, personal: Bool)

        var currency: Currency {
            switch self {
            case .currency(let currency): return currency
            case .preset(let preset, _): return preset.currency
            }
        }
        var id: String { currency.rawValue }
    }

    private var draft: CalculationDraft { workspace.state.draft }
    private var platforms: [Platform] {
        Platform.allCases.filter { $0.currency == draft.currency } + Platform.allCases.filter { $0.currency != draft.currency }
    }

    var body: some View {
        SheetFrame(title: L.t("presets.title")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L.t("presets.currency")).font(.headline)
                        Spacer()
                        currencyMenu
                    }
                    Button(action: applyManual) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L.t("presets.manual")).font(.headline)
                            Caption(L.t("presets.manualNote"))
                        }
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("preset.manual")
                    .padding(.horizontal, 12).padding(.vertical, 5).panel()
                    if !purchases.hasPro {
                        Caption(L.t("presets.locked"))
                        Button(L.t("purchase.title")) { paywall = true }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("presets.paywall")
                    }
                    VStack(spacing: 0) {
                        ForEach(platforms) { platform in
                            if platform != platforms.first { Divider() }
                            row(platform)
                        }
                    }.panel()
                    if let error = workspace.error { Caption(error) }
                }.padding(20)
            }
        }
        .sheet(item: $edit) { platform in
            PresetEditor(preset: presetFor(platform), editable: purchases.hasPro) { selected in
                edit = nil
                choose(.preset(selected, personal: true))
            }
        }
        .sheet(isPresented: $paywall) { PaywallView(purchases: purchases) }
        .alert(L.t("presets.currencyChange"), isPresented: $confirmSwitch, presenting: pending) { choice in
            Button(L.t("action.cancel"), role: .cancel) {}
            Button(L.t("presets.switchCurrency")) { apply(choice) }
        } message: { choice in
            Text(L.f("presets.currencyWarning", draft.currency.rawValue, choice.currency.rawValue))
        }
    }

    private var currencyMenu: some View {
        Menu {
            ForEach(Currency.allCases) { currency in
                Button(currency.rawValue) { choose(.currency(currency)) }
                    .accessibilityIdentifier("currency." + currency.rawValue)
            }
        } label: {
            Label(draft.currency.rawValue, systemImage: "chevron.down")
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }.accessibilityIdentifier("preset.currency")
    }

    private func row(_ platform: Platform) -> some View {
        let preset = presetFor(platform)
        return HStack(spacing: 8) {
            Button {
                choose(.preset(preset, personal: false))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t(platform.titleKey)).font(.headline)
                    Caption(L.f("presets.regionLine", L.t("preset.region." + platform.rawValue), platform.currency.rawValue))
                    Caption(workspace.state.personal[platform.rawValue] == nil
                            ? L.t("preset.rule." + platform.rawValue) : L.t("preset.personal"))
                }.frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!purchases.hasPro)
            .accessibilityIdentifier("preset.apply." + platform.rawValue)
            Button(L.t("action.details")) { edit = platform }
                .buttonStyle(QuietStyle()).accessibilityIdentifier("preset.details." + platform.rawValue)
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func presetFor(_ platform: Platform) -> FeePreset {
        workspace.state.personal[platform.rawValue] ?? FeePreset.standard(platform)
    }

    private func applyManual() {
        Task {
            if await workspace.commit({ state in
                state.draft = state.draft.withManualFee()
                return true
            }) { dismiss() }
        }
    }

    private func choose(_ choice: Choice) {
        if choice.currency != draft.currency && !draft.price.isEmpty {
            pending = choice
            confirmSwitch = true
        } else {
            apply(choice)
        }
    }

    private func apply(_ choice: Choice) {
        let premium = purchases.hasPro
        Task {
            if await workspace.commit({ state in
                state.changeCurrency(choice.currency, empty: true)
                if case .preset(let preset, let personal) = choice {
                    guard premium else { return false }
                    state.draft.preset = preset
                    state.draft.fee = "0"
                    if personal { state.personal[preset.platform.rawValue] = preset }
                }
                return true
            }) { dismiss() }
        }
    }
}

@MainActor
private struct PresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rate: String
    @State private var fixed: String
    @State private var basis: FeePreset.Basis
    let preset: FeePreset
    let editable: Bool
    let save: (FeePreset) -> Void

    init(preset: FeePreset, editable: Bool = true, save: @escaping (FeePreset) -> Void) {
        self.preset = preset
        self.editable = editable
        self.save = save
        _rate = State(initialValue: NumberInput.text(preset.rate * 100))
        _fixed = State(initialValue: NumberInput.text(preset.orderFee))
        _basis = State(initialValue: preset.basis)
    }

    private var edited: FeePreset? {
        guard let rate = NumberInput.parse(rate, scale: 2, maximum: 100),
              let orderFee = NumberInput.parse(fixed, scale: preset.currency.scale, maximum: preset.currency.maximum) else { return nil }
        var modified = preset
        modified.rate = rate / 100
        modified.orderFee = orderFee
        modified.basis = basis
        return modified.isValid ? modified : nil
    }

    var body: some View {
        SheetFrame(title: L.t(preset.platform.titleKey)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Caption(L.f("presets.regionLine", L.t("preset.region." + preset.platform.rawValue), preset.currency.rawValue))
                    Text(L.t("preset.rule." + preset.platform.rawValue)).font(.body)
                    Caption(L.f("preset.checked", preset.checkedOn))
                    Caption(L.t("preset.source"))
                    Text(verbatim: preset.source).font(.footnote).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 11) {
                        EditorField(title: L.t("preset.rate"), id: "preset.rate", value: $rate)
                        EditorField(title: L.t("preset.fixed"), id: "preset.fixed", value: $fixed)
                        Picker(L.t("preset.basis"), selection: $basis) {
                            ForEach(FeePreset.Basis.allCases, id: \.self) { Text(L.t($0.titleKey)).tag($0) }
                        }.frame(minHeight: 44).accessibilityIdentifier("preset.basis")
                    }
                    .disabled(!editable)
                    if editable {
                        Button(L.t("preset.save")) { if let edited { save(edited) } }
                            .buttonStyle(ActionStyle(filled: true)).disabled(edited == nil)
                            .accessibilityIdentifier("preset.save")
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
        }
    }
}

@MainActor
struct FeeDetailsView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var buyer = ""
    @State private var extra = ""

    private var draft: CalculationDraft { workspace.state.draft }

    var body: some View {
        SheetFrame(title: L.t("fee.details")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fees
                    EditorField(title: L.t("fee.buyer"), id: "fee.buyer", value: $buyer, note: L.t("fee.buyerHelp"))
                    EditorField(title: L.t("fee.extra"), id: "fee.extra", value: $extra, note: L.t("fee.extraHelp"))
                    Button(L.t("action.save")) {
                        Task {
                            if await workspace.commit({ state in
                                state.draft.buyerShipping = buyer
                                state.draft.extraBase = extra
                                return true
                            }) { dismiss() }
                        }
                    }.buttonStyle(ActionStyle(filled: true))
                        .disabled(draft.amount(buyer) == nil || draft.amount(extra) == nil || workspace.busy)
                        .accessibilityIdentifier("fee.save")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
        }
        .onAppear { buyer = draft.buyerShipping; extra = draft.extraBase }
    }

    private var fees: some View {
        let input = draft.input
        let result = input.flatMap(Calculator.calculate)
        let currency = draft.currency
        let entries: [(String, Decimal?)] = [
            ("field.price", input?.price), ("fee.buyer", input?.buyerShipping), ("field.fee", result?.fee),
            ("field.shipping", input?.sellerShipping), ("result.net", result?.net)
        ]
        return VStack(spacing: 0) {
            ForEach(entries.indices, id: \.self) { index in
                if index > 0 { Divider() }
                HStack {
                    Text(L.t(entries[index].0))
                    Spacer()
                    Text(entries[index].1.map(currency.money) ?? L.t("value.empty"))
                        .monospacedDigit()
                }.frame(minHeight: 45)
            }
        }.padding(.horizontal, 13).panel()
    }
}

@MainActor
struct ImportView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var text = ""
    @State private var importError: String?
    @State private var files = false

    private var candidate: ShareSettings? { try? ShareCode.decode(text) }

    var body: some View {
        SheetFrame(title: L.t("import.title")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Caption(L.t("import.description"))
                    HStack {
                        Button(L.t("import.paste"), action: pasteCode)
                            .buttonStyle(ActionStyle(filled: true)).accessibilityIdentifier("import.paste")
                        Button(L.t("import.file")) { editing = false; files = true }
                            .buttonStyle(ActionStyle()).accessibilityIdentifier("import.file")
                    }
                    TextEditor(text: Binding(get: { text }, set: { value in
                        text = value
                        importError = nil
                    })).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 103)
                        .scrollContentBackground(.hidden)
                        .padding(8).panel()
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($editing)
                        .accessibilityLabel(L.t("import.title"))
                        .accessibilityIdentifier("import.text")
                    if let importError { Caption(importError).accessibilityIdentifier("import.error") }
                    else if let candidate { previewCard(candidate) }
                    else if !editing && !text.isEmpty {
                        Caption(L.t("import.invalid")).accessibilityIdentifier("import.error")
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.plainText, .data]) { result in
            if case .success(let url) = result {
                Task {
                    do { inspect(try await workspace.disk.readCode(url)) }
                    catch { importError = L.t("import.invalid") }
                }
            }
        }
    }

    private func previewCard(_ settings: ShareSettings) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L.t("import.preview")).font(.headline).accessibilityIdentifier("import.valid")
            Text(L.f("import.settings", settings.currency.rawValue, settings.currency.money(settings.threshold), String(settings.minutes)))
            if let template = settings.template {
                Caption(L.t(template.platform.titleKey))
                if !purchases.hasPro { Caption(L.t("import.manualTemplate")) }
            }
            if settings.currency != workspace.state.draft.currency { Caption(L.t("import.parked")) }
            Button(L.t("import.apply")) {
                Task {
                    if await workspace.apply(settings, premium: purchases.hasPro) { dismiss() }
                    else { importError = workspace.error }
                }
            }.buttonStyle(ActionStyle(filled: true)).disabled(workspace.busy)
                .accessibilityIdentifier("import.apply")
        }.padding(14).panel(tinted: true)
    }

    private func pasteCode() {
        let value = workspace.test ? ProcessInfo.processInfo.environment["SD_TEST_CODE"] : UIPasteboard.general.string
        inspect(value)
    }

    private func inspect(_ value: String?) {
        editing = false
        guard let value, !value.isEmpty else {
            importError = L.t("import.invalid")
            return
        }
        text = value
        importError = nil
    }
}
