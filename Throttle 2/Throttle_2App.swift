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
    @StateObject var networkMonitor = NetworkMonitor()
    @State var isBackground: Timer?
    @State var tunnelClosed = false
    @State var isTunneling = false
    @AppStorage("canAirplay") var canAirplay = false

    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
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
                .onChange(of: scenePhase){
                    #if os(iOS)
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        if scenePhase == .background {
                            isBackground = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
                                DispatchQueue.main.async{
//                                    //TunnelManagerHolder.shared.tearDownAllTunnels()
                                    manager.stopPeriodicUpdates()
                                    TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                                    tunnelClosed = true
                                    print("Background - stopping queue")
                                }
                            }
                        } else if scenePhase == .active {
                            
                            if tunnelClosed && networkMonitor.isConnected{
                                //setupServer(store: store, torrentManager: manager)
                                refeshTunnel(store: store, torrentManager: manager)
                            }
                            isBackground?.invalidate()
                            tunnelClosed = false
                            print("Foreground- starting queue")
                            ExternalDisplayManager.shared.startMonitoring()
                        }
                    }
                    #endif
                }
                .onChange(of: networkMonitor.gateways){
                    if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                        if networkMonitor.isConnected {
                            Task {
                                refeshTunnel(store: store, torrentManager: manager)
                            }
                        }
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                            Task {
                                if store.selection?.sftpBrowse == true || store.selection?.sftpRpc == true {
                                    TunnelManagerHolder.shared.tearDownAllTunnels()
                                }
                                setupServer(store: store, torrentManager: manager)
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
