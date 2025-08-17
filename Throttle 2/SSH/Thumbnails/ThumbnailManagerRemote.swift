//  ThumbnailManagerRemote.swift
//  Throttle 2
//
//  Created for unified remote thumbnailing (macOS/iOS) via SSH/FFmpeg

import Foundation
import SwiftUI
import  Semaphore
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
typealias PlatformImage = UIImage
#endif

// MARK: - Remote Thumbnail Manager

public class ThumbnailManagerRemote: NSObject {
    public static let shared = ThumbnailManagerRemote()
    private let fileManager = FileManager.default
    
    // Memory cache for thumbnails
    private let memoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 150
        return cache
    }()
    
    // Visibility tracking
    private var visiblePaths = Set<String>()
    private let visiblePathsLock = NSLock()
    
    // Cache directory for saved thumbnails
    private var cacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("remoteThumbnailCache")
    }
    
    // Track ffmpeg paths in UserDefaults - THREAD SAFE
    private let ffmpegPathPrefix = "com.throttle.ffmpeg.path."
    private let timeoutInterval: TimeInterval = 30.0
    
    override init() {
        super.init()
        createCacheDirectoryIfNeeded()
        
        // Listen for semaphore retry notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThumbnailRefreshNotification),
            name: .thumbnailShouldRefresh,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleThumbnailRefreshNotification() {
        // This notification tells UI components to refresh their thumbnails
        // No action needed here - the UI will call getThumbnail again for visible items
    }
    
    private func createCacheDirectoryIfNeeded() {
        if let cacheDir = cacheDirectory, !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Visibility tracking
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
    
    // Public method for queue management
    public func isVisiblePath(_ path: String) -> Bool {
        return isVisible(path)
    }
    
    // MARK: - Main entry point
    func getThumbnail(for path: String, server: ServerEntity) async throws -> PlatformImage {
        return try await getResizedImage(for: path, server: server, maxWidth: nil)
    }
    
    // New: Get resized image with optional maxWidth
    func getResizedImage(for path: String, server: ServerEntity, maxWidth: Int?) async throws -> PlatformImage {
        // Check visibility first - if not visible, don't even start
        if !isVisible(path) {
            throw NSError(domain: "ThumbnailManagerRemote", code: -10, userInfo: [NSLocalizedDescriptionKey: "Not visible"])
        }
        
        // Check cache first
        if let cached = memoryCache.object(forKey: path as NSString) {
            return cached
        }
        if let cached = try? await loadFromCache(for: path) {
            memoryCache.setObject(cached, forKey: path as NSString)
            return cached
        }
        
        // Check connection status for debugging
        let status = await GlobalConnectionSemaphore.shared.getStatus()
        print("ThumbnailManagerRemote: Status - Server: \(status.serverName ?? "none"), Active: \(status.activeConnections)/\(status.maxConnections), Queue: \(status.queueSize)")
        
        // Queue for thumbnail generation (will wait if needed)
        let shouldProceed = await GlobalConnectionSemaphore.shared.queueThumbnail(path: path, server: server)
        
        // If cancelled (because became invisible), don't generate
        if !shouldProceed {
            print("ThumbnailManagerRemote: ❌ Thumbnail generation cancelled: \(path)")
            throw NSError(domain: "ThumbnailManagerRemote", code: -11, userInfo: [NSLocalizedDescriptionKey: "Thumbnail generation cancelled"])
        }
        
        // Check visibility again after getting connection slot - may have become invisible while waiting
        if !isVisible(path) {
            print("ThumbnailManagerRemote: ❌ Thumbnail became invisible while waiting: \(path)")
            // Don't start generation, just release connection immediately
            await GlobalConnectionSemaphore.shared.releaseConnection()
            throw NSError(domain: "ThumbnailManagerRemote", code: -10, userInfo: [NSLocalizedDescriptionKey: "Became invisible while waiting"])
        }
        
        do {
            // Double-check cache after getting connection slot
            if let cached = memoryCache.object(forKey: path as NSString) {
                await GlobalConnectionSemaphore.shared.releaseConnection()
                return cached
            }
            
            let fileType = FileType.determine(from: URL(fileURLWithPath: path))
            if fileType == .video || fileType == .image {
                let image = try await self.generateFFmpegThumbnail(for: path, server: server, maxWidth: maxWidth)
                memoryCache.setObject(image, forKey: path as NSString)
                _ = try? saveToCache(image: image, for: path)
                await GlobalConnectionSemaphore.shared.releaseConnection()
                return image
            } else {
                await GlobalConnectionSemaphore.shared.releaseConnection()
                throw NSError(domain: "ThumbnailManagerRemote", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported file type for thumbnail"])
            }
        } catch {
            await GlobalConnectionSemaphore.shared.releaseConnection()
            throw error
        }
    }
    
    public func cancelThumbnail(for path: String) {
        markAsInvisible(path)
    }
    
    // MARK: - FFmpeg Thumbnail Generation (via SSH) - Refactored for safety
    private func generateFFmpegThumbnail(for path: String, server: ServerEntity, maxWidth: Int?) async throws -> PlatformImage {
        return try await SSHConnection.withConnection(server: server) { connection in
            try await connection.connect()
            
            let _ = try? await connection.executeCommand("mkdir -p $HOME/thumbs")
            guard let ffmpegPath = await self.ensureFFmpegAvailable(for: server, using: connection) else {
                throw NSError(domain: "ThumbnailManagerRemote", code: -3, userInfo: [NSLocalizedDescriptionKey: "FFmpeg not available on server"])
            }
        let remoteTempThumbPath = "thumb_\(UUID().uuidString).jpg"
        let tempDir = FileManager.default.temporaryDirectory
        let localTempURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        FileManager.default.createFile(atPath: localTempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: localTempURL) }
        let escapedPath = shellQuote(path)
        let escapedThumbPath = shellQuote(remoteTempThumbPath)
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        let width = maxWidth ?? 1920
        if fileType == .image {
            let ffmpegCmd = "\(ffmpegPath) -i \(escapedPath) -vf scale=\(width):-1 \(escapedThumbPath) 2>/dev/null || echo $?"
            print("[DEBUG] Running ffmpeg command for image: \(ffmpegCmd)")
            let (_, _) = try await connection.executeCommand(ffmpegCmd)
            let testCmd = "[ -f \(escapedThumbPath) ] && echo 'success' || echo 'failed'"
            print("[DEBUG] Running test command for image: \(testCmd)")
            let (_, testOutput) = try await connection.executeCommand(testCmd)
            if testOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "success" {
                try await connection.downloadFile(remotePath: remoteTempThumbPath, localURL: localTempURL) { _ in }
                let rmCmd = "rm -f \(escapedThumbPath)"
                print("[DEBUG] Running rm command for image: \(rmCmd)")
                let _ = try? await connection.executeCommand(rmCmd)
                #if os(macOS)
                if let image = NSImage(contentsOf: localTempURL) {
                    return image
                }
                #elseif os(iOS)
                if let data = try? Data(contentsOf: localTempURL), let image = UIImage(data: data) {
                    return image
                }
                #endif
            } else {
                let rmCmd = "rm -f \(escapedThumbPath)"
                print("[DEBUG] Running rm command for image (fail): \(rmCmd)")
                let _ = try? await connection.executeCommand(rmCmd)
            }
        } else if fileType == .video {
            let timestamps = ["00:02:00.000", "00:00:10.000", "00:00:00.000"]
            for timestamp in timestamps {
                do{
                    let ffmpegCmd = "\(ffmpegPath) -ss \(timestamp) -i \(escapedPath) -vframes 1 -vf scale=\(width):-1 \(escapedThumbPath) 2>/dev/null || echo $?"
                    print("[DEBUG] Running ffmpeg command for video: \(ffmpegCmd)")
                    let (_, _) = try await connection.executeCommand(ffmpegCmd)
                    let testCmd = "[ -f \(escapedThumbPath) ] && echo 'success' || echo 'failed'"
                    print("[DEBUG] Running test command for video: \(testCmd)")
                    let (_, testOutput) = try await connection.executeCommand(testCmd)
                    if testOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "success" {
                        do {
                            try await connection.downloadFile(remotePath: remoteTempThumbPath, localURL: localTempURL) { _ in }
                            let rmCmd = "rm -f \(escapedThumbPath)"
                            print("[DEBUG] Running rm command for video: \(rmCmd)")
                            let _ = try? await connection.executeCommand(rmCmd)
#if os(macOS)
                            if let image = NSImage(contentsOf: localTempURL) {
                                return image
                            }
#elseif os(iOS)
                            if let data = try? Data(contentsOf: localTempURL), let image = UIImage(data: data) {
                                return image
                            }
#endif
                        } catch{
                            
                        }
                    } else {
                        let rmCmd = "rm -f \(escapedThumbPath)"
                        print("[DEBUG] Running rm command for video (fail): \(rmCmd)")
                        let _ = try? await connection.executeCommand(rmCmd)
                    }
                }
            }
        }
        
        throw NSError(domain: "ThumbnailManagerRemote", code: -5, userInfo: [NSLocalizedDescriptionKey: "Could not create thumbnail"])
        } // End of withConnection block
    }
    
    // MARK: - FFmpeg Availability (iOS logic)
    private func getFFmpegPath(for server: ServerEntity) -> String? {
        let key = ffmpegPathPrefix + (server.id?.uuidString ?? server.name ?? server.sftpHost ?? "default")
        return UserDefaults.standard.string(forKey: key)
    }
    
    private func setFFmpegPath(_ path: String?, for server: ServerEntity) {
        let key = ffmpegPathPrefix + (server.id?.uuidString ?? server.name ?? server.sftpHost ?? "default")
        if let path = path {
            UserDefaults.standard.set(path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    private func ensureFFmpegAvailable(for server: ServerEntity, using connection: SSHConnection) async -> String? {
        let serverKey = server.name ?? server.sftpHost ?? "default"
        
        // Check the persistent path if available (this is thread-safe via UserDefaults)
        if let path = getFFmpegPath(for: server), !path.isEmpty {
            // Always verify the path is still valid (don't rely on cached validation)
            if let (_, testOutput) = try? await connection.executeCommand("\(path) -version || echo 'notfound'") {
                if !testOutput.contains("notfound") && !testOutput.contains("not found") {
                    print("[ThumbnailManagerRemote] Verified ffmpegPath for server: \(serverKey): \(path)")
                    return path
                } else {
                    print("[ThumbnailManagerRemote] Cached ffmpegPath invalid for server: \(serverKey), clearing and re-detecting.")
                    setFFmpegPath(nil, for: server)
                }
            }
        }
        // Otherwise, detect or install ffmpeg
        let knownInstallPaths = [
            "ffmpeg",
            "$HOME/bin/ffmpeg",
            "$HOME/bin/ffmpeg-master-latest-win64-gpl-shared/bin/ffmpeg.exe"
        ]
        var foundPath: String? = nil
        print("[ThumbnailManagerRemote] Checking known ffmpeg paths...")
        for path in knownInstallPaths {
            print("[ThumbnailManagerRemote] Checking ffmpeg at: \(path) for server: \(server.name ?? server.sftpHost ?? "default")")
            if let (_, testOutput) = try? await connection.executeCommand("\(path) -version || echo 'notfound'") {
                print("[ThumbnailManagerRemote] Output for \(path): \(testOutput)")
                if !testOutput.contains("notfound") && !testOutput.contains("not found") {
                    foundPath = path
                    break
                }
            }
        }
        if foundPath == nil {
            print("[ThumbnailManagerRemote] ffmpeg not found, attempting install for server: \(server.name ?? server.sftpHost ?? "default")...")
            do {
                foundPath = try await RemoteFFmpegInstaller.ensureFFmpegAvailable(using: connection)
                print("[ThumbnailManagerRemote] ffmpeg installed at: \(String(describing: foundPath)) for server: \(server.name ?? server.sftpHost ?? "default")")
                if let path = foundPath, path.hasPrefix("~") {
                    foundPath = path.replacingOccurrences(of: "~", with: "$HOME")
                }
            } catch {
                print("[ThumbnailManagerRemote] ffmpeg install failed for server: \(server.name ?? server.sftpHost ?? "default"): \(error)")
                return nil
            }
        }
        if let foundPath = foundPath {
            setFFmpegPath(foundPath, for: server)
            print("[ThumbnailManagerRemote] Persisted ffmpegPath for server: \(server.name ?? server.sftpHost ?? "default"): \(foundPath)")
            return foundPath
        }
        return nil
    }
    
    // MARK: - Caching
    private func cacheFileURL(for path: String) -> URL? {
        guard let cacheDir = cacheDirectory else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let filename = encoded.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "%", with: "_")
        return cacheDir.appendingPathComponent(filename + ".thumb")
    }
    
    private func saveToCache(image: PlatformImage, for path: String) throws {
        guard let cacheURL = cacheFileURL(for: path) else { return }
        #if os(macOS)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .jpeg, properties: [:]) else { return }
        try data.write(to: cacheURL)
        #elseif os(iOS)
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try data.write(to: cacheURL)
        #endif
    }
    
    private func loadFromCache(for path: String) async throws -> PlatformImage? {
        guard let cacheURL = cacheFileURL(for: path),
              fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        #if os(macOS)
        return NSImage(contentsOf: cacheURL)
        #elseif os(iOS)
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return UIImage(data: data)
        #endif
    }
    
    // MARK: - Cache clearing
    public func clearCache() {
        // Clear memory cache
        memoryCache.removeAllObjects()
        // Clear disk cache
        if let cacheURL = cacheDirectory {
            do {
                let fileURLs = try fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
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
}

// MARK: - SwiftUI View

public struct RemotePathThumbnailView: View {
    let path: String
    let server: ServerEntity
    let overlay: Bool?
    @State private var thumbnail: PlatformImage?
    @State private var isLoading = false
    @State private var loadingTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var hasError = false
    let filetype: FileType
    
    public init(path: String, server: ServerEntity, overlay: Bool? = nil) {
        self.path = path
        self.server = server
        self.overlay = overlay ?? true
        self.filetype = FileType.determine(from: URL(string: path)!)
    }
    
    public var body: some View {
        Group {
            if let thumbnail = thumbnail {
                ZStack {
#if os(macOS)
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
#elseif os(iOS)
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
#endif
                    if server.sftpBrowse && overlay == false {
                        if filetype == .video {
                            Image(systemName: "play.fill")
                                .resizable()
                                .frame(width: 15, height: 15)
                                .padding([.top,.leading],30)
                                .foregroundColor(.white)
                        } else if filetype == .image {
                            Image(systemName: "photo.fill")
                                .resizable()
                                .frame(width: 17, height: 14)
                                .padding([.top,.leading],30)
                                .foregroundColor(.white)
                        }
                    }
                }
            } else {
                let fileType = FileType.determine(from: URL(fileURLWithPath: path))
                switch fileType {
                case .video, .image:
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
                        .overlay {
                            if filetype == .video {
                                Image(systemName: "play.fill")
                                    .resizable()
                                    .frame(width: 15, height: 15)
                                    .padding([.top,.leading],30)
                                    .foregroundColor(.white)
                            } else if filetype == .image {
                                Image(systemName: "photo.fill")
                                    .resizable()
                                    .frame(width: 17, height: 14)
                                    .padding([.top,.leading],30)
                                    .foregroundColor(.white)
                            }
                        }
                case .audio:
                    Image("audio")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                case .archive:
                    Image("archive")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                case .part:
                    Image("part")
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
        .id(path)
        .onAppear {
            isVisible = true
            ThumbnailManagerRemote.shared.markAsVisible(path)
            loadingTask = Task {
                await loadThumbnailIfNeeded()
            }
        }
        .onDisappear {
            defer{
                loadingTask = nil
            }
            isVisible = false
            // Remove from queue when no longer visible
            Task {
                await GlobalConnectionSemaphore.shared.removeThumbnailFromQueue(path: path)
            }
            loadingTask?.cancel()
            
//            ThumbnailManagerRemote.shared.cancelThumbnail(for: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailShouldRefresh)) { _ in
            // Retry thumbnail loading if we don't have one yet and are visible
            if thumbnail == nil && isVisible && !isLoading {
                loadingTask?.cancel()
                loadingTask = Task {
                    await loadThumbnailIfNeeded()
                }
            }
        }
    }
    
    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil, !isLoading, isVisible else { return }
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        guard fileType == .video || fileType == .image else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Check visibility again before starting the potentially expensive operation
            if !isVisible || Task.isCancelled { return }
            let image = try await ThumbnailManagerRemote.shared.getThumbnail(for: path, server: server)
            if isVisible && !Task.isCancelled {
                await MainActor.run {
                    self.thumbnail = image
                }
            }
        } catch {
            // Optionally handle error
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
        
        RemotePathThumbnailView(path: item.url.path, server: server , overlay: false)
       
    }
}

// MARK: - Safe SSH Helper Methods (Create-and-Destroy Pattern)
extension ThumbnailManagerRemote {
    
    /// Safely check if ffmpeg is available on a server
    static func checkFFmpegAvailability(on server: ServerEntity) async -> String? {
        do {
            return try await SSHConnection.withConnection(server: server) { connection in
                try await connection.connect()
                
                let knownInstallPaths = [
                    "ffmpeg",
                    "$HOME/bin/ffmpeg",
                    "$HOME/bin/ffmpeg-master-latest-win64-gpl-shared/bin/ffmpeg.exe"
                ]
                
                for path in knownInstallPaths {
                    if let (_, testOutput) = try? await connection.executeCommand("\(path) -version || echo 'notfound'") {
                        if !testOutput.contains("notfound") && !testOutput.contains("not found") {
                            return path
                        }
                    }
                }
                return nil
            }
        } catch {
            print("[ThumbnailManagerRemote] Error checking ffmpeg availability: \(error)")
            return nil
        }
    }
    
    /// Safely install ffmpeg on a server if not already present
    static func ensureFFmpegInstalled(on server: ServerEntity) async throws -> String {
        // First check if it's already available
        if let existingPath = await checkFFmpegAvailability(on: server) {
            return existingPath
        }
        
        // If not, install it using the safe installer
        return try await RemoteFFmpegInstaller.ensureFFmpegAvailable(on: server)
    }
}
