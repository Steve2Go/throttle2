import SwiftUI
#if os(macOS)
import AppKit
    #endif
import FilePicker
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MutateTorrentView: View {
    @ObservedObject var torrentManager: TorrentManager
    let torrent: Torrent
    @Binding var showMoveSheet: Bool
    @Binding var showRenameAlert: Bool
    @State private var moveLocation = ""
    @State private var showFileBrowser = false
    @State var server: ServerEntity?

    var content: some View {
        #if os(iOS)
        NavigationView {
            Form {
                Section("New Location") {
                    HStack {
                        TextField("Enter new location", text: $moveLocation)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        if ServerManager.shared.selectedServer?.sftpBrowse == true {
                            Button {
                                showFileBrowser = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Move Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        Task {
                            do {
                                if try await torrentManager.moveTorrents(
                                    ids: [torrent.id],
                                    to: moveLocation,
                                    move: true
                                ) {
                                    showMoveSheet = false
                                }
                            } catch {
                                print("Error moving torrent:", error)
                            }
                        }
                    }.disabled(moveLocation.isEmpty)
                }
            }
        }
        #else
        VStack(spacing: 20) {
            Text("Move Torrent").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("New Location:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("", text: $moveLocation)
                        .textFieldStyle(.roundedBorder)
                    
                    if ServerManager.shared.selectedServer?.fsBrowse == true {
                        
                        Button("", systemImage: "folder") {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.allowsOtherFileTypes = false
                            panel.canChooseDirectories = true
                            
                            // Set initial directory to current moveLocation
                            if !moveLocation.isEmpty,
                               let serverPath = ServerManager.shared.selectedServer?.pathServer,
                               let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem {
                                
                                // Convert server path to filesystem path for the panel
                                let localPath = moveLocation.replacingOccurrences(of: serverPath, with: filesystemPath)
                                
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
                               let filesystemPath = ServerManager.shared.selectedServer?.pathFilesystem,
                               let serverPath = ServerManager.shared.selectedServer?.pathServer {
                                
                                // Convert from filesystem path to server path
                                let movepath = fpath.absoluteString.replacingOccurrences(
                                    of: "file://" + filesystemPath,
                                    with: serverPath
                                )
                                
                                moveLocation = movepath
                            }
                        }.labelsHidden()
//                        FilePicker(types: [.item], allowMultiple: false) { urls in
//                                        print("selected \(urls.count) files")
//                            if urls.count > 0{
//                                moveLocation = urls.first?.absoluteString ?? moveLocation
//                            }
//                                    } label: {
//                                        HStack {
//                                            Image(systemName: "folder")
//                                        }
//                                    }
                    } else if ServerManager.shared.selectedServer?.sftpBrowse == true {
                        Button { showFileBrowser = true } label: {
                            Image(systemName: "folder")
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { showMoveSheet = false }

                Button("Move") {
                    Task {
                        do {
                            try await torrentManager.moveTorrents(
                                ids: [torrent.id],
                                to: moveLocation,
                                move: true
                            )
                            showMoveSheet = false
                        } catch {
                            print("Error moving torrent:", error)
                        }
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(moveLocation.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
        #endif
    }

//    #if os(macOS)
//    func openFilePicker() {
//        let openPanel = NSOpenPanel()
//        openPanel.directoryURL = URL(string: "files://" + serverPath_to_local(moveLocation))
//        openPanel.allowsMultipleSelection = false
//        openPanel.canChooseDirectories = true
//        openPanel.canChooseFiles = false
//
//        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
//            moveLocation = local_to_serverPath(selectedURL.absoluteString.removingPercentEncoding ?? "")
//        }
//    }
//    #endif

    var body: some View {
        content
            .sheet(isPresented: $showFileBrowser) {
#if os(iOS)
NavigationView {
    FileBrowserView(
        currentPath: moveLocation,
        basePath: ServerManager.shared.selectedServer?.pathFilesystem ?? "",
        server: ServerManager.shared.selectedServer,
        onFolderSelected: { folderPath in
            moveLocation = folderPath
            showFileBrowser = false
        }
    ).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") {
                    showFileBrowser = false
                }
            }
        }
}
.presentationDetents([.large])
#else
FileBrowserView(
    currentPath: moveLocation,
    basePath: ServerManager.shared.selectedServer?.pathFilesystem ?? "",
    server: ServerManager.shared.selectedServer,
    onFolderSelected: { folderPath in
        moveLocation = folderPath
        showFileBrowser = false
    }
).frame(width: 600, height: 600)
#endif
            }
            .onAppear {
                Task {
                    if let downloadDir = try? await torrentManager.getDownloadDirectory() {
                        await MainActor.run {
                            moveLocation = downloadDir
                        }
                    }
                }
            }
    }
}
struct MutateTorrent {
    @ObservedObject var torrentManager: TorrentManager
    let torrent: Torrent
    @Binding var showMoveSheet: Bool
    @Binding var showRenameAlert: Bool
    @State var newPath = ""
    var server: ServerEntity?
    
    func move() {
        showMoveSheet = true
    }
    
    func rename() {
        if let name = torrent.name {
            newPath = name
            showRenameAlert = true
        }
    }
    
    var moveSheet: some View {
        MutateTorrentView(
            torrentManager: torrentManager,
            torrent: torrent,
            showMoveSheet: $showMoveSheet,
            showRenameAlert: $showRenameAlert
        )
    }
}
