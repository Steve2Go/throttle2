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
    @Published var selection: ServerEntity? {
        didSet {
            if let server = selection {
                selectedServerId = server.id?.uuidString
            } else {
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
 






//final class DataManager {
//    static let shared = DataManager()
//    
//    let persistentContainer: NSPersistentCloudKitContainer
//    
//    init() {
//        persistentContainer = NSPersistentCloudKitContainer(name: "CoreData") // Use your new model name
//        
//        // Configure CloudKit
//        if let description = persistentContainer.persistentStoreDescriptions.first {
//            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
//                containerIdentifier: "iCloud.Throttle"
//            )
//            
//            // Enable history tracking for CloudKit
//            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
//        }
//        
//        persistentContainer.loadPersistentStores { description, error in
//            if let error = error {
//                fatalError("Failed to load Core Data stack: \(error)")
//            }
//        }
//        
//        // Configure the view context
//        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
//        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
//    }
//    
//    var viewContext: NSManagedObjectContext {
//        return persistentContainer.viewContext
//    }
//    
//    func saveContext() {
//        let context = viewContext
//        if context.hasChanges {
//            do {
//                try context.save()
//            } catch {
//                print("Error saving context: \(error)")
//            }
//        }
//    }
//}


final class DataManager {
    static let shared = DataManager()
    static var initCount = 0
    
    let persistentContainer: NSPersistentContainer
    
    private init() {
        DataManager.initCount += 1
        print("⚠️ DataManager initialized \(DataManager.initCount) times")
        
        // Initialize with NSPersistentContainer
        persistentContainer = NSPersistentContainer(name: "CoreData")
        
        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load Core Data stack: \(error)")
            }
            print("Successfully loaded persistent store: \(description)")
            print("Model URL: \(description.url?.absoluteString ?? "unknown")")
        }
        
        // Configure the view context
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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
                print("Error saving context: \(error)")
            }
        }
    }
}
