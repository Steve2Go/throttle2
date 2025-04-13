//import SwiftUI
//
////#if os(iOS)
//public struct PathThumbnailView: View {
//    let path: String
//    let server: ServerEntity
//    @State var fromRow: Bool?
//    @State private var thumbnail: Image?
//    @State private var isLoading = false
//    @State private var loadingTask: Task<Void, Never>?
//    @State private var isVisible = false
//    
//    public init(path: String, server: ServerEntity, fromRow: Bool? = nil) {
//        self.path = path
//        self.server = server
//        _fromRow = State(initialValue: fromRow)
//    }
//    
//    public var body: some View {
//        Group {
//            if let thumbnail = thumbnail {
//                thumbnail
//                    .resizable()
//                    .aspectRatio(contentMode: .fill)
//                    .frame(width: 60, height: 60)
//                    .cornerRadius(8)
//                    .padding(.trailing, 10)
//            } else {
//                let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//                switch fileType {
//                case .video:
//                    Image("video")
//                        .resizable()
//                        .aspectRatio(contentMode: .fill)
//                        .frame(width: 60, height: 60)
//                        .padding(.trailing, 10)
//                case .image:
//                    Image("image")
//                        .resizable()
//                        .aspectRatio(contentMode: .fill)
//                        .frame(width: 60, height: 60)
//                        .padding(.trailing, 10)
//                case .other:
//                    if fromRow == true {
//                        Image("folder")
//                            .resizable()
//                            .aspectRatio(contentMode: .fill)
//                            .frame(width: 60, height: 60)
//                            .padding(.trailing, 10)
//                            .foregroundColor(.gray)
//                    } else {
//                        Image("document")
//                            .resizable()
//                            .aspectRatio(contentMode: .fill)
//                            .frame(width: 60, height: 60)
//                            .padding(.trailing, 10)
//                            .foregroundColor(.gray)
//                    }
//                }
//            }
//        }
//        .id(path) // Ensure view updates when path changes
//        .onAppear {
//            isVisible = true
//            //ThumbnailManager.shared.markAsVisible(path)
//            loadThumbnailIfNeeded()
//        }
//        .onDisappear {
//            isVisible = false
//           // ThumbnailManager.shared.markAsInvisible(path)
//            loadingTask?.cancel()
//            loadingTask = nil
//            ThumbnailManager.shared.cancelThumbnail(for: path)
//        }
//    }
//    
//    private func loadThumbnailIfNeeded() {
//        // Don't reload if we already have a thumbnail or are loading
//        guard thumbnail == nil, !isLoading, isVisible else { return }
//        
//        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//        guard fileType == .video || fileType == .image else { return }
//        
//        // Cancel any existing task
//        loadingTask?.cancel()
//        
//        // Start a new task
//        loadingTask = Task {
//            isLoading = true
//            defer { isLoading = false }
//            
//            do {
//                // Check visibility again before starting the potentially expensive operation
//                if !isVisible || Task.isCancelled { return }
//                
//                let image = try await ThumbnailManager.shared.getThumbnail(for: path, server: server)
//                
//                // Check again if view is still visible before updating UI
//                if isVisible && !Task.isCancelled {
//                    await MainActor.run {
//                        self.thumbnail = image
//                    }
//                }
//            } catch {
//                if isVisible && !Task.isCancelled {
//                    print("❌ Error loading thumbnail for \(path): \(error)")
//                }
//            }
//        }
//    }
//}
//
//public struct FileRowThumbnail: View {
//    let item: FileItem
//    let server: ServerEntity
//    
//    init(item: FileItem, server: ServerEntity) {
//        self.item = item
//        self.server = server
//    }
//    
//    public var body: some View {
//        PathThumbnailView(path: item.url.path, server: server)
//    }
//}
////#endif
