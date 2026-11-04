import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SelectorScope: String, CaseIterable, Identifiable {
    case element, matching, custom
    var id: String { rawValue }
}

struct CustomizePanel: View {
    @ObservedObject var tab: BrowserTab
    @State private var scope: SelectorScope = .element
    @State private var customSelector = ""

    private var activeSelector: String? {
        guard let element = tab.picked else {
            let trimmed = customSelector.trimmingCharacters(in: .whitespaces)
            return scope == .custom && !trimmed.isEmpty ? trimmed : nil
        }
        switch scope {
        case .element: return element.selector
        case .matching: return element.classSelector
        case .custom:
            let trimmed = customSelector.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? element.selector : trimmed
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !tab.isEditing {
                    editModeOffCard
                }
                Group {
                    pickerSection
                    if let element = tab.picked, let selector = activeSelector {
                        elementSection(element, selector: selector)
                        StyleEditor(tab: tab, selector: selector, computed: element.computed)
                    }
                    RulesSection(tab: tab, onSelect: { rule in
                        scope = .element
                        tab.selectElement(selector: rule.selector)
                    })
                    FontsSection(tab: tab)
                    IsolateSection(tab: tab)
                    CodeSection(tab: tab)
                    InspectorSection(tab: tab)
                }
                .disabled(!tab.isEditing)
                .opacity(tab.isEditing ? 1 : 0.55)
            }
            .padding(12)
        }
        .onChange(of: tab.picked?.selector) { _, _ in
            if scope == .custom { customSelector = tab.picked?.selector ?? "" }
            if scope == .matching { tab.highlightMatches(tab.picked?.classSelector) }
        }
        .onChange(of: scope) { _, newScope in
            tab.highlightMatches(newScope == .matching ? tab.picked?.classSelector : nil)
            if newScope == .custom && customSelector.isEmpty { customSelector = tab.picked?.selector ?? "" }
        }
        .onDisappear { tab.highlightMatches(nil) }
    }

    private var editModeOffCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.slash").foregroundStyle(.orange)
                Text("Edit Mode is off").font(.system(size: 12.5, weight: .semibold))
            }
            Text(tab.isLive
                 ? "This tab is on air. Entering Edit Mode \(AppModel.shared.preferences.liveEditBehavior == .holdOutputs ? "holds its outputs on the last frame until you click Done, so nothing from editing reaches air." : "keeps outputs live; the Web Inspector stays disabled while on air.")"
                 : "Turn on Edit Mode to pick elements, change styles and open the Web Inspector. Saved changes keep applying either way.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                tab.enterEditMode()
            } label: {
                Label("Enter Edit Mode (⌘E)", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .card()
    }

    private var pickerSection: some View {
        PanelSection("Element") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button {
                        tab.togglePicking()
                    } label: {
                        Label(tab.isPicking ? "Picking… (Esc)" : "Pick Element", systemImage: "scope")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(tab.isPicking ? .orange : .accentColor)
                    .help("Click an element in the canvas (⇧⌘C)")
                    Button {
                        tab.selectParentElement()
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .controlSize(.large)
                    .disabled(tab.picked == nil)
                    .help("Select the parent element")
                    Button {
                        tab.clearSelection()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .controlSize(.large)
                    .disabled(tab.picked == nil)
                    .help("Clear selection")
                }
                Text("Click any element in the canvas to style it. Selection highlights live in an overlay that is never sent to your outputs. You can also right-click an element › Customize This Element.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func elementSection(_ element: PickedElement, selector: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(element.label)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            if !element.text.isEmpty {
                Text("“\(element.text)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Picker("", selection: $scope) {
                Text("This element").tag(SelectorScope.element)
                Text("All like it (\(element.matchCount))").tag(SelectorScope.matching)
                Text("Custom").tag(SelectorScope.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            if !tab.outputs.isEmpty, tab.pickedCanvasRect != nil {
                Menu {
                    ForEach(tab.outputs) { output in
                        Button(output.name.isEmpty ? output.kind.shortLabel : output.name) {
                            if let rect = tab.pickedCanvasRect { tab.cropOutput(output.id, to: rect) }
                        }
                    }
                } label: {
                    Label("Crop an output to this element", systemImage: "crop")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if scope == .custom {
                TextField("CSS selector", text: $customSelector)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Text(selector)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .card()
    }
}

// MARK: - Style editor

struct StyleEditor: View {
    @ObservedObject var tab: BrowserTab
    let selector: String
    let computed: [String: String]
    @State private var newProperty = ""
    @State private var newValue = ""

    private static let handled: Set<String> = [
        "font-family", "font-size", "font-weight", "font-style", "color", "background-color", "text-align",
        "text-transform", "line-height", "letter-spacing", "text-shadow", "opacity", "padding", "border-radius", "display",
    ]

    private func value(_ property: String) -> String { tab.styleValue(selector: selector, property: property) ?? "" }
    private func set(_ property: String, _ value: String?) { tab.setStyle(selector: selector, property: property, value: value) }
    private func binding(_ property: String) -> Binding<String> {
        Binding(get: { value(property) }, set: { set(property, $0) })
    }

    var body: some View {
        PanelSection("Style", accessory: {
            Button("Reset All") { tab.clearStyles(selector: selector) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(tab.ruleIndex(for: selector) == nil)
        }) {
            VStack(alignment: .leading, spacing: 9) {
                FontFamilyRow(tab: tab, value: binding("font-family"), computed: computed["font-family"] ?? "")
                LengthRow(label: "Size", value: binding("font-size"), computed: computed["font-size"] ?? "", step: 1)
                FieldRow(label: "Weight") {
                    Picker("", selection: binding("font-weight")) {
                        Text("Default (\(computed["font-weight"] ?? "—"))").tag("")
                        ForEach(["100", "200", "300", "400", "500", "600", "700", "800", "900"], id: \.self) { weight in
                            Text(weightName(weight)).tag(weight)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                FieldRow(label: "Style") {
                    Picker("", selection: binding("font-style")) {
                        Text("Default").tag("")
                        Text("Normal").tag("normal")
                        Text("Italic").tag("italic")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                ColorRow(label: "Text color", value: binding("color"), computed: computed["color"] ?? "")
                ColorRow(label: "Background", value: binding("background-color"), computed: computed["background-color"] ?? "", allowsClear: true)
                FieldRow(label: "Align") {
                    Picker("", selection: binding("text-align")) {
                        Text("—").tag("")
                        Image(systemName: "text.alignleft").tag("left")
                        Image(systemName: "text.aligncenter").tag("center")
                        Image(systemName: "text.alignright").tag("right")
                        Image(systemName: "text.justify").tag("justify")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                FieldRow(label: "Transform") {
                    Picker("", selection: binding("text-transform")) {
                        Text("Default").tag("")
                        Text("None").tag("none")
                        Text("UPPERCASE").tag("uppercase")
                        Text("lowercase").tag("lowercase")
                        Text("Capitalize").tag("capitalize")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                LengthRow(label: "Line height", value: binding("line-height"), computed: computed["line-height"] ?? "", step: 1)
                LengthRow(label: "Letter spacing", value: binding("letter-spacing"), computed: computed["letter-spacing"] ?? "", step: 0.5)
                FieldRow(label: "Text shadow") {
                    Picker("", selection: binding("text-shadow")) {
                        Text("Default").tag("")
                        Text("None").tag("none")
                        Text("Soft").tag("0 2px 6px rgba(0, 0, 0, 0.75)")
                        Text("Hard").tag("2px 2px 0 rgba(0, 0, 0, 0.9)")
                        Text("Outline").tag("0 0 2px #000, 0 0 2px #000, 0 0 3px #000, 0 0 4px #000")
                        Text("Glow").tag("0 0 12px rgba(255, 255, 255, 0.8)")
                        if !value("text-shadow").isEmpty && !Self.shadowPresets.contains(value("text-shadow")) {
                            Text("Custom").tag(value("text-shadow"))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                FieldRow(label: "Opacity") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { Double(value("opacity")) ?? Double(computed["opacity"] ?? "1") ?? 1 },
                            set: { set("opacity", String(format: "%.2f", $0)) }), in: 0...1)
                            .controlSize(.small)
                        if !value("opacity").isEmpty {
                            Button { set("opacity", nil) } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.borderless)
                                .help("Reset")
                        }
                    }
                }
                TextRow(label: "Padding", value: binding("padding"), computed: computed["padding"] ?? "")
                TextRow(label: "Corner radius", value: binding("border-radius"), computed: computed["border-radius"] ?? "")
                FieldRow(label: "Visibility") {
                    Toggle("Hide this element", isOn: Binding(
                        get: { value("display") == "none" },
                        set: { set("display", $0 ? "none" : nil) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                extraProperties
            }
            .card()
        }
    }

    private static let shadowPresets: Set<String> = [
        "none", "0 2px 6px rgba(0, 0, 0, 0.75)", "2px 2px 0 rgba(0, 0, 0, 0.9)",
        "0 0 2px #000, 0 0 2px #000, 0 0 3px #000, 0 0 4px #000", "0 0 12px rgba(255, 255, 255, 0.8)",
    ]

    private var extraProperties: some View {
        let index = tab.ruleIndex(for: selector)
        let extras = index.map { tab.customization.rules[$0].properties.keys.filter { !Self.handled.contains($0) }.sorted() } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            ForEach(extras, id: \.self) { property in
                HStack(spacing: 6) {
                    Text(property)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(width: 92, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: binding(property))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                    Button { set(property, nil) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                TextField("property", text: $newProperty)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 104)
                TextField("value", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
                    .onSubmit(addProperty)
                Button(action: addProperty) { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(newProperty.isEmpty || newValue.isEmpty)
                    .help("Add any CSS property")
            }
        }
    }

    private func addProperty() {
        let property = newProperty.trimmingCharacters(in: .whitespaces).lowercased()
        guard !property.isEmpty, !newValue.isEmpty else { return }
        set(property, newValue)
        newProperty = ""
        newValue = ""
    }

    private func weightName(_ weight: String) -> String {
        switch weight {
        case "100": return "100 Thin"
        case "200": return "200 Extra Light"
        case "300": return "300 Light"
        case "400": return "400 Regular"
        case "500": return "500 Medium"
        case "600": return "600 Semibold"
        case "700": return "700 Bold"
        case "800": return "800 Extra Bold"
        default: return "900 Black"
        }
    }
}

struct TextRow: View {
    let label: String
    @Binding var value: String
    let computed: String

    var body: some View {
        FieldRow(label: label) {
            HStack(spacing: 4) {
                TextField(computed, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                if !value.isEmpty {
                    Button { value = "" } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Reset to the site's value")
                }
            }
        }
    }
}

/// Text field with −/+ nudging for CSS lengths (keeps the unit, defaults to px).
struct LengthRow: View {
    let label: String
    @Binding var value: String
    let computed: String
    let step: Double

    var body: some View {
        FieldRow(label: label) {
            HStack(spacing: 4) {
                TextField(computed, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button { nudge(-step) } label: { Image(systemName: "minus") }
                    .help("Smaller")
                Button { nudge(step) } label: { Image(systemName: "plus") }
                    .help("Larger")
                if !value.isEmpty {
                    Button { value = "" } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Reset to the site's value")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
        }
    }

    private func nudge(_ delta: Double) {
        let base = value.isEmpty ? computed : value
        let scanner = Scanner(string: base)
        guard let number = scanner.scanDouble() else {
            value = "\(Int(max(0, 16 + delta)))px"
            return
        }
        var unit = String(base[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        if unit.isEmpty || unit == "normal" { unit = "px" }
        let next = number + delta
        let formatted = next.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(next)) : String(format: "%.1f", next)
        value = "\(formatted)\(unit)"
    }
}

struct ColorRow: View {
    let label: String
    @Binding var value: String
    let computed: String
    var allowsClear = false

    var body: some View {
        FieldRow(label: label) {
            HStack(spacing: 4) {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: CSSColor.parse(value.isEmpty ? computed : value) ?? .white) },
                    set: { value = CSSColor.string(NSColor($0)) }), supportsOpacity: true)
                    .labelsHidden()
                TextField(computed, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
                if allowsClear {
                    Button { value = "transparent" } label: { Image(systemName: "circle.slash") }
                        .buttonStyle(.borderless)
                        .help("Transparent")
                }
                if !value.isEmpty {
                    Button { value = "" } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Reset to the site's value")
                }
            }
        }
    }
}

struct FontFamilyRow: View {
    @ObservedObject var tab: BrowserTab
    @Binding var value: String
    let computed: String

    private static let webSafe = ["Arial", "Helvetica", "Verdana", "Tahoma", "Trebuchet MS", "Georgia", "Times New Roman", "Courier New", "Impact"]
    private static let mac = ["-apple-system", "Helvetica Neue", "Avenir Next", "Avenir Next Condensed", "Futura", "Gill Sans", "Optima", "Menlo", "SF Mono"]
    private static let installed: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    var body: some View {
        FieldRow(label: "Font") {
            HStack(spacing: 4) {
                TextField(shortened(computed), text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Menu {
                    let tabFonts = tab.customization.googleFonts + tab.customization.importedFonts
                    if !tabFonts.isEmpty {
                        Section("This tab") {
                            ForEach(tabFonts, id: \.self) { family in Button(family) { choose(family) } }
                        }
                    }
                    Section("Web safe") {
                        ForEach(Self.webSafe, id: \.self) { family in Button(family) { choose(family) } }
                    }
                    Section("Mac") {
                        ForEach(Self.mac, id: \.self) { family in Button(family) { choose(family) } }
                    }
                    Menu("Installed Fonts") {
                        ForEach(Self.installed, id: \.self) { family in Button(family) { choose(family) } }
                    }
                } label: {
                    Image(systemName: "textformat")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if !value.isEmpty {
                    Button { value = "" } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Reset to the site's font")
                }
            }
        }
    }

    private func choose(_ family: String) {
        value = family.hasPrefix("-") ? family : "'\(family)', sans-serif"
    }

    private func shortened(_ stack: String) -> String {
        stack.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? stack
    }
}

// MARK: - Rules

struct RulesSection: View {
    @ObservedObject var tab: BrowserTab
    let onSelect: (StyleRule) -> Void

    var body: some View {
        PanelSection("Saved changes (\(tab.customization.rules.count))") {
            if tab.customization.rules.isEmpty {
                Text("Style changes you make are saved here and re-applied every time the page loads.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach($tab.customization.rules) { $rule in
                        HStack(spacing: 6) {
                            Toggle("", isOn: $rule.enabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Button {
                                onSelect(rule)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.selector)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Text(rule.properties.keys.sorted().joined(separator: ", "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Select in page and edit")
                            Button {
                                tab.customization.rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
                    }
                }
            }
        }
    }
}

// MARK: - Fonts

struct FontsSection: View {
    @ObservedObject var tab: BrowserTab
    @State private var googleFont = ""
    @State private var importError: String?

    var body: some View {
        PanelSection("Fonts") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Google Font name (e.g. Roboto Condensed)", text: $googleFont)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit(addGoogleFont)
                    Button("Add", action: addGoogleFont)
                        .controlSize(.small)
                        .disabled(googleFont.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    importFont()
                } label: {
                    Label("Import Font File…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                if let importError {
                    Text(importError).font(.system(size: 10.5)).foregroundStyle(.orange)
                }
                ForEach(tab.customization.googleFonts, id: \.self) { family in
                    fontRow(family, kind: "Google") { tab.customization.googleFonts.removeAll { $0 == family } }
                }
                ForEach(tab.customization.importedFonts, id: \.self) { family in
                    fontRow(family, kind: "Imported") { tab.customization.importedFonts.removeAll { $0 == family } }
                }
                Text("Added fonts appear in the Font menu above. Imported files are embedded into the page, so they work on any site.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }

    private func fontRow(_ family: String, kind: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(family).font(.system(size: 11, weight: .medium))
            Text(kind).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private func addGoogleFont() {
        let family = googleFont.trimmingCharacters(in: .whitespaces)
        guard !family.isEmpty, !tab.customization.googleFonts.contains(family) else { return }
        tab.customization.googleFonts.append(family)
        googleFont = ""
    }

    private func importFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf", "woff", "woff2"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importError = nil
        for url in panel.urls {
            do {
                let family = try FontLibrary.shared.importFont(from: url)
                if !tab.customization.importedFonts.contains(family) {
                    tab.customization.importedFonts.append(family)
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Isolate

struct IsolateSection: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        PanelSection("Isolate") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("CSS selector", text: $tab.customization.isolateSelector)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Use Selected") {
                        if let selector = tab.picked?.selector { tab.customization.isolateSelector = selector }
                    }
                    .controlSize(.small)
                    .disabled(tab.picked == nil)
                    if !tab.customization.isolateSelector.isEmpty {
                        Button { tab.customization.isolateSelector = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                Text("Shows only this element and hides the rest of the page — ideal for scoreboards, tickers and widgets. Combine with a transparent background for keying.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }
}

// MARK: - Custom CSS / JS

struct CodeSection: View {
    @ObservedObject var tab: BrowserTab
    @State private var showCSS = false
    @State private var showJS = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showCSS) {
                VStack(alignment: .leading, spacing: 6) {
                    codeEditor(text: $tab.customization.customCSS)
                    Text("Applied live and on every load. Add !important to win over the site's styles.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 6)
            } label: {
                Text("CUSTOM CSS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            }
            DisclosureGroup(isExpanded: $showJS) {
                VStack(alignment: .leading, spacing: 6) {
                    codeEditor(text: $tab.customization.customJS)
                    HStack {
                        Text("Runs after each page load.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Run Now") { tab.runCustomJSNow() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("CUSTOM JAVASCRIPT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            }
        }
    }

    private func codeEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .padding(6)
            .frame(minHeight: 130)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
    }
}

struct InspectorSection: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        PanelSection("Web Inspector") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    tab.openWebInspector()
                } label: {
                    Label("Open Web Inspector", systemImage: "hammer")
                        .font(.system(size: 11.5))
                }
                Text("Full developer tools (Elements, Styles, Console, Network) in a separate window. Edits made there are temporary — use the tools above to save changes with the session. Note: Inspector's hover highlights are drawn inside the page and do appear on air.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }
}
