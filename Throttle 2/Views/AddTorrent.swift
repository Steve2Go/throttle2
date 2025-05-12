import SwiftUI
import CoreData
import UniformTypeIdentifiers
import FilePicker
#if os(macOS)
import AppKit
#endif

// MARK: - AddTorrentView

struct AddTorrentView: View {
    @FetchRequest(
        entity: ServerEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default
    ) var servers: FetchedResults<ServerEntity>
    @ObservedObject var store: Store
    @StateObject var manager: TorrentManager
    @State var presenting: Presenting
    
    @State private var isShowingFilePicker = false
    @State private var downloadDir: String = ""
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var fileBrowser = false
    @AppStorage("deleteOnSuccess") var deleteOnSuccess: Bool = true
    @AppStorage("trigger") var trigger = true
    
    @AppStorage("downloadDir") var defaultDownloadDir: String = ""
    
    var body: some View {
        NavigationStack {
            if store.selection?.sftpRpc == true && TunnelManagerHolder.shared.activeTunnels.count < 1  {
                ProgressView()
                    .onChange(of: defaultDownloadDir) {
                        if store.addPath.isEmpty {
                            downloadDir = defaultDownloadDir
                        }
                    }
            }else{
                VStack(alignment: .leading, spacing: 15) {
                    Text("Add a Download")
                        .font(.title2)
                        .padding(.bottom, 10)
                    
                    // Torrent input section
                    HStack {
                        Text("Torrent")
                        
                        if store.selectedFile == nil {
                            TextField("Magnet Link or File", text: $store.magnetLink)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Button {
                                store.selectedFile = nil
                            } label: {
                                HStack {
                                    Text(store.selectedFile!.lastPathComponent)
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        
                        FilePicker(types: [.item], allowMultiple: false) { urls in
                            print("selected \(urls.count) files")
                            if urls.count > 0{
                                store.selectedFile = urls.first
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                            }
                        }
                    }
                    
                    // Download directory section
                    if let pathServer = store.selection?.pathServer {
                        HStack {
                            Text("Save to:")
                            
                            TextField("Save to", text: $downloadDir)
                                .textFieldStyle(.roundedBorder)
                                .onAppear {
                                    if !store.addPath.isEmpty {
                                        downloadDir = store.addPath
                                    }
                                    else if downloadDir.isEmpty {
                                        downloadDir = defaultDownloadDir
                                    }
                                }
                            
                            // Directory Browse Button (SFTP or local filesystem)
                            if store.selection?.sftpBrowse == true {
                                Button {
                                    fileBrowser = true
                                } label: {
                                    Image(systemName: "folder")
                                }.buttonStyle(.plain)
                            } else if store.selection?.fsBrowse == true {
#if os(macOS)
                                Button("", systemImage: "folder") {
                                    let panel = NSOpenPanel()
                                    panel.allowsMultipleSelection = false
                                    panel.allowsOtherFileTypes = false
                                    panel.canChooseDirectories = true
                                    
                                    // Set the initial directory to the current downloadDir
                                    // Since downloadDir is not an optional (it's a String), we don't need if let here
                                    if let serverPath = ServerManager.shared.selectedServer?.pathServer,
                                       let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                        
                                        // No need for optional binding with downloadDir if it's already a String
                                        let localPath = downloadDir.replacingOccurrences(of: serverPath, with: filesystemPath)
                                        
                                        // Create URL with file:// prefix if needed
                                        let directoryURLString = localPath.hasPrefix("file://") ?
                                        localPath :
                                        "file://" + localPath
                                        
                                        if let directoryURL = URL(string: directoryURLString) {
                                            panel.directoryURL = directoryURL
                                        }
                                    }
                                    
                                    if panel.runModal() == .OK,
                                       let fpath = panel.url,
                                       let serverPath = ServerManager.shared.selectedServer?.pathServer,
                                       let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                        
                                        // Convert from filesystem path back to server path
                                        let movepath = fpath.absoluteString.replacingOccurrences(of: "file://" + filesystemPath, with: serverPath)
                                        downloadDir = movepath
                                    }
                                }.labelsHidden()
#endif
                            }
                        }
                    }
                    
                    // Server selection
                    HStack {
#if os(iOS)
                        Text("Server: ")
#endif
                        Picker("Server", selection: $store.selection) {
                            ForEach(servers) { server in
                                HStack{
                                    Text(server.name ?? "Unknown")
                                    Image(systemName: "externaldrive.badge.wifi")
                                }.tag(server as ServerEntity?)
                            }
                        }
                        .onChange(of: defaultDownloadDir) {
                            if store.addPath.isEmpty {
                                downloadDir = defaultDownloadDir
                            }
                        }
                        
                        //                    .onChange(of: trigger) {
                        //                        Task {
                        //                            await updateDownloadDirectory()
                        //                        }
                        //                    }
                        .pickerStyle(MenuPickerStyle())
                    }
                    if store.selectedFile != nil {
                        Toggle("Delete Torrent File", isOn: $deleteOnSuccess)
#if os(iOS)
                            .toggleStyle(CheckboxToggleStyle())
#endif
                    }
                    // Action buttons
                    HStack {
                        
                        Spacer()
                        Button("Cancel") {
                            presenting.activeSheet = nil
                        }
#if os(iOS)
                        Spacer()
#endif
                        Button("Add") {
                            Task { @MainActor in
                                await addTorrent()
                            }
                        }
                        .disabled((store.magnetLink.isEmpty && store.selectedFile == nil) || isLoading)
                    }
                    
                    .padding(.top, 10)
                    
                    
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .padding(.top, 5)
                    }
                }
                .padding()
                .frame(minWidth: 400, maxWidth: 600, minHeight: 300)
            }
        }
        
        .sheet(isPresented: $fileBrowser) {
            #if os(iOS)
            NavigationView {
                FileBrowserView(
                    currentPath: downloadDir,
                    basePath: store.selection?.pathServer ?? "",
                    server: store.selection,
                    onFolderSelected: { folderPath in
                        downloadDir = folderPath
                        fileBrowser = false
                    }
                ).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Cancel") {
                                fileBrowser = false
                            }
                        }
                    }
            }
            .presentationDetents([.large])
            #else
            FileBrowserView(
                currentPath: downloadDir,
                basePath: store.selection?.pathServer ?? "",
                server: store.selection,
                onFolderSelected: { folderPath in
                    downloadDir = folderPath
                    fileBrowser = false
                }
            ).frame(width: 600, height: 600)
            #endif
        }
        
        .alert("Error", isPresented: $showError, presenting: error) { _ in
            Button("OK") { }
        } message: { error in
            Text(error.localizedDescription)
        }
    }
    
    
    // MARK: - Helper Functions
    
    private func updateDownloadDirectory() async {
        if !store.addPath.isEmpty {
            downloadDir = store.addPath
        } else{
            do {
                try await Task.sleep(for: .milliseconds(500))
                if let directory = try? await manager.getDownloadDirectory() {
                    await MainActor.run {
                        downloadDir = directory
                    }
                }
            } catch {
                // Handle sleep error if needed
            }
        }
    }
    
    @MainActor
    func addTorrent() async {
        isLoading = true
        
        do {
            let file = store.selectedFile
            let dir = downloadDir.isEmpty ? store.selection?.pathServer : downloadDir
            
            var magnetLinkParam: String? = nil
            if !store.magnetLink.isEmpty {
                magnetLinkParam = store.magnetLink
            }
            
            let response = try await manager.addTorrent(
                fileURL: file,
                magnetLink: magnetLinkParam,
                downloadDir: dir
            )
            
            if response.result != "success" {
                throw NSError(domain: "", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Failed to add torrent"])
            } else {
                
                if deleteOnSuccess {
                    do {
                        let _ = store.selectedFile!.startAccessingSecurityScopedResource()
                        try FileManager.default.removeItem(at: file!)
                        // File deleted successfully
                        
                    } catch {
                        print("Error deleting file: \(error)")
                    }
                }
                presenting.activeSheet = nil
                isLoading = false
                ToastManager.shared.show(message: "Download Added", icon: "icloud.and.arrow.down", color: Color.green)
            }
            
        } catch {
            isLoading = false
            self.error = error
            showError = true
        }
    }
}
