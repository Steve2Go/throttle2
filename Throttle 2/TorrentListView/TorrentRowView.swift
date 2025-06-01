//
//  TorrentRowView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//


import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TorrentRowView: View {
    @ObservedObject var manager: TorrentManager
    @ObservedObject var store: Store
    let torrent: Torrent
    let onDelete: () -> Void
    let onMove: () -> Void
    let onRename: () -> Void
    @State var showDetailsSheet = false
    @State var isStarred = false
    @AppStorage("showThumbs") var showThumbs: Bool = false
    var selecting: Bool
    @Binding var selected: [Int]
    @AppStorage("primaryFile") var primaryFiles: Bool = false
    @AppStorage("thumbsLocal") var thumbsLocal = false
    #if os(iOS)
    var isiPad: Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }
    #endif
    var body: some View {
        HStack {
            if selecting {
                Toggle("", isOn: Binding(
                    get: { selected.contains(torrent.id) },
                    set: { newValue in
                        if newValue {
                            if !selected.contains(torrent.id) {
                                selected.append(torrent.id)
                            }
                        } else {
                            selected.removeAll(where: { $0 == torrent.id })
                        }
                    }
                ))
                
                .toggleStyle(CheckboxToggleStyle())
                .labelsHidden()
                .padding(.trailing)
            }
            if showThumbs && !selecting && torrent.hashString != nil && torrent.progress == 1 {
                let torrentFiles = manager.getTorrentFiles(forHash: torrent.hashString!)
       
                if let mediaFile = findFirstMediaFile(from: torrentFiles) {
                    if store.selection != nil {
                        
#if os(iOS)
                        let mediaPath = get_media_path(file: mediaFile, torrent:torrent, server: store.selection!)
                        
                        //PathThumbnailView(path: mediaPath, server: store.selection!, fromRow: torrent.files.count > 1 ? true : nil)
                        RemotePathThumbnailView(path: mediaPath, server: store.selection!)
#else
                        if store.selection?.sftpBrowse == true {
                            if thumbsLocal {
                                let mediaPath = get_media_path_local(file: mediaFile, torrent:torrent, server: store.selection!)
                                PathThumbnailViewMacOS(path: mediaPath)
                            } else {
                                let mediaPath = get_media_path(file: mediaFile, torrent:torrent, server: store.selection!)
                                RemotePathThumbnailView(path: mediaPath, server: store.selection!)
                            }
                        } else if store.selection?.fsBrowse == true {
                            if let downloadDir = torrent.dynamicFields["downloadDir"]?.value as? String,
                               let serverPath = store.selection?.pathServer,
                               let filesystemPath = store.selection?.pathFilesystem,
                               let decodedName = mediaFile.name.removingPercentEncoding {
                                
                                let pathSuffix = downloadDir.hasPrefix(serverPath) ?
                                String(downloadDir.dropFirst(serverPath.count)) :
                                downloadDir
                                
                                let mediaPath = filesystemPath + String(pathSuffix) + "/" + decodedName
                                
                                PathThumbnailViewMacOS(path: mediaPath)
                            } else {
                                // Provide a fallback view for when any of the optionals are nil
                                Text("Unable to display thumbnail")
                            }
                        }
                        
                        
#endif
                    }
                    } else {
                        Image( "folder")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .padding(.trailing, 5)
                            .foregroundColor(.secondary)
                        
                    }
                

            } else if showThumbs && !selecting {
                Image( "folder-downloading")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .padding(.trailing, 5)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text(torrent.name?.truncatedMiddle() ?? "Loading...")
                   
                HStack {
                   
                        switch torrent.status {
                        case 0:
                            ProgressView(value: torrent.progress)
                                .tint(.red)
                        case 2:
                            ProgressView(value: torrent.progress)
                                .tint(.yellow)
                        case 4:
                            ProgressView(value: torrent.progress)
                                .tint(.blue)
                        case 6:
                            ProgressView(value: torrent.progress)
                                .tint(.green)
//                        case 6:
//                            ProgressView(value: torrent.progress)
//                                .tint(.orange)
                        default:
                            ProgressView(value: torrent.progress)
                                .tint(.gray)
                        }
             // folder icon
            if (store.selection?.sftpBrowse == true || store.selection?.fsBrowse == true) && torrent.dynamicFields["downloadDir"] != nil {
                        if ((store.selection?.sftpBrowse) != nil){
                            if torrent.files.count > 1 || torrent.percentDone == 1 {
                                Button {
                                    if var torrentU = torrent.dynamicFields["downloadDir"]?.value as? String {
                                        
#if os(iOS)
                                        store.fileURL = torrentU
                                        store.fileBrowserName = torrent.name!
                                        if isiPad{
                                            store.FileBrowse = true
                                        } else{
                                            store.FileBrowseCover = true
                                        }
#else
                                        //macos, mounted via fuse
                                        if store.selection?.sftpBrowse == true {
                                            let pathName = get_fuse_path(torrent: torrent, downloadDir: torrentU)
                                            openInFinder(url: pathName)
                                        }
                                        else if store.selection?.pathServer != nil && store.selection?.pathFilesystem != nil {
                                            let pathName = URL(string :"file://" + torrentU.replacingOccurrences(of: (store.selection?.pathServer!)!, with: store.selection?.pathFilesystem! ?? "/") + "/" + torrent.name!)
                                            if pathName != nil{
                                                print(pathName!.absoluteString)
                                                openInFinder(url: pathName!)
                                            }
                                        }
                                        
#endif
                                    }
                                    
                                    
                                } label: {
                                    Image(systemName: "internaldrive")
                                        .foregroundStyle(.gray)
                                }
                                .buttonStyle(.plain)
                            } else{
                                Image(systemName: "externaldrive.badge.timemachine")
                                    .foregroundStyle(.gray)
                            }
                        }
                    }
                    Button {
                        Task {
                            isStarred.toggle()
                            try? await manager.toggleStar(for: torrent)
                            ToastManager.shared.show(message: manager.isStarred(torrent) ? "Removing Star" : "Starring", icon: manager.isStarred(torrent) ? "star.slash.fill" : "star.fill", color: Color.yellow)
                        }
                    } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .foregroundStyle(isStarred ? .yellow : .gray)
                    }
                    .buttonStyle(.plain)
                    .onAppear{
                        isStarred = manager.isStarred(torrent)
                    }
                    .onChange(of: manager.isStarred(torrent) ){
                        isStarred = manager.isStarred(torrent)
                    }
                }
                
                if let downloaded = torrent.downloadedEver,
                   let total = torrent.totalSize {
                    Text("Downloaded: \(formatBytes(downloaded)) / \(formatBytes(total)) (\(Int(torrent.progress * 100))%)")
                        .font(.caption)
                }
                
                if let error = torrent.error, error != 0 {
                    Text(torrent.errorString ?? "Unknown error")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                Divider()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 15)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Text("Delete")
                Image( systemName: "trash")
            }
            Button {
                
                Task {
                    ToastManager.shared.show(message: "Verifying" ,icon: "externaldrive.badge.questionmark", color: Color.yellow)
                    _ = try await manager.verifyTorrents(ids: [torrent.id])
                }
            } label: {
                Text("Verify")
                Image(systemName: "externaldrive.badge.questionmark")
            }
            Button {
                Task {
                    ToastManager.shared.show(message: "Announcing" ,icon: "megaphone.fill", color: Color.blue)
                    _ = try await manager.reannounceTorrents(ids: [torrent.id])
                }
            } label: {
                Text("Announce")
                Image(systemName: "megaphone")
            }
            if torrent.status == 0 {
                Button {
                    Task {
                        ToastManager.shared.show(message: "Starting" ,icon: "play", color: Color.green)
                        _ = try await manager.startTorrents(ids: [torrent.id])
                    }
                } label: {
                    Text("Start")
                    Image(systemName: "play")
                }
            }else {
                Button {
                    Task {
                        ToastManager.shared.show(message: "Stopping" ,icon: "stop", color: Color.red)
                        _ = try await manager.stopTorrents(ids: [torrent.id])
                    }
                } label: {
                    Text("Stop")
                    Image(systemName: "stop")
                }
            }
            
            Button {
                onMove()
            } label: {
                Text("Move")
                Image(systemName: "rectangle.portrait.and.arrow.forward")
            }
            
            Button {
                onRename()
            } label: {
                Text("Rename")
                Image(systemName: "dots.and.line.vertical.and.cursorarrow.rectangle")
            }
        }.onTapGesture {
            
            store.selectedTorrentId = torrent.id
            #if os(iOS)
                showDetailsSheet = true

            #endif
        }
#if os(iOS)
.sheet(isPresented: $showDetailsSheet) {
    NavigationStack {
        DetailsView(store: store, manager: manager)
    }
}
#endif
    }
    func findFirstMediaFile(from files: [TorrentFile]) -> TorrentFile? {
        
        //print("Number of files: \(files.count)")
        // Common image extensions
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp"]
        
        // Common video extensions
        let videoExtensions = ["mp4", "mov", "avi", "wmv", "flv", "mkv", "m4v", "webm"]
        
        // First try to find a video
        if let firstImage = files.first(where: { file in
            let ext = file.name.components(separatedBy: ".").last?.lowercased() ?? ""
            return (videoExtensions.contains(ext) && file.progress == 1)
        }) {
            return firstImage
        }
        
        // If no image found, try to find a video
        return files.first(where: { file in
            let ext = file.name.components(separatedBy: ".").last?.lowercased() ?? ""
            return (imageExtensions.contains(ext) && file.progress == 1)
        })
    }
    
   // #if os(iOS)
    func get_media_path(file: TorrentFile, torrent: Torrent,  server: ServerEntity) -> String {
        let name = file.name
        if let path = torrent.dynamicFields["downloadDir"] {
            //let baseDir = server.pathServer!
            let returnvalue = "\(path.value)/\(name)".replacingOccurrences(of: "//", with: "/")
            //print("returning path: " + returnvalue)
            return returnvalue
        }
        return ""
    }
//#/endif
    
    
    #if os(macOS)
    
    func openInFinder(url: URL) {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                // It's a directory, open the folder
                NSWorkspace.shared.open(url)
            } else {
                // It's a file, select it in Finder
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else {
            // Handle error - path doesn't exist
            print("Path doesn't exist: \(url.path)")
        }
    }
    
    
    func get_media_path_local(file: TorrentFile, torrent: Torrent,  server: ServerEntity) -> String {
        let name = file.name
        let baseDir = server.pathServer!
        if var path = torrent.dynamicFields["downloadDir"]?.value as? String {
            if path.hasPrefix(baseDir) {
                path = String(path.dropFirst(baseDir.count))
                if path.hasPrefix("/") { path = String(path.dropFirst()) }
                let mountBase = ServerMountManager.shared.getMountPath(for: store.selection!).absoluteString.dropLast().replacingOccurrences(of: "file://", with: "")
                let returnvalue = "\(mountBase)/\(path)/\(name)"
                print("returning path: " + returnvalue)
                return returnvalue
            }
        }
        return ""
    }
    
    func get_mapped_path(file: TorrentFile, torrent: Torrent,  server: ServerEntity) -> String {
        let name = file.name
        let baseDir = server.pathServer!
        if var path = torrent.dynamicFields["downloadDir"]?.value as? String {
            if path.hasPrefix(baseDir) {
                path = String(path.dropFirst(baseDir.count))
                if path.hasPrefix("/") { path = String(path.dropFirst()) }
                let mountBase = ServerMountManager.shared.getMountPath(for: store.selection!).absoluteString.dropLast().replacingOccurrences(of: "file://", with: "")
                let returnvalue = "\(mountBase)/\(path)/\(name)"
                print("returning path: " + returnvalue)
                return returnvalue
            }
        }
        return ""
    }
    
#if os(macOS)
func get_fuse_path(torrent: Torrent, downloadDir: String) -> URL {
    let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
    let mountKey = ServerMountUtilities.getMountKey(for: store.selection!)
    let openBasePath = tmpURL.appendingPathComponent("com.srgim.Throttle-2.sftp")
                            .appendingPathComponent(mountKey!)
    // Clean up the download directory path
    var cleanPath = downloadDir
    if let baseDir = store.selection?.pathServer {
        // Remove baseDir if it exists at the start of downloadDir
        if cleanPath.hasPrefix(baseDir) {
            cleanPath = String(cleanPath.dropFirst(baseDir.count))
        }
    }
    // Remove any leading slashes
    cleanPath = cleanPath.trimmingCharacters(in: .init(charactersIn: "/"))
    // Decode the torrent name
    let decodedName = torrent.name?.removingPercentEncoding ?? torrent.name ?? ""
    // Build the final path
    let finalPath = openBasePath
        .appendingPathComponent(cleanPath)
        .appendingPathComponent(decodedName)
    return finalPath
}
#endif
#endif
}
extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
