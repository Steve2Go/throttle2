//
//  Throttle_2App.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 17/2/2025.
//

import SwiftUI
import KeychainAccess
import UniformTypeIdentifiers
import CoreData
import SimpleToast

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "jfif", "bmp"]
let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "flv", "mpeg", "m4v", "wmv"]
let videoExtensionsPlayable: Set<String> = ["mp4", "mov", "mpeg", "m4v"]




@main
struct Throttle_2App: App {
    @Environment(\.managedObjectContext) var viewContext
    let dataManager = DataManager.shared
    var tunnelManager: SSHTunnelManager?
    // Monitor the scene phase so we can restart the proxy when needed.
    @Environment(\.scenePhase) private var scenePhase
    @State var serverArray: [ServerEntity] = []
    @ObservedObject var manager = TorrentManager()
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var presenting = Presenting()
    @ObservedObject var filter = TorrentFilters()
    @ObservedObject var store = Store()
    @StateObject var networkMonitor = NetworkMonitor()
    @State var isBackground: Timer?
    @State var tunnelClosed = false
    @State var isTunneling = false
    @AppStorage("mountOnLogin") var mountOnLogin = false
    @AppStorage("sftpCompression") var sftpCompression: Bool = false
    @State var ftpIsStarting = false
    var body: some Scene {
        #if os(macOS)
        // Use a single window for macOS:
        Window("Throttle 2", id: "main-window") {
            ContentView(presenting: presenting,manager: manager, filter: filter, store: store )
                .environment(\.managedObjectContext, DataManager.shared.viewContext)
                .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
                .environmentObject(networkMonitor)
                //.environment(\.managedObjectContext, persistenceController.container.viewContext)
                .background(colorScheme == .dark ? Color.black : Color.white)
                
                .onAppear {
                    presenting.didStart = true
                    // Manual fetch of servers after context is available
                    let context = DataManager.shared.viewContext
                    let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
                    do {
                        serverArray = try context.fetch(fetchRequest)
                    } catch {
                        print("Failed to fetch servers: \(error)")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                                    // This code will be executed just before the app terminates
                    if store.launching == false && mountOnLogin == false {
                        ServerMountManager.shared.unmountAllServers()
                    }
                                }
                .onChange(of: networkMonitor.gateways){
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        if networkMonitor.isConnected {
                            Task {
                                setupServer(store: store, torrentManager: manager)
                            }
                        }
                    }
                }
                .onChange(of: store.selection) {
                    //Task {
                        setupServer(store: store, torrentManager: manager)
                    // Refresh serverArray on selection change
                    let context = DataManager.shared.viewContext
                    let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
                    do {
                        serverArray = try context.fetch(fetchRequest)
                    } catch {
                        print("Failed to fetch servers: \(error)")
                    }
                   // }
                    }
                   
               // }
            
        }
    
        
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Servers...") {
                    presenting.activeSheet = "servers"  // Assuming you have activeSheet enum defined
                }
                .keyboardShortcut("e", modifiers: [.command])
                
                Button("Settings...") {
                    presenting.activeSheet = "settings"  // Assuming you have activeSheet enum defined
                }
                .keyboardShortcut(",", modifiers: [.command])
                Button("Refresh") {
                    manager.reset()
                    manager.isLoading.toggle()
                }.keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Throttle"){
                    presenting.activeSheet = "settings"
                    @AppStorage("isAbout") var isAbout = true
                }
                
            }
            CommandMenu("Mount") {
                

//                Button("Mount") {
//                    if !serverArray.isEmpty {
//                        ServerMountManager.shared.mountAllServers(serverArray)
//                    }
//                }
//                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Refresh Mounts") {
                    ServerMountManager.shared.unmountAllServers()
                    if !serverArray.isEmpty {
                        ServerMountManager.shared.mountAllServers(serverArray)
                        manager.reset()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
//                
//                Button("Unmount Remotes") {
//                    ServerMountManager.shared.unmountAllServers()
//                }
//                .keyboardShortcut("u", modifiers: [.command, .shift])
                
                Divider()
                // Toggle for Mount on Open
                Button(action: { mountOnLogin.toggle() }) {
                    Text("Mount on Login" + (mountOnLogin ? "  ✓" : ""))
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                
//                if !mountOnLogin {
//                    Button(action: { mountOnOpen.toggle() }) {
//                        Text("Mount on Open" + (mountOnOpen ? "  ✓" : ""))
//                    }
//                    .keyboardShortcut("o", modifiers: [.command, .shift])
//                    
//                    // Toggle for Unmount on Close
//                    Button(action: { unMountOnClose.toggle() }) {
//                        Text("Unmount on Close" + (unMountOnClose ? "  ✓" : ""))
//                    }
//                    .keyboardShortcut("c", modifiers: [.command, .shift])
//                }
                // Toggle for Compression
                Button(action: {
                    sftpCompression.toggle()
                    ServerMountManager.shared.unmountAllServers()
                    if !serverArray.isEmpty {
                        ServerMountManager.shared.mountAllServers(serverArray)
                        manager.reset()
                    }
                }) {
                    Text("Compress Transfers" + (sftpCompression ? "  ✓" : ""))
                    
                }
            }
            
            
        }

            
        #else
        // Use WindowGroup for iOS (or other platforms)
        WindowGroup {
            ContentView(presenting: presenting,manager: manager, filter: filter, store: store)
                .environment(\.managedObjectContext, DataManager.shared.viewContext)
                .environmentObject(networkMonitor)
                .environment(\.externalDisplayManager, ExternalDisplayManager.shared)
                //.environment(\.managedObjectContext, persistenceController.container.viewContext)
                .background(colorScheme == .dark ? Color.black : Color.white)
            
                .onAppear {
                    presenting.didStart = true
                    
                }
                // app backgrounding
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { (_) in
                    if networkMonitor.isConnected{
                        refreshSFTP(store: store)
                    }
                    if networkMonitor.isConnected && !manager.isLoading {
                        manager.isLoading = true
                        if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                            refeshTunnel(store: store, torrentManager: manager)
                        }
                        print("Foreground- starting queue")
                        //manager.isLoading = false
                    }
                    
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { (_) in
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        stopSFTP()
                        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                        Task{
                            await SSHConnectionManager.shared.cleanupBeforeTermination()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { (_) in
                    manager.stopPeriodicUpdates()
                    stopSFTP()
                    TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                    Task{
                        await SSHConnectionManager.shared.cleanupBeforeTermination()
                    }
                    
                    print("Background - stopping queue")
                }
                .onChange(of: networkMonitor.gateways){
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        refreshSFTP(store: store)
                        
                        if networkMonitor.isConnected && !manager.isLoading {
                            manager.isLoading = true
                            if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                                refeshTunnel(store: store, torrentManager: manager)
                            }
                            print("Foreground- starting queue")
                            //manager.isLoading = false
                        }
                        
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                            Task {
                                if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                                    if oldValue != nil {
                                        manager.isLoading = true
                                        manager.stopPeriodicUpdates()
                                        refreshSFTP(store: store)
                                        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                                    }
                                    if newValue != nil {
                                        setupServer(store: store, torrentManager: manager)
                                    }
                                } else {
                                    setupServer(store: store, torrentManager: manager)
                                }
                            }
                }
                .onChange(of: UIApplication.shared.connectedScenes) { 
                    ExternalDisplayManager.shared.updateExternalDisplayStatus()
                }
        }
      
        #endif
    }
    
    
    
}

#if os(macOS)
extension UTType {
    static var torrent: UTType {
        UTType(filenameExtension: "torrent", conformingTo: .data)!
    }
}
#else
extension UTType {
    static var torrent: UTType {
        UTType(exportedAs: "com.throttle.bittorrent")
    }
}
#endif
//extension UTType {
//    static let torrent = UTType(tag: "torrent",
//                               tagClass: .filenameExtension,
//                               conformingTo: nil)!
//}
