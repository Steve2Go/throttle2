//  ThumbnailManagerRemote.swift
//  Throttle 2
//
//  Created for unified remote thumbnailing (macOS/iOS) via SSH/FFmpeg

import Foundation
import SwiftUI
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
    private let thumbnailQueue = DispatchQueue(label: "com.throttle.remoteThumbnailQueue", qos: .utility)
    private var inProgressPaths = Set<String>()
    private let inProgressLock = NSLock()
    // Memory cache for thumbnails
    private let memoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 150
        return cache
    }()
    // SSH connection pooling
    private var connections = [String: SSHConnection]()
    private let connectionsLock = NSLock()
    // Visibility tracking
    private var visiblePaths = Set<String>()
    private let visiblePathsLock = NSLock()
    // Cache directory for saved thumbnails
    private var cacheDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("remoteThumbnailCache")
    }
    // Track which servers have had their ffmpegPath checked this session
    private var ffmpegCheckedServers = Set<String>()
    
    override init() {
        super.init()
        createCacheDirectoryIfNeeded()
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
    
    // MARK: - SSH connection pooling
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
    
    // MARK: - AsyncSemaphore for queuing
    actor AsyncSemaphore {
        private var value: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(value: Int) { self.value = value }
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
    // Actor for thread-safe semaphore storage
    actor SemaphoreStore {
        private var semaphores: [String: ThumbnailManagerRemote.AsyncSemaphore] = [:]
        func get(for key: String, max: Int) -> ThumbnailManagerRemote.AsyncSemaphore {
            if let sem = semaphores[key] { return sem }
            let sem = ThumbnailManagerRemote.AsyncSemaphore(value: max)
            semaphores[key] = sem
            return sem
        }
    }
    private let semaphoreStore = SemaphoreStore()
    
    // MARK: - Main entry point
    func getThumbnail(for path: String, server: ServerEntity) async throws -> PlatformImage {
        return try await getResizedImage(for: path, server: server, maxWidth: nil)
    }
    
    // New: Get resized image with optional maxWidth
    func getResizedImage(for path: String, server: ServerEntity, maxWidth: Int?) async throws -> PlatformImage {
        if !isVisible(path) {
            throw NSError(domain: "ThumbnailManagerRemote", code: -10, userInfo: [NSLocalizedDescriptionKey: "Not visible"])
        }
        let key = server.name ?? server.sftpHost ?? "default"
        let max = max(1, server.thumbMax)
        let semaphore = await semaphoreStore.get(for: key, max: Int(max))
        await semaphore.wait()
        var didSignal = false
        func signalIfNeeded() async {
            if !didSignal {
                await semaphore.signal()
                didSignal = true
            }
        }
        defer { Task { await signalIfNeeded() } }
        if let cached = memoryCache.object(forKey: path as NSString) {
            return cached
        }
        if let cached = try? await loadFromCache(for: path) {
            memoryCache.setObject(cached, forKey: path as NSString)
            return cached
        }
        let alreadyInProgress = markInProgress(path: path)
        if alreadyInProgress {
            // Wait for the thumbnail to become available in cache or on disk
            for _ in 0..<100 { // Wait up to ~5 seconds (100 * 0.05s)
                if let cached = memoryCache.object(forKey: path as NSString) {
                    return cached
                }
                if let cached = try? await loadFromCache(for: path) {
                    memoryCache.setObject(cached, forKey: path as NSString)
                    return cached
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if Task.isCancelled { throw CancellationError() }
            }
            throw NSError(domain: "ThumbnailManagerRemote", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for thumbnail in progress"])
        }
        defer { clearInProgress(path: path) }
        let fileType = FileType.determine(from: URL(fileURLWithPath: path))
        if fileType == .video || fileType == .image {
            do {
                let image = try await self.generateFFmpegThumbnail(for: path, server: server, maxWidth: maxWidth)
                memoryCache.setObject(image, forKey: path as NSString)
                _ = try? saveToCache(image: image, for: path)
                return image
            } catch {
                throw error
            }
        } else {
            throw NSError(domain: "ThumbnailManagerRemote", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported file type for thumbnail"])
        }
    }
    
    private func markInProgress(path: String) -> Bool {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        if inProgressPaths.contains(path) {
            return true
        }
        inProgressPaths.insert(path)
        return false
    }
    
    private func clearInProgress(path: String) {
        inProgressLock.lock()
        defer { inProgressLock.unlock() }
        inProgressPaths.remove(path)
    }
    
    public func cancelThumbnail(for path: String) {
        clearInProgress(path: path)
        markAsInvisible(path)
    }
    
    // MARK: - FFmpeg Thumbnail Generation (via SSH)
    private func generateFFmpegThumbnail(for path: String, server: ServerEntity, maxWidth: Int?) async throws -> PlatformImage {
        let connection = getConnection(for: server)
        let _ = try? await connection.executeCommand("mkdir -p $HOME/thumbs")
        guard let ffmpegPath = await ensureFFmpegAvailable(for: server, connection: connection) else {
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
            let (_, ffmpegOutput) = try await connection.executeCommand(ffmpegCmd)
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
                let ffmpegCmd = "\(ffmpegPath) -ss \(timestamp) -i \(escapedPath) -vframes 1 -vf scale=\(width):-1 \(escapedThumbPath) 2>/dev/null || echo $?"
                print("[DEBUG] Running ffmpeg command for video: \(ffmpegCmd)")
                let (_, ffmpegOutput) = try await connection.executeCommand(ffmpegCmd)
                let testCmd = "[ -f \(escapedThumbPath) ] && echo 'success' || echo 'failed'"
                print("[DEBUG] Running test command for video: \(testCmd)")
                let (_, testOutput) = try await connection.executeCommand(testCmd)
                if testOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "success" {
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
                } else {
                    let rmCmd = "rm -f \(escapedThumbPath)"
                    print("[DEBUG] Running rm command for video (fail): \(rmCmd)")
                    let _ = try? await connection.executeCommand(rmCmd)
                }
            }
        }
        throw NSError(domain: "ThumbnailManagerRemote", code: -5, userInfo: [NSLocalizedDescriptionKey: "FFmpeg did not create a thumbnail"])
    }
    
    // MARK: - FFmpeg Availability (iOS logic)
    private func ensureFFmpegAvailable(for server: ServerEntity, connection: SSHConnection) async -> String? {
        let serverKey = server.name ?? server.sftpHost ?? "default"
        // Use the persistent ffmpegPath if available, but check it once per session
        if let path = server.ffmpegPath, !path.isEmpty {
            if !ffmpegCheckedServers.contains(serverKey) {
                // Check the path is valid
                if let (_, testOutput) = try? await connection.executeCommand("\(path) -version || echo 'notfound'") {
                    if !testOutput.contains("notfound") && !testOutput.contains("not found") {
                        ffmpegCheckedServers.insert(serverKey)
                        print("[ThumbnailManagerRemote] Verified ffmpegPath for server: \(serverKey): \(path)")
                        return path
                    } else {
                        print("[ThumbnailManagerRemote] Cached ffmpegPath invalid for server: \(serverKey), clearing and re-detecting.")
                        server.ffmpegPath = nil
                        _ = try? server.managedObjectContext?.save()
                    }
                }
            } else {
                return path
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
                foundPath = try await RemoteFFmpegInstaller.ensureFFmpegAvailable(connection: connection)
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
            server.ffmpegPath = foundPath
            _ = try? server.managedObjectContext?.save()
            ffmpegCheckedServers.insert(serverKey)
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
                case .video:
                    Image("video")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                case .image:
                    Image("image")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                case .audio:
                    Image("audio")
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
            isVisible = false
            ThumbnailManagerRemote.shared.markAsInvisible(path)
            loadingTask?.cancel()
            loadingTask = nil
            ThumbnailManagerRemote.shared.cancelThumbnail(for: path)
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
