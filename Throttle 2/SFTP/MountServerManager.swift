//
//  ServerManager.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 7/3/2025.
//

#if os(macOS)
import Foundation
import CoreData
import Combine

class ServerMountManager: ObservableObject {
    private let dataManager = DataManager.shared
    private let mountManager = MountManager()
    private var cancellables = Set<AnyCancellable>()
    
    @Published private(set) var servers: [ServerEntity] = []
    
    init() {
        // Setup observation of context changes
        NotificationCenter.default
            .publisher(for: .NSManagedObjectContextObjectsDidChange, object: dataManager.viewContext)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshServers()
            }
            .store(in: &cancellables)
        
        refreshServers()
    }
    
    func refreshServers() {
        let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
        
        do {
            let fetchedServers = try dataManager.viewContext.fetch(fetchRequest)
            DispatchQueue.main.async {
                self.servers = fetchedServers
                self.mountManager.mountFolders(servers: fetchedServers)
            }
        } catch {
            print("Error fetching servers: \(error)")
        }
    }
    
    func mountServer(_ server: ServerEntity) {
        mountManager.mountFolder(server: server)
    }
    
    func unmountServer(_ server: ServerEntity) {
        mountManager.unmountFolder(server: server)
    }
    
    func getMountStatus(for server: ServerEntity) -> Bool {
        return mountManager.mountStatus[server.name ?? ""] ?? false
    }
    
    func getError(for server: ServerEntity) -> Error? {
        return mountManager.mountErrors[server.name ?? ""]
    }
}
#endif
