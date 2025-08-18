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
#if os(macOS)
import AppKit
#endif

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "jfif", "bmp"]
let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "flv", "mpeg", "m4v", "wmv"]
let videoExtensionsPlayable: Set<String> = ["mp4", "mov", "mpeg", "m4v"]

// Add this actor at file scope (outside Throttle_2App struct):
actor FTPStartupActor {
    private var isStarting = false
    func run<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        while isStarting { await Task.yield() }
        isStarting = true
        defer { isStarting = false }
        return try await operation()
    }
}

private let ftpStartupActor = FTPStartupActor()

#if os(macOS)
// AppDelegate to handle file opening when app is already running
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        print("🍏 AppDelegate: application(_:open:) called with URLs: \(urls)")
        
        for url in urls {
            print("🍏 AppDelegate: Processing URL: \(url)")
            print("🍏 AppDelegate: URL scheme: \(url.scheme ?? "nil")")
            print("🍏 AppDelegate: URL path: \(url.path)")
            print("🍏 AppDelegate: URL isFileURL: \(url.isFileURL)")
            
            // Post notification to trigger onOpenURL in SwiftUI
            NotificationCenter.default.post(
                name: Notification.Name("HandleExternalURL"),
                object: url
            )
        }
    }
}
#endif

@main
struct Throttle_2App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
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
    @StateObject var localTransmissionManager = LocalTransmissionManager.shared
    @State var tunnelClosed = false
    @AppStorage("isBackground") var isBackground = false
    @AppStorage("mountOnLogin") var mountOnLogin = false
    @AppStorage("transmissionOnLogin") var transmissionOnLogin = false
    @AppStorage("sftpCompression") var sftpCompression: Bool = false
    @AppStorage("sftpCipher") var sftpCipher: Bool = true
    var body: some Scene {
        #if os(macOS)
        // Use a single window for macOS:
        Window("Throttle 2", id: "main-window") {
            ContentView(presenting: presenting,manager: manager, filter: filter, store: store )
                .environment(\.managedObjectContext, DataManager.shared.viewContext)
                .environmentObject(networkMonitor)
                //.environment(\.managedObjectContext, persistenceController.container.viewContext)
                .background(colorScheme == .dark ? Color.black : Color.white)
                // Least disruptive window restore helper (macOS only)
#if os(macOS)
                .background(WindowFrameRestorer())
#endif
                
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
#if os(macOS)
                    // Persist final frame explicitly (in addition to autosave) as a safety net
                    if let win = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main-window" || $0.title == "Throttle 2" }) {
                        let r = win.frame
                        let str = "\(Int(r.origin.x)) \(Int(r.origin.y)) \(Int(r.size.width)) \(Int(r.size.height))"
                        UserDefaults.standard.set(str, forKey: "ThrottleMainWindowFrame")
                    }
#endif
                                }
                .onChange(of: networkMonitor.gateways){
                    if store.selection?.sftpRpc == true {
                        if networkMonitor.isConnected {
                            Task {
                                setupServer(store: store, torrentManager: manager)
                            }
                        }
                    }
                }
                .onChange(of: store.selection) {
                    Task {
                        manager.isLoading = true
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
                    }
                    }
                   
               // }
            
        }
        // Enforce single window behavior for better file handling
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
    
        
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
            CommandMenu("File System") {
                

                Button("Refresh Connection") {
                    ServerMountManager.shared.unmountAllServers()
                    if !serverArray.isEmpty {
                        ServerMountManager.shared.mountAllServers(serverArray)
                        manager.reset()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                
                Divider()
                // Toggle for Mount on Login
                Button(action: { mountOnLogin.toggle() }) {
                        Text(serverArray.count > 1 ? "Connect Drives on Login" :"Connect Drive on Login" + (mountOnLogin ? "  ✓" : ""))
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                
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
                
                // Toggle for Compression
                Button(action: {
                    sftpCipher.toggle()
                    ServerMountManager.shared.unmountAllServers()
                    if !serverArray.isEmpty {
                        ServerMountManager.shared.mountAllServers(serverArray)
                        manager.reset()
                    }
                }) {
                    Text("Faster Encryption (chacha20-poly1305)" + (sftpCipher ? "  ✓" : ""))
                    
                }
            }
            
            CommandMenu("Transmission") {
                let localServers = serverArray.filter { $0.isLocal }
                
                if let localServer = localServers.first {
                    Button("Start Daemon") {
                        localTransmissionManager.startDaemon(for: localServer)
                    }
                    .disabled(localTransmissionManager.isRunning)
                    
                    Button("Stop Daemon") {
                        localTransmissionManager.stopDaemon(for: localServer)
                    }
                    .disabled(!localTransmissionManager.isRunning)
                    
                    Button("Restart Daemon") {
                        localTransmissionManager.stopDaemon(for: localServer)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            localTransmissionManager.startDaemon(for: localServer)
                        }
                    }
                    .disabled(!localTransmissionManager.isRunning)
                    
                    Divider()
                    
                    // Toggle for Transmission on Login
                    Button(action: { transmissionOnLogin.toggle() }) {
                        Text("Start on Login" + (transmissionOnLogin ? "  ✓" : ""))
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                } else {
                    Text("No local servers configured")
                        .foregroundColor(.secondary)
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
                    isBackground = false
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    switch newPhase {
                    case .active:
                        // App became active (foreground)
                        // only connect if not already handled, and only from background
                        guard isBackground else { return }
                        isBackground = false
                        print("active")
                        Task {
                            connection(ftp: true, fullRefresh: false)
                        }
                    case .inactive:
                        // App going inactive (transitioning state)
                        // No need for specific handling here
                        break
                    case .background:
                        // App entered background
                        isBackground = true
                        Task {
                            manager.stopPeriodicUpdates()
                            // Handle app termination cleanup - similar to willTerminateNotification
//                            if store.selection?.sftpUsesKey == true {
//                                await SimpleFTPServerManager.shared.removeAllServers()
//                            }
                            
                            if store.selection?.sftpRpc == true {
                                TunnelManagerHolder.shared.tearDownAllTunnels()
                            }
                            
                            await SSHConnectionManager.shared.cleanupBeforeTermination()
                        }
                        print("Background - stopping queue")
                    @unknown default:
                        // Handle any future cases
                        break
                    }
                }
                .onChange(of: UIApplication.shared.connectedScenes) {
                    ExternalDisplayManager.shared.updateExternalDisplayStatus()
                }
                .onChange(of: networkMonitor.gateways) {
                    // network changed
                    guard !isBackground else {return}
                    Task {
                        connection(ftp: true, fullRefresh: false)
                        NotificationCenter.default
                                        .post(name: .gatewayChanged,
                                              object: nil,
                                              userInfo: ["gateways": networkMonitor.gateways])
                    }
                }
                .onChange(of: store.selection) {
                    connection()
                }
        }
      
        #endif
    }
    
    func connection(ftp:Bool = true, fullRefresh:Bool = true) {
        // are we doing this already?
        guard let server = store.selection else {return}
        manager.stopPeriodicUpdates()
        
        // FTP
        Task {
//            if await SimpleFTPServerManager.shared.activeServers.count > 0 && ftp {
               await SimpleFTPServerManager.shared.removeAllServers()
            
//            }
            if server.sftpBrowse && networkMonitor.isConnected && ftp {
                Task {
                    await connectFTP(store: store)
                }
            }
        }
        
        //Tunnels
        Task {
            if TunnelManagerHolder.shared.activeTunnels.count > 0 {
                TunnelManagerHolder.shared.tearDownAllTunnels()
            }
            if store.selection?.sftpRpc == true && networkMonitor.isConnected {
                setupServer(store: store, torrentManager: manager, fullRefresh: fullRefresh)
            }
        }
        
        
        
    }
    
    func connectFTP(store: Store , tries:Int = 0) async {
        await ftpStartupActor.run {
            await SimpleFTPServerManager.shared.removeAllServers()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if store.selection != nil {
                do {
                    let ftpServer = SimpleFTPServer(server: store.selection!)
                    try await ftpServer.start()
                    await SimpleFTPServerManager.shared.storeServer(ftpServer, withIdentifier: "sftp-ftp")
                } catch{
                    if tries < 4 {
                        await SimpleFTPServerManager.shared.removeAllServers()
                        await connectFTP(store:store ,tries: tries + 1)
                    } else {
                        ToastManager.shared.show(message: "FTP Proxy failed after \(tries) Attempts")
                    }
                }
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
