struct FileRowThumbnail: View {
    let item: FileItem
    let server: ServerEntity
    @StateObject private var thumbnailLoader = ThumbnailLoader()
    
    class ThumbnailLoader: ObservableObject {
        @Published var thumbnail: Image?
        @Published var isLoading = false
        
        func loadThumbnail(for path: String, server: ServerEntity) {
            guard !isLoading else { return }
            isLoading = true
            
            Task {
                do {
                    let thumb = try await ThumbnailManager.shared.getThumbnail(for: path, server: server)
                    await MainActor.run {
                        self.thumbnail = thumb
                        self.isLoading = false
                    }
                } catch {
                    print("Error loading thumbnail: \(error)")
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
            }
        }
    }
    
    var body: some View {
        Group {
            if thumbnailLoader.thumbnail != nil {
                thumbnailLoader.thumbnail?
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            } else {
                // Default icon based on file type
                let fileType = FileType.determine(from: item.url)
                switch fileType {
                case .video:
                    Image(systemName: "video")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .padding(.trailing, 10)
                case .image:
                    Image(systemName: "photo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .padding(.trailing, 10)
                case .other:
                    Image("document")
                        .resizable()
                        .frame(width: 60, height: 60)
                }
            }
        }
        .onAppear {
            let fileType = FileType.determine(from: item.url)
            if fileType == .video || fileType == .image {
                thumbnailLoader.loadThumbnail(for: item.url.path, server: server)
            }
        }
    }
}