//
//  ServerMountUtilities.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 20/4/2025.
//


#if os(macOS)
import Foundation

/// Utility functions for server mounting operations
enum ServerMountUtilities {
    
    /// Creates a unique mount key based on server connection details
    /// Format: host:lastPathComponent (e.g., "srg.im:storage")
    static func getMountKey(host: String?, user: String?, path: String?) -> String? {
        guard let host = host,
              let path = path,
              !host.isEmpty,
              !path.isEmpty else {
            return nil
        }
        
        // Generate the last path component
        let pathComponents = path.split(separator: "/")
        let lastComponent = pathComponents.last?.description ?? "root"
        
        // Format: host:lastPathComponent
        return "\(host):\(lastComponent)"
    }
    
    /// Convenience method to get mount key from a ServerEntity
    static func getMountKey(for server: ServerEntity) -> String? {
        return getMountKey(host: server.sftpHost, 
                          user: server.sftpUser, 
                          path: server.pathServer)
    }
    
    /// Creates a mount path from a mount key
    static func getMountPath(for mountKey: String) -> URL {
        return URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("com.srgim.Throttle-2.sftp/\(mountKey)", isDirectory: true)
    }
}
#endif
