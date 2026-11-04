import AppKit
import SwiftUI

struct StartView: View {
    let onNewSession: () -> Void
    let onOpenSession: () -> Void
    let onOpenRecent: (URL) -> Void
    let onRecover: () -> Void
    let onPreferences: () -> Void
    @EnvironmentObject var app: AppModel

    private var hasAutosave: Bool {
        FileManager.default.fileExists(atPath: AppPaths.autosaveURL.path)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 330)
            Divider()
            RecentSessionsList(recents: app.recents, onOpen: onOpenRecent)
        }
        .frame(width: 860, height: 540)
        .background(Color.bbChrome)
        .preferredColorScheme(.dark)
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 46)
            AppMark()
                .frame(width: 72, height: 72)
            Text("Broadcast Browser")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 16)
            Text("Turn browser tabs into video sources.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(spacing: 10) {
                StartButton(title: "New Session", subtitle: "Start with a blank tab", symbol: "plus.rectangle.on.rectangle", prominent: true, action: onNewSession)
                StartButton(title: "Open Session…", subtitle: "Load a saved .json session", symbol: "folder", action: onOpenSession)
                if hasAutosave {
                    StartButton(title: "Recover Unsaved Session", subtitle: "Restore the last autosave", symbol: "clock.arrow.circlepath", action: onRecover)
                }
            }
            .padding(.top, 30)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("DeckLink SDI/HDMI · NDI® · Syphon · Display · Record")
                    .foregroundStyle(.tertiary)
                Button("Preferences…", action: onPreferences)
                    .buttonStyle(.link)
            }
            .font(.system(size: 11))
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 30)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [Color.bbLive.opacity(0.14), Color.clear], startPoint: .topLeading, endPoint: .center)
        )
    }
}

struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 44, height: 30)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.black.opacity(0.25)).frame(height: 7)
                    }
            }
            Circle()
                .fill(Color.bbLive)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color(white: 0.12), lineWidth: 3))
                .offset(x: 22, y: 16)
        }
    }
}

struct StartButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 28)
                    .foregroundStyle(prominent ? Color.white : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(prominent ? Color.white.opacity(0.8) : Color.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(prominent ? Color.bbLive.opacity(hovering ? 1 : 0.88) : Color.white.opacity(hovering ? 0.1 : 0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct RecentSessionsList: View {
    @ObservedObject var recents: RecentSessionsStore
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Sessions")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 46)
                .padding(.bottom, 10)
            if recents.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                    Text("No recent sessions")
                        .font(.system(size: 13, weight: .medium))
                    Text("Sessions you save or open appear here.\nThey store your tabs, output settings and site customizations.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recents.items) { item in
                            RecentRow(item: item, onOpen: { onOpen(item.url) }, onRemove: { recents.remove(item) })
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RecentRow: View {
    let item: RecentSession
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12.5, weight: .medium))
                    Text((item.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(item.tabCount) tab\(item.tabCount == 1 ? "" : "s") · \(item.outputCount) output\(item.outputCount == 1 ? "" : "s")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(item.lastOpened, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.white.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from List") { onRemove() }
        }
    }
}
