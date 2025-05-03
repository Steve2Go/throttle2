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
    let dataManager = DataManager.shared
    var tunnelManager: SSHTunnelManager?
    // Monitor the scene phase so we can restart the proxy when needed.
    @Environment(\.scenePhase) private var scenePhase
    
    @ObservedObject var manager = TorrentManager()
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var presenting = Presenting()
    @ObservedObject var filter = TorrentFilters()
    @ObservedObject var store = Store()
  //  @StateObject var proxyServer = SSHProxyServer.shared
    @StateObject var networkMonitor = NetworkMonitor()
    @State var isBackground: Timer?
    @State var tunnelClosed = false
    @State var isTunneling = false
    @AppStorage("canAirplay") var canAirplay = false

    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        .synchronizable(true)
#if os(iOS)
    init() {
            // Initialize external display manager at app startup
            setupExternalDisplayManager()
        }
    #endif
    
    var body: some Scene {
        #if os(macOS)
        // Use a single window for macOS:
        Window("Throttle 2", id: "main-window") {
            ContentView(presenting: presenting,manager: manager, filter: filter, store: store)
                .environment(\.managedObjectContext, DataManager.shared.viewContext)
                .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
                .environmentObject(networkMonitor)
                //.environment(\.managedObjectContext, persistenceController.container.viewContext)
                .background(colorScheme == .dark ? Color.black : Color.white)
                
                .onAppear {
                    presenting.didStart = true
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
                    Task {
                        setupServer(store: store, torrentManager: manager)
                    }
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
           
            
            
        }
        #else
        // Use WindowGroup for iOS (or other platforms)
        WindowGroup {
            ContentView(presenting: presenting, manager: manager, filter: filter, store: store)
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
                    
                    if networkMonitor.isConnected && !manager.isLoading {
                        manager.isLoading = true
                        if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                            refeshTunnel(store: store, torrentManager: manager)
                        }
                        ExternalDisplayManager.shared.startMonitoring()
                        print("Foreground- starting queue")
                        manager.isLoading = false
                    }
                    
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { (_) in
                    manager.stopPeriodicUpdates()
                    //stopSFTP()
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        SimpleFTPServerManager.shared.removeAllServers()
                        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                    }
                    print("Background - stopping queue")
                }
                .onChange(of: networkMonitor.gateways){
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        
                        if networkMonitor.isConnected && !manager.isLoading {
                            manager.isLoading = true
                            if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                                refeshTunnel(store: store, torrentManager: manager)
                            }
                            ExternalDisplayManager.shared.startMonitoring()
                            print("Foreground- starting queue")
                            manager.isLoading = false
                        }
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                            Task {
                                if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                                    //if oldValue != nil {
                                        manager.isLoading = true
                                        manager.stopPeriodicUpdates()
                                        //stopSFTP()
                                        TunnelManagerHolder.shared.tearDownAllTunnels()
                                        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                                        SimpleFTPServerManager.shared.removeAllServers()
                                    
                                    //}
                                    setupServer(store: store, torrentManager: manager)
                                } else {
                                    setupServer(store: store, torrentManager: manager)
                                }
                            }
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
