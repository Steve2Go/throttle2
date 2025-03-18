class ThumbnailManager {
    private var cache = NSCache<NSString, ThumbnailContainer>()
    private let queue = DispatchQueue(label: "com.throttle.thumbnails", qos: .utility)
    private let mediaPlayer = VLCMediaPlayer()
    
    struct ThumbnailContainer {
        let image: Image
        let timestamp: Date
    }
    
    func getThumbnail(for path: String, server: ServerEntity) async throws -> Image? {
        // Check cache first
        if let cached = cache.object(forKey: path as NSString) {
            // Only use cache if less than 1 hour old
            if Date().timeIntervalSince(cached.timestamp) < 3600 {
                return cached.image
            }
        }
        
        // Generate thumbnail
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    // Setup SFTP URL
                    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
                    guard let username = server.sftpUser,
                          let password = keychain["sftpPassword" + (server.name ?? "")],
                          let hostname = server.sftpHost else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    let port = server.sftpPort
                    let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
                    let sftpURLString = "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)"
                    
                    guard let sftpURL = URL(string: sftpURLString) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    let media = VLCMedia(url: sftpURL)
                    self.mediaPlayer.media = media
                    
                    // For video files, take snapshot at 1 second
                    self.mediaPlayer.time = VLCTime(int: 1000)
                    if let snapshot = self.mediaPlayer.snapshots?.first {
                        #if os(iOS)
                        let image = Image(uiImage: snapshot)
                        #else
                        let image = Image(nsImage: snapshot)
                        #endif
                        
                        // Cache the result
                        let container = ThumbnailContainer(image: image, timestamp: Date())
                        self.cache.setObject(container, forKey: path as NSString)
                        
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func clearCache() {
        cache.removeAllObjects()
    }
}