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
    @Published var isCreating: Bool = false
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
//                if let oldServer = oldValue {
//                    Task {
//                       // await tunnelManager.closeTunnel(
//                    }
//                }
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
    
    @Published var streamingUrl = ""
    
    //Sidebar
//    @AppStorage("sideBar") private var sideBar = false
//    @AppStorage("detailView") private var detailView = false
    
    //Browse folders in ios
    @Published var FileBrowse = false
    @Published var FileBrowseCover = false
    @Published var fileURL:String?
    @Published var fileBrowserName:String?
    @Published var isOpeningVideoDirectly = false
    @Published var launching = false
   // #if os(iOS)
    //@Published var ssh: SSHConnection?
//#endif
    var currentSFTPViewModel: SFTPFileBrowserViewModel?
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
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    let keychain = useCloudKit ? Keychain(service: "srgim.throttle2").synchronizable(true) : Keychain(service: "srgim.throttle2").synchronizable(false)
    guard let storedPath = server.sshKeyFullPath,
          let filename = server.sshKeyFilename else { return nil }
    
    // Verify the stored path exists
    if FileManager.default.fileExists(atPath: storedPath) {
        #if os(macOS)
        let sshKeychain = Keychain(service: "com.apple.ssh.passphrases")
            .synchronizable(true)
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
        @AppStorage("useCloudKit") var useCloudKit: Bool = true
        let sshKeychain = useCloudKit ? Keychain(service: "srgim.throttle2").synchronizable(true) : Keychain(service: "srgim.throttle2").synchronizable(false)
        let passphrase = try? sshKeychain.get(alternatePath)
        #else
        let passphrase = try? keychain.get("passphrase-$filename)")
        #endif
        return (alternatePath, passphrase)
    }
    
    return nil
}

