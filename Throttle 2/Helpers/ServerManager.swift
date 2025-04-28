import Foundation
import SwiftUI
import CoreData
import KeychainAccess
import Citadel
import NIOSSH
import NIO

// Global server manager
@MainActor
class ServerManager: ObservableObject {
    static let shared = ServerManager()
    @Published var selectedServer: ServerEntity?
    
    private var connections: [UUID: SSHConnection] = [:]
    
    private init() {}
    
    func setServer(_ server: ServerEntity) {
        selectedServer = server
        UserDefaults.standard.set(server.id?.uuidString, forKey: "selectedServer")
    }
    
    func connectSSH(_ server: ServerEntity) async throws -> SSHClient {
        // Get or create connection for this server
        let connection = connections[server.id!] ?? SSHConnection(server: server)
        connections[server.id!] = connection
        
        // Connect and return the client
        try await connection.connect()
        return try await connection.getSSHClient()
    }
    
    // Clean up connections when needed
    func closeConnection(for server: ServerEntity) {
        if let connection = connections[server.id!] {
            Task {
                await connection.disconnect()
                connections.removeValue(forKey: server.id!)
            }
        }
    }
    
    // Clean up all connections
    func closeAllConnections() {
        Task {
            for connection in connections.values {
                await connection.disconnect()
            }
            connections.removeAll()
        }
    }
}

// Updated path converter functions
@MainActor
func serverPath_to_url(_ path: String) -> String {
    print("url start")
    let server = ServerManager.shared.selectedServer
    guard let serverPath = server?.pathServer,
          var urlPath = server?.pathHttp,
          !serverPath.isEmpty,
          !urlPath.isEmpty else {
        return "" // fallback URL if server info missing
    }
    print("commence pass revial for server " + (server?.name ?? "Missing server name"))
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
    let password = keychain["httpPassword" + (server!.name ?? "")]
    print("pass retreived for server " + (server?.name ?? "Missing"))
    //handle password construction
    if let httpUser = server?.httpUser,
       !httpUser.isEmpty,
       let password = password,
       !password.isEmpty {
        urlPath = urlPath.replacingOccurrences(of: "://", with: "://\(httpUser):\(password)@")
        print("url converted with password")
    }
    
    // Remove serverPath prefix to get relative path
    var relativePath = path
    if path.starts(with: serverPath) {
        relativePath = String(path.dropFirst(serverPath.count))
    }
    
    // Ensure relative path starts with a single /
    relativePath = "/" + relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    
    // Construct the full URL
    let baseUrl = urlPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let urlString = baseUrl + relativePath
    
    return urlString
}

@MainActor
func url_to_url(_ path: String) -> String {
    guard let server = ServerManager.shared.selectedServer,
          var urlPath = server.pathHttp,
          !urlPath.isEmpty else {
        return "" // fallback URL if server info missing
    }
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
    let password = keychain["httpPassword" + (server.name ?? "")]
    
    //handle password construction
    if let httpUser = server.httpUser,
       let password = password,
       !password.isEmpty {
        urlPath = urlPath.replacingOccurrences(of: "://", with: "://\(httpUser):\(password)@")
    }
    
    return urlPath
}

@MainActor
func serverPath_to_local(_ path: String) -> String {
    guard let server = ServerManager.shared.selectedServer,
          let serverPath = server.pathServer,
          let urlPath = server.pathFilesystem,
          !serverPath.isEmpty,
          !urlPath.isEmpty else {
        return "" // fallback URL if server info missing
    }
   
    // Remove serverPath prefix to get relative path
    var relativePath = path
    if path.starts(with: serverPath) {
        relativePath = String(path.dropFirst(serverPath.count))
    }
   
    // Ensure relative path starts with a single /
    relativePath = "/" + relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
   
    // Construct the full filesystem path
    let basePath = urlPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let fullPath = basePath + relativePath
   
    return fullPath
}

@MainActor
func url_to_serverPath(_ urlString: String) -> String {
    guard let server = ServerManager.shared.selectedServer,
          let serverPath = server.pathServer,
          let urlPath = server.pathHttp,
          !serverPath.isEmpty,
          !urlPath.isEmpty else {
        return "" // fallback if server info missing
    }
    
    // Remove HTTP base path to get relative path
    var relativePath = urlString
    relativePath = relativePath.replacingOccurrences(of: "://[^@]+@", with: "://", options: .regularExpression)
    let basePath = urlPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if relativePath.starts(with: basePath) {
        relativePath = String(relativePath.dropFirst(basePath.count))
    }
    
    // Ensure relative path starts with a single /
    relativePath = "/" + relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    
    // Construct the full server path
    let serverBasePath = serverPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var fullPath = serverBasePath + relativePath
    
    if !fullPath.hasPrefix("/") {
        fullPath = "/" + fullPath
    }
    
    return fullPath.removingPercentEncoding ?? fullPath
}

@MainActor
func local_to_serverPath(_ localPath: String) -> String {
    guard let server = ServerManager.shared.selectedServer,
          let serverPath = server.pathServer,
          let filesystemPath = server.pathFilesystem,
          !serverPath.isEmpty,
          !filesystemPath.isEmpty else {
        return "" // fallback if server info missing
    }
    
    // Remove filesystem base path to get relative path
    var relativePath = localPath.replacingOccurrences(of: "file://", with: "")
    relativePath = relativePath.replacingOccurrences(of: filesystemPath, with: serverPath)
    
//    let basePath = filesystemPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
//    if relativePath.starts(with: basePath) {
//        relativePath = String(relativePath.dropFirst(basePath.count))
//    }
//
//    // Ensure relative path starts with a single /
//    relativePath = "/" + relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
//
//    // Construct the full server path
//    let serverBasePath = serverPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    //let fullPath = serverBasePath + relativePath
    
    return relativePath
}

func isWindowsFilePath(_ path: String) -> Bool {
    // This regex checks for a drive letter (A-Z or a-z) followed by a colon and a slash/backslash.
    let pattern = "^[A-Za-z]:[\\\\/].*"
    return path.range(of: pattern, options: .regularExpression) != nil
}
