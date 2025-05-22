import Foundation
import Network
import SwiftUI
//import Helpers.FilenameMapper

enum DataConnectionMode {
    case active
    case passive
}

// Manager for simple FTP servers
actor SimpleFTPServerManager {
    static let shared = SimpleFTPServerManager()
    
    var activeServers: [String: SimpleFTPServer] = [:]
    
    private init() {}
    
    func storeServer(_ server: SimpleFTPServer, withIdentifier identifier: String) {
        activeServers[identifier] = server
    }
    
    func getServer(withIdentifier identifier: String) -> SimpleFTPServer? {
        return activeServers[identifier]
    }
    
    func removeServer(withIdentifier identifier: String) async {
        let server = activeServers[identifier]
        activeServers.removeValue(forKey: identifier)
        if let server = server {
            server.stop()
        }
    }
    
    func removeAllServers() async {
        let servers = activeServers.values
        activeServers.removeAll()
        for server in servers {
            server.stop()
        }
    }
    
    func activeServersCount() -> Int {
        activeServers.count
    }
}

///// Simplified FTP server that allows anonymous access and focuses on file transfers
class SimpleFTPServer: ObservableObject {
    // FTP server
    private var listener: NWListener?
    
    // Configuration
    private let server: ServerEntity
    private let localPort: Int
    
    // Status
    @Published var isRunning = false
    @Published var status = "Stopped"
    @Published var connectionCount = 0
    
    // Active connections managed by an actor
    actor Connections {
        var activeConnections: [UUID: FTPSimpleHandler] = [:]
        func getAll() -> [FTPSimpleHandler] { Array(activeConnections.values) }
        func getInactiveIds(timeoutSeconds: Int) -> [UUID] {
            activeConnections.values.filter { $0.isInactive(timeoutSeconds: timeoutSeconds) }.map { $0.id }
        }
        func add(_ handler: FTPSimpleHandler, for id: UUID) {
            activeConnections[id] = handler
        }
        func remove(id: UUID) {
            activeConnections.removeValue(forKey: id)
        }
        func count() -> Int { activeConnections.count }
        func removeAll() -> [FTPSimpleHandler] {
            let handlers = Array(activeConnections.values)
            activeConnections.removeAll()
            return handlers
        }
        func get(id: UUID) -> FTPSimpleHandler? { activeConnections[id] }
    }
    private let connections = Connections()
    
    // Timer for closing idle connections
    private var idleTask: Task<Void, Never>? = nil
    
    init(server: ServerEntity, localPort: Int = 2121) {
        self.server = server
        self.localPort = localPort
    }
    
    deinit {
        print("SimpleFTPServer deinit called")
        
        // Clean up
        idleTask?.cancel()
        idleTask = nil
        
        // Only call synchronous cleanup here to avoid retain cycles
        listener?.cancel()
        listener = nil
        
        // Do NOT launch a Task here!
        print("SimpleFTPServer deinit completed")
    }
    
    func start() async throws {
        guard !isRunning else {
            return
        }
        
        await MainActor.run {
            status = "Starting..."
        }
        
        // 1. Test that we can connect to the server
        let testConnection = SSHConnection(server: server)
        try await testConnection.connect()
        
        // Test the connection with a simple command
        _ = try await testConnection.executeCommand("echo Connected")
        
        // Immediately disconnect the test connection
        await testConnection.disconnect()
        
        // 2. Create FTP server
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(localPort)))
        
        // Set up connection handler
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            
            let connectionId = UUID()
            let clientDescription = connection.endpoint.debugDescription
            print("New FTP connection from \(clientDescription)")
            
            // Close all existing connections before accepting the new one
            // self.closeAllExistingConnections()

            let clientHandler = FTPSimpleHandler(
                connection: connection,
                id: connectionId,
                server: self.server,
                onDisconnect: { [weak self] id in
                    self?.handleClientDisconnect(id: id)
                }
            )
            
            // Store the handler
            Task { [weak self] in
                await self?.connections.add(clientHandler, for: connectionId)
                let count = await self?.connections.count() ?? 0
                await MainActor.run {
                    self?.connectionCount = count
                    self?.status = "Active: \(count) connection(s)"
                    // Start idle timer if not running
                    self?.startIdleTimer()
                }
            }
            
            // Start the handler
            clientHandler.start()
        }
        
        // Set up listener state handler
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                print("FTP server ready on port \(self.localPort)")
                Task { @MainActor [weak self] in
                    self?.isRunning = true
                    self?.status = "Running on localhost:\(self?.localPort ?? 0)"
                    
                    // Start idle timer
                    self?.startIdleTimer()
                }
                
            case .failed(let error):
                print("FTP server failed: \(error)")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.status = "Failed: \(error.localizedDescription)"
                    self?.stopIdleTimer()
                }
                
            case .cancelled:
                print("FTP server cancelled")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.status = "Stopped"
                    self?.stopIdleTimer()
                }
                
            default:
                break
            }
        }
        
        // Start the listener
        listener?.start(queue: .global())
        
        // Show connection info
        print("FTP Server started:")
        print("  Host: localhost")
        print("  Port: \(localPort)")
    }
    
    // Start idle timer to check for inactive connections
    private func startIdleTimer() {
        // Only start if not already running
        if idleTask == nil {
            idleTask = Task.detached { [weak self] in
                guard let self = self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                    await self.checkForInactiveConnectionsAsync()
                }
            }
        }
    }
    
    // Stop idle timer
    private func stopIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }
    
    // Check for inactive connections and close them
    @MainActor
    private func checkForInactiveConnectionsAsync() async {
        let inactiveIds = await connections.getInactiveIds(timeoutSeconds: 300)
        // Close inactive connections
        for id in inactiveIds {
            print("Closing inactive connection \(id)")
            if let handler = await connections.get(id: id) {
                handler.stop()
                await connections.remove(id: id)
            }
            let count = await connections.count()
            await MainActor.run {
                connectionCount = count
                status = count > 0 ? "Active: \(count) connection(s)" : "Running on localhost:\(localPort)"
            }
        }
    }
    
    private func closeAllExistingConnections() {
        print("Closing all existing connections for new request")
        
        Task { [weak self] in
            guard let self = self else { return }
            let handlers = await self.connections.removeAll()
            for handler in handlers {
                handler.forceCloseForNewRequest()
            }
            await MainActor.run {
                self.connectionCount = 0
                self.status = "Running on localhost:\(self.localPort) - New connection incoming"
            }
        }
    }
    
    private func handleClientDisconnect(id: UUID) {
        Task { [weak self] in
            guard let self = self else { return }
            await self.connections.remove(id: id)
            let count = await self.connections.count()
            await MainActor.run {
                self.connectionCount = count
                self.status = count > 0 ? "Active: \(count) connection(s)" : "Running on localhost:\(self.localPort)"
            }
        }
    }
    
    func stop() {
        print("Stopping FTP server...")
        
        // Stop the idle timer
        stopIdleTimer()
        
        // Stop the listener first
        listener?.cancel()
        listener = nil
        
        Task { [weak self] in
            guard let self = self else { return }
            let handlers = await self.connections.removeAll()
            for handler in handlers {
                handler.stop()
            }
            await MainActor.run {
                self.isRunning = false
                self.connectionCount = 0
                self.status = "Stopped"
            }
        }
        
        print("FTP server stopped")
    }
}


/// Simplified FTP client handler focused on file transfers
class FTPSimpleHandler : @unchecked Sendable {
    // Network
    private let connection: NWConnection
    let id: UUID
    
    // SFTP backend - now using server info instead of a shared connection
    private let server: ServerEntity
    private var activeSSHConnection: SSHConnection?
    
    // State
    private var isAuthenticated = true // Always authenticated
    private var currentDirectory = "/"
    private var dataMode = DataConnectionMode.passive
    private var passiveListener: NWListener?
    private var dataConnection: NWConnection?
    private var dataHost: String = ""
    private var dataPort: UInt16 = 0
    private var restPosition: UInt64 = 0
    private var restEnabled = false
    
    // Command buffer to handle partial commands
    private var commandBuffer = Data()
    
    // Callback for disconnection
    private let onDisconnect: (UUID) -> Void
    
    // Flag to track if we're already in cleanup
    private var isCleaningUp = false
    
    // Timestamp of last activity
    private var lastActivityTime = Date()
    
    // Task tracking for better cleanup
    private var activeTask: Task<Void, Never>?
    
    // State for rename
    private var renameFromPath: String? = nil
    
    // Initializer
    init(connection: NWConnection, id: UUID, server: ServerEntity,
         onDisconnect: @escaping (UUID) -> Void) {
        self.connection = connection
        self.id = id
        self.server = server
        self.onDisconnect = onDisconnect
    }
    
    // Check if this connection is inactive
    func isInactive(timeoutSeconds: Int) -> Bool {
        return -lastActivityTime.timeIntervalSinceNow > Double(timeoutSeconds)
    }
    
    // Start handling the connection
    func start() {
        // Set up state handler
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                print("FTP client connected")
                self.sendResponse(220, "Anonymous FTP server ready")
                self.receiveCommands()
                
            case .failed(let error):
                print("FTP client connection failed: \(error)")
                self.cleanup()
                
            case .cancelled:
                print("FTP client connection cancelled")
                self.cleanup()
                
            default:
                break
            }
        }
        
        // Start the connection
        connection.start(queue: .global())
    }
    
    // Stop handling the connection
    func stop() {
        print("Stopping FTP handler \(id)...")
        // Cancel any active tasks
        activeTask?.cancel()
        activeTask = nil
        // Close any active SSH connection
        if let connection = activeSSHConnection {
            print("Closing active SSH connection for FTP handler \(id)")
            let conn = connection
            activeSSHConnection = nil
            Task { [weak self] in
                guard self != nil else { return }
                await conn.disconnect()
            }
        }
        passiveListener?.cancel()
        passiveListener = nil
        dataConnection?.cancel()
        dataConnection = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        print("FTP handler \(id) stopped.")
    }
    
    // Request closing - to be called when a new request arrives
    func forceCloseForNewRequest() {
        print("Forcing close of FTP client connection \(id) for new request")
        // Set a flag to prevent recursive cleanup calls
        if isCleaningUp { return }
        isCleaningUp = true
        
        // Cancel any active tasks
        activeTask?.cancel()
        activeTask = nil
        
        // Close any active SSH connection
        if let connection = activeSSHConnection {
            print("Closing active SSH connection for FTP handler \(id)")
            let conn = connection
            activeSSHConnection = nil
            
            Task { [weak self] in
                guard self != nil else { return }
                await conn.disconnect()
            }
        }
        
        // Close all connections
        passiveListener?.cancel()
        passiveListener = nil
        dataConnection?.cancel()
        dataConnection = nil
        connection.cancel()
        
        // Trigger the disconnect callback
        onDisconnect(id)
    }
    
    // Clean up resources
    private func cleanup() {
        print("Cleaning up FTP handler \(id)...")
        // Prevent multiple cleanups
        if isCleaningUp { return }
        isCleaningUp = true
        stop()
        onDisconnect(id)
        print("Cleanup complete for FTP handler \(id)")
    }
    
    // Create a new SSH connection
    private func createSSHConnection() async throws -> SSHConnection {
        print("Creating new SSH connection for FTP handler \(id)")
        do {
            let connection = SSHConnection(server: server)
            try await connection.connect()
            return connection
        } catch {
            // Check for max connections error (customize this check as needed)
            let nsError = error as NSError
            if nsError.localizedDescription.contains("max connections") || nsError.localizedDescription.contains("too many") {
                // Send FTP 421 response and cleanup
                sendResponse(421, "Max connections reached, try again later")
                cleanup()
                throw error
            } else {
                throw error
            }
        }
    }
    
    // Get or create an SSH connection for a command
    private func getSSHConnection() async throws -> SSHConnection {
        if let conn = activeSSHConnection {
            return conn
        }
        
        let connection = try await createSSHConnection()
        activeSSHConnection = connection
        return connection
    }
    
    // Release an SSH connection after use
    private func releaseSSHConnection() {
        if let connection = activeSSHConnection {
            print("Releasing SSH connection for FTP handler \(id)")
            let conn = connection
            activeSSHConnection = nil
            
            Task {
                await conn.disconnect()
            }
        }
    }
    
    // Receive FTP commands - simplified to avoid range errors
    private func receiveCommands() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isCleaningUp else { return }
            
            if let data = data, !data.isEmpty {
                // Update activity timestamp
                self.lastActivityTime = Date()
                
                // Append to command buffer
                self.commandBuffer.append(data)
                
                // Process commands using safer string-based approach
                self.processCommandBuffer()
                
                // Continue receiving
                self.receiveCommands()
            } else if isComplete || error != nil {
                print("Connection closed or error: \(String(describing: error))")
                self.cleanup()
            }
        }
    }
    
    // Process the command buffer with a safer string-based approach
    private func processCommandBuffer() {
        // Convert buffer to string for easier processing
        if let commandString = String(data: commandBuffer, encoding: .utf8) {
            // Split by CRLF
            let commands = commandString.components(separatedBy: "\r\n")
            
            // If we have complete commands (more than one component or ends with CRLF)
            if commands.count > 1 || commandString.hasSuffix("\r\n") {
                // Process all but potentially the last component (which might be incomplete)
                for i in 0..<commands.count-1 {
                    let command = commands[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !command.isEmpty {
                        handleCommand(command)
                    }
                }
                
                // If the string ends with CRLF, process the last component too
                if commandString.hasSuffix("\r\n") {
                    let lastCommand = commands.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !lastCommand.isEmpty {
                        handleCommand(lastCommand)
                    }
                    
                    // Clear buffer completely
                    commandBuffer.removeAll()
                } else {
                    // Keep only the last incomplete command in the buffer
                    commandBuffer = Data((commands.last ?? "").utf8)
                }
            }
        }
    }
    
    // Send FTP response with improved error handling
    private func sendResponse(_ code: Int, _ message: String) {
        // Update activity timestamp
        lastActivityTime = Date()
        
        let response = "\(code) \(message)\r\n"
        let data = Data(response.utf8)
        
        print("FTP response: \(response.trimmingCharacters(in: .newlines))")
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                if case let .posix(posixErrorCode) = error, posixErrorCode == .EPIPE {
                    print("Client disconnected before response was sent")
                } else {
                    print("Error sending response: \(error)")
                    self?.cleanup()
                }
            }
        })
    }
    
    // Send multi-line response
    private func sendMultilineResponse(_ code: Int, _ lines: [String]) {
        // Update activity timestamp
        lastActivityTime = Date()
        
        guard !lines.isEmpty else { return }
        
        var response = ""
        
        // Format according to RFC 959
        if lines.count == 1 {
            response = "\(code) \(lines[0])\r\n"
        } else {
            for (index, line) in lines.enumerated() {
                if index == lines.count - 1 {
                    response += "\(code) \(line)\r\n"
                } else {
                    response += "\(code)-\(line)\r\n"
                }
            }
        }
        
        let data = Data(response.utf8)
        print("FTP multi-line response: \(code)")
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                if case let .posix(posixErrorCode) = error, posixErrorCode == .EPIPE {
                    print("Client disconnected before multi-line response was sent")
                } else {
                    print("Error sending multi-line response: \(error)")
                    self?.cleanup()
                }
            }
        })
    }
    
    // Handle FTP command
    private func handleCommand(_ commandLine: String) {
        print("FTP command: \(commandLine)")
        
        // Update activity timestamp
        lastActivityTime = Date()
        
        // Parse command and arguments
        let parts = commandLine.split(separator: " ", maxSplits: 1)
        let command = parts.first?.uppercased() ?? ""
        let argument = parts.count > 1 ? String(parts[1]) : ""
        
        // Handle command - simplified set focusing on file transfers
        switch command {
        // Authentication commands - auto-accept
        case "USER":
            sendResponse(331, "User name okay, need password")
        case "PASS":
            sendResponse(230, "User logged in")
        
        // Basic info commands
        case "SYST":
            sendResponse(215, "UNIX Type: L8")
        case "PWD":
            sendResponse(257, "\"\(normalizePath(currentDirectory))\" is current directory")
        case "TYPE":
            sendResponse(200, "Type set to \(argument)")
            
        // File information commands
        case "SIZE":
            // Create a new task for this command
            activeTask = Task {
                await handleSize(path: argument)
                // Release SSH connection after command completes
                self.releaseSSHConnection()
            }
        case "DELE":
            // Create a new task for this command
            activeTask = Task {
                await handleDelete(argument)
                // Release SSH connection after command completes
                self.releaseSSHConnection()
            }
            
        // Data connection commands
        case "PASV":
            handlePassive()
        case "PORT":
            handlePort(argument)
        case "EPSV":
            handleExtendedPassive(argument)
            
        // Navigation and listing commands
        case "CWD":
            // Create a new task for this command
            activeTask = Task {
                await handleChangeDirectory(argument)
                // Release SSH connection after command completes
                self.releaseSSHConnection()
            }
        case "CDUP":
            // Create a new task for this command
            activeTask = Task {
                await handleChangeDirectory("..")
                // Release SSH connection after command completes
                self.releaseSSHConnection()
            }
        case "LIST":
            // Create a new task for this command
            activeTask = Task {
                await handleList(argument)
                // Connection will be released in the handler after data transfer
            }
            
        // File transfer commands - these are the important ones
        case "RETR":
            // Create a new task for this command
            activeTask = Task {
                await handleRetrieve(argument)
                // Connection will be released in the handler after data transfer
            }
            
        case "REST":
            handleRest(argument)
            
        case "STOR":
            // Create a new task for this command
            activeTask = Task {
                await handleStore(argument)
                // Connection will be released in the handler after data transfer
            }
            
        // Session end
        case "QUIT":
            sendResponse(221, "Goodbye")
            cleanup()
            
        // Extended features
        case "FEAT":
            // List supported features
            sendMultilineResponse(211, [
                "Features:",
                " SIZE",
                " PASV",
                " UTF8",
                " EPSV",
                "End"
            ])
            
        // Respond OK to common commands we don't need to fully implement
        case "OPTS", "MODE", "STRU", "NOOP", "STAT":
            sendResponse(200, "Command OK")
            
        // For anything else
        case "RMD":
            // Create a new task for this command
            activeTask = Task {
                await handleRemoveDirectory(argument)
                // Release SSH connection after command completes
                self.releaseSSHConnection()
            }
            
        case "MKD":
            // Create a new task for this command
            activeTask = Task {
                await handleMakeDirectory(argument)
                self.releaseSSHConnection()
            }
        case "RNFR":
            // Store the rename-from path for the next RNTO
            let realName = FilenameMapper.decodePath(argument) ?? argument
            renameFromPath = realName
            sendResponse(350, "File or directory exists, ready for destination name")
        case "RNTO":
            // Create a new task for this command
            activeTask = Task {
                await handleRenameTo(argument)
                self.releaseSSHConnection()
            }
            
        case "ABOR":
            // Abort the current transfer if any
            if let task = activeTask {
                task.cancel()
                activeTask = nil
                dataConnection?.cancel()
                dataConnection = nil
                sendResponse(226, "Transfer aborted")
            } else {
                sendResponse(226, "No transfer to abort")
            }
            
        default:
            sendResponse(502, "Command not implemented")
        }
    }
    
    private func handleRest(_ argument: String) {
        if let position = UInt64(argument) {
            restPosition = position
            restEnabled = true
            sendResponse(350, "Restarting at \(position). Send RETR to initiate transfer.")
        } else {
            sendResponse(501, "Invalid REST parameter")
        }
    }
    
    // Handle directory change - now with async/await pattern
    private func handleChangeDirectory(_ path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let targetPath: String
        if realName.hasPrefix("/") {
            targetPath = realName
        } else {
            targetPath = currentDirectory + (currentDirectory.hasSuffix("/") ? "" : "/") + realName
        }
        let normalizedTarget = normalizePath(targetPath)
        do {
            let sshConnection = try await getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            let attrs = try await sftp.getAttributes(at: normalizedTarget)
            if SSHConnection.isDirectory(attributes: attrs) {
                currentDirectory = normalizedTarget
                sendResponse(250, "Directory changed to \(currentDirectory)")
            } else {
                sendResponse(550, "Not a directory")
            }
        } catch {
            print("Error checking directory via SFTP: \(error)")
            sendResponse(550, "Directory not found or inaccessible")
        }
    }
    
    // Normalize a path
    private func normalizePath(_ path: String) -> String {
        let components = path.split(separator: "/")
        var stack: [String] = []
        
        for component in components {
            if component == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                }
            } else if component != "." && !component.isEmpty {
                stack.append(String(component))
            }
        }
        
        let result = "/" + stack.joined(separator: "/")
        return result.isEmpty ? "/" : result
    }
    
    // Handle SIZE command with reliable shell commands
    private func handleSize(path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fullPath = realName.hasPrefix("/") ? realName : "\(currentDirectory)/\(realName)"
        let normalizedPath = normalizePath(fullPath)
        do {
            let sshConnection = try await getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            let command = "stat -c %s \"\(normalizedPath)\" 2>/dev/null || stat -f %z \"\(normalizedPath)\" 2>/dev/null || echo 'notfound'"
            let (_, output) = try await sshConnection.executeCommand(command)
            let sizeStr = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if sizeStr == "notfound" {
                sendResponse(550, "File not found")
            } else if let size = Int(sizeStr) {
                sendResponse(213, "\(size)")
            } else {
                sendResponse(550, "Could not determine file size")
            }
        } catch {
            print("Error getting file size: \(error)")
            sendResponse(550, "Error getting file size")
        }
    }
    
    // Handle PASV command
    private func handlePassive() {
        // Cancel any existing passive listener
        passiveListener?.cancel()
        passiveListener = nil
        dataConnection = nil
        
        // Create a passive listener
        let parameters = NWParameters.tcp
        
        // Add a timeout for data connections
        parameters.multipathServiceType = .handover
        
        do {
            // Try to bind to fixed ports (better for firewall rules)
            var listener: NWListener?
            var port: UInt16 = 0
            
            // Try specific ports first - choose a range less likely to have conflicts
            for tryPort in 60000...60100 {
                do {
                    let endpoint = NWEndpoint.Port(rawValue: UInt16(tryPort))
                    listener = try NWListener(using: parameters, on: endpoint!)
                    port = UInt16(tryPort)
                    print("Successfully bound to port \(port) for PASV")
                    break
                } catch {
                    // Continue trying if this port fails
                    continue
                }
            }
            
            // If we couldn't bind to any specific port, try letting the system assign one
            if listener == nil {
                listener = try NWListener(using: parameters)
                if let assignedPort = listener?.port?.rawValue {
                    port = assignedPort
                    print("System assigned port \(port) for PASV")
                }
            }
            
            guard let listener = listener, port > 0 else {
                throw NSError(domain: "FTPServer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to get valid port for passive mode"])
            }
            
            passiveListener = listener
            
            // Calculate the passive mode response
            let portHi = Int(port / 256)
            let portLo = Int(port % 256)
            
            let ipParts = [127, 0, 0, 1] // Localhost
            let pasvResponse = ipParts.map(String.init).joined(separator: ",") + ",\(portHi),\(portLo)"
            sendResponse(227, "Entering Passive Mode (\(pasvResponse))")
            
            // Set up listener for data connection
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else {
                    listener.cancel()
                    return
                }
                
                // Accept only one connection
                listener.cancel()
                self.passiveListener = nil
                
                self.dataConnection = connection
                
                // Configure the connection
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        print("FTP data connection established (passive)")
                    }
                }
                
                connection.start(queue: .global())
            }
            
            // Set up listener state handler
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("FTP passive listener ready on port \(port)")
                case .failed(let error):
                    print("FTP passive listener failed: \(error)")
                default:
                    break
                }
            }
            
            // Start the listener
            listener.start(queue: .global())
        } catch {
            print("Error setting up passive mode: \(error)")
            sendResponse(425, "Cannot open data connection - \(error.localizedDescription)")
        }
    }
    
    // Handle EPSV command (Extended Passive Mode)
    private func handleExtendedPassive(_ argument: String) {
        if argument.uppercased() == "ALL" {
            // Client requesting to use EPSV exclusively
            sendResponse(200, "EPSV ALL command successful")
            return
        }
        
        // Cancel any existing passive listener
        passiveListener?.cancel()
        passiveListener = nil
        dataConnection = nil
        
        // Create a new listener for EPSV
        let parameters = NWParameters.tcp
        do {
            // Try to bind to fixed ports (better for firewall rules)
            var listener: NWListener?
            var port: UInt16 = 0
            
            // Try specific ports first - choose a range less likely to have conflicts
            for tryPort in 60000...60100 {
                do {
                    let endpoint = NWEndpoint.Port(rawValue: UInt16(tryPort))
                    listener = try NWListener(using: parameters, on: endpoint!)
                    port = UInt16(tryPort)
                    print("Successfully bound to port \(port) for EPSV")
                    break
                } catch {
                    // Continue trying if this port fails
                    continue
                }
            }
            
            // If we couldn't bind to any specific port, try letting the system assign one
            if listener == nil {
                listener = try NWListener(using: parameters)
                if let assignedPort = listener?.port?.rawValue {
                    port = assignedPort
                    print("System assigned port \(port) for EPSV")
                }
            }
            
            guard let listener = listener, port > 0 else {
                throw NSError(domain: "FTPServer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to get valid port for extended passive mode"])
            }
            
            passiveListener = listener
            
            // Set up listener for data connection
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else {
                    listener.cancel()
                    return
                }
                
                // Accept only one connection
                listener.cancel()
                self.passiveListener = nil
                
                self.dataConnection = connection
                
                // Configure the connection
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        print("FTP data connection established (EPSV)")
                    }
                }
                
                connection.start(queue: .global())
            }
            
            // Set up listener state handler
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("FTP extended passive listener ready on port \(port)")
                case .failed(let error):
                    print("FTP extended passive listener failed: \(error)")
                default:
                    break
                }
            }
            
            // Start the listener
            listener.start(queue: .global())
            
            // Send the EPSV response (format: |||port|)
            sendResponse(229, "Entering Extended Passive Mode (|||" + String(port) + "|)")
        } catch {
            print("Error setting up extended passive mode: \(error)")
            sendResponse(425, "Cannot open data connection - \(error.localizedDescription)")
        }
    }
    
    // Handle PORT command
    private func handlePort(_ argument: String) {
        let parts = argument.split(separator: ",").map { String($0) }
        if parts.count == 6 {
            let ipParts = parts[0..<4]
            let portHi = Int(parts[4]) ?? 0
            let portLo = Int(parts[5]) ?? 0
            
            dataHost = ipParts.joined(separator: ".")
            dataPort = UInt16(portHi * 256 + portLo)
            dataMode = .active
            
            sendResponse(200, "PORT command successful")
        } else {
            sendResponse(501, "Invalid PORT command")
        }
    }
    
    // Handle LIST command
    private func handleList(_ path: String) async {
        // Determine which directory to list
        let targetPath: String
        if path.isEmpty {
            targetPath = currentDirectory
        } else if path.hasPrefix("/") {
            targetPath = path
        } else {
            targetPath = currentDirectory + (currentDirectory.hasSuffix("/") ? "" : "/") + path
        }

        // Send status
        sendResponse(150, "Opening data connection for directory listing")

        // Set up data connection
        await setupDataConnection { [weak self] connection in
            guard let self = self else { return }

            Task {
                do {
                    // Get a fresh SSH connection
                    let sshConnection = try await self.getSSHConnection()

                    // Use SFTP to get directory contents as [FileItem]
                    let items: [FileItem] = try await sshConnection.listDirectory(path: targetPath)

                    // Format as Unix-style LIST output, but use simplified names
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "MMM dd HH:mm"

                    let lines = items.map { item -> String in
                        let perms = item.isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
                        let nlink = "1"
                        let owner = "user"
                        let group = "group"
                        let size = String(item.size ?? 0)
                        let dateStr = formatter.string(from: item.modificationDate)
                        let simpleName = FilenameMapper.encodePath(item.name)
                        return "\(perms) \(nlink) \(owner) \(group) \(size) \(dateStr) \(simpleName)"
                    }
                    let output = lines.joined(separator: "\r\n") + "\r\n"
                    let data = Data(output.utf8)

                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            print("Error sending directory listing: \(error)")
                        }
                        connection.cancel()
                        self.sendResponse(226, "Directory send OK")
                        self.releaseSSHConnection()
                    })
                } catch {
                    print("Error listing directory: \(error)")
                    connection.cancel()
                    self.sendResponse(550, "Failed to list directory")
                    self.releaseSSHConnection()
                }
            }
        }
    }
    
    // Handle RETR command with direct streaming using SFTP
    private func handleRetrieve(_ path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fullPath: String
        if realName.hasPrefix("/") {
            fullPath = realName
        } else {
            fullPath = currentDirectory + (currentDirectory.hasSuffix("/") ? "" : "/") + realName
        }
        let normalizedPath = normalizePath(fullPath)
        
        // Check if REST is enabled
        let hasRestPosition = restEnabled
        let startPosition = restPosition
        
        // Reset REST flag after use
        restEnabled = false
        
        print("Processing RETR for path: \(normalizedPath)\(hasRestPosition ? " starting at position \(startPosition)" : "")")
        
        // Send status
        sendResponse(150, "Opening data connection for file transfer\(hasRestPosition ? " (restarting from position \(startPosition))" : "")")
        
        // Start data connection
        await setupDataConnection { [weak self] connection in
            guard let self = self else { return }
            Task {
                await self.transferFileOverConnection(connection: connection, normalizedPath: normalizedPath, hasRestPosition: hasRestPosition, startPosition: startPosition)
            }
        }
    }

    private func transferFileOverConnection(connection: NWConnection, normalizedPath: String, hasRestPosition: Bool, startPosition: UInt64) async {
        do {
            // Get a fresh SSH connection
            let sshConnection = try await self.getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            let file = try await sftp.openFile(filePath: normalizedPath, flags: .read)
            defer { Task { try? await file.close() } }
            
            // Get file size for progress reporting
            let attributes = try await file.readAttributes()
            let totalSize = attributes.size ?? 0
            
            // Start reading from the correct offset
            var offset: UInt64 = hasRestPosition ? startPosition : 0
            let chunkSize: UInt32 = 32768 // 32 KB
            var totalSent = 0
            
            while true {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let data = try await file.read(from: offset, length: chunkSize)
                if data.readableBytes == 0 {
                    break // End of file
                }
                let dataToSend = Data(buffer: data)
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        connection.send(content: dataToSend, completion: .contentProcessed { error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        })
                    }
                } catch {
                    print("Error sending data: \(error)")
                    break
                }
                totalSent += dataToSend.count
                offset += UInt64(dataToSend.count)
                // Optionally log progress
                if totalSize > 0 {
                    let progress = Double(totalSent + (hasRestPosition ? Int(startPosition) : 0)) / Double(totalSize) * 100
                    if Int(progress) % 5 == 0 {
                        print("Transfer progress: \(Int(progress))% (\(totalSent + (hasRestPosition ? Int(startPosition) : 0))/\(totalSize))")
                    }
                } else if totalSent % (5 * 1024 * 1024) < dataToSend.count {
                    print("Transferred \(totalSent) bytes (starting at position \(hasRestPosition ? Int(startPosition) : 0))")
                }
            }
            // Close the data connection when done
            connection.cancel()
            // Send completion status
            if totalSent > 0 {
                self.sendResponse(226, "Transfer complete")
                print("RETR completed successfully: \(totalSent) bytes transferred (starting at \(hasRestPosition ? Int(startPosition) : 0))")
            } else {
                self.sendResponse(550, "Failed to transfer file")
                print("RETR failed: No data transferred")
            }
            // Release SSH connection after transfer completes
            self.releaseSSHConnection()
        } catch {
            print("Error retrieving file: \(error)")
            self.sendResponse(550, "Error retrieving file: \(error.localizedDescription)")
            connection.cancel()
            // Release SSH connection on error
            self.releaseSSHConnection()
        }
    }
    
    // Handle STOR command using SFTP file upload
    private func handleStore(_ path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fullPath: String
        if realName.hasPrefix("/") {
            fullPath = realName
        } else {
            fullPath = currentDirectory + (currentDirectory.hasSuffix("/") ? "" : "/") + realName
        }
        let normalizedPath = normalizePath(fullPath)
        
        // Send status
        sendResponse(150, "Opening data connection for file upload")
        
        // Start data connection
        await setupDataConnection { [weak self] connection in
            guard let self = self else { return }
            
            // Create a temporary file to store the upload
            let tempDir = FileManager.default.temporaryDirectory
            let tempFilePath = tempDir.appendingPathComponent(UUID().uuidString)
            let tempFileURL = tempFilePath
            
            // Create the file
            FileManager.default.createFile(atPath: tempFilePath.path, contents: nil)
            let fileHandle = try? FileHandle(forWritingTo: tempFileURL)
            
            // Function to receive data
            func receiveAndWrite() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty, let fileHandle = fileHandle {
                        // Write data to the temp file
                        try? fileHandle.write(contentsOf: data)
                        // Continue receiving
                        receiveAndWrite()
                    } else if isComplete || error != nil {
                        // Close the file handle
                        try? fileHandle?.close()
                        // Upload the file to server using SFTP
                        Task {
                            do {
                                // Get a fresh SSH connection
                                let sshConnection = try await self.getSSHConnection()
                                // Use the uploadFile method from SSHConnection which works with local URL
                                try await sshConnection.uploadFile(localURL: tempFileURL, remotePath: normalizedPath)
                                // Clean up temp file
                                try? FileManager.default.removeItem(at: tempFileURL)
                                // Send completion status
                                self.sendResponse(226, "Transfer complete")
                                // Release SSH connection after transfer completes
                                self.releaseSSHConnection()
                            } catch {
                                print("Error uploading file: \(error)")
                                self.sendResponse(550, "Error uploading file: \(error.localizedDescription)")
                                // Clean up temp file
                                try? FileManager.default.removeItem(at: tempFileURL)
                                // Release SSH connection on error
                                self.releaseSSHConnection()
                            }
                        }
                        // Close the connection
                        connection.cancel()
                    }
                }
            }
            // Start receiving data
            receiveAndWrite()
        }
    }
    
    // Handle DELE command using SFTP
    private func handleDelete(_ path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fullPath = realName.hasPrefix("/") ? realName : "\(currentDirectory)/\(realName)"
        let normalizedPath = normalizePath(fullPath)
        do {
            let sshConnection = try await getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            try await sftp.remove(at: normalizedPath)
            sendResponse(250, "File deleted")
        } catch {
            print("Error deleting file: \(error)")
            sendResponse(550, "Error deleting file: \(error.localizedDescription)")
        }
    }
    
    // Handle RMD command using SFTP
    private func handleRemoveDirectory(_ path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fullPath = realName.hasPrefix("/") ? realName : "\(currentDirectory)/\(realName)"
        let normalizedPath = normalizePath(fullPath)
        do {
            let sshConnection = try await getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            try await sftp.rmdir(at: normalizedPath)
            sendResponse(250, "Directory removed")
        } catch {
            print("Error removing directory: \(error)")
            sendResponse(550, "Error removing directory: \(error.localizedDescription)")
        }
    }
    
    // Set up data connection
    private func setupDataConnection(completion: @escaping (NWConnection) -> Void) async {
        if dataMode == .passive {
            // In passive mode, we wait for the client to connect to us
            if let connection = dataConnection {
                print("Using existing data connection")
                completion(connection)
            } else {
                print("Waiting for client to connect to passive port...")
                
                // Set a timeout for the connection
                DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    if let self = self, let connection = self.dataConnection {
                        // Got a connection within the timeout
                        print("Data connection established within timeout")
                        completion(connection)
                    } else if let self = self {
                        print("Timed out waiting for data connection")
                        self.sendResponse(425, "No data connection established within timeout")
                        
                        // Release SSH connection if we time out
                        self.releaseSSHConnection()
                    }
                }
            }
        } else {
            // In active mode, we connect to the client
            if let port = NWEndpoint.Port(rawValue: dataPort) {
                print("Connecting to client in active mode at \(dataHost):\(dataPort)")
                
                let connection = NWConnection(
                    host: NWEndpoint.Host(dataHost),
                    port: port,
                    using: .tcp
                )
                
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        print("FTP data connection established (active)")
                        completion(connection)
                    case .failed(let error):
                        print("FTP data connection failed: \(error)")
                    case .cancelled:
                        print("FTP data connection cancelled")
                    default:
                        break
                    }
                }
                
                connection.start(queue: .global())
                dataConnection = connection
            } else {
                print("Invalid data port: \(dataPort)")
                sendResponse(425, "Cannot open data connection: invalid port")
                
                // Release SSH connection if setup fails
                releaseSSHConnection()
            }
        }
    }
    
    // Handle MKD command using SFTP
    private func handleMakeDirectory(_ path: String) async {
        let realName = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fullPath = realName.hasPrefix("/") ? realName : "\(currentDirectory)/\(realName)"
        let normalizedPath = normalizePath(fullPath)
        do {
            let sshConnection = try await getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            try await sftp.createDirectory(atPath: normalizedPath)
            sendResponse(257, "\"\(normalizedPath)\" directory created")
        } catch {
            print("Error creating directory: \(error)")
            sendResponse(550, "Error creating directory: \(error.localizedDescription)")
        }
    }
    
    // Handle RNTO command using SFTP
    private func handleRenameTo(_ path: String) async {
        guard let from = renameFromPath else {
            sendResponse(503, "Bad sequence of commands")
            return
        }
        let realFrom = (FilenameMapper.decodePath(from) ?? from).precomposedStringWithCanonicalMapping
        let realTo = (FilenameMapper.decodePath(path) ?? path).precomposedStringWithCanonicalMapping
        let fromPath = realFrom.hasPrefix("/") ? realFrom : "\(currentDirectory)/\(realFrom)"
        let toPath = realTo.hasPrefix("/") ? realTo : "\(currentDirectory)/\(realTo)"
        let normalizedFrom = normalizePath(fromPath)
        let normalizedTo = normalizePath(toPath)
        do {
            let sshConnection = try await getSSHConnection()
            let sftp = try await sshConnection.connectSFTP()
            try await sftp.rename(at: normalizedFrom, to: normalizedTo)
            sendResponse(250, "Rename successful")
        } catch {
            print("Error renaming: \(error)")
            sendResponse(550, "Error renaming: \(error.localizedDescription)")
        }
        renameFromPath = nil
    }
    
    deinit {
        print("FTPSimpleHandler deinit called for id: \(id)")
        // Defensive: ensure all async work is cancelled
        activeTask?.cancel()
        activeTask = nil
        passiveListener?.cancel()
        passiveListener = nil
        dataConnection?.cancel()
        dataConnection = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        // Defensive: nil out SSH connection
        if let connection = activeSSHConnection {
            print("[deinit] Disconnecting SSH connection for handler \(id)")
            Task {
                await connection.disconnect()
            }
            activeSSHConnection = nil
        }
    }
}

// Helper to resolve a simplified filename to the real/original filename in the current directory
//private func resolveRealName(for requestedName: String, in directory: String, sftp: SFTPClient) async throws -> String {
//    let entries = try await sftp.listDirectory(path: directory)
//    if let match = entries.first(where: { FilenameMapper.simplify($0) == requestedName }) {
//        return match
//    }
//    return requestedName // fallback if not found
//}
