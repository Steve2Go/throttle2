////
////  ThumbnailManager 2.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 12/4/2025.
////
//
//
//#if os(iOS)
//import SwiftUI
//import KeychainAccess
//import UIKit
//import AVFoundation
//import MobileVLCKit
//import Citadel
//import ffmpegkit
//import mft
//
//public class ThumbnailManager: NSObject {
//    public static let shared = ThumbnailManager()
//    private let fileManager = FileManager.default
//    private let thumbnailQueue = DispatchQueue(label: "com.throttle.thumbnailQueue", qos: .utility)
//    private var inProgressPaths = Set<String>()
//    private let inProgressLock = NSLock()
//    
//    // Visibility tracking for optimization
//    private var visiblePaths = Set<String>()
//    private let visiblePathsLock = NSLock()
//    
//    // Memory cache to complement file cache
//    private let memoryCache = NSCache<NSString, UIImage>()
//    
//    // Cache directory for saved thumbnails
//    private var cacheDirectory: URL? {
//        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
//            .first?.appendingPathComponent("thumbnailCache")
//    }
//    
//    // Semaphore dictionary to limit connections per server
//    private var serverSemaphores = [String: DispatchSemaphore]()
//    private let semaphoreAccess = NSLock()
//    
//    override init() {
//        super.init()
//        createCacheDirectoryIfNeeded()
//        memoryCache.countLimit = 100 // Limit memory cache size
//    }
//    
//    private func createCacheDirectoryIfNeeded() {
//        if let cacheDir = cacheDirectory, !fileManager.fileExists(atPath: cacheDir.path) {
//            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
//        }
//    }
//    
//    // MARK: - Visibility tracking methods
//    
//    public func markAsVisible(_ path: String) {
//        visiblePathsLock.lock()
//        defer { visiblePathsLock.unlock() }
//        visiblePaths.insert(path)
//    }
//    
//    public func markAsInvisible(_ path: String) {
//        visiblePathsLock.lock()
//        defer { visiblePathsLock.unlock() }
//        visiblePaths.remove(path)
//    }
//    
//    private func isVisible(_ path: String) -> Bool {
//        visiblePathsLock.lock()
//        defer { visiblePathsLock.unlock() }
//        return visiblePaths.contains(path)
//    }
//    
//    private func getSemaphore(for server: ServerEntity) -> DispatchSemaphore {
//        let key = server.name ?? server.sftpHost ?? "default"
//        
//        semaphoreAccess.lock()
//        defer { semaphoreAccess.unlock() }
//        
//        if let semaphore = serverSemaphores[key] {
//            return semaphore
//        } else {
//            // Create a new semaphore with the server's max connections value
//            let maxConnections = max(1, Int(server.thumbMax)) // Ensure at least 1
//            let semaphore = DispatchSemaphore(value: maxConnections)
//            serverSemaphores[key] = semaphore
//            return semaphore
//        }
//    }
//    
//    /// Main entry point – returns a SwiftUI Image thumbnail for a given SFTP path.
//    public func getThumbnail(for path: String, server: ServerEntity) async throws -> Image {
//        // If not visible, return default immediately
//        if !isVisible(path) {
//            return defaultThumbnail(for: path)
//        }
//        
//        // Check memory cache first (fastest)
//        if let cachedImage = memoryCache.object(forKey: path as NSString) {
//            return Image(uiImage: cachedImage)
//        }
//        
//        // Check disk cache next
//        if let cached = try? await loadFromCache(for: path) {
//            return cached
//        }
//        
//        // If path isn't marked as in-progress, proceed with generating
//        let alreadyInProgress = markInProgress(path: path)
//        if alreadyInProgress {
//            return defaultThumbnail(for: path)
//        }
//        
//        defer {
//            clearInProgress(path: path)
//        }
//        
//        // Get semaphore for this server
//        let semaphore = getSemaphore(for: server)
//        
//        // Use async/await with semaphore for connection limiting
//        return await withCheckedContinuation { continuation in
//            Task {
//                // Wait for a semaphore slot (respecting server.thumbMax)
//                await withUnsafeContinuation { innerContinuation in
//                    DispatchQueue.global().async {
//                        semaphore.wait()
//                        innerContinuation.resume()
//                    }
//                }
//                
//                // Once we have a slot, generate the thumbnail
//                defer {
//                    // Always release the semaphore when done
//                    semaphore.signal()
//                }
//                
//                // Check again if path is still visible before proceeding
//                if !isVisible(path) {
//                    continuation.resume(returning: defaultThumbnail(for: path))
//                    return
//                }
//                
//                do {
//                    let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//                    
//                    let thumbnail: Image
//                    if fileType == .image {
//                        thumbnail = try await generateImageThumbnail(for: path, server: server)
//                    } else if fileType == .video {
//                        if server.ffThumb {
//                            // Use server-side FFmpeg thumbnailing if enabled
//                            do {
//                                thumbnail = try await generateFFmpegThumbnail(for: path, server: server)
//                            } catch {
//                                print("FFmpeg thumbnail failed, trying streaming approach: \(error.localizedDescription)")
//                                // Try streaming approach instead
//                                do {
//                                    thumbnail = try await generateStreamingVideoThumbnail(for: path, server: server)
//                                } catch let streamError {
//                                    print("Streaming thumbnail failed: \(streamError.localizedDescription)")
//                                    thumbnail = defaultThumbnail(for: path)
//                                }
//                            }
//                        } else {
//                            // Use streaming approach for videos when server-side FFmpeg is not enabled
//                            do {
//                                thumbnail = try await generateStreamingVideoThumbnail(for: path, server: server)
//                            } catch let error {
//                                print("Streaming thumbnail failed: \(error.localizedDescription)")
//                                thumbnail = defaultThumbnail(for: path)
//                            }
//                        }
//                    } else {
//                        thumbnail = defaultThumbnail(for: path)
//                    }
//                    
//                    continuation.resume(returning: thumbnail)
//                } catch {
//                    // Always return a default thumbnail on any error
//                    print("Thumbnail generation failed with error: \(error.localizedDescription)")
//                    continuation.resume(returning: defaultThumbnail(for: path))
//                }
//            }
//        }
//    }
//    
//    private func markInProgress(path: String) -> Bool {
//        inProgressLock.lock()
//        defer { inProgressLock.unlock() }
//        
//        if inProgressPaths.contains(path) {
//            return true // Already in progress
//        }
//        
//        inProgressPaths.insert(path)
//        return false // Not previously in progress
//    }
//    
//    private func clearInProgress(path: String) {
//        inProgressLock.lock()
//        defer { inProgressLock.unlock() }
//        inProgressPaths.remove(path)
//    }
//    
//    // MARK: - Image Thumbnail Generation
//    
//    private func generateImageThumbnail(for path: String, server: ServerEntity) async throws -> Image {
//        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
//        guard let username = server.sftpUser,
//              let password = keychain["sftpPassword" + (server.name ?? "")],
//              let hostname = server.sftpHost else {
//            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SFTP credentials"])
//        }
//        
//        // Create SSH client
//        let client = try await SSHClient.connect(
//            host: hostname,
//            port: Int(server.sftpPort),
//            authenticationMethod: .passwordBased(username: username, password: password),
//            hostKeyValidator: .acceptAnything(),
//            reconnect: .never
//        )
//        
//        // Open an SFTP session
//        let sftp = try await client.openSFTP()
//        
//        // Read the file data
//        let buffer = try await sftp.withFile(
//            filePath: path,
//            flags: .read
//        ) { file in
//            try await file.readAll()
//        }
//        
//        // Close the SFTP session
//        try await sftp.close()
//        
//        // Convert ByteBuffer to Data
//        let imageData = Data(buffer: buffer)
//        
//        guard let uiImage = UIImage(data: imageData) else {
//            throw NSError(domain: "ThumbnailManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to load image data"])
//        }
//        
//        // Cache the image for future use
//        memoryCache.setObject(uiImage, forKey: path as NSString)
//        
//        let thumb = processThumbnail(uiImage: uiImage, isVideo: false)
//        try? saveToCache(image: uiImage, for: path)
//        return thumb
//    }
//    
//    // MARK: - Video thumbs via FFmpeg (server-side)
//    
//    private func generateFFmpegThumbnail(for path: String, server: ServerEntity) async throws -> Image {
//        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
//        guard let username = server.sftpUser,
//              let password = keychain["sftpPassword" + (server.name ?? "")],
//              let hostname = server.sftpHost else {
//            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing credentials"])
//        }
//        
//        // Create SSH client
//        let client = try await SSHClient.connect(
//            host: hostname,
//            port: Int(server.sftpPort),
//            authenticationMethod: .passwordBased(username: username, password: password),
//            hostKeyValidator: .acceptAnything(),
//            reconnect: .never
//        )
//        
//        // Generate a unique temp filename
//        let tempThumbPath = "/tmp/thumb_\(UUID().uuidString).jpg"
//        
//        // Escape single quotes in paths
//        let escapedPath = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
//        let escapedThumbPath = "'\(tempThumbPath.replacingOccurrences(of: "'", with: "'\\''"))'"
//        
//        let timestamps = ["00:00:06.000","00:00:02.000", "00:00:00.000"]
//        
//        for timestamp in timestamps {
//            // Execute ffmpeg command with current timestamp and check its exit status
//            let ffmpegCmd = "ffmpeg -y -i \(escapedPath) -ss \(timestamp) -vframes 1 \(escapedThumbPath) 2>/dev/null; echo $?"
//            let exitCodeBuffer = try await client.executeCommand(ffmpegCmd)
//            let exitCode = Int32(String(buffer: exitCodeBuffer).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
//            
//            if exitCode == 0 {
//                // FFmpeg succeeded, try to read the file
//                let catCmd = "cat \(escapedThumbPath)"
//                let imageBuffer = try await client.executeCommand(catCmd)
//                
//                // Clean up regardless of success
//                let cleanupCmd = "rm -f \(escapedThumbPath)"
//                _ = try await client.executeCommand(cleanupCmd)
//                
//                // Convert buffer to UIImage
//                if let uiImage = UIImage(data: Data(buffer: imageBuffer)) {
//                    // Cache the image
//                    memoryCache.setObject(uiImage, forKey: path as NSString)
//                    
//                    let thumb = processThumbnail(uiImage: uiImage, isVideo: true)
//                    try? saveToCache(image: uiImage, for: path)
//                    return thumb
//                }
//            }
//            
//            // Clean up if this attempt failed
//            let cleanupCmd = "rm -f \(escapedThumbPath)"
//            _ = try await client.executeCommand(cleanupCmd)
//        }
//        
//        throw NSError(domain: "ThumbnailManager", code: -3,
//            userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail with FFmpeg"])
//    }
//    
//    // MARK: - Streaming Video Thumbnail Generation
//    
//    private func generateStreamingVideoThumbnail(for path: String, server: ServerEntity) async throws -> Image {
//        // If not visible, return default immediately
//        if !isVisible(path) {
//            return defaultThumbnail(for: path)
//        }
//        
//        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
//        guard let username = server.sftpUser,
//              let password = keychain["sftpPassword" + (server.name ?? "")],
//              let hostname = server.sftpHost else {
//            throw NSError(domain: "ThumbnailManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing SFTP credentials"])
//        }
//        
//        // Create temporary files with more distinctive extensions to help FFmpeg
//        let fileExt = URL(fileURLWithPath: path).pathExtension.lowercased()
//        let tempFilePath = FileManager.default.temporaryDirectory.appendingPathComponent("temp_video_\(UUID().uuidString).\(fileExt)")
//        let thumbPath = FileManager.default.temporaryDirectory.appendingPathComponent("thumb_\(UUID().uuidString).jpg")
//        
//        // Cleanup function
//        let cleanup = {
//            try? FileManager.default.removeItem(at: tempFilePath)
//            try? FileManager.default.removeItem(at: thumbPath)
//        }
//        
//        do {
//            // Create the SFTP connection
//            let sftpConnection: MFTSftpConnection
//            if server.sftpUsesKey {
//                let key = keychain["sftpKey" + (server.name ?? "")] ?? ""
//                let keyPassword = keychain["sftpPassword" + (server.name ?? "")] ?? ""
//                sftpConnection = MFTSftpConnection(
//                    hostname: hostname,
//                    port: Int(server.sftpPort),
//                    username: username,
//                    prvKey: key,
//                    passphrase: keyPassword
//                )
//            } else {
//                sftpConnection = MFTSftpConnection(
//                    hostname: hostname,
//                    port: Int(server.sftpPort),
//                    username: username,
//                    password: password
//                )
//            }
//            
//            // Connect to server
//            try sftpConnection.connect()
//            try sftpConnection.authenticate()
//            
//            // For MP4 files, the moov atom might be at the end - let's handle two approaches
//            let isMP4 = ["mp4", "m4v", "mov", "3gp"].contains(fileExt.lowercased())
//            
//            // Get file info to know file size
//            var fileSize: UInt64 = 0
//            do {
//                let fileInfo = try sftpConnection.infoForFile(atPath: path)
//                fileSize = fileInfo.size
//            } catch {
//                print("Could not get file info: \(error)")
//            }
//            
//            // Create file for the temporary data
//            FileManager.default.createFile(atPath: tempFilePath.path, contents: nil)
//            guard let outputStream = OutputStream(toFileAtPath: tempFilePath.path, append: false) else {
//                throw NSError(domain: "ThumbnailManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create output stream"])
//            }
//            
//            // For MP4 files, we might need more data or even the whole file
//            let maxBytesToDownload: UInt64
//            if isMP4 {
//                // For MP4 files, we need more data - up to 20% of file or 20MB max
//                maxBytesToDownload = min(fileSize > 0 ? fileSize / 5 : 20 * 1024 * 1024, 20 * 1024 * 1024)
//            } else {
//                // For other formats, try with less data
//                maxBytesToDownload = 8 * 1024 * 1024
//            }
//            
//            print("Starting download for \(path) (max \(maxBytesToDownload / 1024 / 1024)MB)")
//            
//            // Start downloading
//            var downloadedBytes: UInt64 = 0
//            do {
//                try sftpConnection.contents(
//                    atPath: path,
//                    toStream: outputStream,
//                    fromPosition: 0,
//                    progress: { bytesReceived, totalBytes in
//                        // Update downloaded bytes
//                        downloadedBytes = bytesReceived
//                        
//                        // Continue if we haven't reached max and thumbnail is still needed
//                        return bytesReceived < maxBytesToDownload && self.isVisible(path) && !Task.isCancelled
//                    }
//                )
//            } catch let error as NSError {
//                // Handle expected cancellation
//                if error.domain != "mft" || error.code != MFTErrorCode.canceled.rawValue {
//                    throw error
//                }
//            }
//            
//            print("Downloaded \(downloadedBytes / 1024 / 1024)MB for thumbnail generation")
//            
//            // Now attempt to extract thumbnail with the downloaded data
//            if self.isVisible(path) && !Task.isCancelled {
//                do {
//                    let image = try await attemptThumbnailExtraction(
//                        from: tempFilePath.path,
//                        to: thumbPath.path,
//                        fileType: fileExt
//                    )
//                    
//                    // Process and cache the thumbnail
//                    let thumb = processThumbnail(uiImage: image, isVideo: true)
//                    try? saveToCache(image: image, for: path)
//                    memoryCache.setObject(image, forKey: path as NSString)
//                    
//                    // Clean up and return
//                    cleanup()
//                    return thumb
//                } catch {
//                    print("Thumbnail extraction failed: \(error)")
//                }
//            }
//            
//            // If we reached here, extraction failed or thumbnail is no longer needed
//            cleanup()
//            return defaultThumbnail(for: path)
//        } catch {
//            cleanup()
//            print("Streaming thumbnail error: \(error.localizedDescription)")
//            return defaultThumbnail(for: path)
//        }
//    }
//
//    private func attemptThumbnailExtraction(from videoPath: String, to outputPath: String, fileType: String = "") async throws -> UIImage {
//        return try await withCheckedThrowingContinuation { continuation in
//            // Determine file type and appropriate FFmpeg options
//            let fileExt = fileType.lowercased()
//            
//            // Create a list of extraction methods to try
//            var extractionMethods = [String]()
//            
//            // For MP4 files that may have moov atom issues, try different strategies
//            if ["mp4", "m4v", "mov", "3gp"].contains(fileExt) {
//                // For MP4 files, force MP4 demuxer and try with faststart flag
//                extractionMethods.append("-f mp4 -movflags faststart -i \(videoPath) -frames:v 1 -q:v 2 -y \(outputPath)")
//            }
//            
//            // Add general methods for all formats
//            extractionMethods.append(contentsOf: [
//                // General method, let FFmpeg detect format
//                "-i \(videoPath) -frames:v 1 -q:v 2 -y \(outputPath)",
//                
//                // Use error resilience options
//                "-err_detect ignore_err -fflags +genpts+igndts+discardcorrupt -i \(videoPath) -frames:v 1 -q:v 2 -y \(outputPath)",
//                
//                // Force format based on extension if we have one
//                "-f \(fileTypeToFormat(fileExt)) -i \(videoPath) -frames:v 1 -q:v 2 -y \(outputPath)"
//            ])
//            
//            func tryMethod(index: Int) {
//                if index >= extractionMethods.count {
//                    continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -4,
//                        userInfo: [NSLocalizedDescriptionKey: "Failed to extract thumbnail"]))
//                    return
//                }
//                
//                // Log which method we're trying
//                print("Trying extraction method \(index + 1)/\(extractionMethods.count)")
//                
//                FFmpegKit.executeAsync(extractionMethods[index]) { session in
//                    let returnCode = session?.getReturnCode()
//                    let success = returnCode?.isValueSuccess() == true
//                    
//                    if success,
//                       let image = UIImage(contentsOfFile: outputPath),
//                       !self.isEmptyImage(image) {
//                        continuation.resume(returning: image)
//                    } else {
//                        // Try next method
//                        tryMethod(index: index + 1)
//                    }
//                }
//            }
//            
//            // Start with the first method
//            tryMethod(index: 0)
//        }
//    }
//
//    // Helper function to map file extensions to FFmpeg format names
//    private func fileTypeToFormat(_ fileType: String) -> String {
//        switch fileType.lowercased() {
//        case "mp4", "m4v", "mov":
//            return "mp4"
//        case "mkv", "webm":
//            return "matroska"
//        case "avi":
//            return "avi"
//        case "flv":
//            return "flv"
//        case "wmv":
//            return "asf"
//        default:
//            return "mp4" // Default to MP4 if unknown
//        }
//    }
//
//    
//
//    
//    
//    private func extractThumbnailSafe(from videoPath: String, to outputPath: String) async throws -> UIImage {
//        return try await withCheckedThrowingContinuation { continuation in
//            // Try a few different methods that are resilient to corruption
//            let options = [
//                // Try to extract key frame (I-frame) with error concealment
//                "-i \(videoPath) -vf showinfo,select='eq(pict_type,I)' -vsync 0 -frames:v 1 -q:v 2 -y -c:v mjpeg -error-resilient 1 -max_error_rate 0.99 \(outputPath)",
//                
//                // Try to just grab any frame very early in the file
//                "-i \(videoPath) -frames:v 1 -q:v 2 -y -c:v mjpeg -error-resilient 1 -max_error_rate 0.99 \(outputPath)",
//                
//                // Try one more approach with error concealment and skip damaged frames
//                "-i \(videoPath) -frames:v 1 -q:v 2 -y -c:v mjpeg -flags2 +ignorecrop -flags +bitexact -error-resilient 1 \(outputPath)"
//            ]
//            
//            func tryOption(index: Int) {
//                if index >= options.count {
//                    continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -4,
//                        userInfo: [NSLocalizedDescriptionKey: "All FFmpeg extraction approaches failed"]))
//                    return
//                }
//                
//                FFmpegKit.executeAsync(options[index]) { session in
//                    let returnCode = session?.getReturnCode()
//                    let success = returnCode?.isValueSuccess() == true
//                    
//                    if success,
//                       let image = UIImage(contentsOfFile: outputPath),
//                       !self.isEmptyImage(image) {
//                        continuation.resume(returning: image)
//                    } else {
//                        // Try the next approach
//                        tryOption(index: index + 1)
//                    }
//                }
//            }
//            
//            // Start with the first option
//            tryOption(index: 0)
//        }
//    }
//
//    private func extractThumbnailLastResort(from videoPath: String, to outputPath: String) async throws -> UIImage {
//        // This is our absolute last resort approach
//        return try await withCheckedThrowingContinuation { continuation in
//            // Force output format and enable all possible error resilience options
//            let command = "-threads 1 -i \(videoPath) -frames:v 1 -q:v 3 -y -f image2 -c:v mjpeg -vf 'scale=320:240:force_original_aspect_ratio=decrease' -error-resilient 1 -strict experimental -max_error_rate 0.99 \(outputPath)"
//            
//            FFmpegKit.executeAsync(command) { session in
//                let returnCode = session?.getReturnCode()
//                let success = returnCode?.isValueSuccess() == true
//                
//                if success, let image = UIImage(contentsOfFile: outputPath), !self.isEmptyImage(image) {
//                    continuation.resume(returning: image)
//                } else {
//                    continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -4,
//                        userInfo: [NSLocalizedDescriptionKey: "Last resort thumbnail extraction failed"]))
//                }
//            }
//        }
//    }
//
//    private func attemptThumbnailExtractionWithValidation(from videoPath: String, to outputPath: String, stageMB: Int) async throws -> UIImage {
//        return try await withCheckedThrowingContinuation { continuation in
//            // Try different approaches depending on how much data we have
//            
//            // For early stages, prioritize I-frames
//            let commandOptions: [(String, String)] = [
//                // First try with I-frame selection - best quality
//                ("select='eq(pict_type,I)'", "-frames:v 1 -q:v 2"),
//                
//                // If that fails, try with a specific timestamp near the start
//                ("", "-ss 00:00:02 -frames:v 1 -q:v 2"),
//                
//                // Last resort - just take the first frame
//                ("", "-frames:v 1 -q:v 2")
//            ]
//            
//            func tryNextOption(index: Int) {
//                if index >= commandOptions.count {
//                    continuation.resume(throwing: NSError(domain: "ThumbnailManager", code: -4,
//                        userInfo: [NSLocalizedDescriptionKey: "All FFmpeg extraction approaches failed"]))
//                    return
//                }
//                
//                let (filter, options) = commandOptions[index]
//                
//                // Configure FFmpeg with appropriate options
//                let filterOption = filter.isEmpty ? "" : "-vf \(filter)"
//                let ffmpegCommand = "-err_detect ignore_err -fflags +genpts+igndts+discardcorrupt -i \(videoPath) \(filterOption) \(options) -y \(outputPath)"
//                
//                FFmpegKit.executeAsync(ffmpegCommand) { session in
//                    let returnCode = session?.getReturnCode()
//                    let success = returnCode?.isValueSuccess() == true
//                    
//                    if success, let image = UIImage(contentsOfFile: outputPath), !self.isBlankOrCorrupted(image) {
//                        continuation.resume(returning: image)
//                    } else {
//                        // Try the next approach
//                        tryNextOption(index: index + 1)
//                    }
//                }
//            }
//            
//            // Start with the first option
//            tryNextOption(index: 0)
//        }
//    }
//
//    // Helper to check if image appears valid
//    private func isBlankOrCorrupted(_ image: UIImage) -> Bool {
//        // Basic dimension check
//        guard let cgImage = image.cgImage,
//              cgImage.width > 10,
//              cgImage.height > 10 else {
//            return true
//        }
//        
//        // Perform a more thorough check for blank/corrupted images
//        let width = min(cgImage.width, 30)  // Check more pixels than before
//        let height = min(cgImage.height, 30)
//        let bytesPerRow = width * 4
//        let bitmapData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
//        defer { bitmapData.deallocate() }
//        
//        guard let context = CGContext(
//            data: bitmapData,
//            width: width,
//            height: height,
//            bitsPerComponent: 8,
//            bytesPerRow: bytesPerRow,
//            space: CGColorSpaceCreateDeviceRGB(),
//            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
//        ) else {
//            return true
//        }
//        
//        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
//        
//        // Check 1: Are most pixels the same color? (blank or solid color)
//        var colorHistogram = [UInt32: Int]()
//        var totalPixels = 0
//        
//        for y in 0..<height {
//            for x in 0..<width {
//                let offset = (y * bytesPerRow) + (x * 4)
//                let r = bitmapData[offset]
//                let g = bitmapData[offset + 1]
//                let b = bitmapData[offset + 2]
//                let a = bitmapData[offset + 3]
//                
//                // Skip fully transparent pixels
//                if a < 10 { continue }
//                
//                // Create a color key (simplify by using only most significant bits)
//                let colorKey: UInt32 = (UInt32(r) & 0xF0) << 24 | (UInt32(g) & 0xF0) << 16 | (UInt32(b) & 0xF0) << 8
//                
//                colorHistogram[colorKey, default: 0] += 1
//                totalPixels += 1
//            }
//        }
//        
//        // If one color dominates (over 90%), it's likely a blank or corrupted image
//        if let maxColor = colorHistogram.max(by: { $0.value < $1.value }),
//           totalPixels > 0,
//           (Double(maxColor.value) / Double(totalPixels)) > 0.9 {
//            return true
//        }
//        
//        // Check 2: Is there very little variation in the image?
//        var sumR = 0, sumG = 0, sumB = 0
//        var sqSumR = 0, sqSumG = 0, sqSumB = 0
//        var count = 0
//        
//        for y in 0..<height {
//            for x in 0..<width {
//                let offset = (y * bytesPerRow) + (x * 4)
//                let r = Int(bitmapData[offset])
//                let g = Int(bitmapData[offset + 1])
//                let b = Int(bitmapData[offset + 2])
//                
//                sumR += r
//                sumG += g
//                sumB += b
//                
//                sqSumR += r * r
//                sqSumG += g * g
//                sqSumB += b * b
//                
//                count += 1
//            }
//        }
//        
//        if count > 0 {
//            // Calculate standard deviation as a measure of color variation
//            let meanR = Double(sumR) / Double(count)
//            let meanG = Double(sumG) / Double(count)
//            let meanB = Double(sumB) / Double(count)
//            
//            let varR = (Double(sqSumR) / Double(count)) - (meanR * meanR)
//            let varG = (Double(sqSumG) / Double(count)) - (meanG * meanG)
//            let varB = (Double(sqSumB) / Double(count)) - (meanB * meanB)
//            
//            let stdDev = sqrt((varR + varG + varB) / 3.0)
//            
//            // Very low standard deviation suggests minimal color variation
//            if stdDev < 10.0 {
//                return true
//            }
//        }
//        
//        return false
//    }
//
//    
//    // Helper method to extract thumbnail with retries
//    private func extractThumbnail(from videoPath: String, to outputPath: String, pathToCheck: String) async throws -> UIImage {
//        // Try multiple times with increasing delays
//        for attempt in 1...5 {
//            // Check if still visible
//            if !isVisible(pathToCheck) {
//                throw NSError(domain: "ThumbnailManager", code: -6,
//                              userInfo: [NSLocalizedDescriptionKey: "Path no longer visible"])
//            }
//            
//            if Task.isCancelled {
//                throw NSError(domain: "ThumbnailManager", code: -7,
//                              userInfo: [NSLocalizedDescriptionKey: "Task cancelled"])
//            }
//            
//            do {
//                return try await attemptThumbnailExtraction(from: videoPath, to: outputPath)
//            } catch {
//                if attempt == 5 {
//                    throw error
//                }
//                // Wait before next attempt
//                try await Task.sleep(nanoseconds: UInt64(500_000_000 * min(attempt, 4)))
//            }
//        }
//        
//        throw NSError(domain: "ThumbnailManager", code: -5,
//                      userInfo: [NSLocalizedDescriptionKey: "Failed to extract thumbnail after retries"])
//    }
//
//    
//    
//    
//    // Helper function to check if image is empty (solid color)
//    private func isEmptyImage(_ image: UIImage) -> Bool {
//        // Quick check - if image size is invalid, consider it empty
//        guard let cgImage = image.cgImage,
//              cgImage.width > 1 && cgImage.height > 1 else {
//            return true
//        }
//        
//        // Create a small bitmap context and draw the image
//        let width = min(cgImage.width, 20)  // Sample at most 20x20 pixels
//        let height = min(cgImage.height, 20)
//        let bytesPerRow = width * 4
//        let bitmapData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
//        defer { bitmapData.deallocate() }
//        
//        guard let context = CGContext(
//            data: bitmapData,
//            width: width,
//            height: height,
//            bitsPerComponent: 8,
//            bytesPerRow: bytesPerRow,
//            space: CGColorSpaceCreateDeviceRGB(),
//            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
//        ) else {
//            return true
//        }
//        
//        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
//        
//        // Check for pixel variation
//        var firstPixel: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
//        var hasInitialPixel = false
//        var hasVariation = false
//        
//        for y in 0..<height {
//            for x in 0..<width {
//                let offset = (y * bytesPerRow) + (x * 4)
//                let r = bitmapData[offset]
//                let g = bitmapData[offset + 1]
//                let b = bitmapData[offset + 2]
//                
//                // Save first pixel
//                if !hasInitialPixel {
//                    firstPixel = (r, g, b)
//                    hasInitialPixel = true
//                    continue
//                }
//                
//                // Check for meaningful variation
//                let rDiff = abs(Int(r) - Int(firstPixel.r))
//                let gDiff = abs(Int(g) - Int(firstPixel.g))
//                let bDiff = abs(Int(b) - Int(firstPixel.b))
//                
//                if rDiff > 5 || gDiff > 5 || bDiff > 5 {
//                    hasVariation = true
//                    break
//                }
//            }
//            if hasVariation {
//                break
//            }
//        }
//        
//        return !hasVariation
//    }
//    
//    // MARK: - Thumbnail Processing & Caching
//    
//    private func processThumbnail(uiImage: UIImage, isVideo: Bool) -> Image {
//        let size = CGSize(width: 60, height: 60)
//        let renderer = UIGraphicsImageRenderer(size: size)
//        let thumbnailImage = renderer.image { context in
//            let scale = max(size.width / uiImage.size.width, size.height / uiImage.size.height)
//            let scaledSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
//            let origin = CGPoint(x: (size.width - scaledSize.width) / 2,
//                                 y: (size.height - scaledSize.height) / 2)
//            uiImage.draw(in: CGRect(origin: origin, size: scaledSize))
//            
//            if isVideo {
//                let badgeSize = size.width * 0.3
//                let badgeRect = CGRect(x: size.width - badgeSize - 2,
//                                       y: size.height - badgeSize - 2,
//                                       width: badgeSize,
//                                       height: badgeSize)
//                context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
//                context.cgContext.fillEllipse(in: badgeRect)
//                if let badge = UIImage(systemName: "play.fill") {
//                    let badgeTintColor = UIColor.white
//                    badge.withTintColor(badgeTintColor).draw(in: badgeRect)
//                }
//            }
//        }
//        return Image(uiImage: thumbnailImage)
//    }
//    
//    private func defaultThumbnail(for path: String) -> Image {
//        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//        switch fileType {
//        case .video:
//            return Image("video")
//        case .image:
//            return Image("image")
//        default:
//            return Image("item")
//        }
//    }
//    
//    // MARK: - Cache methods
//    
//    private func cacheFileURL(for path: String) -> URL? {
//        guard let cacheDir = cacheDirectory else { return nil }
//        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
//        let filename = encoded.replacingOccurrences(of: "/", with: "_")
//            .replacingOccurrences(of: "%", with: "_")
//        return cacheDir.appendingPathComponent(filename + ".thumb")
//    }
//    
//    private func saveToCache(image: UIImage, for path: String) throws {
//        guard let cacheURL = cacheFileURL(for: path),
//              let jpegData = image.jpegData(compressionQuality: 0.8) else { return }
//        try jpegData.write(to: cacheURL)
//    }
//    
//    private func loadFromCache(for path: String) async throws -> Image? {
//        guard let cacheURL = cacheFileURL(for: path),
//              fileManager.fileExists(atPath: cacheURL.path),
//              let data = try? Data(contentsOf: cacheURL),
//              let uiImage = UIImage(data: data) else { return nil }
//        
//        // Store in memory cache too
//        memoryCache.setObject(uiImage, forKey: path as NSString)
//        
//        // Determine if it's a video for proper badge display
//        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//        return processThumbnail(uiImage: uiImage, isVideo: fileType == .video)
//    }
//    
//    // MARK: - Public methods
//    
//    public func clearCache() {
//        // Clear memory cache
//        memoryCache.removeAllObjects()
//        
//        if let cacheURL = cacheDirectory {
//            do {
//                // Get all files in the cache directory
//                let fileURLs = try fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
//                
//                // Remove each file individually
//                for fileURL in fileURLs {
//                    try fileManager.removeItem(at: fileURL)
//                }
//                
//                print("Successfully cleared \(fileURLs.count) thumbnails from cache")
//            } catch {
//                // If we can't get directory contents or there's another error, try removing the entire directory
//                try? fileManager.removeItem(at: cacheURL)
//                print("Removed entire cache directory due to error: \(error.localizedDescription)")
//                createCacheDirectoryIfNeeded()
//            }
//        }
//    }
//    
//    public func cancelThumbnail(for path: String) {
//        clearInProgress(path: path)
//        markAsInvisible(path)
//    }
//    
//    // MARK: - clear the queue
//    public func clearAllConnections() {
//        // Clear all in-progress paths
//        inProgressLock.lock()
//        inProgressPaths.removeAll()
//        inProgressLock.unlock()
//        
//        // Clear semaphores to reset connection limits
//        semaphoreAccess.lock()
//        serverSemaphores.removeAll()
//        semaphoreAccess.unlock()
//        
//        // Clear visibility tracking
//        visiblePathsLock.lock()
//        visiblePaths.removeAll()
//        visiblePathsLock.unlock()
//        
//        // Log the cleanup action
//        print("All thumbnail operations canceled and connections reset")
//    }
//}
//
//// Global access function that can be called from anywhere in the app
//public func clearThumbnailOperations() {
//    ThumbnailManager.shared.clearAllConnections()
//}
//
//// Updated PathThumbnailView with visibility tracking
//public struct PathThumbnailView: View {
//    let path: String
//    let server: ServerEntity
//    @State var fromRow: Bool?
//    @State private var thumbnail: Image?
//    @State private var isLoading = false
//    @State private var loadingTask: Task<Void, Never>?
//    @State private var isVisible = false
//    
//    public init(path: String, server: ServerEntity, fromRow: Bool? = nil) {
//        self.path = path
//        self.server = server
//        _fromRow = State(initialValue: fromRow)
//    }
//    
//    public var body: some View {
//        Group {
//            if let thumbnail = thumbnail {
//                thumbnail
//                    .resizable()
//                    .aspectRatio(contentMode: .fill)
//                    .frame(width: 60, height: 60)
//                    .cornerRadius(8)
//                    .padding(.trailing, 10)
//            } else {
//                let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//                switch fileType {
//                case .video:
//                    Image("video")
//                        .resizable()
//                        .aspectRatio(contentMode: .fill)
//                        .frame(width: 60, height: 60)
//                        .padding(.trailing, 10)
//                case .image:
//                    Image("image")
//                        .resizable()
//                        .aspectRatio(contentMode: .fill)
//                        .frame(width: 60, height: 60)
//                        .padding(.trailing, 10)
//                case .other:
//                    if fromRow == true {
//                        Image("folder")
//                            .resizable()
//                            .aspectRatio(contentMode: .fill)
//                            .frame(width: 60, height: 60)
//                            .padding(.trailing, 10)
//                            .foregroundColor(.gray)
//                    } else {
//                        Image("document")
//                            .resizable()
//                            .aspectRatio(contentMode: .fill)
//                            .frame(width: 60, height: 60)
//                            .padding(.trailing, 10)
//                            .foregroundColor(.gray)
//                    }
//                }
//            }
//        }
//        .id(path) // Ensure view updates when path changes
//        .onAppear {
//            isVisible = true
//            ThumbnailManager.shared.markAsVisible(path)
//            
//            // Start loading when the view appears in the viewport
//            loadingTask = Task { 
//                await loadThumbnailIfNeeded() 
//            }
//        }
//        .onDisappear {
//            isVisible = false
//            ThumbnailManager.shared.markAsInvisible(path)
//            
//            // Cancel loading when the view disappears from viewport
//            loadingTask?.cancel()
//            loadingTask = nil
//            ThumbnailManager.shared.cancelThumbnail(for: path)
//        }
//    }
//    
//    private func loadThumbnailIfNeeded() async {
//        // Don't reload if we already have a thumbnail or are loading
//        guard thumbnail == nil, !isLoading, isVisible else { return }
//        
//        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
//        guard fileType == .video || fileType == .image else { return }
//        
//        isLoading = true
//        defer { isLoading = false }
//        
//        do {
//            // Check visibility again before starting the potentially expensive operation
//            if !isVisible || Task.isCancelled { return }
//            
//            let image = try await ThumbnailManager.shared.getThumbnail(for: path, server: server)
//            
//            // Check again if view is still visible before updating UI
//            if isVisible && !Task.isCancelled {
//                await MainActor.run {
//                    self.thumbnail = image
//                }
//            }
//        } catch {
//            if isVisible && !Task.isCancelled {
//                print("❌ Error loading thumbnail for \(path): \(error)")
//            }
//        }
//    }
//}
//
//public struct FileRowThumbnail: View {
//    let item: FileItem
//    let server: ServerEntity
//    
//    init(item: FileItem, server: ServerEntity) {
//        self.item = item
//        self.server = server
//    }
//    
//    public var body: some View {
//        PathThumbnailView(path: item.url.path, server: server)
//    }
//}
//#endif
//
//extension FileManager {
//    func fileSize(atPath path: String) -> UInt64 {
//        do {
//            let attributes = try attributesOfItem(atPath: path)
//            return attributes[.size] as? UInt64 ?? 0
//        } catch {
//            return 0
//        }
//    }
//}
