import SwiftUI
import CoreData
import KeychainAccess
#if os(macOS)
import ServiceManagement
#endif

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
    @AppStorage("mountOnLogin") var mountOnLogin = false
    @State var isCreating = false
#if os(iOS)
    @State var currentSFTPViewModel: SFTPFileBrowserViewModel?
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
                              store: store
                              
            )
            
#else
            if servers.count > 0 {
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
            
        }
        
        .onAppear {
            
            #if os(macOS)
            if !mountOnLogin {
                let serverArray = Array(servers)
                ServerMountManager.shared.mountAllServers(serverArray)
            }
            #endif
            
            if presenting.didStart {
                if UserDefaults.standard.bool(forKey: "openDefaultServer") != false || UserDefaults.standard.object(forKey: "selectedServer") == nil {
                    store.selection = servers.first(where: { $0.isDefault }) ?? servers.first
                } else{
                    store.selection = servers.first(where: { $0.id?.uuidString == UserDefaults.standard.string(forKey: "selectedServer")}) ?? servers.first
                }
                if servers.count > 0 && store.selection == nil {
                    store.selection = servers.first
                }
                
                presenting.didStart = false
            }
            
            // Set appropriate visibility only for iPad - preserves state on macOS
        }
        .onChange(of: mountOnLogin) {
            #if os(macOS)
            let fileManager = FileManager.default
            let agentName = "com.srgim.throttle2.mounter.plist"
            let launchAgentsURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            let destURL = launchAgentsURL.appendingPathComponent(agentName)

            if mountOnLogin == true {
                // Copy the plist from the app bundle to ~/Library/LaunchAgents/
                if let srcURL = Bundle.main.url(forResource: "com.srgim.throttle2.mounter", withExtension: "plist") {
                    do {
                        // Create LaunchAgents directory if needed
                        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
                        // Remove any existing file
                        if fileManager.fileExists(atPath: destURL.path) {
                            try fileManager.removeItem(at: destURL)
                        }
                        try fileManager.copyItem(at: srcURL, to: destURL)
                        // Load the agent
                        let task = Process()
                        task.launchPath = "/bin/launchctl"
                        task.arguments = ["load", destURL.path]
                        try? task.run()
                    } catch {
                        print("Failed to install LaunchAgent: \(error)")
                    }
                }
            } else {
                // Unload and remove the LaunchAgent
                let task = Process()
                task.launchPath = "/bin/launchctl"
                task.arguments = ["unload", destURL.path]
                try? task.run()
                try? fileManager.removeItem(at: destURL)
            }
            #endif
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
                    .onDisappear{
                    store.selectedFile = nil
                    store.magnetLink = ""
                    store.addPath = ""
                    
                }
#if os(iOS)
                    .presentationDetents([.medium])
#endif
            }
        }
        
        .onOpenURL { url in
            if url.isFileURL {
                store.selectedFile = url
                _ = store.selectedFile!.startAccessingSecurityScopedResource()
                //if manager.fetchTimer?.isValid == true || store.selection?.sftpRpc != true  {
                    Task{
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        presenting.activeSheet = "adding"
                    }
                //}
            }
            else if url.absoluteString.lowercased().hasPrefix("magnet:") {
                store.magnetLink = url.absoluteString
                //if manager.fetchTimer?.isValid == true || store.selection?.sftpRpc != true {
                Task{
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    presenting.activeSheet = "adding"
                    //}
                }
            }
            else if url.scheme == "throttle2", url.host == "mountall" {
                    #if os(macOS)
                store.launching = true
                    // Mount all servers and quit (headless)
                    let serverArray = Array(servers)
                    ServerMountManager.shared.mountAllServers(serverArray)
                    // quit after mounting
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        NSApp.terminate(nil)
                    }
                    #endif
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

//    func isRemoteMounted(byName remoteName: String) -> Bool {
//        // 1. Determine the expected mount point path
//        
//        ///private/tmp/com.srgim.Throttle-2.sftp/Backup
//        let mountsDirectory = "private/tmp/com.srgim.Throttle-2.sftp" // Standard location for macOS mounts
//        let mountPath = "\(mountsDirectory)/\(remoteName)"
//        
//        // 2. Check if the mount exists and is accessible
//        let fileManager = FileManager.default
//        let isDirectory = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
//        defer { isDirectory.deallocate() }
//        
//        // Check if path exists and is a directory
//        let exists = fileManager.fileExists(atPath: mountPath, isDirectory: isDirectory)
//        
//        // 3. Optional: Check if directory has content (additional validation)
//        let _ = exists && isDirectory.pointee.boolValue &&
//                       ((try? fileManager.contentsOfDirectory(atPath: mountPath).isEmpty) == false) //?? false
//        
//        return exists && isDirectory.pointee.boolValue
//        // Or use the stricter check: return hasContent
 //   }
