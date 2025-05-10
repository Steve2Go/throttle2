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
        Task{

            //Task{
               // await SSHConnectionManager.shared.resetAllConnections()
            //}
            guard let server = store.selection else {return}
            
            let isTunnel = server.sftpRpc
#if os(iOS)
            if server.sftpUsesKey == true {
                setupSFTPIfNeeded(store: store)
            }
#endif
            
            
            if isTunnel {
                let localport = 4000 // update after tunnel logic
                let port  = server.port
                
                //Task{
                    
                    let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "127.0.0.1", remotePort: Int(port))
                    try await tmanager.start()
                    TunnelManagerHolder.shared.storeTunnel(tmanager, withIdentifier: "transmission-rpc")
                    try await torrentManager.fetchUpdates(fullFetch: true)
                    torrentManager.startPeriodicUpdates()
                    try? await Task.sleep(nanoseconds: 500_000_000)
//                    if !store.magnetLink.isEmpty || store.selectedFile != nil {
//                        presenting.activeSheet = "adding"
//                    }
            } else{
                try await torrentManager.fetchUpdates(fullFetch: true)
                torrentManager.startPeriodicUpdates()
//                if !store.magnetLink.isEmpty || store.selectedFile != nil {
//                        try? await Task.sleep(nanoseconds: 500_000_000)
//                        presenting.activeSheet = "adding"
//                        
//                }
            }
        }
    }
    
    func setupServer (store: Store, torrentManager: TorrentManager, tries: Int = 0) {
        
        @AppStorage("trigger") var trigger = true
    
        // Reset all SSH connections
//        Task{
//            await SSHConnectionManager.shared.resetAllConnections()
//        }
            store.selectedTorrentId = nil
            
            if store.selection != nil {
                
                
                
                // load the keychain
                @AppStorage("useCloudKit") var useCloudKit: Bool = true
                let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
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
                
#if os(iOS)
                if server?.sftpUsesKey == true {
                    setupSFTPIfNeeded(store: store)
//                    Task{
//                        //sftp tunnel
//                        let sftp = try SSHTunnelManager(server: server!, localPort: 2222, remoteHost: "127.0.0.1", remotePort: Int(server!.sftpPort))
//                        try await sftp.start()
//                        TunnelManagerHolder.shared.storeTunnel(sftp, withIdentifier: "sftp")
//
//                    }
                }
                #endif
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
                                //try await Task.sleep(for: .milliseconds(500))
//                                if !store.magnetLink.isEmpty || store.selectedFile != nil {
//                                    presenting.activeSheet = "adding"
//                                    
//
//                                }
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
    }
    #if os(iOS)
    func setupExternalDisplayManager() {
           // This will start monitoring for external displays and create a black screen when needed
           ExternalDisplayManager.shared.startMonitoring()
       }

    
    #endif
    
    
    func setupSimpleFTPServer(store: Store,tries: Int = 0) {
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
                if tries < 3 {
                    //stopSFTP()
                    SimpleFTPServerManager.shared.removeAllServers()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    setupSimpleFTPServer(store: store, tries: tries + 1)
                }else{
                    // Show error toast
                    ToastManager.shared.show(
                        message: "Failed to start FTP server: \(error.localizedDescription)",
                        icon: "exclamationmark.triangle",
                        color: Color.red
                    )
                }
            }
        }
        #endif
    }
    
    // Replace your SFTP setup code with this
    func setupSFTPIfNeeded(store: Store) {
        guard let server = store.selection, server.sftpUsesKey == true else { return }
        
        //#if os(iOS)
        setupSimpleFTPServer(store: store)
        //#endif
    }
    
    func stopSFTP() {
        //guard let server = store.selection, server.sftpUsesKey == true else { return }
        
        //#if os(iOS)
        SimpleFTPServerManager.shared.removeAllServers()
        //#endif
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



// Escape single quotes and special characters in paths
func escapePath(_ path: String) -> String {
        // Escape backslashes and double quotes
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
func urlEncodePath(_ path: String) -> String {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return path // fallback to original if encoding fails
        }
        return "'\(encodedPath)'"
    }
