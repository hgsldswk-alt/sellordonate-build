import SwiftUI
import UIKit

struct ShareChoice: Identifiable {
    let session: DeclutterSession
    let milestone: Int?
    var id: String { session.id.uuidString + (milestone.map { String($0) } ?? "") }
}

struct ActivityPayload: Identifiable {
    var id = UUID()
    var items: [Any]
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
struct SharePreview: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var purchases: Purchases
    let choice: ShareChoice

    @State private var currency: Currency?
    @State private var hideAmount = false
    @State private var qr: CGImage?
    @State private var attachment: ActivityPayload?
    @State private var message: String?
    @State private var working = false
    @State private var includeTemplate = false
    @State private var shareRequested = false

    private var summary: SessionSummary { choice.session.summary }
    private var currencies: [Currency] { summary.income.keys.sorted { $0.rawValue < $1.rawValue } }
    private var selectedCurrency: Currency? {
        if let currency, currencies.contains(currency) { return currency }
        return currencies.first
    }
    private var income: String? {
        guard !hideAmount, let selectedCurrency, let amount = summary.income[selectedCurrency] else { return nil }
        return L.f("share.incomeCurrency", selectedCurrency.money(amount), selectedCurrency.rawValue)
    }

    private var card: ResultsCard {
        ResultsCard(summary: summary, income: income, milestone: choice.milestone, qr: qr)
    }

    var body: some View {
        SheetFrame(title: L.t("share.preview")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    GeometryReader { geometry in
                        let scale = geometry.size.width / 360
                        card.scaleEffect(scale, anchor: .topLeading)
                    }
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("share.card")
                    Button(L.t("share.image"), action: exportImage)
                        .buttonStyle(ActionStyle(filled: true))
                        .disabled(qr == nil || working).accessibilityIdentifier("share.image")
                    amountOptions
                    settingsOptions
                    if let message { Caption(message).accessibilityIdentifier("share.message") }
                    if shareRequested {
                        Text(L.t("share.requested")).accessibilityIdentifier("share.requested")
                    }
                }.padding(20)
            }
        }
        .sheet(item: $attachment) { payload in ActivitySheet(items: payload.items) }
        .task {
            let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String
            qr = await Task.detached { QRCode.image(for: QRCode.downloadLink(appStoreID: id)) }.value
            if qr == nil { message = L.t("error.export") }
        }
    }

    @ViewBuilder private var amountOptions: some View {
        if !currencies.isEmpty {
            Toggle(L.t("share.hideAmount"), isOn: $hideAmount)
                .frame(minHeight: 44).accessibilityIdentifier("share.hideAmount")
            if currencies.count > 1 && !hideAmount {
                Picker(L.t("presets.currency"), selection: $currency) {
                    Text(L.t("share.defaultCurrency")).tag(nil as Currency?)
                    ForEach(currencies) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(minHeight: 44).accessibilityIdentifier("share.currency")
            }
        }
    }

    private var settingsOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if purchases.hasPro && workspace.state.draft.preset != nil {
                Toggle(L.t("share.includeTemplate"), isOn: $includeTemplate)
                    .frame(minHeight: 44).accessibilityIdentifier("share.includeTemplate")
            }
            HStack {
                Button(L.t("share.copyCode"), action: copyCode)
                    .buttonStyle(QuietStyle()).accessibilityIdentifier("share.copyCode")
                Spacer()
                Button(L.t("share.codeFile"), action: exportCode)
                    .buttonStyle(QuietStyle()).accessibilityIdentifier("share.codeFile")
            }
        }
    }

    private func code() throws -> String {
        let draft = workspace.state.draft
        guard let threshold = draft.amount(draft.threshold), let minutes = draft.duration else {
            throw ShareCode.Failure.invalid
        }
        let preset = purchases.hasPro && includeTemplate ? draft.preset : nil
        return try ShareCode.encode(ShareSettings(currency: draft.currency, threshold: threshold,
                                 minutes: minutes, template: preset.map(ShareSettings.Template.init)))
    }

    private func copyCode() {
        do {
            let value = try code()
            if !workspace.test { UIPasteboard.general.string = value }
            message = L.t("share.copied")
        } catch {
            message = L.t("share.settingsError")
        }
    }

    private func exportCode() {
        do {
            let content = try code()
            send(Data((content + "\n").utf8), filename: "sell-or-donate-settings.txt")
        } catch {
            message = L.t("share.settingsError")
        }
    }

    private func exportImage() {
        guard !working, qr != nil else { return }
        let renderer = ImageRenderer(content: card.environment(\.dynamicTypeSize, .medium))
        renderer.scale = 3
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: 360, height: 450)
        guard let data = renderer.uiImage?.pngData() else {
            message = L.t("error.export")
            return
        }
        let caption = summary.discarded > 0
            ? L.f("share.captionWithDiscarded", String(summary.sold), String(summary.donated), String(summary.discarded))
            : L.f("share.caption", String(summary.completed))
        send(data, filename: "declutter.png", caption: caption)
    }

    private func send(_ data: Data, filename: String, caption: String? = nil) {
        guard !working else { return }
        working = true
        shareRequested = false
        Task {
            defer { working = false }
            do {
                let url = try await workspace.disk.export(data, filename: filename)
                if workspace.test { shareRequested = true }
                else {
                    var items: [Any] = [url]
                    if let caption { items.append(caption) }
                    attachment = ActivityPayload(items: items)
                }
            } catch {
                message = L.t("error.export")
            }
        }
    }
}

private struct ResultsCard: View {
    let summary: SessionSummary
    let income: String?
    let milestone: Int?
    let qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.accent).frame(height: 2)
            Text(L.t("app.name")).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.accentText).padding(.top, 9)
            Text(milestone.map { L.f("milestone.reached", String($0)) } ?? L.t("share.heading"))
                .font(.system(size: 34, weight: .bold)).tracking(-1.2)
                .lineLimit(2).minimumScaleFactor(0.75).padding(.vertical, 12)
            metric(L.t("status.donated"), value: String(summary.donated))
            metric(L.t("status.sold"), value: String(summary.sold))
            if summary.discarded > 0 {
                metric(L.t("status.discarded"), value: String(summary.discarded))
            }
            if let income { metric(L.t("share.income"), value: income) }
            metric(L.t("session.savedTime"), value: durationText(summary.savedMinutes))
            Spacer(minLength: 10)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("share.tags")).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.accentText)
                    Text(L.t("share.qr")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if let qr {
                    Image(decorative: qr, scale: 1).interpolation(.none)
                        .resizable().frame(width: 84, height: 84)
                }
            }
        }
        .padding(22)
        .frame(width: 360, height: 450)
        .foregroundStyle(Palette.ink)
        .background(Palette.paper)
        .overlay(Rectangle().strokeBorder(Palette.line))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.muted)
                Spacer()
                Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.55)
            }.frame(minHeight: 33)
            Divider()
        }
    }
}
