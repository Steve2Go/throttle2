#if os(iOS)
import SwiftUI
import Combine
import Citadel
import KeychainAccess
import AVKit
import SimpleToast

// MARK: - FileBrowserView
struct SFTPFileBrowserView: View {
    @StateObject var viewModel: SFTPFileBrowserViewModel
    @State var showNewFolderPrompt = false
    @State var newFolderName = ""
    @State var showActionSheet = false
    @State var selectedItem: FileItem?
    @ObservedObject var server: ServerEntity
    @State var store: Store
    @AppStorage("preferVLC") var preferVLC = false
    @AppStorage("sftpViewMode") private var viewMode: String = "list"
    @AppStorage("sftpSortOrder") private var sftpSortOrder: String = "date"
    @AppStorage("sftpFoldersFirst") var sftpFoldersFirst: Bool = true
    @AppStorage("searchQuery") var searchQuery: String = ""
    @State var currentPath: String
    @State private var showRenamePrompt = false
    @State private var itemToRename: FileItem?
    @State private var newItemName = ""
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: FileItem?
    @State private var showUploadView = false
    @State var showingFFmpegPlayer = false
    @State var showAirplay = false
    
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
        @State private var videoPlayerConfiguration: VideoPlayerConfiguration?
        @State private var showingVideoPlayer = false
    
    
    
    
    private var uploadManager: SFTPUploadManager {
            SFTPUploadManager(uploadHandler: viewModel)
        }
    
    init(currentPath: String, basePath: String, server: ServerEntity?, store: Store) {
            self.server = server!
            self.currentPath = currentPath
            self.store = store
            _viewModel = StateObject(wrappedValue: SFTPFileBrowserViewModel(currentPath: currentPath, basePath: basePath, server: server, onDismiss: nil))
        }
    
    
    
    var body: some View {
        VStack {
            NavigationStack {
                Group {
                    if viewMode == "list" {
                        listView
                    } else {
                        gridView
                    }
                }
                // search bar
                .searchable(text: $searchQuery, prompt: "Search")
                .onChange(of: searchQuery) {
                    viewModel.fetchItems()
                }
                .onChange(of : currentPath){
//                    Task {
//                        await ThumbnailManager.shared.cleanup()
//                    }
                    searchQuery = ""
                }
                .onAppear {
                    // Set the dismiss closure for the viewModel
                    viewModel.onDismiss = {
                        dismiss()
                    }
                }
                .onDisappear {
                    searchQuery = ""
                    Task{
                        await viewModel.cleanup()
                    }
                }
//                //tools
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack {
                            Button(action: {
//                             clearThumbnailOperations()
                                dismiss()
                            }) {
                                Text("Close")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(action: {
                                viewMode = viewMode == "list" ? "grid" : "list"
                            }) {
                                Text(viewMode == "list" ? "Show as Grid" : "Show as List")
                                Image(systemName: viewMode == "list" ? "square.grid.2x2" : "list.bullet")
                            }
                            Button {
                                sftpSortOrder = "name"
                                viewModel.fetchItems()
                            } label:{
                                Text("Name")
                                if sftpSortOrder == "name" {
                                    Image(systemName: "chevron.down")
                                }
                            }
                            Button {
                                sftpSortOrder = "date"
                                viewModel.fetchItems()
                            } label:{
                                Text("Date")
                                if sftpSortOrder == "date" {
                                    Image(systemName: "chevron.down")
                                }
                            }
                            Divider()
                            Button("Folders First",  systemImage: sftpFoldersFirst  ? "checkmark.circle" : "circle"){
                                sftpFoldersFirst.toggle()
                                viewModel.fetchItems()
                            }
                            Divider()
                            Button(action: { showUploadView = true }) {
                                                    Label("Upload", systemImage: "arrow.up.doc")
                                                }
                            Button("New Folder", systemImage: "folder.badge.plus"){
                                showNewFolderPrompt.toggle()
                            }
                            
                        } label:{
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    
                    // back button, if not at base path
                    if viewModel.currentPath != viewModel.basePath && viewModel.currentPath + "/" != viewModel.basePath {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(action: {
                                viewModel.navigateUp()
                            }) {
                                HStack {
                                    Image(systemName: "chevron.backward")
                                    //Text("Back")
                                    Text(viewModel.upOne == "/" ? "Top Level" : viewModel.upOne.capitalized)
                                }
                            }
                        }
                    }
                }.navigationTitle(NSString( string: viewModel.currentPath ).lastPathComponent.capitalized).navigationBarTitleDisplayMode(.inline)
            }
//            .navigationTitle(viewModel.isInitialPathAFile ?
//                             viewModel.initialFileItem?.name ?? "File" :
//                                viewModel.currentPath)
            .onAppear {
                store.currentSFTPViewModel = viewModel
            }
            .onDisappear {
                // Unregister when view disappears
                if store.currentSFTPViewModel === viewModel {
                    store.currentSFTPViewModel = nil
                }
            }
            .fullScreenCover(isPresented: $viewModel.showingVideoPlayer) {
                
                        if let config = viewModel.videoPlayerConfiguration {
                            VideoPlayerContainerView(configuration: config)
                                .ignoresSafeArea(edges: .all)
                        }
                    }
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
            .sheet(isPresented: $showUploadView) {
                        SFTPUploadView(uploadManager: uploadManager)
                    .presentationDetents([.medium])
                    }
            
      
//            // Rename Alert
            .alert("Rename Item", isPresented: $showRenamePrompt) {
                TextField("New Name", text: $newItemName)
                Button("Cancel", role: .cancel) {
                    showRenamePrompt = false
                    itemToRename = nil
                }
                Button("Rename") {
                    let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let item = itemToRename else { return }
                    viewModel.requestSent()
                    viewModel.renameItem(item, to: trimmed)
                    showRenamePrompt = false
                    itemToRename = nil
                    newItemName = ""
                    viewModel.fetchItems()
                }
            } message: {
                Text("Enter a new name for this item.")
            }
            .alert("Downlad VLC?", isPresented: $viewModel.showVLCDownload) {
                Button("Not Now", role: .cancel) {
                    viewModel.showVLCDownload = false
                }
                Button("Download") {
                    openURL(URL(string: "https://apps.apple.com/au/app/vlc-media-player/id650377962")!)
                    viewModel.showVLCDownload = false
                }
                
            } message: {
                Text("VLC is required to stream videos. Would you like to download it now?\n\nEnsure you open it at least once and accept the prompts before coming back here.")
            }
            
         
            // Delete Confirmation
            .alert("Delete Item", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    
                    showDeleteConfirmation = false
                    itemToDelete = nil
                    viewModel.requestSent()
                }
                Button("Delete", role: .destructive) {
                    if let item = itemToDelete {
                        viewModel.deleteItem(item)
                    }
                    showDeleteConfirmation = false
                    itemToDelete = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        viewModel.fetchItems()
                    }
                    
                }
            } message: {
                if let item = itemToDelete {
                    Text("Are you sure you want to delete \"\(item.name)\"? This action cannot be undone.")
                } else {
                    Text("Are you sure you want to delete this item? This action cannot be undone.")
                }
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
            .fullScreenCover(isPresented: $viewModel.showingImageBrowser) {
                if let selectedIndex = viewModel.selectedImageIndex {
                    ImageBrowserViewWrapper(
                        imageUrls: viewModel.imageUrls,
                        initialIndex: selectedIndex,
                        sftpConnection: viewModel
                    ).ignoresSafeArea()
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
                    
                    if fileType == .image {
                        //Button("Open") { viewModel.openFile(item: item, server: server) }
                    }
                    
                    if fileType == .video {
                        Button("Play") { self.viewModel.openFile(item: item, server: server)}
                        //Button("Play in VLC") { viewModel.openVideoInVLC(item: item, server: server) }
//                        Button("Play Streaming") {
//                            Task {
//                                await viewModel.openVideoWithHTTPStreaming(item: item, server: server)
//                            }
//                        }
                    }
                    
                    
                    Button("Download") { viewModel.downloadFile(item) }
                    
                    Button("Cancel", role: .cancel) {}
                }
            }
            .sheet(isPresented: $viewModel.showingMusicPlayer) {
                VLCMusicPlayer(urls: viewModel.musicPlayerPlaylist, startIndex: viewModel.musicPlayerStartIndex)
                    .ignoresSafeArea(edges: .all)
                    .onDisappear {
                        viewModel.showingMusicPlayer = false
                    }
            }
        }
    }
    
    
    // List View Implementation
    private var listView: some View {
        ScrollView {
            LazyVStack {
                ForEach(viewModel.items) { item in
                    if viewModel.isInitialPathAFile {
                        fileRow(for: item)
                    } else if item.isDirectory {
                        Button(action: {
                            viewModel.navigateToFolder(item.name)
                            currentPath = item.name
                        }) {
                            HStack {
                                Image("folder")
                                    .resizable()
                                    .frame(width: 60, height: 60, alignment: .center)
                                Text(item.name)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(PlainButtonStyle())
                            .contextMenu(menuItems: {
                                // Add the new options
                                Button(action: {
                                    itemToRename = item
                                    newItemName = item.name
                                    showRenamePrompt = true
                                }) {
                                    Label("Rename", systemImage: "pencil")
                                }
                                
                                Button(role: .destructive, action: {
                                    itemToDelete = item
                                    showDeleteConfirmation = true
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            })
                    } else {
                        fileRow(for: item)
                    }
                    Divider()
                }
            }
            .padding(.leading, 20).padding(.trailing, 20)
        }
    }
    
    // Grid View Implementation
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)
            ], spacing: 16) {
                ForEach(viewModel.items) { item in
                    if viewModel.isInitialPathAFile {
                        fileGridItem(for: item)
                    } else if item.isDirectory {
                        Button(action: {
                            viewModel.navigateToFolder(item.name)
                            currentPath = item.name
                            
                        }) {
                            VStack {
                                Image("folder")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 80, height: 80)
                                
                                Text(item.name)
                                    .lineLimit(2)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(height: 120)
                            .padding(0)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu(menuItems: {
                            // Add the new options
                            Button(action: {
                                itemToRename = item
                                newItemName = item.name
                                showRenamePrompt = true
                            }) {
                                Label("Rename", systemImage: "pencil")
                            }
                            
                            Button(role: .destructive, action: {
                                itemToDelete = item
                                showDeleteConfirmation = true
                            }) {
                                Label("Delete", systemImage: "trash")
                            }
                        })
                    } else {
                        fileGridItem(for: item)
                    }
                }
            }
            .padding()
        }
    }
    
    // File Grid Item
    @ViewBuilder
    private func fileGridItem(for item: FileItem) -> some View {
        let fileType = FileType.determine(from: item.url)
        
        VStack {
            // Thumbnail - reuse FileRowThumbnail for consistency
            FileRowThumbnail(item: item, server: server)
                .frame(width: 80, height: 80)
                .padding(.bottom, 4)
            
            // File name
            Text(item.name)
                .lineLimit(2)
                .font(.caption)
                .multilineTextAlignment(.center)
            
            // File size
            if let size = item.size {
                Text(formatFileSize(size))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 140)
        .padding(8)
        .onTapGesture {
            if fileType == .video || fileType == .image || fileType == .audio {
                viewModel.openFile(item: item, server: server)
            }  else {
                selectedItem = item
                showActionSheet = true
            }
        }
        .contextMenu {
            if fileType == .image || fileType == .video || fileType == .audio {
                Button(action: {
                    viewModel.openFile(item: item, server: server)
                }) {
                    Label("Open", systemImage: "play")
                }
            }
            
            
            Button(action: { viewModel.downloadFile(item) }) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            Button(action: {
                itemToRename = item
                newItemName = item.name
                showRenamePrompt = true
            }) {
                Label("Rename", systemImage: "pencil")
            }
            
            Button(role: .destructive, action: {
                itemToDelete = item
                showDeleteConfirmation = true
            }) {
                Label("Delete", systemImage: "trash")
            }
            
        }
    }
    
    @ViewBuilder
    private func fileRow(for item: FileItem) -> some View {
        let fileType = FileType.determine(from: item.url)
        
        HStack {
            FileRowThumbnail(item: item, server: server)
            
            VStack(alignment: .leading) {
                Text(item.name)
                    .fontWeight(.medium)
                
                if let size = item.size {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }.onTapGesture {
                if fileType == .image || fileType == .video || fileType == .audio {
                    viewModel.openFile(item: item, server: server)
                } else {
                    selectedItem = item
                    showActionSheet = true
                }
            }
            
            Spacer()
            Button(action: {
                selectedItem = item
                showActionSheet = true
            }) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.secondary)
            }.buttonStyle(PlainButtonStyle())
            
        }.contentShape(Rectangle())
            .contextMenu {
                if fileType == .video || fileType == .image || fileType == .audio {
                    Button(action: {
                        self.viewModel.openFile(item: item, server: server)
                    }) {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                }
                
                Button(action: { viewModel.downloadFile(item) }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                
                
                Button(action: {
                    itemToRename = item
                    newItemName = item.name
                    showRenamePrompt = true
                }) {
                    Label("Rename", systemImage: "pencil")
                }
                
                Button(role: .destructive, action: {
                    itemToDelete = item
                    showDeleteConfirmation = true
                }) {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
    
    var downloadOverlay: some View {
        Group {
            if viewModel.isDownloading {
                VStack {
                    Text("Downloading \(viewModel.activeDownload?.name ?? "file")...")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    ProgressView(value: viewModel.downloadProgress)
                        .progressViewStyle(.linear)
                        .padding()
                    
                    Text("\(Int(viewModel.downloadProgress * 100))%")
                        .foregroundColor(.primary)
                    
                    Button("Cancel") {
                        viewModel.cancelDownload()
                    }
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .frame(maxWidth: 300)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemBackground))
                        .shadow(radius: 5)
                        .opacity(0.95)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
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




struct VideoPlayerContainerView: UIViewControllerRepresentable {
    let configuration: VideoPlayerConfiguration
    
    func makeUIViewController(context: Context) -> videoViewController {
        return videoViewController(configuration: configuration)
    }
    
    func updateUIViewController(_ uiViewController: videoViewController, context: Context) {
        // No updates needed
    }
}

extension FileItem {
    var safeFileName: String {
        // Return the name directly from the file item, not from the URL
        return self.name
    }
    
}
#endif
