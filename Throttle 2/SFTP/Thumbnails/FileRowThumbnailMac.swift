#if os(macOS)
import SwiftUI
import QuickLookThumbnailing
import ffmpegkit

class ThumbnailManager: NSObject {
    static let shared = ThumbnailManager()
    
    // Use a concurrent queue for better parallel processing
    private let queue = DispatchQueue(label: "com.throttle.thumbnails", attributes: .concurrent)
    
    // Memory cache to complement file cache
    private var memoryCache = NSCache<NSString, NSImage>()
    
    private let fileManager = FileManager.default
    @AppStorage("qlVideo") var qlVideo: Bool = false
    
    // Thumbnail size constant to avoid recreating CGSize
    private let thumbnailSize = CGSize(width: 120, height: 120)
    
    // Cache
    private var cachePath: URL? {
        get {
            let path = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("thumbnailCache")
            if let path = path {
                if !fileManager.fileExists(atPath: path.path) {
                    try? fileManager.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
                }
            }
            return path
        }
    }

    private override init() {
        super.init()
        memoryCache.countLimit = 100 // Adjust based on your needs
    }
    
    func clearCache() {
        // Clear memory cache
        memoryCache.removeAllObjects()
        
        // Clear disk cache
        guard let cachePath = cachePath else { return }
        
        queue.async(flags: .barrier) {
            try? self.fileManager.removeItem(at: cachePath)
            try? self.fileManager.createDirectory(at: cachePath, withIntermediateDirectories: true)
        }
    }
    
    func getThumbnail(for path: String) async throws -> NSImage {
        // Check memory cache first
        if let cachedImage = memoryCache.object(forKey: path as NSString) {
            return cachedImage
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Task {
                    do {
                        // Check disk cache
                        if let cached = try? await self.loadCachedThumbnail(for: path) {
                            self.memoryCache.setObject(cached, forKey: path as NSString)
                            continuation.resume(returning: cached)
                            return
                        }
                        
                        let fileURL = URL(fileURLWithPath: path)
                        let thumbnail: NSImage
                        
                        // Generate thumbnail based on file type
                        if self.shouldUseFFmpeg(for: fileURL) {
                            thumbnail = try await self.generateFFmpegThumbnail(for: path)
                        } else {
                            thumbnail = try await self.generateQuickLookThumbnail(for: path)
                        }
                        
                        // Cache the result
                        self.memoryCache.setObject(thumbnail, forKey: path as NSString)
                        self.saveToDiskCache(thumbnail: thumbnail, for: path)
                        
                        continuation.resume(returning: thumbnail)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func shouldUseFFmpeg(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mkv", "avi", "flv", "wmv"].contains(ext) && !qlVideo
    }
    
    private func generateQuickLookThumbnail(for path: String) async throws -> NSImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: thumbnailSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail // Use .thumbnail instead of .all for faster generation
        )
        
        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return thumbnail.nsImage
    }
    
    private func generateFFmpegThumbnail(for path: String) async throws -> NSImage {
        guard let cachePath = cachePath else {
            throw NSError(domain: "ThumbnailManager", code: -1)
        }
        
        // Use the same cache file URL pattern as other thumbnails
        guard let cacheFile = cacheFileURL(for: path) else {
            throw NSError(domain: "ThumbnailManager", code: -2)
        }
        
        // If cached version exists, return it
        if fileManager.fileExists(atPath: cacheFile.path),
           let cachedImage = NSImage(contentsOf: cacheFile) {
            return cachedImage
        }
        
        let tempOutput = cachePath.appendingPathComponent(UUID().uuidString + ".jpg")
        
        // Try at 6 seconds first
        if let image = try? await extractFrame(from: path, at: "00:00:06", output: tempOutput) {
            // Save to cache and return
            if let tiffData = image.tiffRepresentation {
                try? tiffData.write(to: cacheFile)
            }
            return image
        }
        
        // Fall back to 1 second if 6 seconds fails
        return try await extractFrame(from: path, at: "00:00:01", output: tempOutput)
    }

    private func extractFrame(from path: String, at timestamp: String, output: URL) async throws -> NSImage {
        let ffmpegArgs = [
            "-y",
            "-ss", timestamp,
            "-i", path,
            "-vframes", "1",
            "-s", "120x120",
            "-f", "image2",
            output.path
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.execute(withArgumentsAsync: ffmpegArgs) { session in
                guard let session = session,
                      session.getReturnCode().isValueSuccess(),
                      let image = NSImage(contentsOf: output) else {
                    try? FileManager.default.removeItem(at: output)
                    continuation.resume(throwing: NSError(domain: "FFmpegKit", code: -1))
                    return
                }
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: output)
                
                continuation.resume(returning: image)
            }
        }
    }
    
    private func saveToDiskCache(thumbnail: NSImage, for path: String) {
        guard let cacheFile = cacheFileURL(for: path),
              let tiffData = thumbnail.tiffRepresentation else { return }
        
        queue.async(flags: .barrier) {
            try? tiffData.write(to: cacheFile)
        }
    }
    
    private func cacheFileURL(for path: String) -> URL? {
        guard let cachePath = cachePath else { return nil }
        
        // Create a safe filename by hashing the path
        let filename = path.data(using: .utf8)?
            .map { String(format: "%02x", $0) }
            .joined() ?? UUID().uuidString
            
        return cachePath.appendingPathComponent(filename + ".thumb")
    }
    
    private func loadCachedThumbnail(for path: String) async throws -> NSImage? {
        guard let cacheFile = cacheFileURL(for: path),
              fileManager.fileExists(atPath: cacheFile.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: cacheFile)
        return NSImage(data: data)
    }
}

struct PathThumbnailViewMacOS: View {
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
                    let thumb = try await ThumbnailManager.shared.getThumbnail(for: path)
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.thumbnail = thumb
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
                    .cornerRadius(8)
            } else {
                defaultImage
            }
        }
        .onAppear {
            let fileType = FileType.determine(from: URL(fileURLWithPath: path))
            if fileType == .video || fileType == .image {
                thumbnailLoader.loadThumbnail(for: path)
            }
        }
        .onDisappear {
            thumbnailLoader.cancelLoading()
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


enum FileType {
    case video
    case image
    case other
    
    static func determine(from url: URL) -> FileType {
        let ext = url.pathExtension.lowercased()
        
        if ["mp4", "mov", "avi", "mkv", "flv", "mpeg", "m4v", "wmv"].contains(ext) {
            return .video
        }
        
        if ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic"].contains(ext) {
            return .image
        }
        
        return .other
    }
}
#endif
