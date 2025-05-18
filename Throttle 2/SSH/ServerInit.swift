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
    
    
    func setupServer (store: Store, torrentManager: TorrentManager, tries: Int = 0, fullRefresh: Bool = true) {
        
        @AppStorage("trigger") var trigger = true
                
                //deselct details view
                store.selectedTorrentId = nil
                
                
                
                // load the keychain
                @AppStorage("useCloudKit") var useCloudKit: Bool = true
                let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
                let server = store.selection
                
                // trying to keep it as clear as possible, building url
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
                                
                                if fullRefresh == true {
                                    torrentManager.isLoading = true
                                    torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                                }
                                //torrentManager.reset()
                               // try? await Task.sleep(nanoseconds: 1_000_000_000)
                                
                            } catch let error as SSHTunnelError {
                                if tries < 3 {
                                    await SSHConnectionManager.shared.resetAllConnections()
                                    TunnelManagerHolder.shared.tearDownAllTunnels()
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    setupServer(store: store, torrentManager: torrentManager, tries: tries + 1)
                                } else{
                                    print("An unexpected error occurred in tunnel: \(error)")
                                    ToastManager.shared.show(message: "Tunnel Error: \(error)", icon: "exclamationmark.triangle", color: Color.red)
                                }
                                
                            }
                            if TunnelManagerHolder.shared.activeTunnels.count > 0 {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                try await torrentManager.fetchUpdates(fullFetch: true)
                                torrentManager.startPeriodicUpdates()
                            }
                        }
                    }
                    
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
                    Task {
                        try await torrentManager.fetchUpdates(fullFetch: true)
                        torrentManager.startPeriodicUpdates()
                        try await Task.sleep(for: .milliseconds(500))
//                        if !store.magnetLink.isEmpty || store.selectedFile != nil {
//                            presenting.activeSheet = "adding"
//                        }
                    }
                    
                

            }
    }

        
//    func startFTP(store: Store,tries: Int = 0) {
//        guard let server = store.selection, server.sftpUsesKey == true else { return }
//        
//        #if os(iOS)
//        Task {
//            do {
//                // Create and start a new FTP server
//                let ftpServer = SimpleFTPServer(server: server)
//                try await ftpServer.start()
//                
//                // Store the server
//                await SimpleFTPServerManager.shared.storeServer(ftpServer, withIdentifier: "sftp-ftp")
//                print("Simple FTP Server started on localhost:2121")
//            } catch {
//                print("Failed to start FTP server: \(error)")
//                if tries < 3 {
//                    //stopSFTP()
//                    await SimpleFTPServerManager.shared.removeAllServers()
//                    try? await Task.sleep(nanoseconds: 2_000_000_000)
//                    startFTP(store: store, tries: tries + 1)
//                }else{
//                    // Show error toast
//                    ToastManager.shared.show(
//                        message: "Failed to start FTP server: \(error.localizedDescription)",
//                        icon: "exclamationmark.triangle",
//                        color: Color.red
//                    )
//                }
//            }
//        }
//        #endif
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



//// Safely quote a path for Unix shell usage
//func shellQuote(_ path: String) -> String {
//    // If the path contains no single quotes, just wrap in single quotes
//    if !path.contains("'") {
//        return "'\(path)'"
//    }
//    // Otherwise, close the quote, insert an escaped single quote, and reopen
//    // e.g. abc'def -> 'abc'\''def'
//    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
//}

// Safely quote a path for Unix shell usage with support for non-English characters
func shellQuote(_ path: String) -> String {
    // First ensure the string is properly encoded for shell usage
    let encodedPath = path.precomposedStringWithCanonicalMapping
    
    // If the path contains no single quotes, just wrap in single quotes
    if !encodedPath.contains("'") {
        return "'\(encodedPath)'"
    }
    
    // Otherwise, close the quote, insert an escaped single quote, and reopen
    // e.g. abc'def -> 'abc'\''def'
    return "'" + encodedPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func urlEncodePath(_ path: String) -> String {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return path // fallback to original if encoding fails
        }
        return "'\(encodedPath)'"
    }
