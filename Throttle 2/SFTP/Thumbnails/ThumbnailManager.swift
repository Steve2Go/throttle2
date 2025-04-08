#if os(iOS)
import SwiftUI
import KeychainAccess
import UIKit
//import NIOSSH
import AVFoundation
import MobileVLCKit
import Citadel

public class ThumbnailManager: NSObject {
    public static let shared = ThumbnailManager()
    private let fileManager = FileManager.default
    private let thumbnailQueue = DispatchQueue(label: "com.throttle.thumbnailQueue", qos: .utility)
    private var inProgressPaths = Set<String>()
    private let inProgressLock = NSLock()
    
    // Cache directory for saved thumbnails
    private var cacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("thumbnailCache")
    }
    
    override init() {
        super.init()
        createCacheDirectoryIfNeeded()
    }
    
    private func createCacheDirectoryIfNeeded() {
        if let cacheDir = cacheDirectory, !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }
    
    // Semaphore dictionary to limit connections per server
    private var serverSemaphores = [String: DispatchSemaphore]()
    private let semaphoreAccess = NSLock()
    
    private func getSemaphore(for server: ServerEntity) -> DispatchSemaphore {
        let key = server.name ?? server.sftpHost ?? "default"
        
        semaphoreAccess.lock()
        defer { semaphoreAccess.unlock() }
        
        if let semaphore = serverSemaphores[key] {
            return semaphore
        } else {
            // Create a new semaphore with the server's max connections value
            let maxConnections = max(1, Int(server.thumbMax)) // Ensure at least 1
            let semaphore = DispatchSemaphore(value: maxConnections)
            serverSemaphores[key] = semaphore
            return semaphore
        }
    }
    
    /// Main entry point – returns a SwiftUI Image thumbnail for a given SFTP path.
    public func getThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        // Check cache first
        if let cached = try? await loadFromCache(for: path) {
            return cached
        }
        
        // Mark as in progress to prevent duplicate requests
        let alreadyInProgress = markInProgress(path: path)
        if alreadyInProgress {
            return defaultThumbnail(for: path)
        }
        
        defer {
            clearInProgress(path: path)
        }
        
        // Get semaphore for this server
        let semaphore = getSemaphore(for: server)
        
        // Use async/await with semaphore for connection limiting
        return await withCheckedContinuation { continuation in
            Task {
                // Wait for a semaphore slot (respecting server.thumbMax)
                await withUnsafeContinuation { innerContinuation in
                    DispatchQueue.global().async {
                        semaphore.wait()
                        innerContinuation.resume()
                    }
                }
                
                // Once we have a slot, generate the thumbnail
                defer {
                    // Always release the semaphore when done
                    semaphore.signal()
                }
                
                do {
                    let fileType = FileType.determine(from: URL(fileURLWithPath: path))
                    
                    let thumbnail: Image
                    if fileType == .image {
                        thumbnail = try await generateImageThumbnail(for: path, server: server)
                    } else if fileType == .video {
                        if server.ffThumb {
                            // Use server-side FFmpeg thumbnailing if enabled
                            do {
                                thumbnail = try await generateFFmpegThumbnail(for: path, server: server)
                            } catch {
                                print("FFmpeg thumbnail failed, trying VLC: \(error.localizedDescription)")
                                // Try to use VLC as fallback
                                do {
                                    thumbnail = try await generateVideoThumbnail(for: path, server: server)
                                } catch let vlcError {
                                    print("VLC thumbnail also failed: \(vlcError.localizedDescription)")
                                    thumbnail = defaultThumbnail(for: path)
                                }
                            }
                        } else {
                            // Use VLC directly for videos when server-side FFmpeg is not enabled
                            do {
                                thumbnail = try await generateVideoThumbnail(for: path, server: server)
                            } catch let error {
                                print("VLC thumbnail failed, using placeholder: \(error.localizedDescription)")
                                thumbnail = defaultThumbnail(for: path)
                            }
                        }
                    } else {
                        thumbnail = defaultThumbnail(for: path)
                    }
                    
                    continuation.resume(returning: thumbnail)
                } catch {
                    // Always return a default thumbnail on any error
                    print("Thumbnail generation failed with error: \(error.localizedDescription)")
                    continuation.resume(returning: defaultThumbnail(for: path))
                }
            }
        }
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
    
    // MARK: - Image Thumbnail Generation
    
    private func generateImageThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SFTP credentials"])
        }
        
        // Create SSH client
        let client = try await SSHClient.connect(
            host: hostname,
            port: Int(server.sftpPort),
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        
        // Open an SFTP session
        let sftp = try await client.openSFTP()
        
        // Read the file data
        let buffer = try await sftp.withFile(
            filePath: path,
            flags: .read
        ) { file in
            try await file.readAll()
        }
        
        // Close the SFTP session
        try await sftp.close()
        
        // Convert ByteBuffer to Data
        let imageData = Data(buffer: buffer)
        
        guard let uiImage = UIImage(data: imageData) else {
            throw NSError(domain: "ThumbnailManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to load image data"])
        }
        
        let thumb = processThumbnail(uiImage: uiImage, isVideo: false)
        try? saveToCache(image: uiImage, for: path)
        return thumb
    }
    
    
    
    // MARK: - Video thumbs via FFmpeg (server-side)
    
    private func generateFFmpegThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing credentials"])
        }
        
        // Create SSH client
        let client = try await SSHClient.connect(
            host: hostname,
            port: Int(server.sftpPort),
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        
        // Generate a unique temp filename
        let tempThumbPath = "/tmp/thumb_\(UUID().uuidString).jpg"
        
        // Escape single quotes in paths
        let escapedPath = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let escapedThumbPath = "'\(tempThumbPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        
        let timestamps = ["00:00:06.000","00:00:02.000", "00:00:00.000"]
        
        for timestamp in timestamps {
            // Execute ffmpeg command with current timestamp and check its exit status
            let ffmpegCmd = "ffmpeg -y -i \(escapedPath) -ss \(timestamp) -vframes 1 \(escapedThumbPath) 2>/dev/null; echo $?"
            let exitCodeBuffer = try await client.executeCommand(ffmpegCmd)
            let exitCode = Int32(String(buffer: exitCodeBuffer).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            
            if exitCode == 0 {
                // FFmpeg succeeded, try to read the file
                let catCmd = "cat \(escapedThumbPath)"
                let imageBuffer = try await client.executeCommand(catCmd)
                
                // Clean up regardless of success
                let cleanupCmd = "rm -f \(escapedThumbPath)"
                _ = try await client.executeCommand(cleanupCmd)
                
                // Convert buffer to UIImage
                if let uiImage = UIImage(data: Data(buffer: imageBuffer)) {
                    let thumb = processThumbnail(uiImage: uiImage, isVideo: true)
                    try? saveToCache(image: uiImage, for: path)
                    return thumb
                }
            }
            
            // Clean up if this attempt failed
            let cleanupCmd = "rm -f \(escapedThumbPath)"
            _ = try await client.executeCommand(cleanupCmd)
        }
        
        throw NSError(domain: "ThumbnailManager", code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail with FFmpeg"])
    }
    
    // MARK: - Video Thumbnail Generation via VLC
        
    @MainActor
    private func generateVideoThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SFTP credentials"])
        }
        
        // Properly escape credentials and path for URL
        let escapedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let escapedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        let port = server.sftpPort
        
        // Encode path components
        var pathComponents = path.split(separator: "/")
        let encodedComponents = pathComponents.map { component in
            return String(component)
                //.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
        }
        let encodedPath = "/" + encodedComponents.joined(separator: "/")
        
        // Create SFTP URL
        let sftpURLString = "sftp://\(escapedUsername):\(escapedPassword)@\(hostname):\(port)\(encodedPath)"
        print("Generating VLC thumbnail for: \(path)")
        
        guard let sftpURL = URL(string: sftpURLString) else {
            // Try fallback URL if standard encoding failed
            let fallbackEncodedPath = path
            let fallbackURLString = "sftp://\(escapedUsername):\(escapedPassword)@\(hostname):\(port)\(fallbackEncodedPath)"
            guard let fallbackURL = URL(string: fallbackURLString) else {
                throw NSError(domain: "ThumbnailManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid SFTP URL"])
            }
            print("Using fallback URL encoding method")
            return try await generateThumbnailWithMonitoring(url: fallbackURL, path: path)
        }
        
        return try await generateThumbnailWithMonitoring(url: sftpURL, path: path)
    }

    @MainActor
    private func generateThumbnailWithMonitoring(url: URL, path: String) async throws -> Image {
        print("Using VLC with direct SFTP URL for video thumbnail: \(path)")
        
        // Create media
        let media = VLCMedia(url: url)
        
        // Add options that help with buffering and connection
        media.addOption(":network-caching=31500")
        media.addOption(":sout-mux-caching=1500")
        media.addOption(":file-caching=1500")
        
        // Create player
        let mediaPlayer = VLCMediaPlayer()
        mediaPlayer.media = media
        mediaPlayer.audio.isMuted = true
        mediaPlayer.videoAspectRatio = UnsafeMutablePointer<CChar>(mutating: ("320:180" as NSString).utf8String)
        
        // Create a view for rendering with 16:9 aspect ratio
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        containerView.backgroundColor = .black
        
        // Create a dedicated videoView that we can manipulate
        let videoView = UIView(frame: containerView.bounds)
        videoView.backgroundColor = .clear
        containerView.addSubview(videoView)
        
        // Set this as the drawable
        mediaPlayer.drawable = videoView
        
        // Set other player properties for better rendering
        mediaPlayer.scaleFactor = 0  // Scale to fill
        
        var thumbnailImage: UIImage?
        
        // Start playback
        mediaPlayer.play()
        
        // Wait for the media to actually start playing by monitoring the time
        var previousTime = mediaPlayer.time?.intValue ?? 0
        var stableCount = 0
        let maxAttempts = 15 // Maximum number of attempts
        //var viewScales = [1.0, 1.5, 2.0, 1.0, 1.5]  // Different scaling factors to try
        
        for attempt in 1...maxAttempts {
            // Wait a short period
            try await Task.sleep(nanoseconds: UInt64(2 * 1_000_000_000))  // 0.5 seconds
            
            // Check if playback has started by comparing time values
            let currentTime = mediaPlayer.time?.intValue ?? 0
            
            print("Attempt \(attempt): Playback time \(currentTime) ms (was \(previousTime) ms)")
            
           
            
            if currentTime > 0 && currentTime != previousTime {
                // Time is progressing, video is playing
                print("Video is playing")
                
                
//                // Seek to 3 seconds
//                mediaPlayer.time = VLCTime(int: 3000)
//                
                
                // Wait for seek to complete
                try await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
            } else if currentTime > 0 && currentTime == previousTime {
                // Time is stable, count consecutive stable readings
                stableCount += 1
                
                if stableCount >= 3 && currentTime >= 3000 {
                    // If we have 3 consecutive stable readings at or after 3 seconds,
                    // we're likely paused at our target position
                    print("Stable position detected at \(currentTime) ms")
                    break
                }
            }
            
            // Try to capture the frame
            UIGraphicsBeginImageContextWithOptions(containerView.bounds.size, false, 0.0)
            containerView.drawHierarchy(in: containerView.bounds, afterScreenUpdates: true)
            let capturedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            // Check if this capture is valid
            if let image = capturedImage, !isEmptyImage(image) {
                thumbnailImage = image
                break
            }
            
            print("Attempt \(attempt) at capturing frame was unsuccessful")
            
            // Update previous time for next check
            previousTime = currentTime
            
            // If progress is detected, try adjusting the video position
            if attempt > 2 && currentTime > 0 {
                // Try to position at different points in the video
                let positions: [Float] = [0.05, 0.15, 0.25, 0.35] // Try different positions
                let positionIndex = min(attempt - 3, positions.count - 1)
                mediaPlayer.position = positions[positionIndex]
                try await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            }
            
            // If we've reached the last attempt, try to seek anyway as a last resort
            if attempt == maxAttempts {
                print("Last attempt, forcing seek to 3 seconds")
                mediaPlayer.time = VLCTime(int: 3000)
                try await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
                
                // Try one final capture
                UIGraphicsBeginImageContextWithOptions(containerView.bounds.size, false, 0.0)
                containerView.drawHierarchy(in: containerView.bounds, afterScreenUpdates: true)
                thumbnailImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
            }
        }
        
        // Stop playback
        mediaPlayer.stop()
        
        // Check if we got a valid image
        guard let image = thumbnailImage, !isEmptyImage(image) else {
            throw NSError(domain: "ThumbnailManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to generate valid thumbnail"])
        }
        
        // Process and cache the thumbnail
        let thumb = processThumbnail(uiImage: image, isVideo: true)
        try? saveToCache(image: image, for: path)
        return thumb
    }
    

    // Helper function to set up VLC player on the main thread
    private func setupVLCPlayerOnMainThread(with url: URL) async throws -> (VLCMediaPlayer, UIView) {
        return try await MainActor.run {
            // Create media
            let media = VLCMedia(url: url)
            
            // Create player
            let mediaPlayer = VLCMediaPlayer()
            mediaPlayer.media = media
            mediaPlayer.audio.isMuted = true
            
            // Set proper scaling mode
            mediaPlayer.scaleFactor = 1 // Fill mode
            
            // Create a simple view for rendering
            // Using standard dimensions
            let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
            containerView.backgroundColor = .black
            
            // Set the drawable
            mediaPlayer.drawable = containerView
            
            return (mediaPlayer, containerView)
        }
    }

    // Helper function to capture a frame on the main thread
    private func captureFrameOnMainThread(from view: UIView) async throws -> UIImage? {
        return await MainActor.run {
            // Ensure the view is laid out
            view.layoutIfNeeded()
            
            // Capture the view
            UIGraphicsBeginImageContextWithOptions(view.bounds.size, false, 0.0)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            return image
        }
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

    // Helper function for task timeout
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the operation task
            group.addTask {
                try await operation()
            }
            
            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "ThumbnailManager", code: -100,
                             userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
            }
            
            // Return the first completed result, which will either be the operation or the timeout
            let result = try await group.next()!
            
            // Cancel any remaining tasks
            group.cancelAll()
            
            return result
        }
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
            return Image("video")
        case .image:
            return Image("image")
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
        
        // Determine if it's a video for proper badge display
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        return processThumbnail(uiImage: uiImage, isVideo: fileType == .video)
    }
    
    // MARK: - Public methods
    
    public func clearCache() {
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
        
        // Log the cleanup action
        print("All thumbnail operations canceled and connections reset")
    }
}

// Global access function that can be called from anywhere in the app
public func clearThumbnailOperations() {
    ThumbnailManager.shared.clearAllConnections()
}
#endif
