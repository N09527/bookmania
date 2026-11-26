import BookmaniaCore
import SwiftUI

/// What the typesetting panel shows (EbookSettingsUiState on Android) and what its controls do. The reader owns it
/// and refreshes it after every change.
@MainActor
final class EbookSettingsPanelModel: ObservableObject {
    /// The settings as seen from `scope` (that level and the ones above it).
    @Published var settings = EbookSettings()
    @Published var scope: SettingsScope = .global
    /// Whether `scope` sets anything itself (otherwise there is nothing to clear).
    @Published var scopeHasValues = false
    /// Keys a nearer level sets for this book; on the page those values are used.
    @Published var overridden: [EbookSettings.Key: SettingsScope] = [:]
    @Published var fonts: [ImportedFont] = []
    /// The page turn animation: one setting for all books.
    @Published var pageTurn = ReaderPreferences.pageTurnCurl
    /// The fold's shadow with two columns: one setting for all books.
    @Published var gutterShadow = true
    /// When the settings ask for two columns on this screen: the largest left + right margins that keep two columns
    /// of at least 120 pt (from the shell). The left and right margins stop there.
    @Published var marginMost: Int?
    @Published var tab = 0

    var onScopeChange: (SettingsScope) -> Void = { _ in }
    var onSet: (EbookSettings.Key, String) -> Void = { _, _ in }
    var onResetScope: () -> Void = {}
    var onImportFont: () -> Void = {}
    var onDeleteFont: (ImportedFont) -> Void = { _ in }
    var onPageTurn: (String) -> Void = { _ in }
    var onGutterShadow: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
}

extension SettingsScope {
    var label: String {
        switch self {
        case .global: return NSLocalizedString("All books", comment: "")
        case .work: return NSLocalizedString("This work", comment: "")
        case .file: return NSLocalizedString("This file", comment: "")
        }
    }
}

/// Typesetting settings (EbookSettingsPanel.kt on Android), shown without covering the whole page so every change
/// can be seen right away: at the bottom in portrait, as a full-height side panel in landscape (the reader places
/// it). Slider values are applied when the slider is released; each value can also be typed in the field next to
/// its slider.
struct EbookSettingsPanel: View {
    @ObservedObject var model: EbookSettingsPanelModel
    @FocusState private var focus: EbookSettings.Key?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker(selection: $model.tab) {
                    Text("Text").tag(0)
                    Text("Layout").tag(1)
                } label: {
                    Text("Typesetting")
                }
                .pickerStyle(.segmented)
                if focus != nil {
                    Button("Done") { focus = nil }
                }
                Button {
                    focus = nil
                    model.onClose()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Picker(selection: Binding(get: { model.scope }, set: { scope in
                    focus = nil
                    model.onScopeChange(scope)
                })) {
                    ForEach(SettingsScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                } label: {
                    Text("Apply to")
                }
                .pickerStyle(.segmented)
                HStack(alignment: .firstTextBaseline) {
                    Text("ebook_scope_inherited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Clear the settings of this level") {
                        focus = nil
                        model.onResetScope()
                    }
                    .font(.caption)
                    .disabled(!model.scopeHasValues)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.tab == 0 { textTab } else { layoutTab }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Tabs

    @ViewBuilder private var textTab: some View {
        let s = model.settings
        let over = model.overridden
        FontSection(font: s.font, fonts: model.fonts, overridden: over[.font],
                    onSelect: { model.onSet(.font, $0) }, onImport: model.onImportFont, onDelete: model.onDeleteFont)
        Divider()
        SwitchRow(label: "Bold text", isOn: s.bold, overridden: over[.bold]) { model.onSet(.bold, $0 ? "true" : "false") }
        StepRow(label: "Font size", value: Double(s.fontSize), range: Double(EbookSettings.Range.fontSize.lowerBound) ... Double(EbookSettings.Range.fontSize.upperBound),
                step: 1, whole: true, unit: nil, key: .fontSize, overridden: over[.fontSize], focus: $focus) {
            model.onSet(.fontSize, String(Int($0.rounded())))
        }
        StepRow(label: "Line height", value: s.lineHeight, range: EbookSettings.Range.lineHeight, step: EbookSettings.Range.lineHeightStep,
                whole: false, unit: nil, key: .lineHeight, overridden: over[.lineHeight], focus: $focus) {
            model.onSet(.lineHeight, EbookSettings.format($0))
        }
        StepRow(label: "Letter spacing", value: s.letterSpacing, range: EbookSettings.Range.letterSpacing, step: EbookSettings.Range.letterSpacingStep,
                whole: false, unit: "em", key: .letterSpacing, overridden: over[.letterSpacing], focus: $focus) {
            model.onSet(.letterSpacing, EbookSettings.format($0))
        }
        OptionalRow(label: "First-line indent", value: s.indent, initial: 2, range: EbookSettings.Range.indent, step: EbookSettings.Range.indentStep,
                    unit: NSLocalizedString("unit_characters", comment: ""), key: .indent, overridden: over[.indent], focus: $focus) {
            model.onSet(.indent, $0.map(EbookSettings.format) ?? EbookSettings.book)
        }
        OptionalRow(label: "Paragraph spacing", value: s.paragraphSpacing, initial: 0.5, range: EbookSettings.Range.paragraphSpacing,
                    step: EbookSettings.Range.paragraphSpacingStep, unit: "em", key: .paragraphSpacing, overridden: over[.paragraphSpacing], focus: $focus) {
            model.onSet(.paragraphSpacing, $0.map(EbookSettings.format) ?? EbookSettings.book)
        }
    }

    @ViewBuilder private var layoutTab: some View {
        let s = model.settings
        let over = model.overridden
        SettingLabel(text: "Writing mode", overridden: over[.writingMode])
        Choices(options: [(EbookSettings.book, "Book's"), (EbookSettings.modeVertical, "Vertical"), (EbookSettings.modeHorizontal, "Horizontal")],
                selected: s.writingMode) { model.onSet(.writingMode, $0) }
        SettingLabel(text: "Page direction", overridden: over[.pageDirection])
        Choices(options: [(EbookSettings.directionAuto, "Automatic"), (EbookSettings.directionRTL, "Right to left"), (EbookSettings.directionLTR, "Left to right")],
                selected: s.pageDirection) { model.onSet(.pageDirection, $0) }
        Hint("ebook_page_direction_hint")
        SettingLabel(text: "Two columns", overridden: over[.columns])
        Choices(options: [(EbookSettings.columnsOff, "Off"), (EbookSettings.columnsOn, "On"), (EbookSettings.columnsLandscape, "Landscape only")],
                selected: s.columns) { model.onSet(.columns, $0) }
        SwitchRow(label: "Gutter shadow", isOn: model.gutterShadow, overridden: nil) { model.onGutterShadow($0) }
        Hint("ebook_gutter_shadow_hint")
        Divider()
        SettingLabel(text: "Margins", overridden: nil)
        let margin = Double(EbookSettings.Range.margin.lowerBound) ... Double(EbookSettings.Range.margin.upperBound)
        let step = Double(EbookSettings.Range.marginStep)
        // With two columns, each side margin stops where the two would leave less than 120 pt per column, so the
        // page does not jump to one column when a margin is moved too far (only when it limits the sides at all).
        let most = model.marginMost.flatMap { $0 < 2 * EbookSettings.Range.margin.upperBound ? $0 : nil }
        StepRow(label: "Top", value: Double(s.marginTop), range: margin, step: step, whole: true, unit: "pt", key: .marginTop,
                overridden: over[.marginTop], focus: $focus) { model.onSet(.marginTop, String(Int($0.rounded()))) }
        StepRow(label: "Bottom", value: Double(s.marginBottom), range: margin, step: step, whole: true, unit: "pt", key: .marginBottom,
                overridden: over[.marginBottom], focus: $focus) { model.onSet(.marginBottom, String(Int($0.rounded()))) }
        if let most {
            Text(String(format: NSLocalizedString("ebook_margins_two_columns", comment: ""), String(most)))
                .font(.caption)
                .foregroundStyle(.secondary)
            if s.marginLeft + s.marginRight > most {
                Text(String(format: NSLocalizedString("ebook_margins_two_columns_over", comment: ""), String(s.marginLeft + s.marginRight)))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        StepRow(label: "Left", value: Double(s.marginLeft), range: sideRange(most, other: s.marginRight, full: margin), step: step,
                whole: true, unit: "pt", key: .marginLeft, overridden: over[.marginLeft], focus: $focus) { model.onSet(.marginLeft, String(Int($0.rounded()))) }
        StepRow(label: "Right", value: Double(s.marginRight), range: sideRange(most, other: s.marginLeft, full: margin), step: step,
                whole: true, unit: "pt", key: .marginRight, overridden: over[.marginRight], focus: $focus) { model.onSet(.marginRight, String(Int($0.rounded()))) }
        Divider()
        SettingLabel(text: "Page turn animation", overridden: nil)
        Choices(options: [(ReaderPreferences.pageTurnNone, "None"), (ReaderPreferences.pageTurnSlide, "Slide"), (ReaderPreferences.pageTurnCurl, "Curl")],
                selected: model.pageTurn) { model.onPageTurn($0) }
        Hint("ebook_page_turn_hint")
    }

    private func sideRange(_ most: Int?, other: Int, full: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let most else { return full }
        let upper = min(max(most - other, EbookSettings.Range.marginStep), EbookSettings.Range.margin.upperBound)
        return 0 ... Double(upper)
    }
}

// MARK: Rows

/// Tells that a nearer level sets this item, so a change here is not what the page shows.
private struct OverriddenNote: View {
    let level: SettingsScope?

    var body: some View {
        if let level {
            Text(String(format: NSLocalizedString("ebook_scope_overridden", comment: ""), level.label))
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

private struct SettingLabel: View {
    let text: LocalizedStringKey
    let overridden: SettingsScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.subheadline.weight(.semibold))
            OverriddenNote(level: overridden)
        }
        .padding(.top, 4)
    }
}

private struct Hint: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key).font(.caption).foregroundStyle(.secondary)
    }
}

private struct SwitchRow: View {
    let label: LocalizedStringKey
    let isOn: Bool
    let overridden: SettingsScope?
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { if $0 != isOn { onChange($0) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold))
                OverriddenNote(level: overridden)
            }
        }
    }
}

private struct Choices: View {
    let options: [(String, LocalizedStringKey)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        Picker(selection: Binding(get: { selected }, set: { if $0 != selected { onSelect($0) } })) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
    }
}

private struct FontSection: View {
    let font: String
    let fonts: [ImportedFont]
    let overridden: SettingsScope?
    let onSelect: (String) -> Void
    let onImport: () -> Void
    let onDelete: (ImportedFont) -> Void

    var body: some View {
        let builtIn: [(String, LocalizedStringKey)] = [
            (EbookSettings.fontBook, "Book's font"), (EbookSettings.fontSans, "System sans-serif"), (EbookSettings.fontSerif, "System serif"),
        ]
        // A deleted (or not restored) imported font falls back to the book's font, as on the page.
        let shown = builtIn.contains { $0.0 == font } || fonts.contains { $0.id == font } ? font : EbookSettings.fontBook
        VStack(alignment: .leading, spacing: 4) {
            SettingLabel(text: "Font", overridden: overridden)
            ForEach(builtIn, id: \.0) { item in
                FontRow(label: Text(item.1), note: nil, selected: shown == item.0, onSelect: { onSelect(item.0) }, onDelete: nil)
            }
            ForEach(fonts) { f in
                FontRow(label: Text(verbatim: f.name), note: f.vertical ? nil : Text("No vertical layout data"),
                        selected: shown == f.id, onSelect: { onSelect(f.id) }, onDelete: { onDelete(f) })
            }
            Button(action: onImport) {
                Label("Import font…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
    }
}

private struct FontRow: View {
    let label: Text
    let note: Text?
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        label.lineLimit(1)
                        if let note { note.font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("Delete font"))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Under a value field: what can be typed, shown after a value outside it.
private struct RangeNote: View {
    let range: ClosedRange<Double>
    let whole: Bool

    var body: some View {
        let lo = numberText(range.lowerBound, whole)
        let hi = numberText(range.upperBound, whole)
        Text(String(format: NSLocalizedString(whole ? "ebook_value_range_whole" : "ebook_value_range", comment: ""), lo, hi))
            .font(.caption)
            .foregroundStyle(.red)
    }
}

private func numberText(_ v: Double, _ whole: Bool) -> String { whole ? String(Int(v.rounded())) : EbookSettings.format(v) }

/// Rounds a slider value to 0.01, so 1.7999999 is stored as 1.8.
private func hundredths(_ v: Double) -> Double { (v * 100).rounded() / 100 }

private struct StepRow: View {
    let label: LocalizedStringKey
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let whole: Bool
    let unit: String?
    let key: EbookSettings.Key
    let overridden: SettingsScope?
    let focus: FocusState<EbookSettings.Key?>.Binding
    let onCommit: (Double) -> Void

    @State private var current: Double
    @State private var invalid = false

    init(label: LocalizedStringKey, value: Double, range: ClosedRange<Double>, step: Double, whole: Bool, unit: String?,
         key: EbookSettings.Key, overridden: SettingsScope?, focus: FocusState<EbookSettings.Key?>.Binding, onCommit: @escaping (Double) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.step = step
        self.whole = whole
        self.unit = unit
        self.key = key
        self.overridden = overridden
        self.focus = focus
        self.onCommit = onCommit
        _current = State(initialValue: min(max(value, range.lowerBound), range.upperBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                Spacer(minLength: 8)
                NumberField(value: current, whole: whole, range: range, key: key, focus: focus, onInvalid: { invalid = $0 }, onCommit: onCommit)
                if let unit { Text(verbatim: unit).foregroundStyle(.secondary) }
            }
            if invalid { RangeNote(range: range, whole: whole) }
            OverriddenNote(level: overridden)
            Slider(value: $current, in: range, step: step, label: { Text(label) }, onEditingChanged: { editing in
                guard !editing else { return }
                invalid = false
                let v = hundredths(current)
                if abs(v - value) > 0.0001 { onCommit(v) }
            })
        }
        .padding(.top, 4)
        .onChange(of: value) { _, newValue in
            current = min(max(newValue, range.lowerBound), range.upperBound)
        }
    }
}

/// A value that can also be left to the book ("Book's setting").
private struct OptionalRow: View {
    let label: LocalizedStringKey
    let value: Double?
    let initial: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String?
    let key: EbookSettings.Key
    let overridden: SettingsScope?
    let focus: FocusState<EbookSettings.Key?>.Binding
    let onCommit: (Double?) -> Void

    @State private var current: Double
    @State private var invalid = false

    init(label: LocalizedStringKey, value: Double?, initial: Double, range: ClosedRange<Double>, step: Double, unit: String?,
         key: EbookSettings.Key, overridden: SettingsScope?, focus: FocusState<EbookSettings.Key?>.Binding, onCommit: @escaping (Double?) -> Void) {
        self.label = label
        self.value = value
        self.initial = initial
        self.range = range
        self.step = step
        self.unit = unit
        self.key = key
        self.overridden = overridden
        self.focus = focus
        self.onCommit = onCommit
        _current = State(initialValue: min(max(value ?? initial, range.lowerBound), range.upperBound))
    }

    var body: some View {
        let followBook = value == nil
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                Spacer(minLength: 8)
                if !followBook {
                    NumberField(value: current, whole: false, range: range, key: key, focus: focus, onInvalid: { invalid = $0 }, onCommit: { onCommit($0) })
                    if let unit { Text(verbatim: unit).foregroundStyle(.secondary) }
                }
            }
            Toggle(isOn: Binding(get: { followBook }, set: { checked in
                invalid = false
                onCommit(checked ? nil : current)
            })) {
                Text("Book's setting").font(.caption)
            }
            if invalid && !followBook { RangeNote(range: range, whole: false) }
            OverriddenNote(level: overridden)
            if !followBook {
                Slider(value: $current, in: range, step: step, label: { Text(label) }, onEditingChanged: { editing in
                    guard !editing else { return }
                    invalid = false
                    let v = hundredths(current)
                    if value.map({ abs(v - $0) > 0.0001 }) ?? true { onCommit(v) }
                })
            }
        }
        .padding(.top, 4)
        .onChange(of: value) { _, newValue in
            current = min(max(newValue ?? current, range.lowerBound), range.upperBound)
        }
    }
}

/// The value of a slider, typed in. Applied when the field loses the focus (the panel's Done button, another
/// control) or with the keyboard's return key where it has one. A number outside the range (or not whole, for a
/// whole value) is not applied: the field shows the value again and the row tells what can be typed. A typed value
/// can be finer than the slider's step (to 0.01, margins to 1 pt). The text is selected when the field gets the
/// focus, so typing replaces it.
private struct NumberField: View {
    let value: Double
    let whole: Bool
    let range: ClosedRange<Double>
    let key: EbookSettings.Key
    let focus: FocusState<EbookSettings.Key?>.Binding
    let onInvalid: (Bool) -> Void
    let onCommit: (Double) -> Void

    @State private var text = ""
    @State private var selection: TextSelection?

    private var shown: String { numberText(value, whole) }

    var body: some View {
        TextField("", text: $text, selection: $selection)
            .keyboardType(whole ? .numberPad : .decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 64)
            .textFieldStyle(.roundedBorder)
            .focused(focus, equals: key)
            .onAppear { text = shown }
            .onChange(of: shown) { _, newValue in
                if focus.wrappedValue != key { text = newValue }
            }
            .onChange(of: focus.wrappedValue) { old, new in
                if old == key && new != key {
                    if !apply() { text = shown }
                } else if new == key && old != key {
                    DispatchQueue.main.async {
                        selection = TextSelection(range: text.startIndex ..< text.endIndex)
                    }
                }
            }
            .onSubmit { _ = apply() }
    }

    private func parsed() -> Double? {
        // Some keyboards type a decimal comma.
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        let epsilon = 0.0001
        if v < range.lowerBound - epsilon || v > range.upperBound + epsilon { return nil }
        if whole && abs(v - v.rounded()) > epsilon { return nil }
        let r = whole ? v.rounded() : hundredths(v)
        return min(max(r, range.lowerBound), range.upperBound)
    }

    private func apply() -> Bool {
        guard let v = parsed() else {
            onInvalid(true)
            return false
        }
        onInvalid(false)
        if abs(v - value) > 0.0001 { onCommit(v) }
        return true
    }
}
