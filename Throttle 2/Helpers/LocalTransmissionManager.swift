#if os(macOS)
import Foundation
import CoreData

/// Manages local Transmission daemon lifecycle
class LocalTransmissionManager: ObservableObject {
    static let shared = LocalTransmissionManager()
    
    @Published var isRunning = false
    @Published var currentPort: Int32 = 9091
    
    private var transmissionProcess: Process?
    
    private var transmissionPath: String? {
        // Try multiple potential paths for transmission-daemon
        let possiblePaths = [
            Bundle.main.path(forResource: "transmission-daemon", ofType: nil),
            Bundle.main.resourcePath?.appending("/transmission-daemon"),
            Bundle.main.bundlePath.appending("/Contents/Resources/transmission-daemon")
        ]
        
        for path in possiblePaths {
            if let path = path, FileManager.default.fileExists(atPath: path) {
                print("Found transmission-daemon at: \(path)")
                return path
            }
        }
        
        print("Could not find transmission-daemon in any of the expected locations:")
        for path in possiblePaths {
            print("  - \(path ?? "nil")")
        }
        
        return nil
    }
    
    private var transmissionRemotePath: String? {
        // Try multiple potential paths for transmission-remote
        let possiblePaths = [
            Bundle.main.path(forResource: "transmission-remote", ofType: nil),
            Bundle.main.resourcePath?.appending("/transmission-remote"),
            Bundle.main.bundlePath.appending("/Contents/Resources/transmission-remote")
        ]
        
        for path in possiblePaths {
            if let path = path, FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    /// Check if transmission-daemon binary exists and is executable
    private func validateTransmissionBinary() -> Bool {
        guard let path = transmissionPath else {
            print("transmission-daemon binary not found")
            return false
        }
        
        let fileManager = FileManager.default
        
        // Check if file exists
        guard fileManager.fileExists(atPath: path) else {
            print("transmission-daemon file does not exist at: \(path)")
            return false
        }
        
        // Check if file is executable
        guard fileManager.isExecutableFile(atPath: path) else {
            print("transmission-daemon is not executable at: \(path)")
            return false
        }
        
        print("transmission-daemon validated at: \(path)")
        return true
    }
    
    private init() {
        // Check if daemon is already running on startup
        checkDaemonStatus()
    }
    
    /// Find the local server entity
    private func findLocalServer() -> ServerEntity? {
        let context = DataManager.shared.viewContext
        let request: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
        request.predicate = NSPredicate(format: "isLocal == true")
        request.fetchLimit = 1
        
        do {
            let servers = try context.fetch(request)
            return servers.first
        } catch {
            print("Failed to fetch local server: \(error)")
            return nil
        }
    }
    
    /// Start the transmission daemon for the local server
    func startDaemon() {
        guard let server = findLocalServer() else {
            print("No local server found")
            return
        }
        
        startDaemon(for: server)
    }
    
    /// Start the transmission daemon for a specific server (internal method)
    private func startDaemon(for server: ServerEntity) {
        guard !isRunning else {
            print("Transmission daemon is already running")
            return
        }
        
        guard validateTransmissionBinary() else {
            print("transmission-daemon binary validation failed")
            return
        }
        
        guard let transmissionPath = transmissionPath else {
            print("Could not find transmission-daemon binary")
            return
        }
        
        print("Starting transmission daemon on port \(server.localPort)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: transmissionPath)
        
        // Build arguments based on server configuration
        var arguments = [
            "--foreground",
            "--port", "\(server.localPort)",
            "--config-dir", getConfigDirectory(for: server),
            "--log-level", "info"
        ]
        
        // Set interface binding and RPC access based on remote access setting
        if server.localRemoteAccess {
            // Allow all interfaces for remote access
            arguments.append(contentsOf: ["--bind-address-ipv4", "0.0.0.0"])
            // Allow access from any IP for remote access
            arguments.append(contentsOf: ["--allowed", "*.*.*.*"])
        } else {
            // Restrict to localhost only
            arguments.append(contentsOf: ["--bind-address-ipv4", "127.0.0.1"])
            // Only allow localhost access
            arguments.append(contentsOf: ["--allowed", "127.0.0.1,::1"])
        }
        
        // Add RPC authentication if remote access is enabled
        if server.localRemoteAccess {
            arguments.append(contentsOf: [
                "--rpc-authentication-required",
                "--rpc-username", getRemoteUsername(for: server),
                "--rpc-password", getRemotePassword(for: server)
            ])
        } else {
            arguments.append("--no-auth")
        }
        
        process.arguments = arguments
        
        // Set up output handling
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isRunning = false
                print("Transmission daemon terminated with exit code: \(process.terminationStatus)")
            }
        }
        
        do {
            try process.run()
            transmissionProcess = process
            isRunning = true
            currentPort = server.localPort
            
            // Update server status in Core Data
            server.localDaemonEnabled = true
            try? server.managedObjectContext?.save()
            
            print("Transmission daemon started successfully on port \(server.localPort)")
        } catch {
            print("Failed to start transmission daemon: \(error)")
        }
    }
    
    /// Stop the transmission daemon for the local server
    func stopDaemon() {
        guard let server = findLocalServer() else {
            print("No local server found")
            return
        }
        
        stopDaemon(for: server)
    }
    
    /// Stop the transmission daemon for a specific server (internal method)
    private func stopDaemon(for server: ServerEntity) {
        guard isRunning, let process = transmissionProcess else {
            print("No transmission daemon is currently running")
            return
        }
        
        print("Stopping transmission daemon")
        
        process.terminate()
        
        // Wait for termination with timeout
        DispatchQueue.global().async {
            let timeout = 10.0 // Give transmission more time to save settings
            let startTime = Date()
            
            while process.isRunning && Date().timeIntervalSince(startTime) < timeout {
                usleep(100000) // 0.1 seconds
            }
            
            if process.isRunning {
                print("Warning: Transmission daemon did not terminate within timeout")
                print("Allowing daemon to continue running to preserve settings")
                // Do not force kill - let transmission save its state
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.transmissionProcess = nil
                self?.isRunning = false
                
                // Update server status in Core Data
                server.localDaemonEnabled = false
                try? server.managedObjectContext?.save()
            }
        }
    }
    
    /// Check if daemon is currently running
    private func checkDaemonStatus() {
        // This is a simple check - in a real implementation you might want to
        // check if the process is actually responding to RPC calls
        isRunning = transmissionProcess?.isRunning ?? false
    }
    
    /// Get configuration directory for a server
    private func getConfigDirectory(for server: ServerEntity) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupport.appendingPathComponent("Throttle2/LocalServers/\(server.id?.uuidString ?? "default")")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        return configDir.path
    }
    
    /// Get remote access username for a server
    private func getRemoteUsername(for server: ServerEntity) -> String {
        return server.localRemoteUsername ?? "throttle"
    }
    
    /// Get remote access password for a server
    private func getRemotePassword(for server: ServerEntity) -> String {
        return server.localRemotePassword ?? "throttle2024"
    }
}

extension LocalTransmissionManager {
    /// Toggle daemon state for the local server
    func toggleDaemon() {
        guard let server = findLocalServer() else {
            print("No local server found")
            return
        }
        
        toggleDaemon(for: server)
    }
    
    /// Toggle daemon state for a specific server (internal method)
    private func toggleDaemon(for server: ServerEntity) {
        if isRunning {
            stopDaemon(for: server)
        } else {
            startDaemon(for: server)
        }
    }
    
    /// Restart daemon for the local server
    func restartDaemon() {
        guard let server = findLocalServer() else {
            print("No local server found")
            return
        }
        
        restartDaemon(for: server)
    }
    
    /// Restart daemon for a specific server (internal method)
    private func restartDaemon(for server: ServerEntity) {
        stopDaemon(for: server)
        
        // Give daemon time to fully stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.startDaemon(for: server)
        }
    }
    
    /// Test daemon connectivity using transmission-remote
    func testDaemonConnection(for server: ServerEntity) async -> Bool {
        guard let remotePath = transmissionRemotePath else {
            print("transmission-remote not found")
            return false
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: remotePath)
        
        var args = [
            "--port", "\(server.localPort)",
            "--session-info"
        ]
        
        // Add authentication if remote access is enabled
        if server.localRemoteAccess {
            args.append(contentsOf: [
                "--auth", "\(getRemoteUsername(for: server)):\(getRemotePassword(for: server))"
            ])
        }
        
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            return process.terminationStatus == 0 && output.contains("RPC version")
        } catch {
            print("Failed to test daemon connection: \(error)")
            return false
        }
    }
    
    /// Get daemon stats using transmission-remote
    func getDaemonStats(for server: ServerEntity) async -> [String: Any]? {
        guard let remotePath = transmissionRemotePath else {
            print("transmission-remote not found")
            return nil
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: remotePath)
        
        var args = [
            "--port", "\(server.localPort)",
            "--session-stats"
        ]
        
        // Add authentication if remote access is enabled
        if server.localRemoteAccess {
            args.append(contentsOf: [
                "--auth", "\(getRemoteUsername(for: server)):\(getRemotePassword(for: server))"
            ])
        }
        
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                // Parse the stats output
                var stats: [String: Any] = [:]
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains(":") {
                        let parts = line.components(separatedBy: ":")
                        if parts.count >= 2 {
                            let key = parts[0].trimmingCharacters(in: .whitespaces)
                            let value = parts[1].trimmingCharacters(in: .whitespaces)
                            stats[key] = value
                        }
                    }
                }
                return stats
            }
        } catch {
            print("Failed to get daemon stats: \(error)")
        }
        
        return nil
    }
}
#endif
