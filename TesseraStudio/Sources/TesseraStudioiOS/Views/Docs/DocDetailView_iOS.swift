#if os(iOS)
import SwiftUI
import TesseraCore

// MARK: - DocDetailView_iOS

/// The iOS detail editor for a single Doc. Mirrors
/// ``NoteEditorView_iOS`` but with the Doc-specific chrome
/// (cover, icon, word count, favorite/archive/trash toggles).
public struct DocDetailView_iOS: View {

    @ObservedObject public var viewModel: DocEditorViewModel
    @State private var showDeleteConfirm: Bool = false

    public init(viewModel: DocEditorViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            TesseraEditorView(
                mode: .document,
                theme: .light,
                document: documentBinding,
                onMutationCommitted: { _, _ in
                    let ast = viewModel.document
                    Task { await viewModel.commitBody(ast) }
                }
            )
            statusBar
        }
        .navigationTitle(viewModel.doc.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await viewModel.toggleFavorite() } } label: {
                        Label(viewModel.doc.isFavorite ? "Unfavorite" : "Favorite",
                              systemImage: viewModel.doc.isFavorite ? "star.slash" : "star")
                    }
                    Button { Task { await viewModel.toggleArchived() } } label: {
                        Label(viewModel.doc.isArchived ? "Unarchive" : "Archive",
                              systemImage: viewModel.doc.isArchived ? "archivebox.fill" : "archivebox")
                    }
                    Button { Task { await viewModel.toggleTrashed() } } label: {
                        Label(viewModel.doc.isTrashed ? "Restore" : "Move to Trash",
                              systemImage: viewModel.doc.isTrashed ? "trash.slash" : "trash")
                    }
                    Divider()
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this document?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                showDeleteConfirm = false
                Task { _ = try? await viewModel.store.delete(id: viewModel.doc.id) }
            }
            Button("Cancel", role: .cancel) { showDeleteConfirm = false }
        }
    }

    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = viewModel.doc.coverImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill().frame(height: 120).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                            .frame(height: 60)
                            .overlay { Label("Cover unavailable", systemImage: "photo.slash").foregroundStyle(.secondary).font(.caption) }
                    case .empty:
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08))
                            .frame(height: 60).overlay { ProgressView() }
                    @unknown default: EmptyView()
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let emoji = viewModel.doc.iconEmoji, !emoji.isEmpty { Text(emoji).font(.title2) }
                TextField("Title", text: $viewModel.draftTitle, onCommit: {
                    Task { await viewModel.commitTitle() }
                })
                .textFieldStyle(.plain).font(.title2).fontWeight(.bold)
            }
            if !viewModel.doc.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(viewModel.doc.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.doc.wordCount) words · \(viewModel.doc.readingTimeMinutes) min")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if viewModel.isSaving { ProgressView().controlSize(.small) }
            if let err = viewModel.lastError {
                Text(err).foregroundStyle(.red).font(.caption2).lineLimit(1)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }

    private var documentBinding: Binding<DocumentAST> {
        Binding<DocumentAST>(
            get: { viewModel.document },
            set: { viewModel.setDocumentLocal($0) }
        )
    }
}

#endif
