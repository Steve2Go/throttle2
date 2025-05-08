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
            
            
            
            
#endif
            
        }
        
        .onAppear {
            
            #if os(macOS)
            print("Mounting")
            let serverArray = Array(servers)
           // print (serverArray)
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
        }
    
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
                if manager.fetchTimer?.isValid == true || store.selection?.sftpRpc != true  {
                    Task{
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        presenting.activeSheet = "adding"
                    }
                }
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
