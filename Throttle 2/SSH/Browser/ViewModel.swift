#if os(iOS)
import SwiftUI
//import mft
import KeychainAccess
import Citadel
import SimpleToast
import NIO

// MARK: - ViewModel
class SFTPFileBrowserViewModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published var isLoading = false
    @Published var currentPath: String
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var activeDownload: FileItem?
    @Published var downloadDestination: URL?
    @Published var showingImageBrowser = false
    @Published var selectedImageIndex: Int?
    @Published var imageUrls: [URL] = []
    @Published var isInitialPathAFile = false
    @Published var initialFileItem: FileItem?
    @Published var showVideoPlayer = false
    @Published var selectedFile: FileItem?
    @Published var upOne = ""
    @Published var showingFFmpegPlayer = false

    @AppStorage("sftpSortOrder") var sftpSortOrder: String = "date"
    @AppStorage("sftpFoldersFirst") var sftpFoldersFirst: Bool = true
    @AppStorage("searchQuery") var searchQuery: String = ""
    @Published var refreshTrigger: UUID = UUID()
    
    @Published var videoPlaylist: [FileItem] = []
    @Published var currentPlaylistIndex: Int = 0
    @Published var showVLCDownload = false
    @AppStorage("currentServer") private var currentServerName: String = ""
    
    // VLC queue
    @AppStorage("pendingVideoFiles") private var pendingVideoFiles: Data = Data()
    // Use regular properties instead of @Published for these
    var showingNextVideoAlert = false
    var nextVideoItem: FileItem?
    var nextVideoCountdown: Int = 5
    private var nextVideoTimer: Timer?
    
    let basePath: String
    let initialPath: String
    // Keep both connection methods for gradual transition
    //var sftpConnection: MFTSftpConnection!
    var connectionManager: SFTPConnectionManager
    
    var downloadTask: Task<Void, Error>?
    weak var delegate: SFTPFileBrowserViewModelDelegate?
    @Published var videoPlayerConfiguration: VideoPlayerConfiguration?
    @Published var showingVideoPlayer = false
    
    private var activeThumbnailOperations: [URL: Task<Void, Never>] = [:]
    
    protocol SFTPFileBrowserViewModelDelegate: AnyObject {
        func viewModel(_ viewModel: SFTPFileBrowserViewModel, didRequestVideoPlayback configuration: VideoPlayerConfiguration)
    }
    
    func requestSent() {
        ToastManager.shared.show(message: "Request Sent", icon: "info.circle", color: Color.green)
    }
    
    // MARK: - Initialization and Connection
    
    init(currentPath: String, basePath: String, server: ServerEntity?) {
        self.currentPath = currentPath
        self.basePath = basePath
        self.initialPath = currentPath
        self.isInitialPathAFile = false // Will be determined after connection
        
        // Initialize the connection manager
        self.connectionManager = SFTPConnectionManager(server: server)
        // The connection manager initializes the MFT connection, so we can reference it
       // self.sftpConnection = connectionManager.mftConnection
        
        // Connect to the server
        connectToServer()
    }
    
    private func connectToServer() {
        Task {
            do {
                try await connectionManager.connect()
                
                // Check if the initial path is a file
                await checkIfInitialPathIsFile()
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    ToastManager.shared.show(message: "Failed to create connect: \(error)", icon: "exclamationmark.triangle", color: Color.red)
                    print("SFTP Connection Error: \(error)")
                }
            }
        }
    }
    
    // MARK: - Directory Operations
    
    func createFolder(name: String) {
        let newFolderPath = "\(currentPath)/\(name)".replacingOccurrences(of: "//", with: "/")
        
        Task {
            do {
                try await connectionManager.createDirectory(atPath: newFolderPath)
                
                await MainActor.run {
                    self.fetchItems() // Refresh directory after creation
                }
            } catch {
                await MainActor.run {
                    ToastManager.shared.show(message: "Failed to create folder: \(error)", icon: "exclamationmark.triangle", color: Color.red)
                    print("❌ Failed to create folder: \(error)")
                }
            }
        }
    }
    
    func fetchItems() {
        guard !isLoading else { return }
        
        Task { @MainActor in
            self.isLoading = true
            
            do {
                // Get directory contents using the connection manager
                let fileItems = try await connectionManager.contentsOfDirectory(atPath: currentPath)
                
                // Calculate "up one" display text
                let upOneValue = NSString(string: NSString(string: self.currentPath).deletingLastPathComponent).lastPathComponent
                self.upOne = upOneValue.count > 10 ? String(upOneValue.prefix(10)) + "..." : upOneValue
                
                // Sort items
                var sortedItems = fileItems
                
                if self.sftpSortOrder == "date" {
                    sortedItems = fileItems.sorted {
                        return $0.modificationDate > $1.modificationDate
                    }
                } else {
                    sortedItems = fileItems.sorted {
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }
                
                if self.sftpFoldersFirst {
                    sortedItems = sortedItems.sorted {
                        return $0.isDirectory && !$1.isDirectory // Folders first
                    }
                }
                
                // Apply search filter if needed
                if !self.searchQuery.isEmpty {
                    sortedItems = sortedItems.filter { item in
                        item.name.localizedCaseInsensitiveContains(self.searchQuery)
                    }
                }
                
                // Update the UI
                self.items = sortedItems
                self.isLoading = false
                self.updateImageUrls()
                self.refreshTrigger = UUID()
            } catch {
                self.isLoading = false
                ToastManager.shared.show(message: "SFTP Lising Error: \(error)", icon: "exclamationmark.triangle", color: Color.red)
                print("SFTP Directory Listing Error: \(error)")
            }
        }
    }
    
    func updateImageUrls() {
        imageUrls = items.filter { !$0.isDirectory && FileType.determine(from: $0.url) == .image }.map { $0.url }
    }
    
    func navigateToFolder(_ folderName: String) {
        clearThumbnailOperations()
        let newPath = "\(currentPath)/\(folderName)".replacingOccurrences(of: "//", with: "/")
        
        Task { @MainActor in
            self.currentPath = newPath
            self.fetchItems()
        }
    }
    
    func navigateUp() {
        clearThumbnailOperations()
        
        // Special handling for initial file path
        if isInitialPathAFile {
            // Get the parent directory path
            let url = URL(fileURLWithPath: initialPath)
            let parentPath = url.deletingLastPathComponent().path
            
            Task { @MainActor in
                self.isInitialPathAFile = false
                self.currentPath = parentPath
                self.fetchItems()
            }
            return
        }
        
        guard currentPath != basePath else { return } // Prevent navigating beyond root
        
        // Trim the last directory from the path
        let trimmedPath = currentPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .dropLast()
            .joined(separator: "/")
        let newPath = trimmedPath.isEmpty ? basePath : "/" + trimmedPath
        
        Task { @MainActor in
            self.currentPath = newPath
            self.fetchItems()
        }
    }
    
    // Check if the initial path points to a file rather than a directory
    private func checkIfInitialPathIsFile() async {
        do {
            // Get file info
            let fileInfo = try await connectionManager.infoForFile(atPath: initialPath)
            
            if !fileInfo.isDirectory {
                // It's a file, set up the pseudo-folder with just this file
                let filename = URL(fileURLWithPath: initialPath).lastPathComponent
                
                // Create a FileItem for the single file
                let fileItem = FileItem(
                    name: filename,
                    url: URL(fileURLWithPath: initialPath),
                    isDirectory: false,
                    size: Int(fileInfo.size),
                    modificationDate: fileInfo.mtime
                )
                
                await MainActor.run {
                    self.isInitialPathAFile = true
                    self.initialFileItem = fileItem
                    self.items = [fileItem] // Set items to contain only this file
                    self.isLoading = false
                    self.updateImageUrls()
                }
            } else {
                // It's a directory, proceed normally
                await MainActor.run {
                    self.isInitialPathAFile = false
                    self.fetchItems()
                }
            }
        } catch {
            // If there's an error, assume it's a directory and proceed normally
            await MainActor.run {
                self.isInitialPathAFile = false
                self.fetchItems()
            }
        }
    }
    
    // MARK: - File Operations
    
    // Delete a file or directory
    func deleteItem(_ item: FileItem) {
        Task { @MainActor in
            self.isLoading = true
            
            do {
                if item.isDirectory {
                    try await recursiveDelete(atPath: item.url.path)
                } else {
                    try await connectionManager.removeFile(atPath: item.url.path)
                }
                
                self.isLoading = false
                self.fetchItems() // Refresh the directory after deletion
                ToastManager.shared.show(message: "Deleted", icon: "info.circle", color: Color.green)
            } catch {
                self.isLoading = false
                ToastManager.shared.show(message: "Failed to Delete: \(error)", icon: "exclamationmark.triangle", color: Color.red)
            }
        }
    }
    
    private func recursiveDelete(atPath path: String) async throws {
        // Collect all files and directories under the given path
        var allPaths: [(path: String, isDirectory: Bool)] = []
        
        func collectPaths(currentPath: String) async throws {
            let entries = try await connectionManager.contentsOfDirectory(atPath: currentPath)
            for entry in entries {
                // Skip special entries
                if entry.name == "." || entry.name == ".." { continue }
                allPaths.append((path: entry.url.path, isDirectory: entry.isDirectory))
                if entry.isDirectory {
                    try await collectPaths(currentPath: entry.url.path)
                }
            }
        }
        
        try await collectPaths(currentPath: path)
        
        // Sort paths by depth (deepest paths first)
        allPaths.sort { (first, second) -> Bool in
            return first.path.components(separatedBy: "/").count > second.path.components(separatedBy: "/").count
        }
        
        // Delete all collected entries: files first, then directories
        for (entryPath, isDirectory) in allPaths {
            if isDirectory {
                try await connectionManager.removeDirectory(atPath: entryPath)
            } else {
                try await connectionManager.removeFile(atPath: entryPath)
            }
        }
        
        // Finally, remove the root directory
        try await connectionManager.removeDirectory(atPath: path)
    }
    
    // Rename a file or directory
    func renameItem(_ item: FileItem, to newName: String) {
        Task { @MainActor in
            self.isLoading = true
            
            // Get the parent directory path
            let parentPath = URL(fileURLWithPath: item.url.path).deletingLastPathComponent().path
            let newPath = "\(parentPath)/\(newName)".replacingOccurrences(of: "//", with: "/")
            
            do {
                try await connectionManager.moveItem(atPath: item.url.path, toPath: newPath)
                
                self.isLoading = false
                self.fetchItems() // Refresh the directory after renaming
                ToastManager.shared.show(message: "Renamed", icon: "info.circle", color: Color.green)
            } catch {
                self.isLoading = false
                print("❌ Failed to rename item: \(error)")
            }
        }
    }
    
    // MARK: - Video Playback
    
    func isVLCInstalled() -> Bool {
        #if os(iOS)
        // Use a simple vlc:// URL to test if VLC is installed
        guard let vlcUrl = URL(string: "vlc://") else { return false }
        return UIApplication.shared.canOpenURL(vlcUrl)
        #else
        // For macOS, you might want to check differently or always return true
        return false
        #endif
    }
    
    func openVideoInVLC(item: FileItem, server: ServerEntity) {
        // Check if VLC is installed
        if !isVLCInstalled() {
            showVLCDownload.toggle()
            return
        }
        
        // Get all video files from current directory
        let videoItems = items.filter { item in
            !item.isDirectory && FileType.determine(from: item.url) == .video
        }
        
        if videoItems.isEmpty {
            print("❌ No video files found in the current directory")
            return
        }
        
        // Find the selected video's index
        guard let selectedIndex = videoItems.firstIndex(where: { $0.url.path == item.url.path }) else {
            print("❌ Selected video not found in filtered list")
            return
        }
        
        // Save remaining videos to AppStorage - Fix range handling
        var remainingVideos: [String] = []
        
        // Add videos after the current one - safer range handling
        if selectedIndex < videoItems.count - 1 {
            let afterVideos = videoItems[(selectedIndex + 1)...].map { $0.url.path }
            remainingVideos.append(contentsOf: afterVideos)
        }
        
        // Add videos before the current one - safer range handling
        if selectedIndex > 0 {
            let beforeVideos = videoItems[..<selectedIndex].map { $0.url.path }
            remainingVideos.append(contentsOf: beforeVideos)
        }
        
        do {
            // Encode and save to AppStorage
            pendingVideoFiles = try JSONEncoder().encode(remainingVideos)
            // Save server name for later reference
            currentServerName = server.name ?? ""
        } catch {
            print("❌ Failed to encode video list: \(error)")
        }
        
        // Use existing code to open the selected video in VLC
        @AppStorage("useCloudKit") var useCloudKit: Bool = true
        let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            print("❌ Missing server credentials")
            return
        }
        
        let port = server.sftpPort
        let path = item.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        
        // Properly encode the password for URL
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        
        let vlcUrl = URL(string: "vlc-x-callback://x-callback-url/stream?x-success=throttle://x-callback-url/playbackDidFinish&x-error=throttle://x-callback-url/playbackDidFail&url=sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")
        
        if let url = vlcUrl {
            DispatchQueue.main.async {
                #if os(iOS)
                UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
        }
    }
    
    func openVideo(item: FileItem, server: ServerEntity) {
        // Get all video files from current directory
        let videoItems = items.filter { item in
            !item.isDirectory && FileType.determine(from: item.url) == .video
        }
        
        if videoItems.isEmpty {
            print("❌ No video files found in the current directory")
            return
        }
        
        // Find the selected video's index
        guard let selectedIndex = videoItems.firstIndex(where: { $0.url.path == item.url.path }) else {
            print("❌ Selected video not found in filtered list")
            return
        }
        
        // Get credentials
        @AppStorage("useCloudKit") var useCloudKit: Bool = true
        let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            print("❌ Missing server credentials")
            return
        }
        @AppStorage("StreamingServerLocalPort") var localStreamPort = 8080
        //var localStreamPort = 4001
        
        let port = server.sftpPort
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        
        if videoItems.count == 1 {
            let path = item.url.path //.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            print("Found Video \(path)")
            var vlcUrl: URL!
            //let vlcUrl = URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!
            if server.sftpUsesKey == true {
                vlcUrl = URL(string: "sftp://\(username):\(encodedPassword)@localhost:2222\(path)")!
            } else {
                vlcUrl = URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!
            }
//            let vlcUrl = URL(string: "http://localhost:\(localStreamPort)\(path)")!
            
            // Create and set the configuration
            self.videoPlayerConfiguration = VideoPlayerConfiguration(singleItem: vlcUrl)
            self.showingVideoPlayer = true
        } else {
            var playlist: [URL] = []
            for item in videoItems {
                let path = item.url.path //.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                print("Found Video \(path)")
                //
                if server.sftpUsesKey == true {
                    playlist.append(URL(string: "sftp://\(username):\(encodedPassword)@localhost:2222\(path)")!)
                } else {
                    playlist.append(URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!)
                }
            }
            
            // Create and set the configuration
            self.videoPlayerConfiguration = VideoPlayerConfiguration(playlist: playlist, startIndex: selectedIndex)
            self.showingVideoPlayer = true
        }
    }
    
    // MARK: - VLC Playlist Handling
    
    func handleVLCCallback(server: ServerEntity) {
        print("📲 Received VLC callback with server: \(server.name ?? "unknown")")
        
        // Check if we have pending videos
        guard !pendingVideoFiles.isEmpty else {
            print("✅ No more videos in queue")
            return
        }
        
        do {
            // Decode the list of video paths
            let videoPaths = try JSONDecoder().decode([String].self, from: pendingVideoFiles)
            
            guard !videoPaths.isEmpty else {
                print("✅ No more videos in queue")
                pendingVideoFiles = Data() // Clear the storage
                return
            }
            
            // Get the next video path
            let nextVideoPath = videoPaths[0]
            
            // Create a FileItem for the next video
            let nextVideoName = URL(fileURLWithPath: nextVideoPath).lastPathComponent
            let nextVideoItem = FileItem(
                name: nextVideoName,
                url: URL(fileURLWithPath: nextVideoPath),
                isDirectory: false,
                size: nil,
                modificationDate: Date()
            )
            
            // Remove this video from the list and update storage
            let remainingVideos = Array(videoPaths.dropFirst())
            pendingVideoFiles = try JSONEncoder().encode(remainingVideos)
            
            // Show alert with countdown before playing next video
            showNextVideoAlert(item: nextVideoItem, server: server)
        } catch {
            print("❌ Failed to decode video list: \(error)")
            pendingVideoFiles = Data() // Clear on error
        }
    }
    
    // Show alert with countdown before playing next video
    private func showNextVideoAlert(item: FileItem, server: ServerEntity) {
        DispatchQueue.main.async {
            self.nextVideoItem = item
            self.nextVideoCountdown = UserDefaults.standard.integer(forKey: "waitPlaylist")
            self.showingNextVideoAlert = true
            
            // Start countdown timer
            self.nextVideoTimer?.invalidate()
            self.nextVideoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                if self.nextVideoCountdown > 0 {
                    self.nextVideoCountdown -= 1
                    // Manually trigger an update since we're not using @Published
                    self.objectWillChange.send()
                } else {
                    // Time's up, play the video
                    self.playNextVideo(server: server)
                    timer.invalidate()
                }
            }
        }
    }
    
    func restartNextVideoTimer(server: ServerEntity) {
        guard let item = nextVideoItem else { return }
        
        // Clear any existing timer
        nextVideoTimer?.invalidate()
        
        // Start countdown timer
        nextVideoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            if self.nextVideoCountdown > 0 {
                self.nextVideoCountdown -= 1
                // Manually trigger an update since we're not using @Published
                self.objectWillChange.send()
            } else {
                // Time's up, play the video
                self.playNextVideo(server: server)
                timer.invalidate()
            }
        }
    }
    
    // Function to play the next video
    func playNextVideo(server: ServerEntity) {
        guard let item = nextVideoItem else {
            showingNextVideoAlert = false
            return
        }
        
        // Close the alert
        showingNextVideoAlert = false
        
        // Send to VLC (reusing the existing VLC opener)
        openVideoInVLC(item: item, server: server)
        
        // Clear references
        nextVideoItem = nil
        nextVideoTimer?.invalidate()
        nextVideoTimer = nil
    }
    
    // Function to cancel next video playback
    func cancelNextVideo() {
        // Close the alert
        showingNextVideoAlert = false
        
        // Clear the queue
        pendingVideoFiles = Data()
        
        // Clear references
        nextVideoItem = nil
        nextVideoTimer?.invalidate()
        nextVideoTimer = nil
    }
    
    func openImageBrowser(_ item: FileItem) {
        if let index = imageUrls.firstIndex(of: item.url) {
            DispatchQueue.main.async {
                self.selectedImageIndex = index
                self.showingImageBrowser = true
            }
        }
    }
    
    // MARK: - File Download
    
    func downloadFile(_ item: FileItem) {
        // Cancel any ongoing download
        cancelDownload()
        
        // Get Documents directory - this will be visible in Files app with proper Info.plist settings
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return
        }
        
        // Create a Downloads folder within Documents
        let downloadDirectory = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        
        do {
            // Create the directory if it doesn't exist
            try FileManager.default.createDirectory(at: downloadDirectory,
                                                   withIntermediateDirectories: true)
        } catch {
            print("❌ Could not create Downloads directory: \(error)")
        }
        
        let localURL = downloadDirectory.appendingPathComponent(item.name)
        
        // Update UI to show download is starting
        Task { @MainActor in
            self.activeDownload = item
            self.downloadDestination = localURL
            self.isDownloading = true
            self.downloadProgress = 0
        }
        
        downloadTask = Task {
            do {
                // Create a progress handler
                let progressHandler: (Double) -> Bool = { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress
                    }
                    // Return false to cancel the download
                    return !Task.isCancelled
                }
                
                // Remove existing file if needed
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                
                // Download the file
                try await connectionManager.downloadFile(
                    remotePath: item.url.path,
                    localURL: localURL,
                    progress: progressHandler
                )
                
                // Verify download succeeded
                if FileManager.default.fileExists(atPath: localURL.path) {
                    await MainActor.run {
                        self.downloadProgress = 1.0
                        self.isDownloading = false
                        
                        // Share sheet still works, but user can also find file in Files app
                        self.showShareSheet(for: localURL)
                    }
                } else {
                    throw NSError(domain: "Download", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "File not found after download"])
                }
            } catch {
                if error is CancellationError {
                    print("Download cancelled by user")
                } else {
                    print("❌ Download error: \(error)")
                    await MainActor.run {
                        self.isDownloading = false
                        self.activeDownload = nil
                    }
                }
            }
        }
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        
        Task { @MainActor in
            self.isDownloading = false
            self.activeDownload = nil
            self.downloadProgress = 0
        }
    }
    
    func showShareSheet(for url: URL) {
        #if os(iOS)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // Find the active window scene
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // Present the activity controller
            rootVC.present(activityVC, animated: true, completion: nil)
        }
        #else
        // macOS implementation
        let sharingServicePicker = NSSharingServicePicker(items: [url])
        
        // Find the window to anchor the share sheet
        if let window = NSApplication.shared.keyWindow {
            sharingServicePicker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .minY)
        }
        #endif
    }
    
    // MARK: - Thumbnail Management
    
    func clearThumbnailOperations() {
        for (_, operation) in activeThumbnailOperations {
            operation.cancel()
        }
        activeThumbnailOperations.removeAll()
    }
}

//// MARK: - SFTPUploadHandler Conformance
//extension SFTPFileBrowserViewModel: SFTPUploadHandler {
//    func getConnection() -> MFTSftpConnection {
//        return sftpConnection
//    }
//    
//    func getConnectionManager() -> SFTPConnectionManager? {
//        return connectionManager
//    }
//    
//    func refreshItems() {
//        self.fetchItems()
//    }
//}
#endif
