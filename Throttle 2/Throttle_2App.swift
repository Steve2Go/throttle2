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
                        manager.startPeriodicUpdates()
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                    if store.selection != nil {
                        ServerManager.shared.setServer(store.selection!)
                    }
                    if let selection = newValue,
                       let user = selection.user,
                       !user.isEmpty {
                        
                        if let password = keychain["password" + selection.name!], !password.isEmpty {
                            store.connectTransmission = selection.url!.replacingOccurrences(
                                of: "://",
                                with: "://" + user + ":" + password + "@"
                            ) + (store.selection?.rpc ?? "")
                        } else {
                            store.connectTransmission = selection.url!
                        }
                        manager.updateBaseURL(URL( string: store.connectTransmission)!)
                        manager.startPeriodicUpdates()
                        //print(store.connectTransmission)
                    }
                   
                }
            
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
            }
            CommandGroup(after: .windowList){
                Button("Refresh") {
                    manager.reset()
                    manager.isLoading.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command])
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
                        manager.startPeriodicUpdates()
                    }
                }
                .onChange(of: store.selection) { oldValue, newValue in
                    if store.selection != nil {
                        ServerManager.shared.setServer(store.selection!)
                    }
                    if let selection = newValue,
                       let user = selection.user,
                       !user.isEmpty {
                        
                        if let password = keychain["password" + selection.name!], !password.isEmpty {
                            store.connectTransmission = selection.url!.replacingOccurrences(
                                of: "://",
                                with: "://" + user + ":" + password + "@"
                            ) + (store.selection?.rpc ?? "")
                        } else {
                            store.connectTransmission = selection.url!
                        }
                        manager.updateBaseURL(URL( string: store.connectTransmission)!)
                        manager.startPeriodicUpdates()
                        //print(store.connectTransmission)
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
