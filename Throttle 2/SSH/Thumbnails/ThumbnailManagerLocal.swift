#if os(macOS)
import SwiftUI
import QuickLookThumbnailing
import CryptoKit
import Foundation

class ThumbnailManager: NSObject {
    static let shared = ThumbnailManager()
    
    // Add this property for the memory cache (500MB)
    let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 500 * 1024 * 1024 // 500MB
        return cache
    }()
    
    // Disk cache directory
    let diskCacheURL: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("com.throttle2.thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    // Standard thumbnail size
    private let thumbnailSize = CGSize(width: 120, height: 120)
    
    // Main public method - get a thumbnail for a path
    func getThumbnail(for path: String) async throws -> NSImage {
        let cacheKey = path as NSString
        // 1. Check memory cache first
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }
        // 2. Check disk cache
        let diskCachePath = diskCacheURL.appendingPathComponent(cacheKeyHash(for: path) + ".png")
        if let diskImage = NSImage(contentsOf: diskCachePath) {
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: Int(diskImage.size.width * diskImage.size.height * 4))
            return diskImage
        }
        // 3. Generate thumbnail
        do {
            let thumbnail = try await generateQuickLookThumbnail(for: path )
            // Save to memory cache
            let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
            memoryCache.setObject(thumbnail, forKey: cacheKey, cost: cost)
            // Save to disk cache
            if let tiffData = thumbnail.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: diskCachePath)
            }
            return thumbnail
        } catch {
            print("Thumbnail generation error: \(error)")
            throw error
        }
    }
    
    // Helper to hash the path for disk cache filename
    func cacheKeyHash(for path: String) -> String {
        if let data = path.data(using: .utf8) {
            return data.reduce("") { $0 + String(format: "%02x", $1) }
        }
        return UUID().uuidString
    }
    
    // MARK: - Thumbnail Generation Methods
    
    private func generateQuickLookThumbnail(for path: String) async throws -> NSImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path.precomposedStringWithCanonicalMapping ),
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
    
    // MARK: - Cache clearing
    public func clearCache() {
        // Clear memory cache
        memoryCache.removeAllObjects()
        // Clear disk cache
        let fileManager = FileManager.default
        let cacheURL = diskCacheURL
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                try fileManager.removeItem(at: fileURL)
            }
            print("Successfully cleared \(fileURLs.count) thumbnails from disk cache")
        } catch {
            // If we can't get directory contents or there's another error, try removing the entire directory
            try? fileManager.removeItem(at: cacheURL)
            print("Removed entire disk cache directory due to error: \(error.localizedDescription)")
            try? fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        }
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
        
        func checkMemoryOrDiskCache(for path: String) -> Bool {
            let cacheKey = path as NSString
            // Check memory cache
            if let cached = ThumbnailManager.shared.memoryCache.object(forKey: cacheKey) {
                DispatchQueue.main.async {
                    self.thumbnail = cached
                    self.isLoading = false
                }
                return true
            }
            // Check disk cache
            let diskCachePath = ThumbnailManager.shared.diskCacheURL.appendingPathComponent(ThumbnailManager.shared.cacheKeyHash(for: path) + ".png")
            if let diskImage = NSImage(contentsOf: diskCachePath) {
                DispatchQueue.main.async {
                    self.thumbnail = diskImage
                    self.isLoading = false
                }
                // Also update memory cache for future
                ThumbnailManager.shared.memoryCache.setObject(diskImage, forKey: cacheKey, cost: Int(diskImage.size.width * diskImage.size.height * 4))
                return true
            }
            return false
        }
        
        func scheduleLoadAfterDelay(for path: String) {
            // Cancel any existing tasks
            cancelAll()
            // Start delay task
            delayTask = Task {
                do {
                    // Wait for 1.5 seconds
                    try await Task.sleep(for: .seconds(1.5))
                    // If not cancelled, start actual loading
                    if !Task.isCancelled {
                        await startLoading(for: path)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
        
        private func startLoading(for path: String) async {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isLoading = true
            }
            currentTask = Task {
                do {
                    let thumbnail = try await ThumbnailManager.shared.getThumbnail(for: path)
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
            delayTask?.cancel()
            delayTask = nil
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
                // Check memory and disk cache instantly
                if !thumbnailLoader.checkMemoryOrDiskCache(for: path) {
                    // Only schedule delayed load if not in memory or disk cache
                    thumbnailLoader.scheduleLoadAfterDelay(for: path)
                }
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
            case .audio: return "audio"
            case .image: return "image"
            case .archive return "archive"
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
