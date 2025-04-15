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
    
    // Rate limiter to prevent too many concurrent operations
    private let semaphore = DispatchSemaphore(value: 4) // Allow 4 concurrent operations
    
    // Processing queue to track which files are already being processed
    private var processingPaths = Set<String>()
    private let processingQueue = DispatchQueue(label: "com.throttle.thumbnails.processing", attributes: .concurrent)
    
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
    
    // Check if QuickLook Video plugin is installed
    private lazy var isQuickLookVideoAvailable: Bool = {
        // Check for the QuickLook Video plugin in common locations
        let possiblePaths = [
            "/Library/QuickLook/Video.qlgenerator",
            "/System/Library/QuickLook/Video.qlgenerator",
            "~/Library/QuickLook/Video.qlgenerator"
        ]
        
        for path in possiblePaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            if fileManager.fileExists(atPath: expandedPath) {
                return true
            }
        }
        
        // Try alternate method: check if we can generate thumbnails for a common video format
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let testFile = appSupportURL.appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            if fileManager.fileExists(atPath: testFile.path) {
                return true
            }
        }
        
        // Default to assuming it's not available
        return false
    }()

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
        // Check memory cache first (fast path)
        if let cachedImage = memoryCache.object(forKey: path as NSString) {
            return cachedImage
        }
        
        // Check if this path is already being processed
        var isAlreadyProcessing = false
        await withCheckedContinuation { continuation in
            processingQueue.sync(flags: .barrier) {
                isAlreadyProcessing = processingPaths.contains(path)
                if !isAlreadyProcessing {
                    processingPaths.insert(path)
                }
                continuation.resume()
            }
        }
        
        // If already processing, wait a bit and check cache again
        if isAlreadyProcessing {
            // Wait a short time for the other task to complete
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Check cache again
            if let cachedImage = memoryCache.object(forKey: path as NSString) {
                return cachedImage
            }
            
            // If still not in cache, wait longer
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            if let cachedImage = memoryCache.object(forKey: path as NSString) {
                return cachedImage
            }
        }
        
        // Use semaphore to limit concurrent operations
        await withCheckedContinuation { continuation in
            Task {
                semaphore.wait()
                continuation.resume()
            }
        }
        
        defer {
            // Always release the semaphore and remove from processing set
            semaphore.signal()
            processingQueue.async(flags: .barrier) {
                self.processingPaths.remove(path)
            }
        }
        
        // Check disk cache
        if let cached = try? await loadCachedThumbnail(for: path) {
            memoryCache.setObject(cached, forKey: path as NSString)
            return cached
        }
        
        do {
            let fileURL = URL(fileURLWithPath: path)
            let thumbnail: NSImage
            
            // Generate thumbnail based on file type
            if shouldUseFFmpeg(for: fileURL) {
                thumbnail = try await generateFFmpegThumbnail(for: path)
            } else {
                thumbnail = try await generateQuickLookThumbnail(for: path)
            }
            
            // Ensure the thumbnail is square
            let squareThumbnail = ensureSquareImage(thumbnail)
            
            // Cache the result
            memoryCache.setObject(squareThumbnail, forKey: path as NSString)
            saveToDiskCache(thumbnail: squareThumbnail, for: path)
            
            return squareThumbnail
        } catch {
            // In case of error, remove from processing set to allow retries
            processingQueue.async(flags: .barrier) {
                self.processingPaths.remove(path)
            }
            throw error
        }
    }
    
    private func shouldUseFFmpeg(for url: URL) -> Bool {
        // Check if this is a video file
        let ext = url.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "avi", "mkv", "flv", "mpeg", "m4v", "wmv"].contains(ext)
        
        if !isVideo {
            return false // Not a video, use QuickLook
        }
        
        // If qlVideo setting is enabled, try to use QuickLook
        if qlVideo {
            return false
        }
        
        // Check if QuickLook Video plugin is installed
        if isQuickLookVideoAvailable {
            return false // QuickLook Video is available, use it
        }
        
        // QuickLook Video isn't available, use FFmpeg for all video formats
        return true
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
        let image = try await extractFrame(from: path, at: "00:00:01", output: tempOutput)
        
        // Explicitly save to cache
        if let tiffData = image.tiffRepresentation {
            try? tiffData.write(to: cacheFile)
        }
        
        return image
    }

    private func extractFrame(from path: String, at timestamp: String, output: URL) async throws -> NSImage {
        // Create a square thumbnail using proper scaling and cropping
        let ffmpegArgs = [
            "-y",                    // Overwrite output files
            "-ss", timestamp,        // Seek to timestamp
            "-i", path,              // Input file
            "-vframes", "1",         // Extract exactly one frame
            "-vf", "scale=120:120:force_original_aspect_ratio=increase,crop=120:120", // Scale and crop to square
            "-f", "image2",          // Output format
            output.path              // Output file
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
    
    // Helper function to ensure images are square
    private func ensureSquareImage(_ image: NSImage) -> NSImage {
        let size = min(image.size.width, image.size.height)
        
        // If already square-ish (within 1px), return as is
        if abs(image.size.width - image.size.height) <= 1.0 {
            // Just resize to exact square if needed
            if abs(image.size.width - thumbnailSize.width) > 1.0 ||
               abs(image.size.height - thumbnailSize.height) > 1.0 {
                return resizeImage(image, toSize: thumbnailSize)
            }
            return image
        }
        
        // Create a new square image
        let squareImage = NSImage(size: NSSize(width: size, height: size))
        
        squareImage.lockFocus()
        
        // Calculate offset to center the image
        let xOffset = max(0, (image.size.width - size) / 2)
        let yOffset = max(0, (image.size.height - size) / 2)
        
        // Draw the original image, cropped to square
        image.draw(in: NSRect(x: -xOffset, y: -yOffset, width: image.size.width, height: image.size.height),
                   from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
                   operation: .copy, fraction: 1.0)
        
        squareImage.unlockFocus()
        
        // Resize to the target size if needed
        if abs(size - thumbnailSize.width) > 1.0 {
            return resizeImage(squareImage, toSize: thumbnailSize)
        }
        
        return squareImage
    }
    
    // Helper function to resize an image
    private func resizeImage(_ image: NSImage, toSize size: CGSize) -> NSImage {
        let resizedImage = NSImage(size: size)
        
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resizedImage.unlockFocus()
        
        return resizedImage
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
