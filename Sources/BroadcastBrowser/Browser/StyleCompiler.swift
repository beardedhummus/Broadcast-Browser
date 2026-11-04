import AppKit
import CoreText

/// Turns a tab's customization into one stylesheet.
enum StyleCompiler {
    static func css(for customization: TabCustomization, transparent: Bool) -> String {
        var out: [String] = ["/* Broadcast Browser customizations */"]

        for family in customization.googleFonts where !family.trimmingCharacters(in: .whitespaces).isEmpty {
            let encoded = family.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "+")
            out.append("@import url('https://fonts.googleapis.com/css2?family=\(encoded)&display=swap');")
        }
        for family in customization.importedFonts {
            if let face = FontLibrary.shared.fontFaceCSS(family: family) { out.append(face) }
        }
        if customization.hideScrollbars {
            out.append("""
            html::-webkit-scrollbar, body::-webkit-scrollbar, *::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
            html, body { scrollbar-width: none !important; }
            """)
        }
        if transparent {
            out.append("html, body { background: transparent !important; background-color: transparent !important; }")
        }
        for rule in customization.rules where rule.enabled && !rule.properties.isEmpty {
            let selector = rule.selector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty else { continue }
            let declarations = rule.properties.keys.sorted().compactMap { key -> String? in
                guard let value = rule.properties[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
                let clean = value.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
                return "  \(key): \(clean) !important;"
            }
            guard !declarations.isEmpty else { continue }
            out.append("\(selector) {\n\(declarations.joined(separator: "\n"))\n}")
        }
        let isolate = customization.isolateSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isolate.isEmpty {
            out.append("""
            body * { visibility: hidden !important; }
            \(isolate), \(isolate) * { visibility: visible !important; }
            """)
        }
        if !customization.customCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(customization.customCSS)
        }
        return out.joined(separator: "\n")
    }
}

/// Fonts imported by the user, embedded into pages as data URLs so they work
/// on any site.
final class FontLibrary {
    static let shared = FontLibrary()

    struct Entry: Hashable {
        let family: String
        let url: URL
    }

    private var cache: [String: String] = [:]

    var entries: [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.fontsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard ["ttf", "otf", "woff", "woff2"].contains(url.pathExtension.lowercased()) else { return nil }
            return Entry(family: Self.familyName(of: url) ?? url.deletingPathExtension().lastPathComponent, url: url)
        }
        .sorted { $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending }
    }

    /// Copies a font file into the library and returns its family name.
    func importFont(from url: URL) throws -> String {
        let destination = AppPaths.fontsDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        let family = Self.familyName(of: destination) ?? destination.deletingPathExtension().lastPathComponent
        cache[family] = nil
        return family
    }

    func fontFaceCSS(family: String) -> String? {
        if let cached = cache[family] { return cached }
        guard let entry = entries.first(where: { $0.family == family }),
              let data = try? Data(contentsOf: entry.url) else { return nil }
        let ext = entry.url.pathExtension.lowercased()
        let mime: String
        let format: String
        switch ext {
        case "otf": mime = "font/otf"; format = "opentype"
        case "woff": mime = "font/woff"; format = "woff"
        case "woff2": mime = "font/woff2"; format = "woff2"
        default: mime = "font/ttf"; format = "truetype"
        }
        let css = "@font-face { font-family: '\(family)'; src: url(data:\(mime);base64,\(data.base64EncodedString())) format('\(format)'); font-display: block; }"
        cache[family] = css
        return css
    }

    static func familyName(of url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }
}

/// CSS color parsing / formatting for the color pickers.
enum CSSColor {
    static func parse(_ string: String) -> NSColor? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
            let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
            let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
            let a = hasAlpha ? Double(value & 0xff) / 255 : 1
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        if s.hasPrefix("rgb") {
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
            let parts = s[s.index(after: open)..<close]
                .replacingOccurrences(of: "/", with: ",")
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else { return nil }
            func component(_ text: String, scale: Double) -> Double {
                if text.hasSuffix("%") { return (Double(text.dropLast()) ?? 0) / 100 }
                return (Double(text) ?? 0) / scale
            }
            let r = component(parts[0], scale: 255)
            let g = component(parts[1], scale: 255)
            let b = component(parts[2], scale: 255)
            let a = parts.count > 3 ? component(parts[3], scale: 1) : 1
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        if s == "transparent" { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
        let named: [String: (Double, Double, Double)] = [
            "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 0.5, 0), "blue": (0, 0, 1),
            "yellow": (1, 1, 0), "orange": (1, 0.647, 0), "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5),
        ]
        if let rgb = named[s] { return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
        return nil
    }

    static func string(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = c.alphaComponent
        if a >= 0.999 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, a)
    }
}
