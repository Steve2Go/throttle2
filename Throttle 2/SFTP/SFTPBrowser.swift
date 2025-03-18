//
//  FileType.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 4/3/2025.
//


import SwiftUI
import Combine
import mft
import KeychainAccess
import AVKit

// MARK: - Constants for file types
enum FileType {
    case video
    case image
    case other
    
    static func determine(from url: URL) -> FileType {
        let ext = url.pathExtension.lowercased()
        
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "3gp", "mpg", "mpeg"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp"]
        
        if videoExtensions.contains(ext) {
            return .video
        } else if imageExtensions.contains(ext) {
            return .image
        } else {
            return .other
        }
    }
}

// MARK: - ViewModel
class FileBrowserViewModel: ObservableObject {
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
    
    let basePath: String
    private var sftpConnection: MFTSftpConnection!
    private var downloadTask: Task<Void, Error>?
    
    init(currentPath: String, basePath: String, server: ServerEntity?) {
        self.currentPath = currentPath
        self.basePath = basePath
        connectSFTP(server: server)
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
                self.fetchItems()
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
        Task {
            isLoading = true
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try self.sftpConnection.contentsOfDirectory(atPath: self.currentPath, maxItems: 0)

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
                let sortedItems = fileItems.sorted {
                    if $0.isDirectory == $1.isDirectory {
                        return $0.modificationDate > $1.modificationDate // Sort by date within each group
                    }
                    return $0.isDirectory && !$1.isDirectory // Folders first
                }

                DispatchQueue.main.async {
                    self.items = sortedItems
                    self.isLoading = false
                    self.updateImageUrls()
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
        let newPath = "\(currentPath)/\(folderName)".replacingOccurrences(of: "//", with: "/")
        DispatchQueue.main.async {
            self.currentPath = newPath
            self.fetchItems()
        }
    }
    
    /// ✅ Navigate up one directory and refresh UI
    func navigateUp() {
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
    
    // MARK: - File Handling
    
    func openFile(_ item: FileItem) {
        guard !item.isDirectory else {
            navigateToFolder(item.name)
            return
        }
        
        let fileType = FileType.determine(from: item.url)
        
        switch fileType {
        case .video:
            openVideoInVLC(item)
        case .image:
            openImageBrowser(item)
        case .other:
            downloadFile(item)
        }
    }
    
    func openVideoInVLC(_ item: FileItem) {
        // Create SFTP URL for VLC
        // Format: sftp://username:password@hostname:port/path
        let serverInfo = getSftpServerInfo()
        guard let username = serverInfo.username,
              let password = serverInfo.password,
              let hostname = serverInfo.hostname else {
            print("❌ Missing server credentials")
            return
        }
        
        let port = serverInfo.port
        let path = item.url.path
        
        // Properly encode the password for URL
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        
        let vlcUrl = URL(string: "vlc-x-callback://x-callback-url/stream?url=sftp://\(username):\(encodedPassword)@\(hostname):\(port)\(path)")
        
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
    
    func openImageBrowser(_ item: FileItem) {
        if let index = imageUrls.firstIndex(of: item.url) {
            DispatchQueue.main.async {
                self.selectedImageIndex = index
                self.showingImageBrowser = true
            }
        }
    }
    
    func downloadFile(_ item: FileItem) {
        // Cancel any ongoing download
        cancelDownload()
        
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent(item.name)
        
        // Check if file exists and remove it
        try? FileManager.default.removeItem(at: localURL)
        
        DispatchQueue.main.async {
            self.activeDownload = item
            self.downloadDestination = localURL
            self.isDownloading = true
            self.downloadProgress = 0
        }
        
        downloadTask = Task {
            do {
                // Create a progress handler
                let progressHandler: ((Double) -> Void) = { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = progress
                    }
                }
                
                try await self.downloadFileAsync(
                    remotePath: item.url.path,
                    localURL: localURL,
                    progressHandler: progressHandler
                )
                
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.showShareSheet(for: localURL)
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
    
    func downloadFileAsync(remotePath: String, localURL: URL, progressHandler: @escaping (Double) -> Void) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try self.sftpConnection.downloadFile(atPath: remotePath, toLocalURL: localURL) { bytesReceived, totalBytes in
                    let progress = Double(bytesReceived) / Double(totalBytes)
                    progressHandler(progress)
                    
                    // Check for cancellation
                    if Task.isCancelled {
                        throw NSError(domain: "Download", code: -999, userInfo: [NSLocalizedDescriptionKey: "Download cancelled"])
                    }
                }
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
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
    
    private func getSftpServerInfo() -> (username: String?, password: String?, hostname: String?, port: Int) {
        // Get connection details from the existing SFTP connection
        return (sftpConnection.username, sftpConnection.password, sftpConnection.hostname, sftpConnection.port)
    }
}

// MARK: - FileBrowserView
struct FileBrowserView: View {
    @StateObject private var viewModel: FileBrowserViewModel
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showActionSheet = false
    @State private var selectedItem: FileItem?
    
    @Environment(\.dismiss) private var dismiss

    init(currentPath: String, basePath: String, server: ServerEntity?) {
        _viewModel = StateObject(wrappedValue: FileBrowserViewModel(currentPath: currentPath, basePath: basePath, server: server))
    }

    var body: some View {
        VStack {
            #if os(macOS)
            HStack {
                MacCloseButton {
                    dismiss()
                }.padding([.top, .leading], 9).padding(.bottom, 0)
                Spacer()
            }
            #endif
            
            VStack {
                List {
                    // Parent Directory Navigation
                    if viewModel.currentPath != viewModel.basePath {
                        Button(action: { viewModel.navigateUp() }) {
                            HStack {
                                Image(systemName: "arrow.up")
                                Text(".. (Up One Level)")
                            }
                        }
                    }
                    
                    // List Items
                    ForEach(viewModel.items) { item in
                        if item.isDirectory {
                            Button(action: { viewModel.navigateToFolder(item.name) }) {
                                HStack {
                                    Image("folder")
                                        .resizable()
                                        .frame(width: 60, height: 60, alignment: .center)
                                    Text(item.name)
                                }
                            }.buttonStyle(PlainButtonStyle())
                        } else {
                            fileRow(for: item)
                        }
                    }
                }

                // Bottom toolbar with New Folder button
                HStack {
                    Button(action: { showNewFolderPrompt = true }) {
                        Image(systemName: "folder.badge.plus")
                        Text("New Folder")
                    }
                    
                    Spacer()
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Close")
                    }
                }
                .padding(.horizontal, 20)
                #if os(iOS)
                .padding(.top, 15)
                #endif
            }
            .padding(.bottom, 15)
            .navigationTitle(viewModel.currentPath)
            .alert("New Folder", isPresented: $showNewFolderPrompt) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { showNewFolderPrompt = false }
                Button("Create") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.createFolder(name: trimmed)
                    showNewFolderPrompt = false
                    newFolderName = ""
                }
            } message: {
                Text("Enter the name for the new folder.")
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Loading…")
                }
            }
            // Download Progress Overlay
            .overlay(
                downloadOverlay
                    .animation(.easeInOut, value: viewModel.isDownloading)
            )
            // Image browser sheet
            .sheet(isPresented: $viewModel.showingImageBrowser) {
                if let selectedIndex = viewModel.selectedImageIndex {
                    ImageBrowserView(
                        imageUrls: viewModel.imageUrls,
                        initialIndex: selectedIndex,
                        sftpConnection: viewModel
                    )
                }
            }
            // File action sheet
            .confirmationDialog(
                "File Options",
                isPresented: $showActionSheet,
                titleVisibility: .visible
            ) {
                if let item = selectedItem {
                    let fileType = FileType.determine(from: item.url)
                    
                    Button("Open") { viewModel.openFile(item) }
                    
                    if fileType == .video || fileType == .image {
                        Button("Download") { viewModel.downloadFile(item) }
                    }
                    
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }
    
    @ViewBuilder
    private func fileRow(for item: FileItem) -> some View {
        let fileType = FileType.determine(from: item.url)
        
        Button(action: { 
            selectedItem = item
            showActionSheet = true
        }) {
            HStack {
                // Icon based on file type
                switch fileType {
                case .video:
                    Image(systemName: "video")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .padding(.trailing, 10)
                case .image:
                    Image(systemName: "photo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .padding(.trailing, 10)
                case .other:
                    Image("document")
                        .resizable()
                        .frame(width: 60, height: 60, alignment: .center)
                }
                
                VStack(alignment: .leading) {
                    Text(item.name)
                        .fontWeight(.medium)
                    
                    if let size = item.size {
                        Text(formatFileSize(size))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(action: { viewModel.openFile(item) }) {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            
            if fileType == .video || fileType == .image {
                Button(action: { viewModel.downloadFile(item) }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }
    
    private var downloadOverlay: some View {
        Group {
            if viewModel.isDownloading {
                VStack {
                    Text("Downloading \(viewModel.activeDownload?.name ?? "file")...")
                        .font(.headline)
                    
                    ProgressView(value: viewModel.downloadProgress)
                        .progressViewStyle(.linear)
                        .padding()
                    
                    Text("\(Int(viewModel.downloadProgress * 100))%")
                    
                    Button("Cancel") {
                        viewModel.cancelDownload()
                    }
                    .padding()
                }
                .frame(maxWidth: 300)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemBackground))
                        .shadow(radius: 5)
                )
            }
        }
    }
    
    // Helper to format file size
    private func formatFileSize(_ size: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Image Browser View
struct ImageBrowserView: View {
    let imageUrls: [URL]
    @State private var currentIndex: Int
    let sftpConnection: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(imageUrls: [URL], initialIndex: Int, sftpConnection: FileBrowserViewModel) {
        self.imageUrls = imageUrls
        self._currentIndex = State(initialValue: initialIndex)
        self.sftpConnection = sftpConnection
    }
    
    var body: some View {
        #if os(iOS)
        // iOS implementation with TabView for swiping
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                TabView(selection: $currentIndex) {
                    ForEach(0..<imageUrls.count, id: \.self) { index in
                        AsyncSFTPImageView(url: imageUrls[index], sftpConnection: sftpConnection)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .background(Color.black)
                
                // Bottom toolbar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    Text("\(currentIndex + 1) of \(imageUrls.count)")
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        if let currentItem = imageUrls.indices.contains(currentIndex) ? 
                            sftpConnection.items.first(where: { $0.url == imageUrls[currentIndex] }) : nil {
                            sftpConnection.downloadFile(currentItem)
                        }
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.6))
            }
        }
        .statusBar(hidden: true)
        #else
        // macOS implementation
        VStack {
            HStack {
                Button(action: {
                    currentIndex = max(0, currentIndex - 1)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title)
                }
                .disabled(currentIndex <= 0)
                
                Spacer()
                
                Text("\(currentIndex + 1) of \(imageUrls.count)")
                
                Spacer()
                
                Button(action: {
                    currentIndex = min(imageUrls.count - 1, currentIndex + 1)
                }) {
                    Image(systemName: "chevron.right")
                        .font(.title)
                }
                .disabled(currentIndex >= imageUrls.count - 1)
            }
            .padding()
            
            AsyncSFTPImageView(url: imageUrls[currentIndex], sftpConnection: sftpConnection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            HStack {
                Button(action: { dismiss() }) {
                    Text("Close")
                }
                
                Spacer()
                
                Button(action: {
                    if let currentItem = sftpConnection.items.first(where: { $0.url == imageUrls[currentIndex] }) {
                        sftpConnection.downloadFile(currentItem)
                    }
                }) {
                    Text("Download")
                }
            }
            .padding()
        }
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
}

// MARK: - AsyncSFTPImageView
struct AsyncSFTPImageView: View {
    let url: URL
    let sftpConnection: FileBrowserViewModel
    @State private var image: Image?
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .pinchToZoom()
            } else if isLoading {
                ProgressView()
            } else {
                Text("Failed to load image")
                    .foregroundColor(.gray)
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        isLoading = true
        
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                let localURL = tempDir.appendingPathComponent(url.lastPathComponent)
                
                // Check if file exists and remove it
                try? FileManager.default.removeItem(at: localURL)
                
                // Download the file
                try await self.sftpConnection.downloadFileAsync(
                    remotePath: url.path,
                    localURL: localURL,
                    progressHandler: { _ in }
                )
                
                // Load the image
                #if os(iOS)
                if let uiImage = UIImage(contentsOfFile: localURL.path) {
                    let finalImage = Image(uiImage: uiImage)
                    DispatchQueue.main.async {
                        self.image = finalImage
                        self.isLoading = false
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }
                #else
                if let nsImage = NSImage(contentsOfFile: localURL.path) {
                    let finalImage = Image(nsImage: nsImage)
                    DispatchQueue.main.async {
                        self.image = finalImage
                        self.isLoading = false
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }
                #endif
                
                // Clean up after loading
                try? FileManager.default.removeItem(at: localURL)
                
            } catch {
                print("Failed to load image: \(error)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - PinchToZoom
struct PinchToZoom: ViewModifier {
    #if os(iOS)
    @State var scale: CGFloat = 1.0
    @State var lastScale: CGFloat = 1.0
    @State var offset: CGSize = .zero
    @State var lastOffset: CGSize = .zero
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale *= delta
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            if scale < 1.0 {
                                withAnimation {
                                    scale = 1.0
                                }
                            }
                        },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                            if scale < 1.1 {
                                withAnimation {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1.0 {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    } else {
                        scale = 2.0
                    }
                }
            }
    }
    #else
    // macOS doesn't need the same pinch-to-zoom implementation
    func body(content: Content) -> some View {
        content
    }
    #endif
}

extension View {
    func pinchToZoom() -> some View {
        modifier(PinchToZoom())
    }
}

// MARK: - Utility Extensions
#if os(macOS)
struct MacCloseButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
#endif