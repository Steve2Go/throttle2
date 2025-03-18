import SwiftUI
import QuickLookThumbnailing
import Quartz
import UniformTypeIdentifiers

#if os(macOS)
enum FileType {
    case video
    case image
    case other
    
    static func determine(from url: URL) -> FileType {
        // Get the UTType for the file
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return .other
        }
        
        if type.conforms(to: .image) {
            return .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        
        return .other
    }
}

struct PathThumbnailView: View {
    let path: String
    @StateObject private var thumbnailLoader = ThumbnailLoader()
    
    class ThumbnailLoader: ObservableObject {
        @Published var thumbnail: NSImage?
        @Published var isLoading = false
        private var currentTask: Task<Void, Never>?
        
        func loadThumbnail(for path: String) {
            guard !isLoading else { return }
            isLoading = true
            
            currentTask = Task {
                do {
                    let url = URL(fileURLWithPath: path)
                    let thumbnail = await generateThumbnail(for: url)
                    
                    await MainActor.run {
                        self.thumbnail = thumbnail
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
        
        private func generateThumbnail(for url: URL) async -> NSImage? {
            let size = CGSize(width: 60, height: 60)
            
            do {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: size,
                    scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                    representationTypes: .thumbnail
                )
                
                let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                return thumbnail.nsImage
            } catch {
                print("Error generating thumbnail: \(error)")
                return nil
            }
        }
        
        func cancelLoading() {
            currentTask?.cancel()
            currentTask = nil
            isLoading = false
        }
    }
    
    var body: some View {
        Group {
            if let thumbnail = thumbnailLoader.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(4)
            } else if thumbnailLoader.isLoading {
                ProgressView()
                    .frame(width: 60, height: 60)
            } else {
                let fileType = FileType.determine(from: URL(fileURLWithPath: path))
                switch fileType {
                case .video:
                    Image("video")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                case .image:
                    Image("image")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                case .other:
                    Image("document")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .onAppear {
            thumbnailLoader.loadThumbnail(for: path)
        }
        .onDisappear {
            thumbnailLoader.cancelLoading()
        }
    }
}

// Optional: Preview provider for testing
#if DEBUG
struct PathThumbnailView_Previews: PreviewProvider {
    static var previews: some View {
        PathThumbnailView(path: "/path/to/test/file.jpg")
            .frame(width: 100, height: 100)
    }
}
#endif
#endif
