import AppKit
import SwiftUI
import WebKit

struct PagePanel: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var session: SessionController

    private static let userAgents: [(String, String)] = [
        ("Safari (default)", ""),
        ("Chrome (Mac)", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"),
        ("Firefox (Mac)", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:143.0) Gecko/20100101 Firefox/143.0"),
        ("iPad", "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"),
        ("iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelSection("Tab") {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldRow(label: "Name") {
                            TextField(tab.title.isEmpty ? "Uses page title" : tab.title, text: $tab.label)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        FieldRow(label: "Address") {
                            Text(tab.urlString)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Text("The tab name is used for the tab strip, the dashboard and new NDI/Syphon output names.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .card()
                }

                PanelSection("Display") {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldRow(label: "Zoom") {
                            HStack(spacing: 6) {
                                Slider(value: $tab.zoom, in: 0.25...3.0)
                                    .controlSize(.small)
                                Text("\(Int((tab.zoom * 100).rounded()))%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                        HStack {
                            Spacer()
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                                Button("\(Int(value * 100))%") { tab.zoom = value }
                                    .controlSize(.mini)
                            }
                        }
                        FieldRow(label: "Scrollbars") {
                            Toggle("Hide scrollbars", isOn: $tab.customization.hideScrollbars)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                        }
                        FieldRow(label: "Guides") {
                            Toggle("Show safe areas (not on air)", isOn: $session.showSafeAreas)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                        }
                        Text("Zoom scales the page like ⌘+/⌘− in a browser, and it is part of the broadcast.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .card()
                }

                PanelSection("Behavior") {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldRow(label: "Auto reload") {
                            Picker("", selection: $tab.autoReloadMinutes) {
                                Text("Off").tag(0)
                                Text("Every minute").tag(1)
                                Text("Every 5 minutes").tag(5)
                                Text("Every 10 minutes").tag(10)
                                Text("Every 15 minutes").tag(15)
                                Text("Every 30 minutes").tag(30)
                                Text("Every hour").tag(60)
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        FieldRow(label: "Audio") {
                            Toggle("Mute this tab", isOn: $tab.muted)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                        }
                        FieldRow(label: "Identify as") {
                            Picker("", selection: $tab.userAgent) {
                                ForEach(Self.userAgents, id: \.1) { entry in
                                    Text(entry.0).tag(entry.1)
                                }
                                if !Self.userAgents.contains(where: { $0.1 == tab.userAgent }) {
                                    Text("Custom").tag(tab.userAgent)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        Text("Changing the browser identity takes effect on the next reload.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .card()
                }

                PanelSection("Website data") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Logins and cookies are shared by all tabs and kept between launches.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Clear All Website Data…") { clearWebsiteData() }
                            .controlSize(.small)
                    }
                    .card()
                }
            }
            .padding(12)
        }
    }

    /// Uses an app-modal alert (a sheet could open underneath the docked canvas).
    private func clearWebsiteData() {
        let alert = NSAlert()
        alert.messageText = "Clear all cookies, caches and logins?"
        alert.informativeText = "You will be signed out of websites in every tab."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}
