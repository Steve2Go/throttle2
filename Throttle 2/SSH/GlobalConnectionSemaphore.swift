import Foundation
import Semaphore

/// Global connection semaphore for managing all connection types to a single active server
/// This includes SSH tunnels, HTTP tunnels, FTP connections, SFTP connections, and thumbnails
actor GlobalConnectionSemaphore {
    static let shared = GlobalConnectionSemaphore()
    
    private var currentSemaphore: AsyncSemaphore?
    private var currentServerName: String?
    private var maxConnections: Int = 5
    private var activeConnections: Int = 0
    
    private init() {}
    
    /// Set the semaphore for a specific server using its thumbMax setting
    func setSemaphore(for serverName: String, maxConnections: Int) {
        let effectiveMax = max(1, maxConnections) // Ensure at least 1 connection
        
        if currentServerName != serverName || currentSemaphore == nil {
            currentSemaphore = AsyncSemaphore(value: effectiveMax)
            currentServerName = serverName
            self.maxConnections = effectiveMax
            activeConnections = 0
            print("GlobalConnectionSemaphore: Set limit to \(effectiveMax) connections for server '\(serverName)'")
        } else if self.maxConnections != effectiveMax {
            // Server is the same but max connections changed
            currentSemaphore = AsyncSemaphore(value: effectiveMax)
            self.maxConnections = effectiveMax
            activeConnections = 0
            print("GlobalConnectionSemaphore: Updated limit to \(effectiveMax) connections for server '\(serverName)'")
        }
    }
    
    /// Set semaphore using ServerEntity (convenience method)
    func setSemaphore(for server: ServerEntity) async {
        let serverName = server.name ?? server.sftpHost ?? "unknown"
        let maxConnections = Int(server.thumbMax)
        await setSemaphore(for: serverName, maxConnections: maxConnections)
    }
    
    /// Acquire a connection slot - blocks until one is available
    func acquireConnection() async {
        guard let semaphore = currentSemaphore else {
            print("GlobalConnectionSemaphore: WARNING - no semaphore set, allowing connection (this should not happen in normal operation)")
            return
        }
        
        await semaphore.wait()
        activeConnections += 1
        print("GlobalConnectionSemaphore: Connection acquired (\(activeConnections)/\(maxConnections)) for '\(currentServerName ?? "unknown")'")
    }
    
    /// Release a connection slot
    func releaseConnection() {
        guard let semaphore = currentSemaphore else {
            print("GlobalConnectionSemaphore: WARNING - no semaphore set for release (this should not happen)")
            return
        }
        
        activeConnections = max(0, activeConnections - 1)
        semaphore.signal()
        print("GlobalConnectionSemaphore: Connection released (\(activeConnections)/\(maxConnections)) for '\(currentServerName ?? "unknown")'")
    }
    
    /// Clear the semaphore when switching servers or shutting down
    func clearSemaphore() {
        if let serverName = currentServerName {
            print("GlobalConnectionSemaphore: Clearing semaphore for server '\(serverName)'")
        }
        currentSemaphore = nil
        currentServerName = nil
        maxConnections = 5
        activeConnections = 0
    }
    
    /// Get current status for debugging
    func getStatus() -> (serverName: String?, maxConnections: Int, activeConnections: Int, hasActiveSemaphore: Bool) {
        return (currentServerName, maxConnections, activeConnections, currentSemaphore != nil)
    }
}
