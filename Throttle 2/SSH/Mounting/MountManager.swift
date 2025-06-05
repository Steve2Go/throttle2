#if os(macOS)
import SwiftUI
import CoreData
import Combine
import KeychainAccess
import AppKit

// We'll keep this enum for compatibility
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
    private let keychain = Keychain(service: "srgim.throttle2")
    
    // Store mount info: server name → mount path
    private var mountedServers: [String: String] = [:]
    
    // Published properties
    @Published private(set) var servers: [ServerEntity] = []
    @Published private(set) var mountStatus: [String: Bool] = [:]
    @Published private(set) var mountErrors: [String: Error] = [:] // Keep for compatibility
    @AppStorage("sftpCompression") var sftpCompression: Bool = false
    @AppStorage("isMounted") private var isMounted: Bool = false
    
    // MARK: - Initialization
    init() {
        // Fetch servers initially
        refreshServers()
        
        // Setup observation of context changes
        NotificationCenter.default
            .publisher(for: .NSManagedObjectContextObjectsDidChange, object: dataManager.viewContext)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshServers()
            }
            .store(in: &cancellables)
        
        // Setup periodic health check
//        Timer.publish(every: 15, on: .main, in: .common)
//            .autoconnect()
//            .sink { [weak self] _ in
//                self?.checkMounts()
//            }
//            .store(in: &cancellables)
    }
    
    // MARK: - Server Management
    func refreshServers() {
        let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
        
        do {
            let fetchedServers = try dataManager.viewContext.fetch(fetchRequest)
            DispatchQueue.main.async {
                self.servers = fetchedServers
                self.mountAutoConnectServers()
            }
        } catch {
            print("Error fetching servers: \(error)")
        }
    }
    
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
    
    private func mountAutoConnectServers() {
        for server in servers where server.sftpBrowse {
            mountServer(server)
        }
    }
    
    // MARK: - Mount Path Methods
    
    // Helper to create a normalized mount key
    private func normalizedMountKey(host: String, path: String) -> String {
        var cleanPath = path
        if cleanPath.hasSuffix("/") {
            cleanPath = String(cleanPath.dropLast())
        }
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        let colonPath = cleanPath.replacingOccurrences(of: "/", with: ":")
        return "\(host):\(colonPath)"
    }

    // Update getMountPath to use normalizedMountKey
    func getMountPath(for server: ServerEntity) -> URL {
        guard let host = server.sftpHost, let path = server.pathServer else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("com.srgim.Throttle-2.sftp/unknown", isDirectory: true)
        }
        let mountKey = normalizedMountKey(host: host, path: path)
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("com.srgim.Throttle-2.sftp/\(mountKey)", isDirectory: true)
    }

    func getMountKey(for server: ServerEntity) -> String? {
        guard let host = server.sftpHost, let path = server.pathServer else {
            return nil
        }
        return normalizedMountKey(host: host, path: path)
    }
    
    // MARK: - Mount Operations
    func mountServer(_ server: ServerEntity) {
        guard let user = server.sftpUser,
              let host = server.sftpHost,
              let path = server.pathServer,
              !user.isEmpty, !host.isEmpty, !path.isEmpty else {
            updateMountStatus(server: server, mounted: false, error: MountError.invalidServerConfiguration)
            return
        }
        let mountKey = normalizedMountKey(host: host, path: path)
        if mountStatus[mountKey] == true {
            return
        }
        let mountPath = NSTemporaryDirectory() + "com.srgim.Throttle-2.sftp/\(mountKey)"
        let directoryURL = URL(fileURLWithPath: mountPath)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("Failed to create mount directory: \(error)")
            updateMountStatus(server: server, mounted: false, error: error, mountKey: mountKey)
            return
        }
        let process = Process()
        process.launchPath = "/bin/zsh"
        var sshfsOptions = "ServerAliveInterval=30,ServerAliveCountMax=6,reconnect,auto_cache,kernel_cache,location=Throttle"
        sshfsOptions += ",StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null"
        if !sftpCompression {
            sshfsOptions += ",Compression=no"
        }
        sshfsOptions += ",Ciphers=chacha20-poly1305@openssh.com"
        var command: String
        if server.sftpUsesKey {
            guard let name = server.name, let keyContent = keychain["sftpKey" + name] else {
                updateMountStatus(server: server, mounted: false, error: MountError.invalidServerConfiguration, mountKey: mountKey)
                return
            }
            let keyPath = createTemporaryKeyFile(content: keyContent, name: name)
            if keyPath.isEmpty {
                updateMountStatus(server: server, mounted: false, error: MountError.invalidServerConfiguration, mountKey: mountKey)
                return
            }
            sshfsOptions += ",PreferredAuthentications=publickey,IdentityFile=\(keyPath)"
            command = "/usr/local/bin/sshfs \(user)@\(host):\(path) \(mountPath) -o \(sshfsOptions)"
        } else {
            let name = server.name ?? ""
            let password = keychain["sftpPassword" + name] ?? ""
            sshfsOptions += ",password_stdin"
            command = "echo \(password) | /usr/local/bin/sshfs \(user)@\(host):\(path) \(mountPath) -o \(sshfsOptions)"
        }
        process.arguments = ["-c", command]
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let success = process.terminationStatus == 0
                if success {
                    self.updateMountStatus(server: server, mounted: true, mountKey: mountKey)
                    self.mountedServers[mountKey] = mountPath
                } else {
                    self.updateMountStatus(server: server, mounted: false, error: MountError.mountProcessFailed, mountKey: mountKey)
                }
            }
        }
        do {
            try process.run()
            updateMountStatus(server: server, mounted: true, mountKey: mountKey)
            mountedServers[mountKey] = mountPath
        } catch {
            print("Failed to start mount process: \(error)")
            updateMountStatus(server: server, mounted: false, error: error, mountKey: mountKey)
        }
    }
    
    func unmountServer(_ server: ServerEntity) {
        guard let host = server.sftpHost, let path = server.pathServer else {
            return
        }
        let mountKey = normalizedMountKey(host: host, path: path)
        guard let mountPath = mountedServers[mountKey] else {
            return
        }
        let process = Process()
        process.launchPath = "/sbin/umount"
        process.arguments = [mountPath]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let forceProcess = Process()
                forceProcess.launchPath = "/sbin/umount"
                forceProcess.arguments = ["-f", mountPath]
                try forceProcess.run()
                forceProcess.waitUntilExit()
            }
            updateMountStatus(server: server, mounted: false, mountKey: mountKey)
            mountedServers.removeValue(forKey: mountKey)
        } catch {
            print("Error unmounting \(mountKey): \(error)")
            updateMountStatus(server: server, mounted: false, error: MountError.unmountFailed, mountKey: mountKey)
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
        for server in servers {
            unmountServer(server)
        }
        mountedServers.removeAll()
        updateGlobalMountStatus()
    }
    
    // MARK: - Helper Methods
    private func createTemporaryKeyFile(content: String, name: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let keyFileName = "key_\(name)_\(UUID().uuidString)"
        let keyPath = tempDir.appendingPathComponent(keyFileName)
        
        do {
            try content.write(to: keyPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
            return keyPath.path
        } catch {
            print("Failed to create key file: \(error)")
            return ""
        }
    }
    
    private func updateMountStatus(server: ServerEntity, mounted: Bool, error: Error? = nil, mountKey: String? = nil) {
        let key = mountKey ?? server.name ?? "unknown"
        mountStatus[key] = mounted
        if let error = error {
            mountErrors[key] = error
        } else {
            mountErrors.removeValue(forKey: key)
        }
        updateGlobalMountStatus()
    }
    
    private func updateGlobalMountStatus() {
        // If any server is mounted, consider the global status as mounted
        isMounted = mountStatus.values.contains(true)
    }
    
//    private func checkMounts() {
//        // Check each mount to ensure it's still valid
//        for (serverName, mountPath) in mountedServers {
//            let stillMounted = isPathMounted(mountPath)
//            
//            // Update status if it changed
//            if mountStatus[serverName] != stillMounted {
//                if let server = servers.first(where: { $0.name == serverName }) {
//                    updateMountStatus(server: server, mounted: stillMounted)
//                }
//            }
//        }
//    }
    
    func isPathMounted(_ path: String) -> Bool {
        let mountPath = NSTemporaryDirectory() + "com.srgim.Throttle-2.sftp/\(path)"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: mountPath, isDirectory: &isDir)
        if exists && isDir.boolValue {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: mountPath) {
                return !contents.isEmpty
            }
        }
        return false
    }
    
    deinit {
        cancellables.removeAll()
    }
}
#endif
