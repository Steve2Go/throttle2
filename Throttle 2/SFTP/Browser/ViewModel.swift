//
//  SFTPFileBrowserViewModel.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//
#if os(iOS)
import SwiftUI
import mft
import KeychainAccess

// MARK: - ViewModel
class SFTPFileBrowserViewModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
       @Published private(set) var isLoading = false
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

    @AppStorage("sftpSortOrder") var sftpSortOrder: String = "date"
    @AppStorage("sftpFoldersFirst") var sftpFoldersFirst: Bool = true
    @AppStorage("searchQuery") var searchQuery: String = ""
    @Published var refreshTrigger: UUID = UUID()
    
    @Published var videoPlaylist: [FileItem] = []
    @Published var currentPlaylistIndex: Int = 0
    @Published var showVLCDownload = false
    @AppStorage("currentServer") private var currentServerName: String = ""
    
    //vlc queue
    @AppStorage("pendingVideoFiles") private var pendingVideoFiles: Data = Data()
    // Use regular properties instead of @Published for these
    var showingNextVideoAlert = false
    var nextVideoItem: FileItem?
    var nextVideoCountdown: Int = 5
    private var nextVideoTimer: Timer?
    
    let basePath: String
    let initialPath: String
    var sftpConnection: MFTSftpConnection!
    var downloadTask: Task<Void, Error>?
    weak var delegate: SFTPFileBrowserViewModelDelegate?
    @Published var videoPlayerConfiguration: VideoPlayerConfiguration?
    @Published var showingVideoPlayer = false
    
    protocol SFTPFileBrowserViewModelDelegate: AnyObject {
        func viewModel(_ viewModel: SFTPFileBrowserViewModel, didRequestVideoPlayback configuration: VideoPlayerConfiguration)
    }
    
    // Delete a file or directory
        func deleteItem(_ item: FileItem) {
            isLoading = true
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if item.isDirectory {
                        try self.recursiveDelete(atPath: item.url.path)
                    } else {
                        try self.sftpConnection.removeFile(atPath: item.url.path)
                    }
                    
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.fetchItems() // Refresh the directory after deletion
                        
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        print("❌ Failed to delete item: \(error)")
                    }
                }
            }
        }
    
    private func recursiveDelete(atPath path: String) throws {
        // Collect all files and directories under the given path
        var allPaths: [(path: String, isDirectory: Bool)] = []
        
        func collectPaths(currentPath: String) throws {
            let entries = try sftpConnection.contentsOfDirectory(atPath: currentPath, maxItems: 0)
            for entry in entries {
                // Skip special entries
                if entry.filename == "." || entry.filename == ".." { continue }
                let entryPath = "\(currentPath)/\(entry.filename)".replacingOccurrences(of: "//", with: "/")
                allPaths.append((path: entryPath, isDirectory: entry.isDirectory))
                if entry.isDirectory {
                    try collectPaths(currentPath: entryPath)
                }
            }
        }
        
        try collectPaths(currentPath: path)
        
        // Sort paths by depth (deepest paths first)
        allPaths.sort { (first, second) -> Bool in
            return first.path.components(separatedBy: "/").count > second.path.components(separatedBy: "/").count
        }
        
        // Delete all collected entries: files first, then directories
        for (entryPath, isDirectory) in allPaths {
            if isDirectory {
                do {
                    try sftpConnection.removeDirectory(atPath: entryPath)
                } catch let error as NSError {
                    if error.domain == "sftp" && error.code == 2 {
                        // Ignore error if file/directory doesn't exist
                    } else {
                        throw error
                    }
                }
            } else {
                do {
                    try sftpConnection.removeFile(atPath: entryPath)
                } catch let error as NSError {
                    if error.domain == "sftp" && error.code == 2 {
                        // Ignore error if file doesn't exist
                    } else {
                        throw error
                    }
                }
            }
        }
        
        // Finally, remove the root directory
        do {
            try sftpConnection.removeDirectory(atPath: path)
        } catch let error as NSError {
            if error.domain == "sftp" && error.code == 2 {
                // Ignore error if the directory doesn't exist
            } else {
                throw error
            }
        }
    }
        
        // Rename a file or directory
        func renameItem(_ item: FileItem, to newName: String) {
            isLoading = true
            
            // Get the parent directory path
            let parentPath = URL(fileURLWithPath: item.url.path).deletingLastPathComponent().path
            let newPath = "\(parentPath)/\(newName)".replacingOccurrences(of: "//", with: "/")
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.sftpConnection.moveItem(atPath: item.url.path, toPath: newPath)
                    
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.fetchItems() // Refresh the directory after renaming
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        print("❌ Failed to rename item: \(error)")
                    }
                }
            }
        }
    
    init(currentPath: String, basePath: String, server: ServerEntity?) {
        self.currentPath = currentPath
        self.basePath = basePath
        self.initialPath = currentPath
        self.isInitialPathAFile = false // Will be determined after connection
        connectSFTP(server: server)
    }
    
    
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
    
    private func connectSFTP(server: ServerEntity?) {
        guard let server = server else {
            print("❌ No server selected for SFTP connection")
            return
        }
        
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if server.sftpUsesKey {
                    // Retrieve the key from the keychain and use it for authentication
                    let key = keychain["sftpKey" + (server.name ?? "")] ?? ""
                    let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
                    self.sftpConnection = MFTSftpConnection(
                        hostname: server.sftpHost ?? "",
                        port: Int(server.sftpPort),
                        username: server.sftpUser ?? "",
                        prvKey: key,
                        passphrase: password
                    )
                } else {
                    // Use password-based authentication
                    let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
                    self.sftpConnection = MFTSftpConnection(
                        hostname: server.sftpHost ?? "",
                        port: Int(server.sftpPort),
                        username: server.sftpUser ?? "",
                        password: password
                    )
                }
                
                try self.sftpConnection.connect()
                try self.sftpConnection.authenticate()
                self.checkIfInitialPathIsFile()
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    print("SFTP Connection Error: \(error)")
                }
            }
        }
    }
    
    func createFolder(name: String) {
        let newFolderPath = "\(currentPath)/\(name)".replacingOccurrences(of: "//", with: "/")
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.sftpConnection.createDirectory(atPath: newFolderPath)
                
                DispatchQueue.main.async {
                    self.fetchItems() // Refresh directory after creation
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Failed to create folder: \(error)")
                }
            }
        }
    }
    
    func fetchItems() {
        guard !isLoading else { return }
       
            DispatchQueue.main.async {
                self.isLoading = true
            }
            
        func refreshView() {
            DispatchQueue.main.async {
                self.refreshTrigger = UUID()
                self.fetchItems()
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try self.sftpConnection.contentsOfDirectory(atPath: self.currentPath, maxItems: 0)
                DispatchQueue.main.async {
                    self.upOne = NSString( string:  NSString( string: self.currentPath ).deletingLastPathComponent ).lastPathComponent
                }
                let fileItems = entries.map { entry -> FileItem in
                    let isDir = entry.isDirectory
                    let url = URL(fileURLWithPath: self.currentPath).appendingPathComponent(entry.filename)
                    let fileSize = entry.isDirectory ? nil : Int(truncatingIfNeeded: entry.size)
                    return FileItem(
                        name: entry.filename,
                        url: url,
                        isDirectory: isDir,
                        size: fileSize,
                        modificationDate: entry.mtime
                    )
                }
                
                // ✅ Sort: Folders First, Then Sort by Modification Date (Newest First)
                //sort everything
                var sortedItems: [FileItem] = []
                
                if self.sftpSortOrder == "date" {
                    sortedItems = fileItems.sorted {
                            return $0.modificationDate > $1.modificationDate
                        }
                } else{
                    sortedItems = fileItems.sorted {
                        return $0.name > $1.name
                        }
                }
                
                if self.sftpFoldersFirst {
                    sortedItems = sortedItems.sorted {
                        return $0.isDirectory && !$1.isDirectory // Folders first
                    }
                }
                if !self.searchQuery.isEmpty {
                    sortedItems = sortedItems.filter { item in
                        item.name.localizedCaseInsensitiveContains(self.searchQuery)
                        
                    }
                }
                
                
                
                
                /// sorted by date
//                let sortedItems = fileItems.sorted {
//                    if $0.isDirectory == $1.isDirectory {
//                        return $0.modificationDate > $1.modificationDate // Sort by date within each group
//                    }
//                    return $0.isDirectory && !$1.isDirectory // Folders first
//                }

                DispatchQueue.main.async {
                    self.items = sortedItems
                    self.isLoading = false
                    self.updateImageUrls()
                    self.refreshTrigger = UUID()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    print("SFTP Directory Listing Error: \(error)")
                }
            }
        }
    }
    
    func updateImageUrls() {
        imageUrls = items.filter { !$0.isDirectory && FileType.determine(from: $0.url) == .image }.map { $0.url }
    }
    
    /// ✅ Navigate into a folder and refresh UI
    func navigateToFolder(_ folderName: String) {
        clearThumbnailOperations()
        let newPath = "\(currentPath)/\(folderName)".replacingOccurrences(of: "//", with: "/")
        DispatchQueue.main.async {
            self.currentPath = newPath
            self.fetchItems()
        }
    }
    
    /// ✅ Navigate up one directory and refresh UI
    func navigateUp() {
        clearThumbnailOperations()
        // Special handling for initial file path
        if isInitialPathAFile { //}&& currentPath == initialPath {
            // Get the parent directory path
            let url = URL(fileURLWithPath: initialPath)
            let parentPath = url.deletingLastPathComponent().path
            
            DispatchQueue.main.async {
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
        DispatchQueue.main.async {
            self.currentPath = newPath
            self.fetchItems()
        }
    }
    
    // Check if the initial path points to a file rather than a directory
    func checkIfInitialPathIsFile() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // First try to get attributes of the path
                // Using fileExistsAtPath instead of attributesOfItem
                //let isDir = try self.sftpConnection.infoForFile(atPath: self.initialPath).isDirectory
                let fileInfo = try? self.sftpConnection.infoForFile(atPath: self.initialPath)
                
                if fileInfo?.isDirectory != false {
                    // It's a directory, proceed normally
                    DispatchQueue.main.async {
                        self.isInitialPathAFile = false
                        self.fetchItems()
                    }
                } else {
                    // It's a file, set up the pseudo-folder with just this file
                    let filename = URL(fileURLWithPath: self.initialPath).lastPathComponent
                    let parentPath = URL(fileURLWithPath: self.initialPath).deletingLastPathComponent().path
                    
                    // Get file size and date if possible
                    
                    let fileSize = fileInfo?.size != nil ? Int(fileInfo!.size) : 0
                    let modDate = fileInfo?.mtime ?? Date()
                    
                    // Create a FileItem for the single file
                    let fileItem = FileItem(
                        name: filename,
                        url: URL(fileURLWithPath: self.initialPath),
                        isDirectory: false,
                        size: fileSize,
                        modificationDate: modDate
                    )
                    
                    DispatchQueue.main.async {
                        self.isInitialPathAFile = true
                        self.initialFileItem = fileItem
                        self.items = [fileItem] // Set items to contain only this file
                        self.isLoading = false
                        self.updateImageUrls()
                    }
                }
            } catch {
                // If we can't get attributes, try the parent directory
                let parentPath = URL(fileURLWithPath: self.initialPath).deletingLastPathComponent().path
                
                DispatchQueue.main.async {
                    self.currentPath = parentPath
                    self.fetchItems()
                    print("Could not determine if path is file, defaulting to parent directory: \(error)")
                }
            }
        }
    }
    
    // MARK: - File Handling
    

    
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
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
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
        
        let vlcUrl = URL(string: "vlc-x-callback://x-callback-url/stream?x-success=throttle://x-callback-url/playbackDidFinish&x-error=throttle://x-callback-url/playbackDidFail&url=http://localhost:\(port)\(path)")
                            //"vlc-x-callback://x-callback-url/stream?x-success=throttle://x-callback-url/playbackDidFinish&x-error=throttle://x-callback-url/playbackDidFail&url=sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")
        
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
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            print("❌ Missing server credentials")
            return
        }
        
        let port = server.sftpPort
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        
        if videoItems.count == 1 {
            let path = item.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            print("Found Video \(path)")
            let vlcUrl = URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!
            
            // Create and set the configuration
            self.videoPlayerConfiguration = VideoPlayerConfiguration(singleItem: vlcUrl)
            self.showingVideoPlayer = true
        } else {
            var playlist: [URL] = []
            for item in videoItems {
                let path = item.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                print("Found Video \(path)")
                playlist.append(URL(string: "sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")!)
            }
            
            // Create and set the configuration
            self.videoPlayerConfiguration = VideoPlayerConfiguration(playlist: playlist, startIndex: selectedIndex)
            self.showingVideoPlayer = true
        }
    }
    
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
    
//    // Update the existing openVideoInVLC function
//    func openVideoInVLC(item: FileItem, server: ServerEntity) {
//        // Check if VLC is installed
//        if !isVLCInstalled() {
//            showVLCDownload.toggle()
//            return
//        }
//
//        // Get all video files from current directory
//        let videoItems = items.filter { item in
//            !item.isDirectory && FileType.determine(from: item.url) == .video
//        }
//
//        if videoItems.isEmpty {
//            print("❌ No video files found in the current directory")
//            return
//        }
//
//        // Find the selected video's index
//        guard let selectedIndex = videoItems.firstIndex(where: { $0.url.path == item.url.path }) else {
//            print("❌ Selected video not found in filtered list")
//            return
//        }
//
//        // Save remaining videos to AppStorage
//        let remainingVideos = Array(videoItems[(selectedIndex + 1)...] + videoItems[..<selectedIndex])
//
//        do {
//            // Create a simple array of file paths
//            let videoPaths = remainingVideos.map { $0.url.path }
//            // Encode and save to AppStorage
//            let data = try JSONEncoder().encode(videoPaths)
//            pendingVideoFiles = data
//            // Save server name for later use
//            currentServerName = server.name ?? ""
//        } catch {
//            print("❌ Failed to encode video list: \(error)")
//        }
//
//        // Open the selected video in VLC
//        sendToVLC(item: item, server: server)
//    }

    // Function to send a video to VLC
    private func sendToVLC(item: FileItem, server: ServerEntity) {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")],
              let hostname = server.sftpHost else {
            print("❌ Missing server credentials")
            return
        }
        
        let port = server.sftpPort
        let path = item.url.path
        
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

    // Function to handle VLC callback
    func handleVLCCallback() {
        print("📲 Received VLC callback")
        
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
            
            // Find the server by name
            if let server = findServerByName(currentServerName) {
                // Show alert with countdown before playing next video
                showNextVideoAlert(item: nextVideoItem, server: server)
            }
        } catch {
            print("❌ Failed to decode video list: \(error)")
            pendingVideoFiles = Data() // Clear on error
        }
    }

    // Find server by name (implement this based on your app structure)
    private func findServerByName(_ name: String) -> ServerEntity? {
        // This would need to be implemented based on how your app stores servers
        // This is a placeholder
        return nil
    }


    
    
    func openImageBrowser(_ item: FileItem) {
        if let index = imageUrls.firstIndex(of: item.url) {
            DispatchQueue.main.async {
                self.selectedImageIndex = index
                self.showingImageBrowser = true
            }
        }
    }
    
    // Modified downloadFileAsync that uses streams instead of direct file writing
    func downloadFileAsync(remotePath: String,
                          localURL: URL,
                          progressHandler: @escaping (Double) -> Void) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                print("Starting download from: \(remotePath) to: \(localURL.path)")
                
                // Create the directory if it doesn't exist
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                
                // First create an output stream to the file
                guard let outputStream = OutputStream(url: localURL, append: false) else {
                    throw NSError(domain: "Download", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Failed to create output stream"])
                }
                
                // Create a progress handler that matches the sftpConnection.contents() method requirement
                let progressAdapter: ((UInt64, UInt64) -> Bool) = { bytesReceived, totalBytes in
                    let progress = totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
                    
                    // Debug progress
                    if bytesReceived % 1024000 == 0 {
                        print("Download progress: \(bytesReceived)/\(totalBytes) bytes (\(Int(progress * 100))%)")
                    }
                    
                    // Report progress on main thread
                    DispatchQueue.main.async {
                        progressHandler(progress)
                    }
                    
                    // Check for cancellation
                    if Task.isCancelled {
                        print("Download cancelled by user")
                        return false // Signal to stop download
                    }
                    
                    return true // Continue download
                }
                
                // Use the contents method to download to the stream
                try self.sftpConnection.contents(
                    atPath: remotePath,
                    toStream: outputStream,
                    fromPosition: 0,
                    progress: progressAdapter
                )
                
                // Verify the file exists
                if FileManager.default.fileExists(atPath: localURL.path) {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
                    print("✅ Download completed successfully: \(localURL.path) (\(fileSize) bytes)")
                    continuation.resume()
                } else {
                    print("❌ File does not exist after download")
                    throw NSError(domain: "Download", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "File not found after download"])
                }
            } catch {
                print("❌ Download error: \(error)")
                // Clean up partial download if there was an error
                try? FileManager.default.removeItem(at: localURL)
                continuation.resume(throwing: error)
            }
        }
    }

    // Updated downloadFile function to use the new approach
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
        DispatchQueue.main.async {
            self.activeDownload = item
            self.downloadDestination = localURL
            self.isDownloading = true
            self.downloadProgress = 0
        }
        
        downloadTask = Task {
            do {
                let progressHandler: ((Double) -> Void) = { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = progress
                    }
                }
                
                // Remove existing file if needed
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                
                // Download using our stream-based method
                try await self.downloadFileAsync(
                    remotePath: item.url.path,
                    localURL: localURL,
                    progressHandler: progressHandler
                )
                
                // Verify download succeeded
                if FileManager.default.fileExists(atPath: localURL.path) {
                    DispatchQueue.main.async {
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
                DispatchQueue.main.async {
                    print("❌ Download error: \(error)")
                    self.isDownloading = false
                    self.activeDownload = nil
                }
            }
        }
    }

    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        
        DispatchQueue.main.async {
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
}
#endif
