import CitadelCore
import Foundation

class ConnectionPool {
    private var connections: [Connection] = []
    private let maxConnections: Int
    private let idleTimeout: TimeInterval = 300 // 5 minutes
    private let serverEntity: ServerEntity
    private let lock = NSLock()
    
    private struct Connection {
        let client: CitadelClient
        let sftp: CitadelSFTP
        var lastUsed: Date
        let isPermanent: Bool
    }
    
    init(serverEntity: ServerEntity) {
        self.serverEntity = serverEntity
        self.maxConnections = max(2, Int(serverEntity.thumbMax)) // At least 2 for hot connection + 1 dynamic
        
        // Start cleanup timer
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupIdleConnections()
        }
    }
    
    private func createConnection(permanent: Bool = false) throws -> Connection {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        let config = CitadelConfig()
        config.username = serverEntity.sftpUser ?? ""
        config.host = serverEntity.sftpHost ?? ""
        config.port = UInt16(serverEntity.sftpPort)
        
        if serverEntity.sftpUsesKey {
            let key = keychain["sftpKey" + (serverEntity.name ?? "")] ?? ""
            let password = keychain["sftpPassword" + (serverEntity.name ?? "")] ?? ""
            
            config.identityString = key
            config.identityPassphrase = password
        } else {
            let password = keychain["sftpPassword" + (serverEntity.name ?? "")] ?? ""
            config.password = password
        }
        
        let client = try CitadelClient(config)
        try client.connect()
        try client.authenticate()
        
        let sftp = try client.sftp()
        
        return Connection(
            client: client,
            sftp: sftp,
            lastUsed: Date(),
            isPermanent: permanent
        )
    }
    
    func getConnection() throws -> CitadelSFTP {
        lock.lock()
        defer { lock.unlock() }
        
        // First, try to find an existing non-busy connection
        if let index = connections.firstIndex(where: { !$0.sftp.isBusy }) {
            connections[index].lastUsed = Date()
            return connections[index].sftp
        }
        
        // If we haven't reached max connections, create a new one
        if connections.count < maxConnections {
            let connection = try createConnection()
            connections.append(connection)
            return connection.sftp
        }
        
        // If we're at max connections, wait for one to become available
        while true {
            if let index = connections.firstIndex(where: { !$0.sftp.isBusy }) {
                connections[index].lastUsed = Date()
                return connections[index].sftp
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    
    private func cleanupIdleConnections() {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        connections.removeAll { connection in
            guard !connection.isPermanent && !connection.sftp.isBusy else { return false }
            return now.timeIntervalSince(connection.lastUsed) > idleTimeout
        }
    }
    
    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        
        // Create permanent hot connection if we don't have one
        if !connections.contains(where: { $0.isPermanent }) {
            let hotConnection = try createConnection(permanent: true)
            connections.append(hotConnection)
        }
    }
    
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        for connection in connections {
            try? connection.client.disconnect()
        }
        connections.removeAll()
    }
}