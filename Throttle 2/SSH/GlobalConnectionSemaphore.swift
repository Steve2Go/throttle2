import Foundation

// Notification for thumbnail refresh
extension Notification.Name {
    static let thumbnailShouldRefresh = Notification.Name("thumbnailShouldRefresh")
}

/// Simple thumbnail queue item
struct ThumbnailQueueItem {
    let path: String
    let server: ServerEntity
    let continuation: CheckedContinuation<Bool, Never>  // Returns true if should proceed, false if cancelled
}

/// Global connection limiter with simple thumbnail queue
actor GlobalConnectionSemaphore {
    static let shared = GlobalConnectionSemaphore()
    
    private var currentServerName: String?
    private var maxConnections: Int = 5
    private var activeConnections: Int = 0
    private var thumbnailQueue: [ThumbnailQueueItem] = []
    
    private init() {}
    
    /// Set the connection limit for a specific server
    func setSemaphore(for serverName: String, maxConnections: Int) {
        let effectiveMax = max(1, maxConnections)
        
        if currentServerName != serverName {
            currentServerName = serverName
            self.maxConnections = effectiveMax
            activeConnections = 0
            // Clear queue when switching servers - cancel all pending thumbnails
            for item in thumbnailQueue {
                item.continuation.resume(returning: false)
            }
            thumbnailQueue.removeAll()
            print("GlobalConnectionSemaphore: Set limit to \(effectiveMax) connections for server '\(serverName)'")
        } else if self.maxConnections != effectiveMax {
            self.maxConnections = effectiveMax
            print("GlobalConnectionSemaphore: Updated limit to \(effectiveMax) connections for server '\(serverName)'")
        }
        
        // Start processing queue
        processQueue()
    }
    
    /// Set connection limit using ServerEntity
    func setSemaphore(for server: ServerEntity) async {
        let serverName = server.name ?? server.sftpHost ?? "unknown"
        let maxConnections = Int(server.thumbMax)
        setSemaphore(for: serverName, maxConnections: maxConnections)
    }
    
    /// Add thumbnail to queue
    func queueThumbnail(path: String, server: ServerEntity) async -> Bool {
        print("GlobalConnectionSemaphore: 📥 Queuing thumbnail: \(path)")
        
        // Check if already in queue
        if thumbnailQueue.contains(where: { $0.path == path }) {
            print("GlobalConnectionSemaphore: ⚠️ Thumbnail already queued: \(path)")
            return false
        }
        
        return await withCheckedContinuation { continuation in
            let item = ThumbnailQueueItem(path: path, server: server, continuation: continuation)
            thumbnailQueue.append(item)
            print("GlobalConnectionSemaphore: Queue size: \(thumbnailQueue.count)")
            processQueue()
        }
    }
    
    /// Remove thumbnail from queue (when no longer visible)
    func removeThumbnailFromQueue(path: String) {
        if let index = thumbnailQueue.firstIndex(where: { $0.path == path }) {
            let item = thumbnailQueue.remove(at: index)
            item.continuation.resume(returning: false)  // Cancel the request
            print("GlobalConnectionSemaphore: 🗑️ Removed from queue: \(path)")
        }
    }
    
    /// Acquire a connection slot for non-thumbnail operations
    func acquireConnection() async {
        print("GlobalConnectionSemaphore: Request to acquire connection. Current: \(activeConnections)/\(maxConnections)")
        
        if activeConnections < maxConnections {
            activeConnections += 1
            print("GlobalConnectionSemaphore: ✅ Connection acquired. Active: \(activeConnections)/\(maxConnections)")
            return
        }
        
        print("GlobalConnectionSemaphore: ⏳ Waiting for connection slot. Active: \(activeConnections)/\(maxConnections)")
        // For non-thumbnail operations, just wait
        await withCheckedContinuation { continuation in
            // Simple wait - we'll resume this when a connection is released
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                Task {
                    await self.acquireConnection()
                    continuation.resume()
                }
            }
        }
    }
    
    /// Release a connection slot
    func releaseConnection() {
        print("GlobalConnectionSemaphore: 🔓 Releasing connection. Current: \(activeConnections)/\(maxConnections)")
        
        activeConnections = max(0, activeConnections - 1)
        
        // Process thumbnail queue
        processQueue()
        
        // Trigger thumbnail refresh notification
        Task { @MainActor in
            NotificationCenter.default.post(name: .thumbnailShouldRefresh, object: nil)
            print("GlobalConnectionSemaphore: � Posted thumbnailShouldRefresh notification")
        }
    }
    
    /// Process the thumbnail queue - start thumbnails if connections available
    private func processQueue() {
        // Reserve connections: 1 for FTP server, 1 for SSH tunnel
        let reservedConnections = 2
        let availableForThumbnails = max(0, maxConnections - reservedConnections)
        
        while activeConnections < availableForThumbnails && !thumbnailQueue.isEmpty {
            let item = thumbnailQueue.removeFirst()
            
            // Check if the thumbnail is still visible
            let isVisible = ThumbnailManagerRemote.shared.isVisiblePath(item.path)
            if !isVisible {
                print("GlobalConnectionSemaphore: ⏭️ Skipping invisible thumbnail: \(item.path). Queue: \(thumbnailQueue.count)")
                item.continuation.resume(returning: false)
                continue
            }
            
            activeConnections += 1
            
            print("GlobalConnectionSemaphore: � Starting thumbnail: \(item.path). Active: \(activeConnections)/\(availableForThumbnails) (reserved: \(reservedConnections)), Queue: \(thumbnailQueue.count)")
            
            // Resume the thumbnail generation
            item.continuation.resume(returning: true)
        }
    }
    
    
    /// Clear the connection limiter when switching servers
    func clearSemaphore() {
        if let serverName = currentServerName {
            print("GlobalConnectionSemaphore: Clearing connections for server '\(serverName)'")
        }
        currentServerName = nil
        maxConnections = 5
        activeConnections = 0
        
        // Clear thumbnail queue - cancel all pending thumbnails
        for item in thumbnailQueue {
            item.continuation.resume(returning: false)
        }
        thumbnailQueue.removeAll()
    }
    
    /// Get current status for debugging
    func getStatus() -> (serverName: String?, maxConnections: Int, activeConnections: Int, queueSize: Int) {
        return (currentServerName, maxConnections, activeConnections, thumbnailQueue.count)
    }
}
