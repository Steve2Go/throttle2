import Foundation
import Network
import SwiftUI

/// Simplified FTP server that allows anonymous access and focuses on file transfers
class SimpleFTPServer: ObservableObject {
    // FTP server
    private var listener: NWListener?
    
    // SFTP connection
    private var sshConnection: SSHConnection?
    
    // Configuration
    private let server: ServerEntity
    private let localPort: Int
    
    // Status
    @Published var isRunning = false
    @Published var status = "Stopped"
    @Published var connectionCount = 0
    
    // Active connections
    private var activeConnections: [UUID: FTPSimpleHandler] = [:]
    private let connectionLock = NSLock()
    
    init(server: ServerEntity, localPort: Int = 2121) {
        self.server = server
        self.localPort = localPort
    }
    
    deinit {
        stop()
    }
    
    func start() async throws {
        guard !isRunning else {
            return
        }
        
        await MainActor.run {
            status = "Starting..."
        }
        
        // 1. Establish SFTP connection to use as backend
        let connection = SSHConnection(server: server)
        try await connection.connect()
        
        // Test the SFTP connection
        let sftp = try await connection.connectSFTP()
        
        // Keep the connection
        self.sshConnection = connection
        
        // 2. Create FTP server
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(localPort)))
        
        // Set up connection handler
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            
            let connectionId = UUID()
            let clientDescription = connection.endpoint.debugDescription
            print("New FTP connection from \(clientDescription)")
            
            // Create a handler for this client
            let clientHandler = FTPSimpleHandler(
                connection: connection,
                id: connectionId,
                sftpConnection: self.sshConnection!,
                onDisconnect: { [weak self] id in
                    self?.handleClientDisconnect(id: id)
                }
            )
            
            // Store the handler
            self.connectionLock.lock()
            self.activeConnections[connectionId] = clientHandler
            let count = self.activeConnections.count
            self.connectionLock.unlock()
            
            // Update connection count
            Task { @MainActor in
                self.connectionCount = count
                self.status = "Active: \(count) connection(s)"
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
                Task { @MainActor in
                    self.isRunning = true
                    self.status = "Running on localhost:\(self.localPort)"
                }
                
            case .failed(let error):
                print("FTP server failed: \(error)")
                Task { @MainActor in
                    self.isRunning = false
                    self.status = "Failed: \(error.localizedDescription)"
                }
                
            case .cancelled:
                print("FTP server cancelled")
                Task { @MainActor in
                    self.isRunning = false
                    self.status = "Stopped"
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
        print("  Mode: Anonymous access (no login required)")
        
        await MainActor.run {
            ToastManager.shared.show(
                message: "FTP ready: Connect to localhost:\(localPort)",
                icon: "link",
                color: Color.green
            )
        }
    }
    
    private func handleClientDisconnect(id: UUID) {
        connectionLock.lock()
        activeConnections.removeValue(forKey: id)
        let count = activeConnections.count
        connectionLock.unlock()
        
        Task { @MainActor in
            connectionCount = count
            status = count > 0 ? "Active: \(count) connection(s)" : "Running on localhost:\(localPort)"
        }
    }
    
    func stop() {
        // Stop the listener
        listener?.cancel()
        listener = nil
        
        // Close all active connections
        connectionLock.lock()
        let handlers = activeConnections.values
        activeConnections.removeAll()
        connectionLock.unlock()
        
        for handler in handlers {
            handler.stop()
        }
        
        // Close the SFTP connection
        if let connection = sshConnection {
            Task {
                await connection.disconnect()
            }
            sshConnection = nil
        }
        
        // Update status
        Task { @MainActor in
            isRunning = false
            connectionCount = 0
            status = "Stopped"
        }
        
        print("FTP server stopped")
    }
}

/// Simplified FTP client handler focused on file transfers
class FTPSimpleHandler {
    // Network
    private let connection: NWConnection
    private let id: UUID
    
    // SFTP backend
    private let sftpConnection: SSHConnection
    private var sftpClient: SFTPClient?
    
    // State
    private var isAuthenticated = true // Always authenticated
    private var currentDirectory = "/"
    private var dataMode = DataConnectionMode.passive
    private var dataConnection: NWConnection?
    private var dataPort: UInt16 = 0
    private var dataHost: String = ""
    
    // Callback for disconnection
    private let onDisconnect: (UUID) -> Void
    
    // Initializer
    init(connection: NWConnection, id: UUID, sftpConnection: SSHConnection, 
         onDisconnect: @escaping (UUID) -> Void) {
        self.connection = connection
        self.id = id
        self.sftpConnection = sftpConnection
        self.onDisconnect = onDisconnect
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
                
                // Initialize SFTP client immediately
                Task {
                    do {
                        self.sftpClient = try await self.sftpConnection.connectSFTP()
                        print("SFTP client initialized")
                    } catch {
                        print("Error initializing SFTP client: \(error)")
                    }
                }
                
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
        connection.cancel()
        dataConnection?.cancel()
        
        // Clean up SFTP client if needed
        if let sftp = sftpClient {
            Task {
                do {
                    try await sftp.close()
                } catch {
                    print("Error closing SFTP client: \(error)")
                }
            }
        }
    }
    
    // Clean up resources
    private func cleanup() {
        stop()
        onDisconnect(id)
    }
    
    // Receive FTP commands
    private func receiveCommands() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                if let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    self.handleCommand(command)
                }
                
                // Continue receiving
                self.receiveCommands()
            } else if isComplete || error != nil {
                self.cleanup()
            }
        }
    }
    
    // Send FTP response
    private func sendResponse(_ code: Int, _ message: String) {
        let response = "\(code) \(message)\r\n"
        let data = Data(response.utf8)
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("Error sending response: \(error)")
                self?.cleanup()
            }
        })
    }
    
    // Handle FTP command
    private func handleCommand(_ commandLine: String) {
        print("FTP command: \(commandLine)")
        
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
            sendResponse(257, "\"\(currentDirectory)\" is current directory")
        case "TYPE":
            sendResponse(200, "Type set to \(argument)")
            
        // Data connection commands
        case "PASV":
            handlePassive()
        case "PORT":
            handlePort(argument)
            
        // Navigation and listing commands - very minimal
        case "CWD":
            // Just accept any directory change
            currentDirectory = argument
            sendResponse(250, "Directory changed to \(argument)")
        case "CDUP":
            // Move up one directory
            if currentDirectory != "/" {
                if let lastSlashIndex = currentDirectory.lastIndex(of: "/") {
                    currentDirectory = String(currentDirectory[..<lastSlashIndex])
                    if currentDirectory.isEmpty {
                        currentDirectory = "/"
                    }
                }
            }
            sendResponse(250, "Directory changed to \(currentDirectory)")
        case "LIST":
            // For LIST, just send a minimal response
            sendResponse(150, "Opening data connection for directory listing")
            
            // Set up data connection
            setupDataConnection { connection in
                // Send a minimal directory listing
                let listingText = "-rw-r--r-- 1 user group 0 Jan 01 2022 file.txt\r\n"
                let listingData = Data(listingText.utf8)
                
                connection.send(content: listingData, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        print("Error sending listing: \(error)")
                    }
                    
                    // Close the data connection
                    connection.cancel()
                    self?.sendResponse(226, "Transfer complete")
                })
            }
            
        // File transfer commands - these are the important ones
        case "RETR":
            handleRetrieve(argument)
        case "STOR":
            handleStore(argument)
            
        // Session end
        case "QUIT":
            sendResponse(221, "Goodbye")
            cleanup()
            
        // Respond OK to common commands we don't need to fully implement
        case "FEAT", "OPTS", "MODE", "STRU", "NOOP", "STAT":
            sendResponse(200, "Command OK")
            
        // For anything else
        default:
            sendResponse(502, "Command not implemented")
        }
    }
    
    // Handle PASV command
    private func handlePassive() {
        // Create a passive listener
        let parameters = NWParameters.tcp
        let listener = try? NWListener(using: parameters)
        
        // Get the port
        if let port = listener?.port, let portInt = port.rawValue {
            dataPort = UInt16(portInt)
            
            // Calculate the passive mode response
            let ipParts = [127, 0, 0, 1] // Localhost
            let portHi = Int(dataPort / 256)
            let portLo = Int(dataPort % 256)
            
            let pasvResponse = ipParts.map(String.init).joined(separator: ",") + ",\(portHi),\(portLo)"
            sendResponse(227, "Entering Passive Mode (\(pasvResponse))")
            
            // Set up listener for data connection
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                
                // Accept only one connection
                listener?.cancel()
                
                self.dataConnection = connection
                connection.start(queue: .global())
                
                print("FTP data connection established (passive)")
            }
            
            // Start the listener
            listener?.start(queue: .global())
        } else {
            sendResponse(425, "Cannot open data connection")
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
    
    // Handle RETR command
    private func handleRetrieve(_ path: String) {
        // Send status
        sendResponse(150, "Opening data connection for file transfer")
        
        // Start data connection
        setupDataConnection { [weak self] connection in
            guard let self = self else { return }
            
            Task {
                do {
                    guard let sftp = self.sftpClient else {
                        self.sendResponse(550, "SFTP client not initialized")
                        return
                    }
                    
                    // Open the file
                    let file = try await sftp.openFile(filePath: path, flags: .read)
                    
                    // Get file size
                    let attributes = try await file.readAttributes()
                    let fileSize = attributes.size ?? 0
                    
                    // Read and send the file in chunks
                    var offset: UInt64 = 0
                    let chunkSize: UInt32 = 32768 // 32 KB chunks
                    
                    while offset < fileSize {
                        // Read a chunk
                        let data = try await file.read(from: offset, length: chunkSize)
                        
                        // Convert to Data
                        var buffer = data
                        let byteBuffer = buffer.readData(length: buffer.readableBytes)
                        
                        // Send the chunk
                        connection.send(content: byteBuffer, completion: .contentProcessed { error in
                            if let error = error {
                                print("Error sending file chunk: \(error)")
                            }
                        })
                        
                        // Update offset
                        offset += UInt64(data.readableBytes)
                        
                        // Break if we reached the end
                        if data.readableBytes < Int(chunkSize) {
                            break
                        }
                    }
                    
                    // Close the file
                    try await file.close()
                    
                    // Close the data connection
                    connection.cancel()
                    
                    // Send completion status
                    self.sendResponse(226, "Transfer complete")
                } catch {
                    print("Error retrieving file: \(error)")
                    self.sendResponse(550, "Error retrieving file: \(error.localizedDescription)")
                    connection.cancel()
                }
            }
        }
    }
    
    // Handle STOR command
    private func handleStore(_ path: String) {
        // Send status
        sendResponse(150, "Opening data connection for file upload")
        
        // Start data connection
        setupDataConnection { [weak self] connection in
            guard let self = self else { return }
            
            Task {
                do {
                    guard let sftp = self.sftpClient else {
                        self.sendResponse(550, "SFTP client not initialized")
                        return
                    }
                    
                    // Open the file for writing
                    let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
                    
                    // Receive and write data
                    var offset: UInt64 = 0
                    
                    // Function to receive data
                    func receiveAndWrite() {
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, isComplete, error in
                            if let data = data, !data.isEmpty {
                                // Create byte buffer
                                var buffer = ByteBuffer()
                                buffer.writeBytes([UInt8](data))
                                
                                // Write to file
                                Task {
                                    do {
                                        try await file.write(buffer, at: offset)
                                        offset += UInt64(data.count)
                                        
                                        // Continue receiving
                                        receiveAndWrite()
                                    } catch {
                                        print("Error writing file: \(error)")
                                        self.sendResponse(550, "Error writing file: \(error.localizedDescription)")
                                        connection.cancel()
                                    }
                                }
                            } else if isComplete || error != nil {
                                // Close the file
                                Task {
                                    do {
                                        try await file.close()
                                        self.sendResponse(226, "Transfer complete")
                                    } catch {
                                        print("Error closing file: \(error)")
                                        self.sendResponse(550, "Error closing file: \(error.localizedDescription)")
                                    }
                                }
                                
                                // Close the connection
                                connection.cancel()
                            }
                        }
                    }
                    
                    // Start receiving data
                    receiveAndWrite()
                } catch {
                    print("Error storing file: \(error)")
                    self.sendResponse(550, "Error storing file: \(error.localizedDescription)")
                    connection.cancel()
                }
            }
        }
    }
    
    // Set up data connection
    private func setupDataConnection(completion: @escaping (NWConnection) -> Void) {
        if dataMode == .passive {
            // In passive mode, we wait for the client to connect to us
            // The dataConnection should already be set up
            if let connection = dataConnection {
                completion(connection)
            } else {
                sendResponse(425, "No data connection established")
            }
        } else {
            // In active mode, we connect to the client
            let connection = NWConnection(
                host: NWEndpoint.Host(dataHost),
                port: NWEndpoint.Port(rawValue: dataPort)!,
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
        }
    }
}

// FTP data connection mode
enum DataConnectionMode {
    case active
    case passive
}

// Manager for simple FTP servers
class SimpleFTPServerManager {
    static let shared = SimpleFTPServerManager()
    
    private var activeServers: [String: SimpleFTPServer] = [:]
    private let serverLock = NSLock()
    
    private init() {}
    
    func storeServer(_ server: SimpleFTPServer, withIdentifier identifier: String) {
        serverLock.lock()
        activeServers[identifier] = server
        serverLock.unlock()
    }
    
    func getServer(withIdentifier identifier: String) -> SimpleFTPServer? {
        serverLock.lock()
        defer { serverLock.unlock() }
        return activeServers[identifier]
    }
    
    func removeServer(withIdentifier identifier: String) {
        serverLock.lock()
        let server = activeServers[identifier]
        activeServers.removeValue(forKey: identifier)
        serverLock.unlock()
        
        if let server = server {
            server.stop()
        }
    }
    
    func removeAllServers() {
        serverLock.lock()
        let servers = activeServers.values
        activeServers.removeAll()
        serverLock.unlock()
        
        for server in servers {
            server.stop()
        }
    }
}

// Integration with your app
extension Throttle_2App {
    func setupSimpleFTPServer(store: Store) {
        guard let server = store.selection, server.sftpUsesKey == true else { return }
        
        #if os(iOS)
        Task {
            do {
                // Clean up any existing servers
                SimpleFTPServerManager.shared.removeServer(withIdentifier: "sftp-ftp")
                
                // Create and start a new FTP server
                let ftpServer = SimpleFTPServer(server: server)
                try await ftpServer.start()
                
                // Store the server
                SimpleFTPServerManager.shared.storeServer(ftpServer, withIdentifier: "sftp-ftp")
                
                print("Simple FTP Server started on localhost:2121")
            } catch {
                print("Failed to start FTP server: \(error)")
                
                // Show error toast
                ToastManager.shared.show(
                    message: "Failed to start FTP server: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    color: Color.red
                )
            }
        }
        #endif
    }
    
    // Replace your SFTP setup code with this
    func setupSFTPIfNeeded(store: Store) {
        guard let server = store.selection, server.sftpUsesKey == true else { return }
        
        #if os(iOS)
        setupSimpleFTPServer(store)
        #endif
    }
}

// SwiftUI view to monitor the FTP server
struct SimpleFTPServerMonitorView: View {
    @ObservedObject var server: SimpleFTPServer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                
                Text("Simple FTP Server")
                    .font(.headline)
                
                Spacer()
                
                Button(action: {
                    if server.isRunning {
                        server.stop()
                    } else {
                        Task {
                            try await server.start()
                        }
                    }
                }) {
                    Text(server.isRunning ? "Stop" : "Start")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(server.isRunning ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            
            Divider()
            
            if server.isRunning {
                HStack {
                    Text("Status:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(server.status)
                }
                
                HStack {
                    Text("Connections:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(server.connectionCount)")
                }
                
                HStack {
                    Text("Connection Info:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("ftp://localhost:2121")
                        .bold()
                }
                
                Text("Note: Connect with FTP in VLC - no login required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } else {
                Text("Server is not running")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}