#if os(macOS)
import SwiftUI
import QuickLookThumbnailing
import CryptoKit

class ThumbnailManager: NSObject {
    static let shared = ThumbnailManager()
    
    // Standard thumbnail size
    private let thumbnailSize = CGSize(width: 120, height: 120)
    
    // Main public method - get a thumbnail for a path
    func getThumbnail(for path: String) async throws -> NSImage {
        
        do {
            let thumbnail: NSImage
            
            // Generate appropriate thumbnail
            thumbnail = try await generateQuickLookThumbnail(for: path)
            
            return thumbnail
        } catch {
            print("Thumbnail generation error: \(error)")
            throw error
        }
    }
    
    // MARK: - Thumbnail Generation Methods
    
    private func generateQuickLookThumbnail(for path: String) async throws -> NSImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: thumbnailSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        
        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return thumbnail.nsImage
    }
    
    // MARK: - Image Processing Helpers
    
    private func resizeImage(_ image: NSImage, to size: CGSize) -> NSImage {
        let resizedImage = NSImage(size: size)
        
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resizedImage.unlockFocus()
        
        return resizedImage
    }
}

// MARK: - Thumbnail View Implementation

struct PathThumbnailViewMacOS: View {
    let path: String
    @StateObject private var thumbnailLoader = ThumbnailLoader()
    
    class ThumbnailLoader: ObservableObject {
        @Published var thumbnail: NSImage?
        @Published var isLoading = false
        private var currentTask: Task<Void, Never>?
        private var delayTask: Task<Void, Never>?
        
        func scheduleLoadAfterDelay(for path: String) {
            // Cancel any existing tasks
            cancelAll()
            
            // Start delay task
            delayTask = Task {
                do {
                    // Wait for 1 second
                    try await Task.sleep(for: .seconds(1.5))
                    
                    // If not cancelled, start actual loading
                    if !Task.isCancelled {
                        await startLoading(for: path)
                    }
                } catch is CancellationError {
                    // Delay was cancelled, do nothing
                    return
                } catch {
                    // Handle any other errors
                    return
                }
            }
        }
        
        private func startLoading(for path: String) async {
            // Proceed only if the delay wasn't cancelled
            guard !Task.isCancelled else { return }
            
            // Set loading state on main thread
            await MainActor.run {
                self.isLoading = true
            }
            
            // Create a new loading task
            currentTask = Task {
                do {
                    let thumbnail = try await ThumbnailManager.shared.getThumbnail(for: path)
                    
                    // If not cancelled, update UI
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.thumbnail = thumbnail
                            self.isLoading = false
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.isLoading = false
                        }
                    }
                }
            }
        }
        
        func cancelAll() {
            // Cancel the delay task
            delayTask?.cancel()
            delayTask = nil
            
            // Cancel the loading task
            currentTask?.cancel()
            currentTask = nil
            
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }
    }
    
    var body: some View {
        Group {
            if let thumbnail = thumbnailLoader.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            } else {
                defaultImage
            }
        }
        .onAppear {
            let fileType = FileType.determine(from: URL(fileURLWithPath: path))
            if fileType == .video || fileType == .image {
                thumbnailLoader.scheduleLoadAfterDelay(for: path)
            }
        }
        .onDisappear {
            thumbnailLoader.cancelAll()
        }
    }
    
    private var defaultImage: some View {
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        let imageName: String = {
            switch fileType {
            case .video: return "video"
            case .image: return "image"
            case .other: return "document"
            }
        }()
        
        return Image(imageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 60, height: 60)
    }
}
#endif
