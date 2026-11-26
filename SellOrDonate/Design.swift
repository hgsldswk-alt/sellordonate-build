import SwiftUI
import UIKit

enum Palette {
    static let paper = Color(red: 247 / 255, green: 245 / 255, blue: 239 / 255)
    static let surface = Color(red: 255 / 255, green: 254 / 255, blue: 251 / 255)
    static let ink = Color(red: 31 / 255, green: 35 / 255, blue: 38 / 255)
    static let muted = Color(red: 81 / 255, green: 92 / 255, blue: 89 / 255)
    static let line = Color(red: 217 / 255, green: 229 / 255, blue: 223 / 255)
    static let accent = Color(red: 30 / 255, green: 140 / 255, blue: 110 / 255)
    static let accentText = Color(red: 18 / 255, green: 105 / 255, blue: 79 / 255)
    static let onAccent = Color(red: 8 / 255, green: 14 / 255, blue: 13 / 255)
    static let tint = Color(red: 225 / 255, green: 243 / 255, blue: 237 / 255)
}

extension View {
    func panel(tinted: Bool = false) -> some View {
        background(tinted ? Palette.tint : Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line).allowsHitTesting(false))
    }
}

struct ActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        let prominent = filled && enabled
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(prominent ? Palette.onAccent : (enabled ? Palette.accentText : Palette.muted))
            .background(prominent ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(prominent ? Palette.accent : Palette.line).allowsHitTesting(false))
            .opacity(configuration.isPressed ? 0.96 : 1)
    }
}

struct QuietStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(enabled ? Palette.accentText : Palette.muted)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.95 : 1)
    }
}

struct Caption: View {
    var value: String
    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value).font(.footnote).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .background(Palette.paper.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L.t("action.close")) { dismiss() }.accessibilityIdentifier("sheet.close")
                    }
                }
        }
        .tint(Palette.accentText)
        .foregroundStyle(Palette.ink)
    }
}

struct EditorField: View {
    var title: String
    var id: String
    @Binding var value: String
    var keyboard: UIKeyboardType = .decimalPad
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(title)
            TextField(title, text: $value)
                .keyboardType(keyboard)
                .font(.body.monospacedDigit())
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier(id)
            if let note { Caption(note) }
        }
    }
}
