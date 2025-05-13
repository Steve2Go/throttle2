#if os(iOS)
import SwiftUI
import KeychainAccess
import UIKit
import AVFoundation
import Citadel
import NIO

public class ThumbnailManager: NSObject {
    public static let shared = ThumbnailManager()
    private let fileManager = FileManager.default
    private let thumbnailQueue = DispatchQueue(label: "com.throttle.thumbnailQueue", qos: .utility)
    private var inProgressPaths = Set<String>()
    private let inProgressLock = NSLock()
    
    // Visibility tracking for optimization
    private var visiblePaths = Set<String>()
    private let visiblePathsLock = NSLock()
    
    // Memory cache to complement file cache
    //private let memoryCache = NSCache<NSString, UIImage>()
    //private let memoryCache = NSCache<NSString, UIImage>()
    
    // Cache of SSH connections by server identifier
    private var connections = [String: SSHConnection]()
    private let connectionsLock = NSLock()
    
    // Semaphore dictionary to limit connections per server
    private var serverSemaphores = [String: DispatchSemaphore]()
    private let semaphoreAccess = NSLock()
    
    // Add an async actor-based semaphore
    actor AsyncSemaphore {
        private var value: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(value: Int) {
            self.value = value
        }

        func wait() async {
            if value > 0 {
                value -= 1
            } else {
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }
        }

        func signal() {
            if !waiters.isEmpty {
                let continuation = waiters.removeFirst()
                continuation.resume()
            } else {
                value += 1
            }
        }
    }
    
    // Replace getSemaphore(for:) to return AsyncSemaphore
    private var asyncSemaphores: [String: AsyncSemaphore] = [:]
    private func getAsyncSemaphore(for server: ServerEntity) -> AsyncSemaphore {
        let key = server.name ?? server.sftpHost ?? "default"
        if let sem = asyncSemaphores[key] { return sem }
        let max = max(1, server.thumbMax)
        let sem = AsyncSemaphore(value: Int(max))
        asyncSemaphores[key] = sem
        return sem
    }
    
    // Cache directory for saved thumbnails
    private var cacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("thumbnailCache")
    }
    
    override init() {
        super.init()
        createCacheDirectoryIfNeeded()
        //memoryCache.countLimit = 150 // Increased memory cache size
    }
    
    private func createCacheDirectoryIfNeeded() {
        if let cacheDir = cacheDirectory, !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }
    
    // Get or create an SSH connection for a server
    private func getConnection(for server: ServerEntity) -> SSHConnection {
        let serverKey = server.name ?? server.sftpHost ?? "default"
        
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        
        if let connection = connections[serverKey] {
            return connection
        } else {
            let newConnection = SSHConnection(server: server)
            connections[serverKey] = newConnection
            return newConnection
        }
    }
    
    // MARK: - Visibility tracking methods
    
    public func markAsVisible(_ path: String) {
        visiblePathsLock.lock()
        defer { visiblePathsLock.unlock() }
        visiblePaths.insert(path)
    }
    
    public func markAsInvisible(_ path: String) {
        visiblePathsLock.lock()
        defer { visiblePathsLock.unlock() }
        visiblePaths.remove(path)
    }
    
    private func isVisible(_ path: String) -> Bool {
        visiblePathsLock.lock()
        defer { visiblePathsLock.unlock() }
        return visiblePaths.contains(path)
    }
    
    /// Main entry point – returns a SwiftUI Image thumbnail for a given path.
    public func getThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        print("[ThumbnailManager] getThumbnail called for path: \(path), server: \(server.name ?? server.sftpHost ?? "default")")
        // If not visible, return default immediately
        if !isVisible(path) {
            return defaultThumbnail(for: path)
        }
        
//        // Check memory cache first (fastest)
//        if let cachedImage = memoryCache.object(forKey: path as NSString) {
//            return Image(uiImage: cachedImage)
//        }
        
        // Check disk cache next
        if let cached = try? await loadFromCache(for: path) {
            return cached
        }
        
        // If path isn't marked as in-progress, proceed with generating
        let alreadyInProgress = markInProgress(path: path)
        if alreadyInProgress {
            return defaultThumbnail(for: path)
        }
        
        let semaphore = self.getAsyncSemaphore(for: server)
        await semaphore.wait()
        var didSignal = false
        func signalIfNeeded() async {
            if !didSignal {
                await semaphore.signal()
                didSignal = true
            }
        }
        defer { clearInProgress(path: path) }
        
        // Check again if path is still visible before proceeding
        if !self.isVisible(path) {
            await signalIfNeeded()
            return self.defaultThumbnail(for: path)
        }
        
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        let thumbnail: Image
        if fileType == .video || fileType == .image {
           
                do {
                    thumbnail = try await self.generateFFmpegThumbnail(for: path, server: server)
                } catch {
                    print("FFmpeg thumbnail failed, using default: \(error.localizedDescription)")
                    thumbnail = self.defaultThumbnail(for: path)
                }
            
        } else if fileType == .audio {
            thumbnail = Image(systemName: "music.note")
        } else {
            thumbnail = self.defaultThumbnail(for: path)
        }
        await signalIfNeeded()
        return thumbnail
    }
    
    private func markInProgress(path: String) -> Bool {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        
        if inProgressPaths.contains(path) {
            return true // Already in progress
        }
        
        inProgressPaths.insert(path)
        return false // Not previously in progress
    }
    
    private func clearInProgress(path: String) {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        inProgressPaths.remove(path)
    }
    
   
    // MARK: - Video thumbs via FFmpeg (server-side) with connection reuse
    private func generateFFmpegThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        print("[ThumbnailManager] generateFFmpegThumbnail called for path: \(path), server: \(server.name ?? server.sftpHost ?? "default")")
        // Ensure the thumbs directory exists before any ffmpeg command
        let connection = getConnection(for: server)
        let createThumbsDirCmd = "mkdir -p $HOME/thumbs"
        let (mkdirStatus, mkdirOutput) = try await connection.executeCommand(createThumbsDirCmd)
        print("[ThumbnailManager] mkdir status: \(mkdirStatus), output: \(mkdirOutput)")
        
        guard let ffmpegPath = await ensureFFmpegAvailable(for: server) else {
            print("[ThumbnailManager] FFmpeg not available on server, using default thumbnail.")
            throw NSError(domain: "ThumbnailManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "FFmpeg not available on server"])
        }
        // Use /tmp for remote thumbnails as in the original working version
        let remoteTempThumbPath = "/tmp/thumb_\(UUID().uuidString).jpg"
        print("[ThumbnailManager] Remote temp thumb path: \(remoteTempThumbPath)")
        let tempDir = FileManager.default.temporaryDirectory
        let localTempURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        FileManager.default.createFile(atPath: localTempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: localTempURL) }
        let escapedPath = shellQuote(path)
        let escapedThumbPath = shellQuote(remoteTempThumbPath)
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        let timestamps = ["00:01:00.000","00:00:10.000", "00:00:00.000", "00:00:00.000"]
        var attempts = 0
        for timestamp in timestamps {
            attempts += 1
            let ffmpegCmd: String
            if fileType == .video {
                if attempts < 4 {
                    ffmpegCmd = "\(ffmpegPath) -ss \(timestamp) -i \(escapedPath) -vframes 1 \(escapedThumbPath) 2>/dev/null || echo $?"
                } else {
                    ffmpegCmd = "\(ffmpegPath) -ss \(timestamp) -i \(escapedPath) -vframes 1 -vsync vfr \(escapedThumbPath) 2>/dev/null || echo $?"
                }
            } else {
                ffmpegCmd = "\(ffmpegPath) -i \(escapedPath) -vf scale=150:-1 \(escapedThumbPath) 2>/dev/null || echo $?"
            }
            print("[ThumbnailManager] About to run ffmpeg command for path: \(path)")
            do {
                print("[ThumbnailManager] Running ffmpeg command: \(ffmpegCmd)")
                let (status, ffmpegOutput) = try await connection.executeCommand(ffmpegCmd)
                print("[ThumbnailManager] ffmpeg output: \(ffmpegOutput)")
                print("[ThumbnailManager] ffmpeg status: \(status)")
                // If ffmpeg is missing or not executable, clear the stored path and save context
                if ffmpegOutput.contains("not found") || ffmpegOutput.contains("No such file or directory") || status == 127 {
                    print("[ThumbnailManager] ffmpeg binary missing or not executable, clearing server.ffmpegPath and will reinstall on next request.")
                    server.ffmpegPath = nil
                    _ = try? server.managedObjectContext?.save()
                    continue
                }
                let testCmd = "[ -f \(escapedThumbPath) ] && echo 'success' || echo 'failed'"
                let (_, testOutput) = try await connection.executeCommand(testCmd)
                let testResult = testOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if testResult == "success" {
                    do {
                        try await connection.downloadFile(remotePath: remoteTempThumbPath, localURL: localTempURL) { _ in }
                        let cleanupCmd = "rm -f \(escapedThumbPath)"
                        _ = try? await connection.executeCommand(cleanupCmd)
                        guard let imageData = try? Data(contentsOf: localTempURL), let uiImage = UIImage(data: imageData) else {
                            print("[ThumbnailManager] Failed to load image data from localTempURL: \(localTempURL)")
                            continue
                        }
                        if isEmptyImage(uiImage) {
                            print("[ThumbnailManager] Generated image is empty for path: \(path)")
                            continue
                        }
                        let thumb = processThumbnail(uiImage: uiImage, isVideo: fileType == .video ? true : false)
                        _ = try? saveToCache(image: uiImage, for: path)
                        print("[ThumbnailManager] Successfully generated and cached thumbnail for path: \(path)")
                        return thumb
                    } catch {
                        print("[ThumbnailManager] Error downloading or processing FFmpeg thumbnail for path: \(path): \(error)")
                        continue
                    }
                } else {
                    print("[ThumbnailManager] ffmpeg did not create a thumbnail for path: \(path), testResult: \(testResult)")
                }
                let cleanupCmd = "rm -f \(escapedThumbPath)"
                _ = try? await connection.executeCommand(cleanupCmd)
            } catch {
                print("[ThumbnailManager] Error running ffmpeg command for path: \(path): \(error)")
                continue
            }
        }
        print("[ThumbnailManager] All attempts failed to generate thumbnail for path: \(path)")
        throw NSError(domain: "ThumbnailManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail with FFmpeg"])
    }
    
    // Helper function to check if image is empty (solid color)
    private func isEmptyImage(_ image: UIImage) -> Bool {
        // Quick check - if image size is invalid, consider it empty
        guard let cgImage = image.cgImage,
              cgImage.width > 1 && cgImage.height > 1 else {
            return true
        }
        
        // Create a small bitmap context and draw the image
        let width = min(cgImage.width, 20)  // Sample at most 20x20 pixels
        let height = min(cgImage.height, 20)
        let bytesPerRow = width * 4
        let bitmapData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { bitmapData.deallocate() }
        
        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Check for pixel variation
        var firstPixel: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
        var hasInitialPixel = false
        var hasVariation = false
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let r = bitmapData[offset]
                let g = bitmapData[offset + 1]
                let b = bitmapData[offset + 2]
                
                // Save first pixel
                if !hasInitialPixel {
                    firstPixel = (r, g, b)
                    hasInitialPixel = true
                    continue
                }
                
                // Check for meaningful variation
                let rDiff = abs(Int(r) - Int(firstPixel.r))
                let gDiff = abs(Int(g) - Int(firstPixel.g))
                let bDiff = abs(Int(b) - Int(firstPixel.b))
                
                if rDiff > 5 || gDiff > 5 || bDiff > 5 {
                    hasVariation = true
                    break
                }
            }
            if hasVariation {
                break
            }
        }
        
        return !hasVariation
    }
    
    // MARK: - Thumbnail Processing & Caching
    
    private func processThumbnail(uiImage: UIImage, isVideo: Bool) -> Image {
        let size = CGSize(width: 60, height: 60)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumbnailImage = renderer.image { context in
            let scale = max(size.width / uiImage.size.width, size.height / uiImage.size.height)
            let scaledSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
            let origin = CGPoint(x: (size.width - scaledSize.width) / 2,
                                 y: (size.height - scaledSize.height) / 2)
            uiImage.draw(in: CGRect(origin: origin, size: scaledSize))
            
            if isVideo {
                let badgeSize = size.width * 0.3
                let badgeRect = CGRect(x: size.width - badgeSize - 2,
                                       y: size.height - badgeSize - 2,
                                       width: badgeSize,
                                       height: badgeSize)
                context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
                context.cgContext.fillEllipse(in: badgeRect)
                if let badge = UIImage(systemName: "play.fill") {
                    let badgeTintColor = UIColor.white
                    badge.withTintColor(badgeTintColor).draw(in: badgeRect)
                }
            }
        }
        return Image(uiImage: thumbnailImage)
    }
    
    private func defaultThumbnail(for path: String) -> Image {
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        switch fileType {
        case .video:
            return Image("playback")
        case .image:
            return Image("image")
        case .audio:
            return Image(systemName: "music.note")
        default:
            return Image("item")
        }
    }
    
    // MARK: - Cache methods
    
    private func cacheFileURL(for path: String) -> URL? {
        guard let cacheDir = cacheDirectory else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let filename = encoded.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "%", with: "_")
        return cacheDir.appendingPathComponent(filename + ".thumb")
    }
    
    private func saveToCache(image: UIImage, for path: String) throws {
        guard let cacheURL = cacheFileURL(for: path),
              let jpegData = image.jpegData(compressionQuality: 0.8) else { return }
        try jpegData.write(to: cacheURL)
    }
    
    private func loadFromCache(for path: String) async throws -> Image? {
        guard let cacheURL = cacheFileURL(for: path),
              fileManager.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let uiImage = UIImage(data: data) else { return nil }
        
        // Store in memory cache too
        //memoryCache.setObject(uiImage, forKey: path as NSString)
        
        // Determine if it's a video for proper badge display
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        return processThumbnail(uiImage: uiImage, isVideo: fileType == .video)
    }
    
    // MARK: - Public methods
    
    public func clearCache() {
        // Clear memory cache
       // memoryCache.removeAllObjects()
        
        if let cacheURL = cacheDirectory {
            do {
                // Get all files in the cache directory
                let fileURLs = try fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
                
                // Remove each file individually
                for fileURL in fileURLs {
                    try fileManager.removeItem(at: fileURL)
                }
                
                print("Successfully cleared \(fileURLs.count) thumbnails from cache")
            } catch {
                // If we can't get directory contents or there's another error, try removing the entire directory
                try? fileManager.removeItem(at: cacheURL)
                print("Removed entire cache directory due to error: \(error.localizedDescription)")
                createCacheDirectoryIfNeeded()
            }
        }
    }
    
    public func cancelThumbnail(for path: String) {
        clearInProgress(path: path)
        markAsInvisible(path)
    }
    
    // MARK: - clear the queue
    public func clearAllConnections() {
        // Clear all in-progress paths
        inProgressLock.lock()
        inProgressPaths.removeAll()
        inProgressLock.unlock()
        
        // Clear semaphores to reset connection limits
        semaphoreAccess.lock()
        serverSemaphores.removeAll()
        semaphoreAccess.unlock()
        
        // Clear visibility tracking
        visiblePathsLock.lock()
        visiblePaths.removeAll()
        visiblePathsLock.unlock()
        
        // Get and clean up all SSH connections
        connectionsLock.lock()
        let activeConnections = connections.values
        connections.removeAll()
        connectionsLock.unlock()
        
        // Disconnect all SSH connections without holding a lock
        for connection in activeConnections {
            Task {
                await connection.disconnect()
            }
        }
        
        // Log the cleanup action
        print("All thumbnail operations canceled and connections reset")
    }
    
    deinit {
        // Properly clean up connection managers without capturing self
        connectionsLock.lock()
        let activeConnections = connections.values
        connections.removeAll()
        connectionsLock.unlock()
        
        // Note: We're not awaiting these disconnects since this is deinit
        for connection in activeConnections {
            Task {
                await connection.disconnect()
            }
        }
    }
    
    // Helper to get or install ffmpeg for a server, pausing all requests until done
    private func ensureFFmpegAvailable(for server: ServerEntity) async -> String? {
        print("starting ffmpeg checks")
        // Use the persistent ffmpegPath if available
        if let path = server.ffmpegPath, !path.isEmpty {
            print("[ThumbnailManager] Using persisted ffmpegPath for server: \(server.name ?? server.sftpHost ?? "default"): \(path)")
            return path
        }
        // Otherwise, detect or install ffmpeg
        let connection = getConnection(for: server)
        let knownInstallPaths = [
            "ffmpeg",
            "$HOME/bin/ffmpeg",
            "$HOME/bin/ffmpeg-master-latest-win64-gpl-shared/bin/ffmpeg.exe"
        ]
        var foundPath: String? = nil
        print("checking paths")
        for path in knownInstallPaths {
            print("[ThumbnailManager] Checking ffmpeg at: \(path) for server: \(server.name ?? server.sftpHost ?? "default")")
            if let (_, testOutput) = try? await connection.executeCommand("\(path) -version || echo 'notfound'") {
                print("[ThumbnailManager] Output for \(path): \(testOutput)")
                if !testOutput.contains("notfound") && !testOutput.contains("not found") {
                    foundPath = path
                    break
                }
            }
        }
        if foundPath == nil {
            print("[ThumbnailManager] ffmpeg not found, attempting install for server: \(server.name ?? server.sftpHost ?? "default")...")
            do {
                foundPath = try await RemoteFFmpegInstaller.ensureFFmpegAvailable(connection: connection)
                print("[ThumbnailManager] ffmpeg installed at: \(String(describing: foundPath)) for server: \(server.name ?? server.sftpHost ?? "default")")
                if let path = foundPath, path.hasPrefix("~") {
                    foundPath = path.replacingOccurrences(of: "~", with: "$HOME")
                }
            } catch {
                print("[ThumbnailManager] ffmpeg install failed for server: \(server.name ?? server.sftpHost ?? "default"): \(error)")
                return nil
            }
        }
        if let foundPath = foundPath {
            server.ffmpegPath = foundPath
            _ = try? server.managedObjectContext?.save()
            print("[ThumbnailManager] Persisted ffmpegPath for server: \(server.name ?? server.sftpHost ?? "default"): \(foundPath)")
            return foundPath
        }
        return nil
    }
    
    /// Disconnects all cached SSH connections. Call this explicitly when shutting down or logging out.
    public func cleanup() async {
        connectionsLock.lock()
        let allConnections = Array(connections.values)
        connections.removeAll()
        connectionsLock.unlock()
        for connection in allConnections {
            await connection.disconnect()
        }
    }
}

// Global access function that can be called from anywhere in the app
public func clearThumbnailOperations() {
    ThumbnailManager.shared.clearAllConnections()
}

// Unchanged PathThumbnailView
public struct PathThumbnailView: View {
    let path: String
    let server: ServerEntity
    @State var fromRow: Bool?
    @State private var thumbnail: Image?
    @State private var isLoading = false
    @State private var loadingTask: Task<Void, Never>?
    @State private var isVisible = false
    
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
                case .image:
                    Image("image")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .padding(.trailing, 10)
                case .audio:
                    Image("audio")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .padding(.trailing, 10)
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
        .onAppear {
            isVisible = true
            ThumbnailManager.shared.markAsVisible(path)
            
            // Start loading when the view appears in the viewport
            loadingTask = Task {
                await loadThumbnailIfNeeded()
            }
        }
        .onDisappear {
            isVisible = false
            ThumbnailManager.shared.markAsInvisible(path)
            
            // Cancel loading when the view disappears from viewport
            loadingTask?.cancel()
            loadingTask = nil
            ThumbnailManager.shared.cancelThumbnail(for: path)
        }
    }
    
    private func loadThumbnailIfNeeded() async {
        // Don't reload if we already have a thumbnail or are loading
        guard thumbnail == nil, !isLoading, isVisible else { return }
        
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        guard fileType == .video || fileType == .image else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Check visibility again before starting the potentially expensive operation
            if !isVisible || Task.isCancelled { return }
            
            let image = try await ThumbnailManager.shared.getThumbnail(for: path, server: server)
            
            // Check again if view is still visible before updating UI
            if isVisible && !Task.isCancelled {
                await MainActor.run {
                    self.thumbnail = image
                }
            }
        } catch {
            if isVisible && !Task.isCancelled {
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
