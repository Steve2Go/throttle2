//
//  store.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 17/2/2025.
//
import Foundation
import SwiftUI
import CoreData



//MARK: Data Stores
class Presenting: ObservableObject {
    @Published var didStart: Bool = true
    // Remove the individual sheet booleans and use the sheet enum instead
    // Other properties as needed...
}

class TorrentFilters: NSObject, ObservableObject {
    @Published var search: String = ""
    @Published var current: String = ""

}

class Store: NSObject, ObservableObject {
    @Published var connectTransmission = ""
    @Published var connectHttp = ""
    @AppStorage("selectedServerId") private var selectedServerId: String?
    @Published var selection: Servers? {
        didSet {
            // Save the server ID to AppStorage when selection changes
            if let server = selection {
                selectedServerId = server.id?.uuidString
            } else {
                // Clear the saved ID if selection is nil
                selectedServerId = nil
            }
        }
    }
    @Published var magnetLink = ""
    @Published var selectedFile: URL?
    @Published var selectedTorrentId: Int?
    @Published var sideBar = false
    @Published var showToast = false
    
    
    
    func restoreSelection() {
        // Retrieve the saved server ID from UserDefaults
        guard let savedId = UserDefaults.standard.string(forKey: "selectedServerId"),
              let uuid = UUID(uuidString: savedId) else {
            return
        }
        
        // Get the Core Data context from your DataManager
        let context = DataManager.shared.viewContext
        
        // Create a fetch request to find the server with the matching UUID
        let fetchRequest: NSFetchRequest<Servers> = Servers.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        fetchRequest.fetchLimit = 1
        
        do {
            // Execute the fetch
            let servers = try context.fetch(fetchRequest)
            if let savedServer = servers.first {
                self.selection = savedServer
            }
        } catch {
            print("❌ Failed to fetch server with id \(uuid): \(error)")
        }
    }
}
 



//@MainActor
//func getStoredServer(container: ModelContainer) -> Servers? {
//    guard let selectedServerId = UserDefaults.standard.string(forKey: "selectedServerId"),
//          let uuid = UUID(uuidString: selectedServerId) else {
//        return nil
//    }
//    
//    let descriptor = FetchDescriptor<Servers>(
//        predicate: #Predicate<Servers> { server in
//            server.id == uuid
//        }
//    )
//    
//    return try? container.mainContext.fetch(descriptor).first
//}



//final class DataManager {
//    var container: ModelContainer
//
//    init() {
//        do {
//            let schema = Schema([Servers.self])
//            let modelConfiguration = ModelConfiguration(schema: schema)
//            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
//        } catch {
//            fatalError("❌ Failed to initialize ModelContainer: \(error)")
//        }
//    }
//}


final class DataManager {
    static let shared = DataManager()

    let persistentContainer: NSPersistentCloudKitContainer

     init() {
        // Replace "YourDataModelName" with the name of your .xcdatamodeld file.
        persistentContainer = NSPersistentCloudKitContainer(name: "Throttle_2")
        
        // Optionally configure CloudKit options if needed:
        if let description = persistentContainer.persistentStoreDescriptions.first {
            // Uncomment and update the container identifier to enable CloudKit syncing.
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.Throttle")
        }
        
        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("❌ Failed to load persistent store: \(error)")
            }
        }
    }
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func saveContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                fatalError("❌ Failed to save context: \(error)")
            }
        }
    }
}
//extension Servers: Identifiable { }
//import Foundation
//import CoreData
//
//@objc(Servers)
//public class Servers: NSManagedObject { }
//
//extension Servers: Identifiable {
//    @nonobjc public class func fetchRequest() -> NSFetchRequest<Servers> {
//        return NSFetchRequest<Servers>(entityName: "Servers")
//    }
//    
//    @NSManaged public var id: UUID
//    @NSManaged public var name: String
//    @NSManaged public var isDefault: Bool
//    @NSManaged public var url: String
//    @NSManaged public var port: Int32   // Use Int32 for Core Data numeric types
//    @NSManaged public var rpc: String
//    @NSManaged public var user: String?
//    @NSManaged public var pathServer: String?
//    @NSManaged public var pathHttp: String?
//    @NSManaged public var httpUser: String?
//    @NSManaged public var httpBrowse: Bool
//    @NSManaged public var httpThumb: Bool
//    @NSManaged public var sftpHost: String?
//    @NSManaged public var sftpPort: Int32  // Again, use Int32
//    @NSManaged public var sftpUser: String?
//    @NSManaged public var pathFilesystem: String?
//    @NSManaged public var fsBrowse: Bool
//    @NSManaged public var fsThumb: Bool
//    @NSManaged public var sftpBrowse: Bool
//    @NSManaged public var fsPath: String?
//}

//
//@Model
//final class Servers {
//    @Attribute(.unique) var id: UUID = UUID()
//    
//    // Required
//    var name: String
//    
//    // Defaults
//    var isDefault: Bool = false
//
//    // **🔹 Torrent Server (Primary)**
//    var url: String = ""
//    var port: Int = 443
//    var rpc: String = "/transmission/rpc"
//    var user: String? = nil
//    var pathServer: String? = nil
//
//    // **🔹 HTTP Server (Optional)**
//    var pathHttp: String? = nil
//    var httpUser: String? = nil
//    var httpBrowse: Bool = false
//    var httpThumb: Bool = false
//
//    // **🔹 SFTP Server (Optional)**
//    var sftpHost: String? = nil
//    var sftpPort: Int? = 22
//    var sftpUser: String? = nil
//    var pathFilesystem: String? = nil
//    var fsBrowse: Bool = false
//    var fsThumb: Bool = false
//    var sftpBrowse: Bool = false
//    var fsPath: String? = nil
//
//    init(name: String) {
//        self.name = name
//    }
//}
