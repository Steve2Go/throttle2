import SwiftUI
import CoreData
import KeychainAccess

// Keep only one enum for sheet types
enum SheetType: String, Identifiable {
    case adding
    case servers
    case settings
    
    // id property required by Identifiable
    var id: String { self.rawValue }
}

struct ContentView: View {
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default)
    var servers: FetchedResults<ServerEntity>
    @ObservedObject var presenting: Presenting
    @ObservedObject var manager: TorrentManager
    @ObservedObject var filter: TorrentFilters
    @ObservedObject var store: Store
    @State private var splitViewVisibility = NavigationSplitViewVisibility.automatic
//    @AppStorage("sideBar") var sideBar = false
    @AppStorage("detailView") private var detailView = false
    @AppStorage("firstRun") private var firstRun = true
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = true
    @State var isMounted = false
    @State var isCreating = false
#if os(iOS)
    @State var currentSFTPViewModel: SFTPFileBrowserViewModel?
    #endif
    #if os(macOS)
    var mountManager = ServerMountManager()
#endif
    
    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        .synchronizable(true)
    
    
    var body: some View {
        let activeSheetBinding = createActiveSheetBinding(presenting)
        ZStack{
            #if os(macOS)
            MacOSContentView( presenting: presenting,
                              manager: manager,
                              filter: filter,
                              store: store,
                              isMounted: isMounted
                              )
            
            #else
            if servers.count > 1 {
                iOSContentView( presenting: presenting,
                                manager: manager,
                                filter: filter,
                                store: store
                )
            } else{
                AddFirstServer(presenting: presenting)
            }
            
#endif
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    presenting.activeSheet = "adding"
                } label: {
                    Image(systemName: "plus")
                    //Text("Add")
                } //.buttonStyle(.borderless)
            }
           // }
#if os(iOS)
            if ((store.selection?.sftpBrowse) != nil){
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        
                        store.fileURL = store.selection?.pathServer
                        store.fileBrowserName = ""
                        store.FileBrowse = true
                        
                        
                    } label:{
                        Image(systemName: "folder")
                    }
                    
                }
            }
#endif
#if os(macOS)
            
            ToolbarItem (placement: .automatic) {
                    Button {
                        presenting.isCreating = true
                    } label: {
                        Image(systemName: "document.badge.plus")
                    }
                }
            
            if ((store.selection?.sftpBrowse) == true){
                ToolbarItem (placement: .automatic) {
                    Button {
                        
                        let path = mountManager.getMountPath(for: store.selection!)
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.absoluteString.replacingOccurrences(of: "file://", with: ""))
                        //NSWorkspace.shared.activateFileViewerSelecting([path])
                        
                    } label:{
                        
                        Image(systemName: "folder")
                    }
                }
            }
#endif
            if !isSidebarVisible {
#if os(iOS)
                if servers.count > 1 {
                    ToolbarItem(placement: .topBarTrailing){
                        Menu {
                            ForEach(servers) { server in
                                Button(action: {
                                    store.selection = server
                                }, label: {
                                    if store.selection == server {
                                        Image(systemName: "checkmark.circle").padding(.leading, 6)
                                    } else {
                                        Image(systemName: "circle")
                                    }
                                    Text(server.isDefault ? (server.name ?? "") + " (Default)" : (server.name ?? ""))
                                })
                                .buttonStyle(.plain)
                            }
                        } label: {
                            Image(systemName: "externaldrive.badge.wifi")
                        }.disabled(manager.isLoading)
                    }
                }
#else
                if servers.count > 1 {
                    ToolbarItem {
                        Menu {
                            ForEach(servers) { server in
                                Button(action: {
                                    store.selection = server
                                }, label: {
                                    if store.selection == server {
                                        Image(systemName: "checkmark.circle").padding(.leading, 6)
                                    } else {
                                        Image(systemName: "circle")
                                    }
                                    Text(server.isDefault ? (server.name ?? "") + " (Default)" : (server.name ?? ""))
                                })
                                .buttonStyle(.plain)
                            }
                        } label: {
                            Image(systemName: "externaldrive.badge.wifi")
                        }.disabled(manager.isLoading)
                    }
                }
#endif
#if os(iOS)
                
#endif
            }
        }
        
        .onAppear {
            let serverArray = Array(servers)
            #if os(macOS)
            mountManager.mountAllServers(serverArray)
            #endif
            
            if presenting.didStart {
                if UserDefaults.standard.bool(forKey: "openDefaultServer") != false || UserDefaults.standard.object(forKey: "selectedServer") == nil {
                    store.selection = servers.first(where: { $0.isDefault }) ?? servers.first
                }else{
                    store.selection = servers.first(where: { $0.id?.uuidString == UserDefaults.standard.string(forKey: "selectedServer")}) ?? servers.first
                }
                
                presenting.didStart = false
            }
            
            // Set appropriate visibility only for iPad - preserves state on macOS
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                // Initialize iPad layout based on current orientation
                setIpadSplitViewVisibility()
            }
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Only respond to iPad orientation changes
            if UIDevice.current.userInterfaceIdiom == .pad {
                setIpadSplitViewVisibility()
            }
        }
        #endif
        #if os(macOS)
        .sheet( isPresented: $presenting.isCreating) {
            CreateTorrent(store: store, presenting: presenting)
                .frame(width: 400, height: 500)
                .padding(20)
        }
        #endif
        .sheet(item: activeSheetBinding) { sheetType in
            switch sheetType {
            case .settings:
                SettingsView(presenting: presenting, manager: manager)
            case .servers:
                ServersListView(presenting: presenting, store: store)
                    #if targetEnvironment(macCatalyst) || os(macOS)
                    .frame(width: 600, height: 600)
                    #endif
            case .adding:
                AddTorrentView(store: store, manager: manager, presenting: presenting)
                    #if os(iOS)
                    .presentationDetents([.medium])
                    #endif
            }
        }
        
        .onOpenURL { url in
            if url.isFileURL {
                store.selectedFile = url
                store.selectedFile!.startAccessingSecurityScopedResource()
                #if os(iOS)
                if manager.fetchTimer?.isValid == true || store.selection?.sftpRpc != true  {
                    Task{
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        presenting.activeSheet = "adding"
                    }
                }
                #else
                presenting.activeSheet = "adding"
                #endif
//                Task {
//                    try await Task.sleep(for: .milliseconds(500))
//                    presenting.activeSheet = "adding"
//                }
            }
            else if url.absoluteString.lowercased().hasPrefix("magnet:") {
                store.magnetLink = url.absoluteString
                if manager.fetchTimer?.isValid == true || store.selection?.sftpRpc != true {
                    presenting.activeSheet = "adding"
                }
            }
            else {
                print("URL ignored: Not a file or magnet link")
            }
        }

//        .onOpenURL { url in
//            // Check if it's a file URL
//            if url.isFileURL {
//                store.selectedFile = url
//                store.selectedFile!.startAccessingSecurityScopedResource()
//                Task {
//                    try await Task.sleep(for: .milliseconds(500))
//                    presenting.activeSheet = "adding"
//                }
//            }
//            // Check if it's a magnet link
//            else if url.absoluteString.lowercased().hasPrefix("magnet:") {
//                store.magnetLink = url.absoluteString
//                Task {
//                    try await Task.sleep(for: .milliseconds(500))
//                    presenting.activeSheet = "adding"
//                }
//            }
//            // Ignore all other URL types
//            else {
//                print("URL ignored: Not a file or magnet link")
//            }
//        }
    }
    
    private func createActiveSheetBinding(_ presenting: Presenting) -> Binding<SheetType?> {
        return Binding<SheetType?>(
            get: {
                if let sheetString = presenting.activeSheet {
                    return SheetType(rawValue: sheetString)
                }
                return nil
            },
            set: { presenting.activeSheet = $0?.rawValue }
        )
    }
#if os(iOS)
// Helper function to set iPad-specific split view visibility
func setIpadSplitViewVisibility() {
    // Only apply to iPad
    if UIDevice.current.userInterfaceIdiom == .pad {
        // In portrait: show content view (torrent list)
        if UIDevice.current.orientation.isPortrait || UIDevice.current.orientation.isFlat {
            splitViewVisibility = .doubleColumn
        } else {
            // In landscape: show all columns
            splitViewVisibility = .all
        }
    }
}
#endif
}

    func isRemoteMounted(byName remoteName: String) -> Bool {
        // 1. Determine the expected mount point path
        
        ///private/tmp/com.srgim.Throttle-2.sftp/Backup
        let mountsDirectory = "private/tmp/com.srgim.Throttle-2.sftp" // Standard location for macOS mounts
        let mountPath = "\(mountsDirectory)/\(remoteName)"
        
        // 2. Check if the mount exists and is accessible
        let fileManager = FileManager.default
        let isDirectory = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        defer { isDirectory.deallocate() }
        
        // Check if path exists and is a directory
        let exists = fileManager.fileExists(atPath: mountPath, isDirectory: isDirectory)
        
        // 3. Optional: Check if directory has content (additional validation)
        let hasContent = exists && isDirectory.pointee.boolValue &&
                       ((try? fileManager.contentsOfDirectory(atPath: mountPath).isEmpty) == false) //?? false
        
        return exists && isDirectory.pointee.boolValue
        // Or use the stricter check: return hasContent
    }
