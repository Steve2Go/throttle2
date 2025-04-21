#if os(macOS)
import SwiftUI
import QuickLookThumbnailing
import ffmpegkit
import CryptoKit

class ThumbnailManager: NSObject {
    static let shared = ThumbnailManager()
    
    // Memory cache
    private let memoryCache = NSCache<NSString, NSImage>()
    
    // File manager and paths
    private let fileManager = FileManager.default
    @AppStorage("qlVideo") var qlVideo: Bool = false
    
    // Standard thumbnail size
    private let thumbnailSize = CGSize(width: 120, height: 120)
    
    // Concurrency control
    private let thumbnailQueue = DispatchQueue(label: "com.throttle.thumbnails", attributes: .concurrent)
    private let maxConcurrentOperations = 4
    private let semaphore = DispatchSemaphore(value: 4)
    
    // Track in-progress operations to avoid duplicates
    private var inProgressPaths = Set<String>()
    private let inProgressLock = NSLock()
    
    // Debug counter
    private var generationCounter = [String: Int]()
    private let counterLock = NSLock()
    
    private override init() {
        super.init()
        memoryCache.countLimit = 200 // Allow more items in memory
        setupCachePath()
    }
    
    // Ensure cache path exists
    private func setupCachePath() {
        guard let path = cachePath?.path, !fileManager.fileExists(atPath: path) else { return }
        try? fileManager.createDirectory(at: cachePath!, withIntermediateDirectories: true)
    }
    
    private var cachePath: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("thumbnailCache")
    }
    
    // Main public method - get a thumbnail for a path
    func getThumbnail(for path: String) async throws -> NSImage {
        // 1. Check memory cache first (fast path)
        if let cachedImage = memoryCache.object(forKey: path as NSString) {
            incrementGenerationCounter(for: path, status: "memory-hit")
            return cachedImage
        }
        
        // 2. Check if we're already processing this path
        if isAlreadyInProgress(path) {
            incrementGenerationCounter(for: path, status: "already-processing")
            // Wait a bit and check memory cache again
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if let cachedImage = memoryCache.object(forKey: path as NSString) {
                return cachedImage
            }
            
            // Wait longer if still not ready
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            if let cachedImage = memoryCache.object(forKey: path as NSString) {
                return cachedImage
            }
        }
        
        // Mark this path as in progress
        markAsInProgress(path)
        
        // Use semaphore to limit concurrent operations
        await withCheckedContinuation { continuation in
            semaphore.wait()
            continuation.resume()
        }
        
        // Always release semaphore and unmark path when done
        defer {
            semaphore.signal()
            unmarkAsInProgress(path)
        }
        
        // 3. Check disk cache
        if let diskCached = loadFromDiskCache(path: path) {
            incrementGenerationCounter(for: path, status: "disk-hit")
            // Add to memory cache for future requests
            memoryCache.setObject(diskCached, forKey: path as NSString)
            return diskCached
        }
        
        // 4. Need to generate a new thumbnail
        incrementGenerationCounter(for: path, status: "generating-new")
        
        do {
            let fileURL = URL(fileURLWithPath: path)
            let thumbnail: NSImage
            
            // Generate appropriate thumbnail
            if shouldUseFFmpeg(for: fileURL) {
                thumbnail = try await generateFFmpegThumbnail(for: path)
            } else {
                thumbnail = try await generateQuickLookThumbnail(for: path)
            }
            
            // 5. Ensure thumbnail is square
            let squareThumbnail = ensureSquareThumbnail(thumbnail)
            
            // 6. Cache the result in both memory and disk
            memoryCache.setObject(squareThumbnail, forKey: path as NSString)
            saveToDiskCache(squareThumbnail, for: path)
            
            return squareThumbnail
        } catch {
            print("Thumbnail generation error: \(error)")
            throw error
        }
    }
    
    // MARK: - Helper Methods for Tracking In-Progress Items
    
    private func isAlreadyInProgress(_ path: String) -> Bool {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        return inProgressPaths.contains(path)
    }
    
    private func markAsInProgress(_ path: String) {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        inProgressPaths.insert(path)
    }
    
    private func unmarkAsInProgress(_ path: String) {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        inProgressPaths.remove(path)
    }
    
    // MARK: - Counter for Debugging
    
    private func incrementGenerationCounter(for path: String, status: String) {
        counterLock.lock()
        defer { counterLock.unlock() }
        
        let count = generationCounter[path] ?? 0
        generationCounter[path] = count + 1
        
        print("[ThumbnailManager] \(status) for \(path) - Count: \(count + 1)")
    }
    
    // MARK: - Thumbnail Generation Methods
    
    private func shouldUseFFmpeg(for url: URL) -> Bool {
        // Determine if we should use FFmpeg based on file type and settings
        let ext = url.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "avi", "mkv", "flv", "mpeg", "m4v", "wmv"].contains(ext)
        
        // If not a video, don't use FFmpeg
        if !isVideo { return false }
        
        // If user prefers QuickLook for videos, don't use FFmpeg
        if qlVideo { return false }
        
        return true
    }
    
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
    
    private func generateFFmpegThumbnail(for path: String) async throws -> NSImage {
        guard let cachePath = cachePath else {
            throw NSError(domain: "ThumbnailManager", code: -1,
                     userInfo: [NSLocalizedDescriptionKey: "Cache path is nil"])
        }
        
        // Create temp output file
        let tempOutput = cachePath.appendingPathComponent(UUID().uuidString + ".jpg")
        
        // Try at 6 seconds first
        if let image = try await extractFrame(from: path, at: "00:00:06", output: tempOutput) {
            return image
        }
        
        // Fallback to 1 second if 6 seconds fails
        guard let image = try await extractFrame(from: path, at: "00:00:01", output: tempOutput, fallback: true) else {
            throw NSError(domain: "ThumbnailManager", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to extract frame from video"])
        }
        
        return image
    }
    
    private func extractFrame(from path: String, at timestamp: String, output: URL, fallback: Bool = false) async throws -> NSImage? {
        let ffmpegArgs = [
            "-y",                    // Overwrite output files
            "-ss", timestamp,        // Seek to timestamp
            "-i", path,              // Input file
            "-vframes", "1",         // Extract exactly one frame
            "-vf", "scale=120:120:force_original_aspect_ratio=increase,crop=120:120", // Scale and crop to square
            "-pix_fmt", "yuvj420p",  // Use full-range color space
            "-q:v", "2",             // JPEG quality (1-31, lower is better)
            output.path              // Output file
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.execute(withArgumentsAsync: ffmpegArgs) { session in
                // Clean up on function exit
                defer {
                    try? FileManager.default.removeItem(at: output)
                }
                
                // Check if session completed successfully
                guard let session = session,
                      session.getState() == .completed else {
                    // For the first attempt, just return nil so we can try the fallback timestamp
                    if !fallback {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: NSError(domain: "FFmpegKit", code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "FFmpeg session failed"]))
                    }
                    return
                }
                
                // Check return code
                let returnCode = session.getReturnCode()
                guard ((returnCode?.isValueSuccess()) != nil) else {
                    // For the first attempt, just return nil so we can try the fallback timestamp
                    if !fallback {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: NSError(domain: "FFmpegKit", code: -2,
                                                              userInfo: [NSLocalizedDescriptionKey: "FFmpeg returned error code: \(String(describing: returnCode?.getValue()))"]))
                    }
                    return
                }
                
                // Check if output file exists
                guard FileManager.default.fileExists(atPath: output.path) else {
                    if !fallback {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: NSError(domain: "FFmpegKit", code: -3,
                                           userInfo: [NSLocalizedDescriptionKey: "FFmpeg output file not found"]))
                    }
                    return
                }
                
                // Load the output image
                guard let image = NSImage(contentsOf: output) else {
                    if !fallback {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: NSError(domain: "FFmpegKit", code: -4,
                                           userInfo: [NSLocalizedDescriptionKey: "Failed to create image from FFmpeg output"]))
                    }
                    return
                }
                
                // Success!
                continuation.resume(returning: image)
            }
        }
    }
    
    // MARK: - Image Processing Helpers
    
    private func ensureSquareThumbnail(_ image: NSImage) -> NSImage {
        let size = min(image.size.width, image.size.height)
        
        // If already square (within 1px) and correct size, return as is
        if abs(image.size.width - image.size.height) <= 1.0 &&
           abs(image.size.width - thumbnailSize.width) <= 1.0 {
            return image
        }
        
        // Need to create a square image
        let squareImage = NSImage(size: NSSize(width: size, height: size))
        
        squareImage.lockFocus()
        
        // Center the image
        let xOffset = max(0, (image.size.width - size) / 2)
        let yOffset = max(0, (image.size.height - size) / 2)
        
        // Draw the original image, cropped to square
        image.draw(in: NSRect(x: -xOffset, y: -yOffset, width: image.size.width, height: image.size.height),
                  from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
                  operation: .copy, fraction: 1.0)
        
        squareImage.unlockFocus()
        
        // If not the target size, resize it
        if abs(size - thumbnailSize.width) > 1.0 {
            return resizeImage(squareImage, to: thumbnailSize)
        }
        
        return squareImage
    }
    
    private func resizeImage(_ image: NSImage, to size: CGSize) -> NSImage {
        let resizedImage = NSImage(size: size)
        
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: image.size),
                  operation: .copy, fraction: 1.0)
        resizedImage.unlockFocus()
        
        return resizedImage
    }
    
    // MARK: - Disk Cache Methods
    
    private func cacheKey(for path: String) -> String {
        // Create a shorter cache key using MD5 hash
        let data = Data(path.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func cacheFileURL(for path: String) -> URL? {
        guard let cachePath = cachePath else { return nil }
        
        let key = cacheKey(for: path)
        return cachePath.appendingPathComponent(key + ".jpg")
    }
    
    private func loadFromDiskCache(path: String) -> NSImage? {
        guard let cacheFile = cacheFileURL(for: path),
              fileManager.fileExists(atPath: cacheFile.path) else {
            return nil
        }
        
        // Attempt to load the image from disk
        let image = NSImage(contentsOf: cacheFile)
        return image
    }
    
    private func saveToDiskCache(_ image: NSImage, for path: String) {
        guard let cacheFile = cacheFileURL(for: path) else { return }
        
        // Ensure the cache directory exists
        setupCachePath()
        
        // Save using a temporary file first
        let tempFilePath = cacheFile.path + ".temp"
        let tempFileURL = URL(fileURLWithPath: tempFilePath)
        
        // Get JPEG representation
        guard let tiffRep = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRep),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            print("Could not get JPEG representation for thumbnail")
            return
        }
        
        // Create a direct file handle - avoid NSData.write for better reliability
        if fileManager.createFile(atPath: tempFilePath, contents: jpegData) {
            do {
                // If destination already exists, remove it
                if fileManager.fileExists(atPath: cacheFile.path) {
                    try fileManager.removeItem(at: cacheFile)
                }
                
                // Move temp file to final destination
                try fileManager.moveItem(at: tempFileURL, to: cacheFile)
                print("Successfully cached thumbnail to: \(cacheFile.path)")
            } catch {
                print("Error moving temp thumbnail file: \(error)")
                try? fileManager.removeItem(at: tempFileURL)
            }
        } else {
            print("Failed to create thumbnail cache file")
        }
    }
    
    // MARK: - Cache Management
    
    func clearCache() {
        // Clear memory cache
        memoryCache.removeAllObjects()
        
        // Clear disk cache
        guard let cachePath = cachePath else { return }
        try? fileManager.removeItem(at: cachePath)
        setupCachePath()
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
        
        func loadThumbnail(for path: String) {
            guard !isLoading else { return }
            
            // Update on main thread
            DispatchQueue.main.async {
                self.isLoading = true
            }
            
            // Cancel any existing task
            currentTask?.cancel()
            
            // Create a new task
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
        
        func cancelLoading() {
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
#endif
