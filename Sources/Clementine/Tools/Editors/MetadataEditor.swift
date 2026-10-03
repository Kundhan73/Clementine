import AppKit
import ClementineCore
import SwiftUI

@MainActor
final class MetadataModel: ObservableObject {
    @Published var rows: [MetadataEntry] = []
    @Published var fields = EditableMetadata()
    @Published var loading = true
    let item: InputItem

    init(item: InputItem) {
        self.item = item
        Task {
            let rows = await MetadataInspector.read(item)
            self.rows = rows
            self.fields = MetadataInspector.editable(item, from: rows)
            self.loading = false
        }
    }

    var canEdit: Bool { [.image, .audio, .video, .pdf].contains(item.kind) }
}

struct MetadataEditor: View {
    let close: () -> Void
    @StateObject private var model: MetadataModel
    @State private var search = ""

    init(item: InputItem, close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: MetadataModel(item: item))
    }

    private var filtered: [MetadataEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.rows }
        return model.rows.filter { "\($0.group) \($0.key) \($0.value)".lowercased().contains(q) }
    }

    private var groups: [String] {
        var seen: [String] = []
        for row in filtered where !seen.contains(row.group) { seen.append(row.group) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search metadata", text: $search)
                    .textFieldStyle(.roundedBorder)
                if model.item.kind != .document {
                    Button("Remove All Metadata…") {
                        ToolUI.export(.removeMetadata, items: [model.item], options: .none)
                        close()
                    }
                }
            }
            .padding(10)
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(filtered.filter { $0.group == group }) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.key)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 190, alignment: .leading)
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .lineLimit(4)
                                }
                                .contextMenu {
                                    Button("Copy Value") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.value, forType: .string)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if model.canEdit {
                Divider()
                Form {
                    TextField("Title", text: $model.fields.title)
                    TextField(model.item.kind == .pdf ? "Author" : "Artist / author", text: $model.fields.author)
                    TextField(model.item.kind == .pdf ? "Subject" : "Comment", text: $model.fields.comment)
                    if model.item.kind != .pdf {
                        TextField("Copyright", text: $model.fields.copyright)
                    }
                }
                .formStyle(.grouped)
                .frame(height: model.item.kind == .pdf ? 150 : 190)
            }
            EditorBottomBar(note: model.canEdit ? "Saves an edited copy" : "", action: model.canEdit ? "Save Copy" : "Done",
                            cancel: close) {
                if model.canEdit { ToolUI.export(.metadata, items: [model.item], options: .metadata(model.fields)) }
                close()
            }
        }
    }
}
