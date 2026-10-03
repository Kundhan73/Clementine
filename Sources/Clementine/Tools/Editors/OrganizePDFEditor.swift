import AppKit
import ClementineCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class OrganizeModel: ObservableObject {
    struct Tile: Identifiable, Hashable {
        var ref: PageRef
        var id: UUID { ref.id }
    }

    @Published var tiles: [Tile] = []
    @Published var selection: Set<UUID> = []
    @Published var thumbSize: CGFloat = 150
    private(set) var sources: [InputItem]
    private var documents: [PDFDocument] = []
    private var cache: [String: NSImage] = [:]
    @Published var error: String?

    init(item: InputItem) {
        sources = [item]
        if let doc = PDFDocument(url: item.url), !doc.isLocked {
            documents = [doc]
            tiles = (0..<doc.pageCount).map { Tile(ref: PageRef(source: 0, page: $0)) }
        } else {
            error = "This PDF can't be opened (it may be password-protected)."
        }
    }

    func thumbnail(_ tile: Tile) -> NSImage? {
        let key = "\(tile.ref.source)-\(tile.ref.page)"
        if let cached = cache[key] { return cached }
        guard documents.indices.contains(tile.ref.source),
              let page = documents[tile.ref.source].page(at: tile.ref.page) else { return nil }
        let image = page.thumbnail(of: NSSize(width: 300, height: 300), for: .cropBox)
        cache[key] = image
        return image
    }

    var selected: [Int] { tiles.indices.filter { selection.contains(tiles[$0].id) } }

    func rotateSelected(by degrees: Int) {
        for i in selected { tiles[i].ref.rotation = ((tiles[i].ref.rotation + degrees) % 360 + 360) % 360 }
    }

    func deleteSelected() {
        tiles.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func duplicateSelected() {
        for i in selected.reversed() {
            var copy = tiles[i].ref
            copy.id = UUID()
            tiles.insert(Tile(ref: copy), at: i + 1)
        }
    }

    func move(_ id: UUID, before target: UUID?) {
        guard let from = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: from)
        if let target, let to = tiles.firstIndex(where: { $0.id == target }) {
            tiles.insert(tile, at: to)
        } else {
            tiles.append(tile)
        }
    }

    /// Appends pages from PDFs or images.
    func insert(_ urls: [URL]) {
        for url in urls {
            let item = InputItem.inspect(url)
            guard item.kind == .pdf || item.kind == .image else { continue }
            let doc: PDFDocument?
            if item.kind == .pdf {
                doc = PDFDocument(url: url)
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                let d = PDFDocument()
                d.insert(page, at: 0)
                doc = d
            } else {
                doc = nil
            }
            guard let doc, !doc.isLocked else { continue }
            sources.append(item)
            documents.append(doc)
            let index = sources.count - 1
            tiles += (0..<doc.pageCount).map { Tile(ref: PageRef(source: index, page: $0)) }
        }
    }
}

struct OrganizePDFEditor: View {
    let close: () -> Void
    @StateObject private var model: OrganizeModel
    @State private var dragging: UUID?

    init(item: InputItem, close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: OrganizeModel(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.rotateSelected(by: 270) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Button { model.rotateSelected(by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                Button { model.duplicateSelected() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: [])
                Button { addPages() } label: { Label("Insert…", systemImage: "doc.badge.plus") }
                Spacer()
                Image(systemName: "photo").font(.caption)
                Slider(value: $model.thumbSize, in: 90...300).frame(width: 120)
                Image(systemName: "photo").font(.body)
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.error != nil)
            .padding(10)
            if let error = model.error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize), spacing: 16)], spacing: 18) {
                        ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
                            PageTile(image: model.thumbnail(tile), number: index + 1, rotation: tile.ref.rotation,
                                     selected: model.selection.contains(tile.id), size: model.thumbSize)
                                .onTapGesture { toggle(tile.id) }
                                .onDrag {
                                    dragging = tile.id
                                    return NSItemProvider(object: tile.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: TileDrop(target: tile.id, model: model, dragging: $dragging))
                        }
                    }
                    .padding(16)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    loadURLs(providers)
                    return true
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
            EditorBottomBar(note: "\(model.tiles.count) pages · drag to reorder, drop PDFs or images to insert",
                            action: "Save", enabled: !model.tiles.isEmpty, cancel: close) {
                ToolUI.export(.organizePDF, items: model.sources, options: .organizePDF(model.tiles.map(\.ref)))
                close()
            }
        }
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
        } else {
            model.selection = [id]
        }
    }

    private func addPages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        if panel.runModal() == .OK { model.insert(panel.urls) }
    }

    private func loadURLs(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { model.insert([url]) } }
            }
        }
    }
}

struct TileDrop: DropDelegate {
    let target: UUID
    let model: OrganizeModel
    @Binding var dragging: UUID?

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        let model = self.model, target = self.target
        MainActor.assumeIsolated {
            withAnimation(.easeInOut(duration: 0.15)) { model.move(dragging, before: target) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct PageTile: View {
    let image: NSImage?
    let number: Int
    let rotation: Int
    let selected: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(Double(rotation)))
            .shadow(radius: selected ? 0 : 2)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text("\(number)").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
