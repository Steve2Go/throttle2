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
    
            
            store.selectedTorrentId = nil
            
            if store.selection != nil {
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
