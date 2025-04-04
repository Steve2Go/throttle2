//
//  store.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 17/2/2025.
//
import Foundation
import SwiftUI
import CoreData
import KeychainAccess


//MARK: Data Stores
class Presenting: ObservableObject {
    @Published var didStart: Bool = true
    @Published var activeSheet: String?
}

class TorrentFilters: NSObject, ObservableObject {
    @Published var search: String = ""
    @Published var current: String = ""
    @Published var order: String = "added"

}

class Store: NSObject, ObservableObject {
    @Published var connectTransmission = ""
    @Published var connectHttp = ""
    @AppStorage("selectedServerId") private var selectedServerId: String?
    private let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    //private var tunnelManager = SSHTunnelManager.shared
    
    @Published var selection: ServerEntity? {
        didSet {
            if let server = selection {
                selectedServerId = server.id?.uuidString
                Task {
                   // await updateConnection(for: server)
                }
            } else {
                selectedServerId = nil
                if let oldServer = oldValue {
                    Task {
                       // await tunnelManager.closeTunnel(
                    }
                }
            }
        }
    }
    
    //torrent creation
    @Published var addPath = ""
    
    //detailssheet
    @Published var showDetailSheet = false
    //Opening external files
    @Published var magnetLink = ""
    @Published var selectedFile: URL?
    @Published var selectedTorrentId: Int?
    
    //Sidebar
//    @AppStorage("sideBar") private var sideBar = false
//    @AppStorage("detailView") private var detailView = false
    
    //Browse folders in ios
    @Published var FileBrowse = false
    @Published var FileBrowseCover = false
    @Published var fileURL:String?
    @Published var fileBrowserName:String?
   // #if os(iOS)
    @Published var ssh: SSHConnection?
//#endif
#if os(iOS)
    var currentSFTPViewModel: SFTPFileBrowserViewModel?
    

    
    func handleVLCCallback(_ url: URL) {
        let action = url.lastPathComponent
        
        if (action == "playbackDidFinish" || action == "playbackDidFinish/") &&
           currentSFTPViewModel != nil && self.selection != nil {
            print("🔄 Store handling VLC callback for action: \(action)")
            // Call the handler with the stored references
            DispatchQueue.main.async {
                self.currentSFTPViewModel?.handleVLCCallback(server: self.selection!)
            }
        } else {
            print("⚠️ Cannot handle VLC callback: missing view model or server")
            if currentSFTPViewModel == nil {
                print("  - currentSFTPViewModel is nil")
            }
            if self.selection == nil {
                print("  - server.selection is nil")
            }
        }
    }
    #endif
    func restoreSelection() {
        guard let savedId = selectedServerId,
              let uuid = UUID(uuidString: savedId) else {
            return
        }
        
        let context = DataManager.shared.viewContext
        
        let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        fetchRequest.fetchLimit = 1
        
        do {
            let servers = try context.fetch(fetchRequest)
            if let savedServer = servers.first {
                self.selection = savedServer
            }
        } catch {
            print("Failed to fetch server with id \(uuid): \(error)")
        }
    }
    
}
 



// Helper function to get key information
func getKeyAndPassphrase(for server: ServerEntity) -> (keyPath: String, passphrase: String?)? {
    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    guard let storedPath = server.sshKeyFullPath,
          let filename = server.sshKeyFilename else { return nil }
    
    // Verify the stored path exists
    if FileManager.default.fileExists(atPath: storedPath) {
        #if os(macOS)
        let sshKeychain = Keychain(service: "com.apple.ssh.passphrases")
        let passphrase = try? sshKeychain.get(storedPath)
        #else
        let passphrase = try? keychain.get("passphrase-$filename)")
        #endif
        return (storedPath, passphrase)
    }
    
    // If stored path doesn't exist, try alternate location
    #if os(macOS)
    let alternatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh")
        .appendingPathComponent(filename)
        .path
    #else
    let alternatePath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("SSH")
        .appendingPathComponent(filename)
        .path
    #endif
    
    if FileManager.default.fileExists(atPath: alternatePath) {
        // Update stored path to match found location
        server.sshKeyFullPath = alternatePath
        
        #if os(macOS)
        let sshKeychain = Keychain(service: "com.apple.ssh.passphrases")
        let passphrase = try? sshKeychain.get(alternatePath)
        #else
        let passphrase = try? keychain.get("passphrase-$filename)")
        #endif
        return (alternatePath, passphrase)
    }
    
    return nil
}

