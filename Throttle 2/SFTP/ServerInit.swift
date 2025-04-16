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
    
    func refeshTunnel(store: Store, torrentManager: TorrentManager){
        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
       TunnelManagerHolder.shared.removeTunnel(withIdentifier: "http-streamer")
        guard let server = store.selection else {return}
        let localport = 4000 // update after tunnel logic
        let port  = server.port
        
        Task{
            if store.selection != nil {
                setupStreamingServer(server: store.selection!)
            }
            let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "127.0.0.1", remotePort: Int(port))
            try await tmanager.start()
            TunnelManagerHolder.shared.storeTunnel(tmanager, withIdentifier: "transmission-rpc")
            torrentManager.startPeriodicUpdates()
            if !store.magnetLink.isEmpty || store.selectedFile != nil {
                presenting.activeSheet = "adding"
            }
        }
        
    }
    
    func setupServer (store: Store, torrentManager: TorrentManager) {
    
            
            store.selectedTorrentId = nil
            
            if store.selection != nil {
                TunnelManagerHolder.shared.removeTunnel(withIdentifier: "http-streamer")
         //       setupStreamingServer(server: store.selection!)
                
                // load the keychain
                let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
                let server = store.selection
                
                // trying to keep it as clear as possible
                let proto = (server?.protoHttps ?? false) ? "https" : "http"
                let domain = server?.url ?? "127.0.0.1"
                let user = server?.sftpUser ?? ""
                let password = keychain["password" + (server?.name! ?? "")] ?? ""
                
                let port  = server?.port ?? 9091
                let path = server?.rpc ?? "transmission/rpc"
                
                let isTunnel = server?.sftpRpc ?? false
                //let hasKey = server?.sftpUsesKey
                let localport = 4000 // update after tunnel logic
                
                var url = ""
                var at = ""
                
                setupStreamingServer(server: server! )
                
                
                if isTunnel{
                    TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                    //server tunnel creation
                    if let server = server {
                        Task {
                            do {
                                let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "127.0.0.1", remotePort: Int(port))
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
                                url += "\(at)127.0.0.1:\(String(localport))\(path)"
                                
                                store.connectTransmission = url
                                ServerManager.shared.setServer(store.selection!)
                                torrentManager.isLoading = true
                                
                                torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                                torrentManager.startPeriodicUpdates()
                                //try await Task.sleep(for: .milliseconds(500))
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
                    torrentManager.reset()
                    torrentManager.startPeriodicUpdates()
                    Task {
                        try await Task.sleep(for: .milliseconds(500))
                        if !store.magnetLink.isEmpty || store.selectedFile != nil {
                            presenting.activeSheet = "adding"
                        }
                    }
                    
                }

            }
    }
    #if os(iOS)
    func setupExternalDisplayManager() {
           // This will start monitoring for external displays and create a black screen when needed
           ExternalDisplayManager.shared.startMonitoring()
       }
    // In Throttle_2App.swift, add this near your setupServer function:

    
    #endif
    
    func setupStreamingServer(server: ServerEntity) {
            Task {
                do {
                    // Only proceed if SFTP browsing is enabled
                    guard server.sftpBrowse else { return }
                    
                    // 1. Setup the HTTP server
                    try await HttpStreamingManager.shared.setupServer(for: server)
                    
                    // 2. Create SSH tunnel using existing infrastructure
                    @AppStorage("StreamingServerPort") var serverPort = 8723
                    @AppStorage("StreamingServerLocalPort") var localStreamPort = 8080
                    
                    // Check if tunnel already exists
                    if TunnelManagerHolder.shared.getTunnel(withIdentifier: "http-streamer") != nil {
                        print("HTTP streaming tunnel already exists")
                    } else {
                        // Create tunnel for HTTP streaming
                        let htunnel = try SSHTunnelManager(
                            server: server,
                            localPort: localStreamPort,
                            remoteHost: "127.0.0.1",
                            remotePort: Int(serverPort)
                        )
                        try await htunnel.start()
                        TunnelManagerHolder.shared.storeTunnel(htunnel, withIdentifier: "http-streamer")
                        print("HTTP streaming tunnel established")
                    }
                    
                    print("HTTP streaming setup completed for \(server.name ?? "unnamed server")")
                } catch {
                    print("Failed to setup HTTP streaming: \(error.localizedDescription)")
                }
            }
        }
        
        // Clean up streaming when disconnecting
        func cleanupStreamingServer(server: ServerEntity) {
            Task {
                // 1. Close the tunnel
                TunnelManagerHolder.shared.removeTunnel(withIdentifier: "http-streamer")
                
                // 2. Stop the server
                await HttpStreamingManager.shared.stopServer(for: server)
            }
        }
    
//    func setupStreamingServer(server: ServerEntity) {
//        Task {
//            do {
//                
//                // Check if the server is running, start if needed
//                
//                if !(try await HttpStreamingManager.shared.isServerRunning(server: server)) {
//                    try await HttpStreamingManager.shared.startStreamingServer(server: server)
//                    print("HTTP streaming server started successfully")
//                } else {
//                    print("HTTP streaming server is already running")
//                }
//                
//                // Create the tunnel if needed
//                //store.streamingUrl =  try await HttpStreamingManager.shared.getStreamingURL(for: "", server: server).absoluteString
//                @AppStorage("StreamingServerPort") var serverPort = 8723 // Remote port for Python HTTP server
//                @AppStorage("StreamingServerLocalPort") var localStreamPort = 8080 // Local port for streaming
//                let htunnel = try SSHTunnelManager(server: server, localPort: localStreamPort, remoteHost: "127.0.0.1", remotePort: Int(serverPort))
//                try await htunnel.start()
//                TunnelManagerHolder.shared.storeTunnel(htunnel, withIdentifier: "http-streamer")
//                
//                print("HTTP streaming tunnel established")
//            } catch {
//                print("Failed to setup streaming server: \(error)")
//            }
//        }
//    }
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
