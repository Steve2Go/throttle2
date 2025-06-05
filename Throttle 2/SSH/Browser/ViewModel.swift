#if os(iOS)
import SwiftUI
import KeychainAccess
import Citadel
import SimpleToast
import NIO
//import Helpers.FilenameMapper

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
    
    // Using SSHConnection instead of SFTPConnectionManager
    private var sshConnection: SSHConnection
    var server: ServerEntity
    
    var downloadTask: Task<Void, Error>?
    weak var delegate: SFTPFileBrowserViewModelDelegate?
    @Published var videoPlayerConfiguration: VideoPlayerConfiguration?
    @Published var showingVideoPlayer = false
    
    private var activeThumbnailOperations: [URL: Task<Void, Never>] = [:]
    
    @Published var musicPlayerPlaylist: [URL] = []
    @Published var musicPlayerStartIndex: Int = 0
    @Published var showingMusicPlayer = false
    
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
        
        // Save server for later use
        self.server = server ?? ServerEntity() // Fallback to avoid force unwrap
        
        // Initialize the SSH connection
        self.sshConnection = SSHConnection(server: self.server)
        
        // Connect to the server
        connectToServer()
    }
    
    deinit {
        Task { [weak self] in
            await self?.cleanup()
        }
    }
    
    private func connectToServer() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.sshConnection.connect()
                await self.checkIfInitialPathIsFile()
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    ToastManager.shared.show(message: "Failed to create connection: \(error)", icon: "exclamationmark.triangle", color: Color.red)
                    print("SSH Connection Error: \(error)")
                }
            }
        }
    }
    
    // MARK: - Directory Operations
    
    func createFolder(name: String) {
        let newFolderPath = "\(currentPath)/\(name)".replacingOccurrences(of: "//", with: "/")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.sshConnection.createDirectory(path: newFolderPath)
                await MainActor.run {
                    self.fetchItems()
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
        Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run { self.isLoading = true }
            do {
                let fileItems = try await self.listDirectoryContents(path: self.currentPath)
                // Build filename mapping for this directory
                let upOneValue = NSString(string: NSString(string: self.currentPath).deletingLastPathComponent).lastPathComponent
                let sortedItems: [FileItem]
                if self.sftpSortOrder == "date" {
                    sortedItems = fileItems.sorted { $0.modificationDate > $1.modificationDate }
                } else {
                    sortedItems = fileItems.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                let foldersFirst = self.sftpFoldersFirst
                let filteredItems = !self.searchQuery.isEmpty ? sortedItems.filter { $0.name.localizedCaseInsensitiveContains(self.searchQuery) } : sortedItems
                let foldersSorted = foldersFirst ? filteredItems.sorted { $0.isDirectory && !$1.isDirectory } : filteredItems
                await MainActor.run {
                    self.upOne = upOneValue.count > 10 ? String(upOneValue.prefix(10)) + "..." : upOneValue
                    self.items = foldersSorted
                    self.isLoading = false
                    self.updateImageUrls()
                    self.refreshTrigger = UUID()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    ToastManager.shared.show(message: "SFTP Listing Error: \(error)", icon: "exclamationmark.triangle", color: Color.red)
                }
                print("SFTP Directory Listing Error: \(error)")
            }
        }
    }
    
    // List directory contents using the SSHConnection's listDirectory method
    private func listDirectoryContents(path: String) async throws -> [FileItem] {
        return try await sshConnection.listDirectory(path: path)
    }
    
    func updateImageUrls() {
        imageUrls = items.filter { !$0.isDirectory && FileType.determine(from: $0.url) == .image }.map { $0.url }
    }
    
    func navigateToFolder(_ folderName: String) {
        clearThumbnailOperations()
        let newPath = "\(currentPath)/\(folderName)".replacingOccurrences(of: "//", with: "/")
        Task { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.currentPath = newPath
                self.fetchItems()
            }
        }
    }
    
    func navigateUp() {
        clearThumbnailOperations()
        if isInitialPathAFile {
            let url = URL(fileURLWithPath: initialPath)
            let parentPath = url.deletingLastPathComponent().path
            Task { [weak self] in
                guard let self = self else { return }
                self.isInitialPathAFile = false
                self.currentPath = parentPath
                self.fetchItems()
            }
            return
        }
        guard currentPath != basePath else { return }
        let trimmedPath = currentPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .dropLast()
            .joined(separator: "/")
        let newPath = trimmedPath.isEmpty ? basePath : "/" + trimmedPath
        Task { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.currentPath = newPath
                self.fetchItems()
            }
           
        }
    }
    
    // Check if the initial path points to a file rather than a directory
    private func checkIfInitialPathIsFile() async {
        do {
            // Get file info by trying to list the directory
            // If it succeeds, it's a directory; if it fails, check if it's a file
            do {
                _ = try await listDirectoryContents(path: initialPath)
                // It's a directory, proceed normally
                await MainActor.run {
                    self.isInitialPathAFile = false
                    self.fetchItems()
                }
            } catch {
                // It might be a file, try to get its attributes
                // Execute a command to check if it's a file and get its info
                let escapedPath = initialPath.replacingOccurrences(of: "'", with: "'\\''")
                let command = "stat -c \"%s %Y\" '\(escapedPath)' 2>/dev/null || echo 'error'"
                
                let (_, output) = try await sshConnection.executeCommand(command)
                let components = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                
                if components.count == 2 && components[0] != "error" {
                    // It's a file, set up the pseudo-folder with just this file
                    let size = Int(components[0]) ?? 0
                    let modTime = TimeInterval(Int(components[1]) ?? 0)
                    let modDate = Date(timeIntervalSince1970: modTime)
                    
                    let filename = URL(fileURLWithPath: initialPath).lastPathComponent
                    
                    // Create a FileItem for the single file
                    let fileItem = FileItem(
                        name: filename,
                        url: URL(fileURLWithPath: initialPath),
                        isDirectory: false,
                        size: size,
                        modificationDate: modDate
                    )
                    
                    await MainActor.run {
                        self.isInitialPathAFile = true
                        self.initialFileItem = fileItem
                        self.items = [fileItem] // Set items to contain only this file
                        self.isLoading = false
                        self.updateImageUrls()
                    }
                } else {
                    // Not a valid file, fallback to directory mode
                    await MainActor.run {
                        self.isInitialPathAFile = false
                        self.fetchItems()
                    }
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
        Task { [weak self] in
            guard let self = self else { return }
            self.isLoading = true
            do {
                if item.isDirectory {
                    try await self.recursiveDelete(atPath: item.url.path)
                } else {
                    try await self.sshConnection.removeFile(path: item.url.path)
                }
                self.isLoading = false
                self.fetchItems()
                ToastManager.shared.show(message: "Deleted", icon: "info.circle", color: Color.green)
            } catch {
                self.isLoading = false
            }
        }
    }
    
    private func recursiveDelete(atPath path: String) async throws {
        // Collect all files and directories under the given path
        var allPaths: [(path: String, isDirectory: Bool)] = []
        
        func collectPaths(currentPath: String) async throws {
            let entries = try await listDirectoryContents(path: currentPath)
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
                try await sshConnection.removeDirectory(path: entryPath)
            } else {
                try await sshConnection.removeFile(path: entryPath)
            }
        }
        
        // Finally, remove the root directory
        try await sshConnection.removeDirectory(path: path)
    }
    
    // Rename a file or directory
    func renameItem(_ item: FileItem, to newName: String) {
        Task { [weak self] in
            guard let self = self else { return }
            self.isLoading = true
            let parentPath = URL(fileURLWithPath: item.url.path).deletingLastPathComponent().path
            let newPath = "\(parentPath)/\(newName)".replacingOccurrences(of: "//", with: "/")
            do {
                try await self.sshConnection.rename(oldPath: item.url.path, newPath: newPath)
                self.isLoading = false
                self.fetchItems()
                ToastManager.shared.show(message: "Renamed", icon: "info.circle", color: Color.green)
            } catch {
                self.isLoading = false
                print("❌ Failed to rename item: \(error)")
            }
        }
    }
    
    // MARK: - File Access and Opening
    
    func openFile(item: FileItem, server: ServerEntity) {
        let fileType = FileType.determine(from: item.url)
        
        switch fileType {
        case .video:
            openVideo(item: item, server: server)
        case .audio:
            openAudio(item: item, server: server)
        case .image:
            openImageBrowser(item)
        case .part:
            return
        case .other, .archive:
            downloadFile(item)
        }
    }
    
    // MARK: - Video Playback
    
    
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
        let keychain = useCloudKit ? Keychain(service: "srgim.throttle2").synchronizable(true) : Keychain(service: "srgim.throttle2").synchronizable(false)

        let username = server.sftpUser ?? ""
        let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
        let hostname = server.sftpHost ?? "127.0.0.1"
        
        let port = server.sftpPort
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        
        if videoItems.count == 1 {
            let encodedPath = item.url.path
            var videoUrl: URL!
           // if server.sftpUsesKey == true {
            videoUrl = URL(string: "ftp://localhost:2121/\(FilenameMapper.encodePath(encodedPath))")!
//            } else {
//                videoUrl = URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)/\(encodedPath)")!
//            }
            self.videoPlayerConfiguration = VideoPlayerConfiguration(singleItem: videoUrl)
            self.showingVideoPlayer = true
        } else {
            var playlist: [URL] = []
            for item in videoItems {
                let encodedPath = item.url.path
//                if server.sftpUsesKey == true {
                    playlist.append(URL(string: "ftp://localhost:2121/\(FilenameMapper.encodePath(encodedPath))")!)
//                } else {
//                    playlist.append(URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)/\(encodedPath)")!)
//                }
            }
            self.videoPlayerConfiguration = VideoPlayerConfiguration(playlist: playlist, startIndex: selectedIndex)
            self.showingVideoPlayer = true
        }
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
        cancelDownload()
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return
        }
        let downloadDirectory = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        } catch {
            print("❌ Could not create Downloads directory: \(error)")
        }
        let localURL = downloadDirectory.appendingPathComponent(item.name)
        Task { [weak self] in
            guard let self = self else { return }
            self.activeDownload = item
            self.downloadDestination = localURL
            self.isDownloading = true
            self.downloadProgress = 0
        }
        downloadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let progressHandler: (Double) -> Bool = { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress
                    }
                    return !Task.isCancelled
                }
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try await self.sshConnection.downloadFile(remotePath: item.url.path, localURL: localURL, progress: { progress in
                    _ = progressHandler(progress)
                })
                if FileManager.default.fileExists(atPath: localURL.path) {
                    await MainActor.run {
                        self.downloadProgress = 1.0
                        self.isDownloading = false
                        self.showShareSheet(for: localURL)
                    }
                } else {
                    throw NSError(domain: "Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "File not found after download"])
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
    
    func openAudio(item: FileItem, server: ServerEntity) {
        // Get all audio files from current directory
        let audioItems = items.filter { item in
            !item.isDirectory && FileType.determine(from: item.url) == .audio
        }
        if audioItems.isEmpty {
            print("❌ No audio files found in the current directory")
            return
        }
        // Find the selected audio's index
        guard let selectedIndex = audioItems.firstIndex(where: { $0.url.path == item.url.path }) else {
            print("❌ Selected audio not found in filtered list")
            return
        }
        // Get credentials
        @AppStorage("useCloudKit") var useCloudKit: Bool = true
        let keychain = useCloudKit ? Keychain(service: "srgim.throttle2").synchronizable(true) : Keychain(service: "srgim.throttle2").synchronizable(false)
         guard let username = server.sftpUser,
               let hostname = server.sftpHost
                else {
             print("❌ Missing SFTP credentials")
             return
         }
              let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
              
            
        
        let port = server.sftpPort
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        if audioItems.count == 1 {
            let path = item.url.path
            print("Found Audio \(path)")
            var audioUrl: URL!
            let encodedPath = item.url.path
            if server.sftpUsesKey == true {
                audioUrl = URL(string: "ftp://localhost:2121\(encodedPath)")!
            } else {
                audioUrl = URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!
            }
            self.musicPlayerPlaylist = [audioUrl]
            self.musicPlayerStartIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showingMusicPlayer = true
            }
        } else {
            var playlist: [URL] = []
            for item in audioItems {
                let path = item.url.path
                print("Found Audio \(path)")
                let encodedPath = item.url.path
                if server.sftpUsesKey == true {
                    playlist.append(URL(string: "ftp://localhost:2121\(encodedPath)")!)
                } else {
                    playlist.append(URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!)
                }
            }
            self.musicPlayerPlaylist = playlist
            self.musicPlayerStartIndex = selectedIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showingMusicPlayer = true
            }
        }
    }
    
    /// Call this before releasing the view model to ensure proper async cleanup.
    @MainActor
    func cleanup() async {
        // Invalidate timer
        nextVideoTimer?.invalidate()
        nextVideoTimer = nil
        // Cancel download task
        downloadTask?.cancel()
        downloadTask = nil
        // Clear thumbnail operations
        clearThumbnailOperations()
        // Disconnect SSH connection
        await sshConnection.disconnect()
    }
}

#endif
