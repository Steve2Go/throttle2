//
//  ThumbnailManager.swift
//  
//
//  Created by Stephen Grigg on 22/3/2025.
//


#if os(iOS)
import SwiftUI
import KeychainAccess
import UIKit
import mft
//import NIOSSH
import MobileVLCKit

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
                                // Fall back to VLC if FFmpeg fails
                                print("FFmpeg thumbnail failed, falling back to VLC: \(error.localizedDescription)")
                                thumbnail = try await generateVLCThumbnail(for: path, server: server)
                            }
                        } else {
                            // Use VLC as primary method if server FFmpeg is disabled
                            thumbnail = try await generateVLCThumbnail(for: path, server: server)
                        }
                    } else {
                        thumbnail = defaultThumbnail(for: path)
                    }
                    
                    continuation.resume(returning: thumbnail)
                } catch {
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
        
        let connection = MFTSftpConnection(
            hostname: hostname,
            port: Int(server.sftpPort),
            username: username,
            password: password
        )
        try connection.connect()
        try connection.authenticate()
        
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: path).pathExtension)
        
        let stream = OutputStream(toFileAtPath: tempURL.path, append: false)!
        stream.open()
        defer {
            stream.close()
            try? fileManager.removeItem(at: tempURL)
        }
        
        try connection.contents(atPath: path, toStream: stream, fromPosition: 0) { _, _ in true }
        
        guard let imageData = try? Data(contentsOf: tempURL),
              let uiImage = UIImage(data: imageData) else {
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
        
        // Create SSH connection
        let ssh = SSHConnection(
            host: hostname,
            port: Int(server.sftpPort),
            username: username,
            password: password
        )
        
        try await ssh.connect()
        defer {
            try? ssh.disconnect()
        }
        
        // Generate a unique temp filename
        let tempThumbPath = "/tmp/thumb_\(UUID().uuidString).jpg"
        
        // Escape single quotes in paths
        let escapedPath = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let escapedThumbPath = "'\(tempThumbPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        
        // Execute ffmpeg command - use 2 seconds timestamp as requested
        let ffmpegCmd = "ffmpeg -y -i \(escapedPath) -ss 00:00:02.000 -vframes 1 \(escapedThumbPath)"
        let result = try await ssh.executeCommand(ffmpegCmd)
        
        if result.status != 0 {
            // Try one more time with a different timestamp if first attempt fails
            let retryCmd = "ffmpeg -y -i \(escapedPath) -ss 00:00:00.500 -vframes 1 \(escapedThumbPath)"
            let retryResult = try await ssh.executeCommand(retryCmd)
            
            if retryResult.status != 0 {
                throw NSError(domain: "ThumbnailManager", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "FFmpeg failed to generate thumbnail"
                ])
            }
        }
        
        // Download the generated thumbnail
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        
        do {
            let connection = MFTSftpConnection(
                hostname: hostname,
                port: Int(server.sftpPort),
                username: username,
                password: password
            )
            try connection.connect()
            try connection.authenticate()
            
            let stream = OutputStream(toFileAtPath: tempURL.path, append: false)!
            stream.open()
            defer {
                stream.close()
            }
            
            try connection.contents(atPath: tempThumbPath, toStream: stream, fromPosition: 0) { _, _ in true }
            
            // Delete remote thumbnail
            _ = try await ssh.executeCommand("rm -f \(escapedThumbPath)")
            
            guard let imageData = try? Data(contentsOf: tempURL),
                  let uiImage = UIImage(data: imageData) else {
                throw NSError(domain: "ThumbnailManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to load thumbnail"])
            }
            
            let thumb = processThumbnail(uiImage: uiImage, isVideo: true)
            try? saveToCache(image: uiImage, for: path)
            
            try? fileManager.removeItem(at: tempURL)
            return thumb
            
        } catch {
            try? fileManager.removeItem(at: tempURL)
            // Delete remote thumbnail in case of error
            try? await ssh.executeCommand("rm -f \(escapedThumbPath)")
            throw error
        }
    }
    
    // MARK: - Video Thumbnail Generation via VLC directly over SFTP
    
    private func generateVLCThumbnail(for path: String, server: ServerEntity) async throws -> Image {
        // Get SFTP credentials
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SFTP credentials"])
        }
        
        // Create VLC-compatible SFTP URL
        // Format: sftp://username:password@hostname:port/path
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let sftpURLString = "sftp://\(username):\(encodedPassword)@\(hostname):\(server.sftpPort)\(encodedPath)"
        
        guard let sftpURL = URL(string: sftpURLString) else {
            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid SFTP URL"])
        }
        
        // Generate the thumbnail using VLC directly over SFTP
        let uiImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            // Use the main thread for VLC initialization to avoid threading issues
            DispatchQueue.main.async {
                let mediaPlayer = VLCMediaPlayer()
                let media = VLCMedia(url: sftpURL)
                
                // Set VLC network caching to improve streaming performance
                var options = [String: Any]()
                options["network-caching"] = 1500
                options["sout-keep"] = true
                media.addOptions(options)
                
                // Set up a simple view to capture frames
                let captureView = UIView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
                mediaPlayer.drawable = captureView
                mediaPlayer.media = media
                
                // Set up a timeout for the entire operation
                var didTimeout = false
                let timeout = DispatchWorkItem {
                    didTimeout = true
                    mediaPlayer.stop()
                    continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -7, userInfo: [
                        NSLocalizedDescriptionKey: "VLC thumbnail generation timed out"
                    ]))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeout)
                
                // Monitor state changes to detect when media is ready
                var stateObserver: NSObjectProtocol?
                stateObserver = NotificationCenter.default.addObserver(
                    forName: NSNotification.Name("VLCMediaPlayerStateChanged"),
                    object: mediaPlayer,
                    queue: .main
                ) { _ in
                    if mediaPlayer.state == .playing {
                        // Once media is actually playing, seek to the 2-second mark
                        let seekTime = VLCTime(int: 2000) // 2 seconds in milliseconds
                        mediaPlayer.time = seekTime
                        
                        // Wait a moment after seeking to capture the frame
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // Cancel the timeout
                            timeout.cancel()
                            
                            if didTimeout { return } // Already timed out
                            
                            // Pause to ensure we have a clean frame
                            mediaPlayer.pause()
                            
                            // Take the screenshot
                            UIGraphicsBeginImageContextWithOptions(captureView.bounds.size, false, UIScreen.main.scale)
                            if let context = UIGraphicsGetCurrentContext() {
                                captureView.layer.render(in: context)
                                let screenshot = UIGraphicsGetImageFromCurrentImageContext()
                                UIGraphicsEndImageContext()
                                
                                // Clean up
                                mediaPlayer.stop()
                                if let observer = stateObserver {
                                    NotificationCenter.default.removeObserver(observer)
                                }
                                
                                if let screenshot = screenshot {
                                    continuation.resume(returning: screenshot)
                                } else {
                                    continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -5, userInfo: [
                                        NSLocalizedDescriptionKey: "Failed to capture VLC frame"
                                    ]))
                                }
                            } else {
                                UIGraphicsEndImageContext()
                                mediaPlayer.stop()
                                if let observer = stateObserver {
                                    NotificationCenter.default.removeObserver(observer)
                                }
                                continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -6, userInfo: [
                                    NSLocalizedDescriptionKey: "Failed to create graphics context"
                                ]))
                            }
                        }
                    } else if mediaPlayer.state == .error {
                        // Handle error state
                        timeout.cancel()
                        mediaPlayer.stop()
                        if let observer = stateObserver {
                            NotificationCenter.default.removeObserver(observer)
                        }
                        continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -4, userInfo: [
                            NSLocalizedDescriptionKey: "VLC encountered an error while loading the media"
                        ]))
                    }
                }
                
                // Start playing the media to initiate loading
                mediaPlayer.play()
            }
        }
        
        // Process the captured frame
        let thumb = processThumbnail(uiImage: uiImage, isVideo: true)
        try? saveToCache(image: uiImage, for: path)
        return thumb
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
