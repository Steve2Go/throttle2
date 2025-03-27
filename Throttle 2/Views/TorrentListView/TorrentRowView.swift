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
    @AppStorage("showThumbs") var showThumbs: Bool = false
    var selecting: Bool
    @Binding var selected: [Int]
    @AppStorage("primaryFile") var primaryFiles: Bool = false
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
#if os(iOS)
                    let mediaPath = get_media_path(file: mediaFile, torrent:torrent, server: store.selection!)
                    
                    PathThumbnailView(path: mediaPath, server: store.selection!, fromRow: torrent.files.count > 1 ? true : nil)
#else
                    if store.selection?.sftpBrowse == true {
                        let mediaPath = get_media_path(file: mediaFile, torrent:torrent, server: store.selection!)
                        
                        PathThumbnailViewMacOS(path: mediaPath)
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
                } else {
                    Image( "folder")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                        .padding(.trailing, 0)
                        .foregroundColor(.secondary)
      
                }
                

            } else if showThumbs && !selecting {
                Image( "folder-downloading")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .padding(.trailing, 0)
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
                        
                        
                        
                        
                    
                    
                        
                   // }
             
            if (store.selection?.sftpBrowse == true || store.selection?.fsBrowse == true) && torrent.dynamicFields["downloadDir"] != nil {
                        if ((store.selection?.sftpBrowse) != nil){
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
                                        //NSWorkspace.shared.activateFileViewerSelecting([pathName])
                                        openInFinder(url: pathName)
                                    }
                                    else if store.selection?.pathServer != nil && store.selection?.pathFilesystem != nil {
                                        let pathName = URL(string :"file://" + torrentU.replacingOccurrences(of: (store.selection?.pathServer!)!, with: store.selection?.pathFilesystem! ?? "/") + "/" + torrent.name!)
                                        if pathName != nil{
                                            print(pathName!.absoluteString)
                                            //NSWorkspace.shared.activateFileViewerSelecting([pathName!])
                                            openInFinder(url: pathName!)
                                        }
                                    }
                                        
                                    
                                    // macos, traditional mapping, to come
                                    
                                    
                                    
#endif
                                }
                                
                            } label: {
                                Image(systemName: "folder")
                                    .foregroundStyle(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        Task {
                            try? await manager.toggleStar(for: torrent)
                        }
                    } label: {
                        Image(systemName: manager.isStarred(torrent) ? "star.fill" : "star")
                            .foregroundStyle(manager.isStarred(torrent) ? .yellow : .gray)
                    }
                    .buttonStyle(.plain)
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
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task {
                    try await manager.verifyTorrents(ids: [torrent.id])
                }
            } label: {
                Label("Verify", systemImage: "externaldrive.badge.questionmark")
            }
            if torrent.status == 0 {
                Button {
                    Task {
                        try await manager.startTorrents(ids: [torrent.id])
                    }
                } label: {
                    Label("Start", systemImage: "play")
                }
            }else {
                Button {
                    Task {
                        try await manager.stopTorrents(ids: [torrent.id])
                    }
                } label: {
                    Label("Stop", systemImage: "stop")
                }
            }
            
            Button {
                onMove()
            } label: {
                Label("Move", systemImage: "folder")
            }
            
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            if torrent.progress < 1.0 {
                Divider()
                Button {
                    // Priority actions - to be implemented
                } label: {
                    Label("Set Priority", systemImage: "arrow.up.arrow.down")
                }
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
        
        // First try to find an image
        if let firstImage = files.first(where: { file in
            let ext = file.name.components(separatedBy: ".").last?.lowercased() ?? ""
            return (imageExtensions.contains(ext) && file.progress == 1)
        }) {
            return firstImage
        }
        
        // If no image found, try to find a video
        return files.first(where: { file in
            let ext = file.name.components(separatedBy: ".").last?.lowercased() ?? ""
            return (videoExtensions.contains(ext) && file.progress == 1)
        })
    }
    
    #if os(iOS)
    func get_media_path(file: TorrentFile, torrent: Torrent,  server: ServerEntity) -> String {
        let name = file.name
        if let path = torrent.dynamicFields["downloadDir"] {
            let baseDir = server.pathServer!
            let returnvalue = "\(path.value)/\(name)".replacingOccurrences(of: "//", with: "/")
            //print("returning path: " + returnvalue)
            return returnvalue
        }
        return ""
    }
#endif
    
    
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
    
    
    func get_media_path(file: TorrentFile, torrent: Torrent,  server: ServerEntity) -> String {
        let name = file.name
        let baseDir = server.pathServer!
        
        if var path = torrent.dynamicFields["downloadDir"]?.value as? String {
            if path.hasPrefix(baseDir) {
                path = String(path.dropFirst(baseDir.count))
                let returnvalue = "/private/tmp/com.srgim.Throttle-2.sftp/\(store.selection!.name!)/\(path)/\(name)".replacingOccurrences(of: "//", with: "/")
//                print("returning path: " + returnvalue)
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
                path = (server.pathFilesystem ?? "") + path
                let returnvalue = "/private/tmp/com.srgim.Throttle-2.sftp/\(store.selection!.name!)/\(path)/\(name)".replacingOccurrences(of: "//", with: "/")
//                print("returning path: " + returnvalue)
                return returnvalue
            }
        }

        return ""
    }
    
#if os(macOS)
func get_fuse_path(torrent: Torrent, downloadDir: String) -> URL {
    let tmpURL = URL(fileURLWithPath: "/private/tmp")
    let openBasePath = tmpURL.appendingPathComponent("com.srgim.Throttle-2.sftp")
                            .appendingPathComponent(store.selection!.name!)
    
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
    
//    print("Base dir: \(store.selection?.pathServer ?? "none")")
//    print("Original download dir: \(downloadDir)")
//    print("Cleaned path: \(cleanPath)")
//    print("Final path: \(finalPath.path)")
    
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
