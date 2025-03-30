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
    private var tunnelManager: SSHTunnelManager?
    // Monitor the scene phase so we can restart the proxy when needed.
    @Environment(\.scenePhase) private var scenePhase
    
    @ObservedObject var manager = TorrentManager()
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var presenting = Presenting()
    @ObservedObject var filter = TorrentFilters()
    @ObservedObject var store = Store()

    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    
    
    var body: some Scene {
        #if os(macOS)
        // Use a single window for macOS:
        Window("Throttle 2", id: "main-window") {
            ContentView(presenting: presenting,manager: manager, filter: filter, store: store)
                .environment(\.managedObjectContext, DataManager.shared.viewContext)
                .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
                
                //.environment(\.managedObjectContext, persistenceController.container.viewContext)
                .background(colorScheme == .dark ? Color.black : Color.white)
                .onAppear {
                    presenting.didStart = true
                    
                }
                .onChange(of: scenePhase) { oldValue, newValue in
                    if newValue == .background {
                        manager.stopPeriodicUpdates()
                    }else if newValue == .active {
                        //manager.startPeriodicUpdates()
                        setupServer(store: store, torrentManager: manager)
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                    setupServer(store: store, torrentManager: manager)
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
                //.environment(\.managedObjectContext, persistenceController.container.viewContext)
                .background(colorScheme == .dark ? Color.black : Color.white)
                .onAppear {
                    presenting.didStart = true
                }
                .onChange(of: scenePhase) { oldValue, newValue in
                    if newValue == .background {
                        manager.stopPeriodicUpdates()
                    }else if newValue == .active {
                        //manager.startPeriodicUpdates()
                        setupServer(store: store, torrentManager: manager)
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                    if store.selection != nil {
                        setupServer(store: store, torrentManager: manager)
                    }
                   
                }
               
        }
      
        #endif
    }
    
    func setupServer (store: Store, torrentManager: TorrentManager) {
        TunnelManagerHolder.shared.tearDownAllTunnels()
        // url construction for server wuaries
        if store.selection != nil {
            // load the keychain
            let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
            var server = store.selection
            // trying to keep it as easy as possible
            let proto = (server?.protoHttps ?? false) ? "https" : "http"
            let domain = server?.url ?? "localhost"
            let user = server?.sftpUser ?? ""
            let password = keychain["password" + (server?.name! ?? "")] ?? ""
            
            let port  = server?.port ?? 9091
            let path = server?.rpc ?? "transmission/rpc"
            
            let isTunnel = server?.sftpRpc ?? false
            let hasKey = server?.sftpUsesKey
            let localport = 4000 // update after tunnel logic
            
            var url = ""
            var at = ""
            
            if isTunnel{
                
                //server tunnel creation
                let sshPass = keychain["sftpPassword" + (server?.name! ?? "")] ?? ""
                
                if let server = server {
                    Task {
                        do {
                            let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "localhost", remotePort: Int(port))
                            try await tmanager.start()
                            TunnelManagerHolder.shared.storeTunnel(tmanager, withIdentifier: "transmission-rpc")
                            
                            url += "http://"
                            if !user.isEmpty {
                                at = "@"
                                url += user
                                if !password.isEmpty {
                                    url += ":\(password)"
                                }
                            }
                            url += "\(at)localhost:\(String(localport))\(path)"
                            
                            store.connectTransmission = url
                            ServerManager.shared.setServer(store.selection!)
                            
                            
                            torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                            torrentManager.startPeriodicUpdates()
                        } catch let error as SSHTunnelError {
                            switch error {
                            case .missingCredentials:
                                print("Error: Missing credentials")
                            case .connectionFailed(let underlyingError):
                                print("Error: Connection failed: \(underlyingError)")
                            case .portForwardingFailed(let underlyingError):
                                print("Error: Port forwarding failed: \(underlyingError)")
                            case .localProxyFailed(let underlyingError):
                                print("Error: Local proxy failed: \(underlyingError)")
                            case .reconnectFailed(let underlyingError):
                                print("Error: Reconnect failed: \(underlyingError)")
                            case .invalidServerConfiguration:
                                print("Error: Invalid server configuration")
                            case .tunnelAlreadyConnected:
                                print("Error: Tunnel already connected")
                            case .tunnelNotConnected:
                                print("Error: Tunnel not connected")
                            }
                        } catch {
                            print("An unexpected error occurred: \(error)")
                        }
                    }
                }
                
                
            }  else {
                url += "\(proto)://"
                if !user.isEmpty {
                    at = "@"
                    url += user
                    if !password.isEmpty {
                        url += ":\(password)"
                    }
                }
                url += "\(at)\(domain):\(String(port))\(path)"
                store.connectTransmission = url
                ServerManager.shared.setServer(store.selection!)
                
                
                torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                torrentManager.startPeriodicUpdates()
            }
            
        }
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
