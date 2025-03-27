import SwiftUI

#if os(iOS)
public struct PathThumbnailView: View {
    let path: String
    let server: ServerEntity
    @State var fromRow: Bool?
    @State private var thumbnail: Image?
    @State private var isLoading = false
    @State private var loadingTask: Task<Void, Never>?
    
    public init(path: String, server: ServerEntity, fromRow: Bool? = nil) {
        self.path = path
        self.server = server
        _fromRow = State(initialValue: fromRow)
    }
    
    public var body: some View {
        Group {
            if let thumbnail = thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .padding(.trailing, 10)
            } else {
                let fileType = FileType.determine(from: URL(fileURLWithPath: path))
                switch fileType {
                case .video:
                    Image("video")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .padding(.trailing, 10)
                        .task {
                            await loadThumbnailIfNeeded()
                        }
                case .image:
                    Image("image")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .padding(.trailing, 10)
                        .task {
                            await loadThumbnailIfNeeded()
                        }
                case .other:
                    if fromRow == true {
                        Image("folder")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .padding(.trailing, 10)
                            .foregroundColor(.gray)
                    } else {
                        Image("document")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .padding(.trailing, 10)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .id(path) // Ensure view updates when path changes
        .task {
            await loadThumbnailIfNeeded()
        }
        .onDisappear {
            loadingTask?.cancel()
            loadingTask = nil
            ThumbnailManager.shared.cancelThumbnail(for: path)
        }
    }
    
    @MainActor
    private func loadThumbnailIfNeeded() async {
        // Don't reload if we already have a thumbnail or are loading
        guard thumbnail == nil, !isLoading else { return }
        
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        guard fileType == .video || fileType == .image else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let image = try await ThumbnailManager.shared.getThumbnail(for: path, server: server)
            if !Task.isCancelled {
                self.thumbnail = image
            }
        } catch {
            if !Task.isCancelled {
                print("❌ Error loading thumbnail for \(path): \(error)")
            }
        }
    }
}

public struct FileRowThumbnail: View {
    let item: FileItem
    let server: ServerEntity
    
     init(item: FileItem, server: ServerEntity) {
        self.item = item
        self.server = server
    }
    
    public var body: some View {
        PathThumbnailView(path: item.url.path, server: server)
    }
}
#endif
