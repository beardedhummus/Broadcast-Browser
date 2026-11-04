import AppKit
import SwiftUI

struct BookmarksManagerView: View {
    @ObservedObject var store: BookmarkStore
    let onOpen: (String) -> Void
    @State private var selection: Bookmark.ID?
    @State private var newTitle = ""
    @State private var newURL = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($store.bookmarks) { $bookmark in
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 10))
                        TextField("Title", text: $bookmark.title)
                            .textFieldStyle(.plain)
                            .frame(width: 170)
                        TextField("URL", text: $bookmark.url)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.secondary)
                        Button("Open") { onOpen(bookmark.url) }
                            .controlSize(.small)
                    }
                    .tag(bookmark.id)
                }
                .onMove { store.bookmarks.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { store.bookmarks.remove(atOffsets: $0) }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Title", text: $newTitle).frame(width: 150)
                TextField("https://", text: $newURL)
                Button("Add") {
                    guard !newURL.isEmpty else { return }
                    store.add(title: newTitle, url: newURL)
                    newTitle = ""
                    newURL = ""
                }
                .disabled(newURL.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .padding(10)
            Divider()
            HStack {
                Button("Delete") {
                    if let selection { store.bookmarks.removeAll { $0.id == selection } }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Import JSON…", action: importBookmarks)
                Button("Export JSON…", action: exportBookmarks)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 380)
        .preferredColorScheme(.dark)
    }

    private func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importFile(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func exportBookmarks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Broadcast Browser Bookmarks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportFile(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
