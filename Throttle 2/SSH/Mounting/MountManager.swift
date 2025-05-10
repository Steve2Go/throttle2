#if os(macOS)
import Foundation
import CoreData
import Combine
import KeychainAccess
import AppKit

enum MountError: Error {
    case directoryCreationFailed
    case mountProcessFailed
    case invalidServerConfiguration
    case alreadyMounted
    case unmountFailed
    case sshAgentSetupFailed
}

class ServerMountManager: ObservableObject {
    // MARK: - Singleton
    static let shared = ServerMountManager()
    
    // MARK: - Properties
    private let dataManager = DataManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    var mountProcesses: [String: Process] = [:]
    
    // Maps server entity IDs to mount key
    private var serverMountMap: [NSManagedObjectID: String] = [:]
    
    // Map of active mount points (mountKey → mountPath)
    private(set) var activeMounts: [String: URL] = [:]
    
    // Track temporary key files for cleanup
    private var temporaryKeyFiles: [String] = []
    
    @Published private(set) var servers: [ServerEntity] = []
    @Published private(set) var mountStatus: [String: Bool] = [:]
    @Published private(set) var mountErrors: [String: Error] = [:]
    
    // MARK: - Initialization
    init() {
        // Fetch servers initially
        refreshServersWithoutAutoMount()
        
        // Setup observation of context changes - only update server list, don't auto-mount
        NotificationCenter.default
            .publisher(for: .NSManagedObjectContextObjectsDidChange, object: dataManager.viewContext)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshServersWithoutAutoMount()
            }
            .store(in: &cancellables)
        
        // Setup cleanup on app termination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        // Setup periodic health check
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMountHealth()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Server Management
    
    /// Refreshes the server list without attempting to mount servers
    func refreshServersWithoutAutoMount() {
        let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
        
        do {
            let fetchedServers = try dataManager.viewContext.fetch(fetchRequest)
            DispatchQueue.main.async {
                self.servers = fetchedServers
            }
        } catch {
            print("Error fetching servers: \(error)")
        }
    }
    
    /// Refreshes server list and then mounts servers with sftpBrowse enabled
    func refreshServers() {
        refreshServersWithoutAutoMount()
        mountAutoConnectServers()
    }
    
    private func mountAutoConnectServers() {
        let autoConnectServers = servers.filter { $0.sftpBrowse }
        mountServers(autoConnectServers)
    }
    
    // MARK: - Mount Key Generation
    
    /// Gets the mount key for a server - DEPRECATED: Use ServerMountUtilities.getMountKey(for:) instead
    @available(*, deprecated, message: "Use ServerMountUtilities.getMountKey(for:) instead")
    func getMountKey(for server: ServerEntity) -> String? {
        return ServerMountUtilities.getMountKey(for: server)
    }
    
    // MARK: - Mount Path Generation
    
    /// Returns the mount path for a given server
    func getMountPath(for server: ServerEntity) -> URL {
        if let mountKey = ServerMountUtilities.getMountKey(for: server) {
            // If this server has an active mount point, return that
            if let existingPath = activeMounts[mountKey] {
                return existingPath
            }
            
            // Otherwise create a new mount path with the mount key
            let path = ServerMountUtilities.getMountPath(for: mountKey)
            
            // Store the mount path for this key
            activeMounts[mountKey] = path
            return path
        }
        
        // Fallback using server name if mount key can't be determined
        return URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("com.srgim.Throttle-2.sftp/\(server.name ?? "unknown")", isDirectory: true)
    }
    

    
    // MARK: - Mount Operations
    func mountServer(_ server: ServerEntity) {
        guard let user = server.sftpUser,
              let host = server.sftpHost,
              let path = server.pathServer,
              let mountKey = ServerMountUtilities.getMountKey(for: server),
              !user.isEmpty,
              !host.isEmpty,
              !path.isEmpty else {
            mountStatus[server.name ?? ""] = false
            mountErrors[server.name ?? ""] = MountError.invalidServerConfiguration
            return
        }
        
        // Associate this server with the mount key
        if let objectID = server.objectID as? NSManagedObjectID {
            serverMountMap[objectID] = mountKey
        }
        
        // Check if we already have a mount for this connection
        if mountProcesses[mountKey] != nil {
            // Already mounted with this key, just update status
            mountStatus[server.name ?? ""] = true
            mountErrors.removeValue(forKey: server.name ?? "")
            return
        }
        
        let directoryURL = getMountPath(for: server)
        
        // Check if already mounted
        if isDirectoryMounted(directoryURL) {
            mountStatus[server.name ?? ""] = true
            return
        }
        
        // Create directory if needed
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            mountStatus[server.name ?? ""] = false
            mountErrors[server.name ?? ""] = error
            return
        }
        
        // Setup mount process
        let process = Process()
        process.launchPath = "/bin/zsh"
        
        let url = directoryURL.path
        var sshfsOptions = "ServerAliveInterval=30,ServerAliveCountMax=4,reconnect,auto_cache,kernel_cache,location=Throttle"
        
        // Add host key check options
        sshfsOptions += ",StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null"
        
        var command: String
        
        // Setup SSH key if needed
        if server.sftpUsesKey {
            // Create temporary key file
            guard let keyContent = keychain["sftpKey" + (server.name ?? "")] else {
                mountStatus[server.name ?? ""] = false
                mountErrors[server.name ?? ""] = MountError.invalidServerConfiguration
                return
            }
            
            let tempDir = FileManager.default.temporaryDirectory
            let keyFileName = "sshfs_key_\(UUID().uuidString)"
            let keyPath = tempDir.appendingPathComponent(keyFileName)
            
            do {
                // Write key to temporary file with restricted permissions
                try keyContent.write(to: keyPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
                
                // Track temporary file for cleanup
                temporaryKeyFiles.append(keyPath.path)
                
                // Use direct key file for authentication
                sshfsOptions += ",PreferredAuthentications=publickey"
                sshfsOptions += ",IdentityFile=\(keyPath.path)"
                
                command = "/usr/local/bin/sshfs \(user)@\(host):\(path) \(url) -o \(sshfsOptions)"
            } catch {
                mountStatus[server.name ?? ""] = false
                mountErrors[server.name ?? ""] = error
                return
            }
        } else {
            // Use password authentication
            let password = keychain["sftpPassword" + mountKey] ??
                           keychain["sftpPassword" + (server.name ?? "")] ?? ""
            
            sshfsOptions += ",password_stdin"
            command = "echo \(password) | /usr/local/bin/sshfs \(user)@\(host):\(path) \(url) -o \(sshfsOptions)"
        }
        
        print("Fuse mounting with command: " + command)
        process.arguments = ["-c", command]
        
        // Setup termination handling
        process.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    // Update status for all servers using this mount key
                    self.updateStatusForMountKey(mountKey, success: true)
                } else {
                    // Update error status for all servers using this mount key
                    self.updateStatusForMountKey(mountKey, success: false, error: MountError.mountProcessFailed)
                }
            }
        }
        
        // Run the mount process
        do {
            try process.run()
            mountProcesses[mountKey] = process
            // Update status for the current server
            mountStatus[server.name ?? ""] = true
        } catch {
            updateStatusForMountKey(mountKey, success: false, error: error)
        }
    }
    
    private func updateStatusForMountKey(_ mountKey: String, success: Bool, error: Error? = nil) {
        // Find all servers that use this mount key and update their status
        for server in servers {
            guard let objectID = server.objectID as? NSManagedObjectID,
                  let serverKey = serverMountMap[objectID],
                  serverKey == mountKey,
                  let name = server.name else {
                continue
            }
            
            mountStatus[name] = success
            
            if success {
                mountErrors.removeValue(forKey: name)
            } else if let error = error {
                mountErrors[name] = error
            }
        }
    }
    
    func unmountServer(_ server: ServerEntity) {
        guard let name = server.name,
              let mountKey = ServerMountUtilities.getMountKey(for: server) else {
            return
        }
        
        // Check if other servers are using this mount
        var otherServersUsingMount = false
        for otherServer in servers where otherServer.name != name {
            if getMountKey(for: otherServer) == mountKey {
                otherServersUsingMount = true
                break
            }
        }
        
        // If other servers are using this mount, just update the status for this server
        if otherServersUsingMount {
            mountStatus[name] = false
            mountErrors.removeValue(forKey: name)
            if let objectID = server.objectID as? NSManagedObjectID {
                serverMountMap.removeValue(forKey: objectID)
            }
            return
        }
        
        // No other servers using this mount, proceed with unmounting
        let directoryURL = getMountPath(for: server)
        
        // Try graceful unmount
        let process = Process()
        process.launchPath = "/sbin/umount"
        process.arguments = [directoryURL.path]
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                // Try force unmount if needed
                let forceProcess = Process()
                forceProcess.launchPath = "/sbin/umount"
                forceProcess.arguments = ["-f", directoryURL.path]
                
                try forceProcess.run()
                forceProcess.waitUntilExit()
            }
            
            // Clean up mount resources
            mountProcesses.removeValue(forKey: mountKey)
            activeMounts.removeValue(forKey: mountKey)
            updateStatusForMountKey(mountKey, success: false)
            
            // Remove this server from mount mapping
            if let objectID = server.objectID as? NSManagedObjectID {
                serverMountMap.removeValue(forKey: objectID)
            }
        } catch {
            mountErrors[name] = error
        }
    }
    
    func mountServers(_ servers: [ServerEntity]) {
        for server in servers {
            mountServer(server)
        }
    }
    
    func mountAllServers(_ servers: [ServerEntity]) {
        mountServers(servers)
    }
    
    func unmountAllServers() {
        // Get unique mount keys
        let mountKeys = Set(activeMounts.keys)
        
        for mountKey in mountKeys {
            if let mountURL = activeMounts[mountKey] {
                // Try graceful unmount
                let process = Process()
                process.launchPath = "/sbin/umount"
                process.arguments = [mountURL.path]
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus != 0 {
                        // Try force unmount if needed
                        let forceProcess = Process()
                        forceProcess.launchPath = "/sbin/umount"
                        forceProcess.arguments = ["-f", mountURL.path]
                        
                        try forceProcess.run()
                        forceProcess.waitUntilExit()
                    }
                    
                    // Update status for all servers using this mount
                    updateStatusForMountKey(mountKey, success: false)
                    
                    // Clean up mount resources
                    mountProcesses.removeValue(forKey: mountKey)
                    activeMounts.removeValue(forKey: mountKey)
                } catch {
                    print("Error unmounting \(mountKey): \(error)")
                }
            }
        }
        
        // Clear mapping
        serverMountMap.removeAll()
    }
    
    private func isDirectoryMounted(_ path: URL) -> Bool {
        let process = Process()
        process.launchPath = "/bin/df"
        process.arguments = [path.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("sshfs")
        } catch {
            return false
        }
    }
    
    private func checkMountHealth() {
        for (mountKey, mountURL) in activeMounts {
            if !isDirectoryMounted(mountURL) {
                updateStatusForMountKey(mountKey, success: false)
            }
        }
    }
    
    // MARK: - Cleanup
    private func cleanupTemporaryFiles() {
        for keyPath in temporaryKeyFiles {
            try? FileManager.default.removeItem(atPath: keyPath)
        }
        temporaryKeyFiles.removeAll()
    }
    
    @objc private func applicationWillTerminate() {
        // Clean up all mounts when app terminates
        unmountAllServers()
        
        // Clean up temporary files
        cleanupTemporaryFiles()
    }
    
    deinit {
        cancellables.removeAll()
        applicationWillTerminate()
    }
}
#endif
