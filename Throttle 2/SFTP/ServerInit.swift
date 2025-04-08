//
//  SSHTunnelClass.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 2/4/2025.
//
import SwiftUI
import KeychainAccess
import Network

// created to unclutter the main app
extension Throttle_2App {
    
    
    
    func setupServer (store: Store, torrentManager: TorrentManager) {
        if !isTunneling {
            isTunneling = true
            //Cleanup
            TunnelManagerHolder.shared.tearDownAllTunnels()
            store.selectedTorrentId = nil
            
            // url construction for server quaries
            if store.selection != nil {
                // load the keychain
                let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
                let server = store.selection
                
                // trying to keep it as clear as possible
                let proto = (server?.protoHttps ?? false) ? "https" : "http"
                let domain = server?.url ?? "localhost"
                let user = server?.sftpUser ?? ""
                let password = keychain["password" + (server?.name! ?? "")] ?? ""
                
                let port  = server?.port ?? 9091
                let path = server?.rpc ?? "transmission/rpc"
                
                let isTunnel = server?.sftpRpc ?? false
                //let hasKey = server?.sftpUsesKey
                let localport = 4000 // update after tunnel logic
                
                var url = ""
                var at = ""
                
                if isTunnel{
                    //server tunnel creation
                    if let server = server {
                        Task {
                            do {
                                let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "localhost", remotePort: Int(port))
                                try await tmanager.start()
                                TunnelManagerHolder.shared.storeTunnel(tmanager, withIdentifier: "transmission-rpc")
                                //
                                //Now build the rpc url
                                
                                url += "http://"
                                if !user.isEmpty {
                                    at = "@"
                                    url += user
                                    if !password.isEmpty {
                                        url += ":\(password)"
                                    }
                                }
                                url += "\(at)localhost:\(String(localport))\(path)"
                                
                                store.connectTransmission = url
                                await ServerManager.shared.setServer(store.selection!)
                                torrentManager.isLoading = true
                                
                                torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                                torrentManager.startPeriodicUpdates()
                                try await Task.sleep(for: .milliseconds(500))
                                if !store.magnetLink.isEmpty || store.selectedFile != nil {
                                    presenting.activeSheet = "adding"
                                }
                            } catch let error as SSHTunnelError {
                                switch error {
                                case .missingCredentials:
                                    print("Error: Missing credentials")
                                case .connectionFailed(let underlyingError):
                                    print("Error: Connection failed: \(underlyingError)")
                                case .portForwardingFailed(let underlyingError):
                                    print("Error: Port forwarding failed: \(underlyingError)")
                                case .localProxyFailed(let underlyingError):
                                    print("Error: Local proxy failed: \(underlyingError)")
                                case .reconnectFailed(let underlyingError):
                                    print("Error: Reconnect failed: \(underlyingError)")
                                case .invalidServerConfiguration:
                                    print("Error: Invalid server configuration")
                                case .tunnelAlreadyConnected:
                                    print("Error: Tunnel already connected")
                                case .tunnelNotConnected:
                                    print("Error: Tunnel not connected")
                                }
                            } catch {
                                print("An unexpected error occurred: \(error)")
                            }
                        }
                    }
                    
                    isTunneling = false
                }  else {
                    // just build the url
                    
                    url += "\(proto)://"
                    if !user.isEmpty {
                        at = "@"
                        url += user
                        if !password.isEmpty {
                            url += ":\(password)"
                        }
                    }
                    url += "\(at)\(domain):\(String(port))\(path)"
                    store.connectTransmission = url
                    ServerManager.shared.setServer(store.selection!)
                    
                    torrentManager.isLoading = true
                    torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                    torrentManager.startPeriodicUpdates()
                    Task {
                        try await Task.sleep(for: .milliseconds(500))
                        if !store.magnetLink.isEmpty || store.selectedFile != nil {
                            presenting.activeSheet = "adding"
                        }
                    }
                    
                }
                
                
                func startPythonServer(for server: ServerEntity) async throws -> (localPort: Int, remotePort: Int) {
                    // Get credentials from Keychain
                    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
                    guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
                        throw NSError(domain: "PythonServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing password"])
                    }
                    
                    // Create SSH connection
                    let ssh = SSHConnection(
                        host: server.sftpHost ?? "",
                        port: Int(server.sftpPort),
                        username: server.sftpUser ?? "",
                        password: password
                    )
                    
                    try await ssh.connect()
                    
                    // CD to the server path and start Python HTTP server on random port
                    let remotePort = Int.random(in: 8000...9000)
                    let serverPath = server.pathServer ?? ""
                    let command = "cd \(serverPath) && python3 -m http.server \(remotePort) --bind 127.0.0.1 > /dev/null 2>&1 & echo $!"
                    let (_, pidOutput) = try await ssh.executeCommand(command)
                    
                    // Create and start tunnel
                    let localPort = 4001 // Fixed local port or could find a free one
                    let tunnel = try SSHTunnelManager(
                        server: server,
                        localPort: localPort,
                        remoteHost: "127.0.0.1",
                        remotePort: remotePort
                    )
                    
                    try await tunnel.start()
                    
                    // Store connection and tunnel
                    TunnelManagerHolder.shared.storeTunnel(tunnel, withIdentifier: "python-web-server")
                    
                    // Save PID for later termination
                    UserDefaults.standard.set(pidOutput.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "pythonServerPID")
                    
                    return (localPort, remotePort)
                }
                
                func stopPythonServer(for server: ServerEntity) async throws {
                    // Get stored PID
                    if let pid = UserDefaults.standard.string(forKey: "pythonServerPID") {
                        // Create SSH connection
                        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
                        guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
                            throw NSError(domain: "PythonServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing password"])
                        }
                        
                        let ssh = SSHConnection(
                            host: server.sftpHost ?? "",
                            port: Int(server.sftpPort),
                            username: server.sftpUser ?? "",
                            password: password
                        )
                        
                        try await ssh.connect()
                        
                        // Kill the process
                        let (_, _) = try await ssh.executeCommand("kill \(pid)")
                    }
                    
                    // Remove tunnel
                    TunnelManagerHolder.shared.removeTunnel(withIdentifier: "python-web-server")
                    
                    // Clear stored PID
                    UserDefaults.standard.removeObject(forKey: "pythonServerPID")
                }
                
            }
        }
    }
}


class NetworkMonitor: ObservableObject {
    private let networkMonitor = NWPathMonitor()
    private let workerQueue = DispatchQueue(label: "Monitor")
    var isConnected = false
    var isExpensive = false
    var gateways: [NWEndpoint] = []

    init() {
        networkMonitor.pathUpdateHandler = { path in
            self.isConnected = path.status == .satisfied
            self.isExpensive = path.isExpensive
            self.gateways = path.gateways
            Task {
                await MainActor.run {
                    self.objectWillChange.send()
                }
            }
        }
        networkMonitor.start(queue: workerQueue)
    }
}
