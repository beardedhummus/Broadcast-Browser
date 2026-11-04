import Foundation

/// A CSS rule created with the Customize inspector.
struct StyleRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var selector: String
    var label: String = ""
    var enabled = true
    /// CSS property -> value. Emitted with `!important`.
    var properties: [String: String] = [:]

    init(selector: String, label: String = "", properties: [String: String] = [:]) {
        self.selector = selector
        self.label = label
        self.properties = properties
    }

    enum CodingKeys: String, CodingKey { case id, selector, label, enabled, properties }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        selector = try c.decode(String.self, forKey: .selector)
        label = c.value(.label, default: "")
        enabled = c.value(.enabled, default: true)
        properties = c.value(.properties, default: [:])
    }
}

/// Everything the user changed about how a site looks. Saved per tab.
struct TabCustomization: Codable, Hashable {
    var rules: [StyleRule] = []
    var customCSS = ""
    var customJS = ""
    var hideScrollbars = true
    /// When set, everything except this selector is hidden.
    var isolateSelector = ""
    /// Google Fonts family names to @import.
    var googleFonts: [String] = []
    /// Font families imported into the app's font library.
    var importedFonts: [String] = []

    init(hideScrollbars: Bool = true) {
        self.hideScrollbars = hideScrollbars
    }

    enum CodingKeys: String, CodingKey {
        case rules, customCSS, customJS, hideScrollbars, isolateSelector, googleFonts, importedFonts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = c.value(.rules, default: [])
        customCSS = c.value(.customCSS, default: "")
        customJS = c.value(.customJS, default: "")
        hideScrollbars = c.value(.hideScrollbars, default: true)
        isolateSelector = c.value(.isolateSelector, default: "")
        googleFonts = c.value(.googleFonts, default: [])
        importedFonts = c.value(.importedFonts, default: [])
    }
}

/// Saved state of one tab.
struct TabState: Codable, Identifiable {
    var id = UUID()
    var label = ""
    var url: String
    var title = ""
    var canvasWidth = 1920
    var canvasHeight = 1080
    var zoom = 1.0
    var transparentBackground = false
    var customization = TabCustomization()
    var outputs: [OutputConfig] = []
    var autoReloadMinutes = 0
    var userAgent = ""
    var muted = false

    var canvas: PixelSize {
        get { PixelSize(canvasWidth, canvasHeight) }
        set {
            canvasWidth = newValue.width
            canvasHeight = newValue.height
        }
    }

    init(url: String, canvas: PixelSize, hideScrollbars: Bool) {
        self.url = url
        self.canvas = canvas
        self.customization = TabCustomization(hideScrollbars: hideScrollbars)
    }

    enum CodingKeys: String, CodingKey {
        case id, label, url, title, canvasWidth, canvasHeight, zoom, transparentBackground
        case customization, outputs, autoReloadMinutes, userAgent, muted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        label = c.value(.label, default: "")
        url = c.value(.url, default: "about:blank")
        title = c.value(.title, default: "")
        canvasWidth = c.value(.canvasWidth, default: 1920)
        canvasHeight = c.value(.canvasHeight, default: 1080)
        zoom = c.value(.zoom, default: 1.0)
        transparentBackground = c.value(.transparentBackground, default: false)
        customization = c.value(.customization, default: TabCustomization())
        outputs = c.value(.outputs, default: [])
        autoReloadMinutes = c.value(.autoReloadMinutes, default: 0)
        userAgent = c.value(.userAgent, default: "")
        muted = c.value(.muted, default: false)
    }
}

/// The JSON document written by Save Session.
struct SessionFile: Codable {
    var formatVersion = 1
    var app = "Broadcast Browser"
    var name: String
    var savedAt = Date()
    var tabs: [TabState]
    var selectedTabID: UUID?
    /// Start every tab's auto-start outputs as soon as the session opens.
    var autoStartOutputs = false
    var windowFrame: String?
    var sidebarVisible = true

    init(name: String, tabs: [TabState]) {
        self.name = name
        self.tabs = tabs
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, app, name, savedAt, tabs, selectedTabID, autoStartOutputs, windowFrame, sidebarVisible
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = c.value(.formatVersion, default: 1)
        app = c.value(.app, default: "Broadcast Browser")
        name = c.value(.name, default: "Untitled Session")
        savedAt = c.value(.savedAt, default: Date())
        tabs = try c.decode([TabState].self, forKey: .tabs)
        selectedTabID = c.value(.selectedTabID, default: nil)
        autoStartOutputs = c.value(.autoStartOutputs, default: false)
        windowFrame = c.value(.windowFrame, default: nil)
        sidebarVisible = c.value(.sidebarVisible, default: true)
    }
}
