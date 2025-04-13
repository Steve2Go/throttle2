//
//  TorrentOperationError.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/2/2025.
//
import SwiftUI

// MARK: - Additional Operations Extension
extension TorrentManager {
    enum TorrentOperationError: Error {
        case invalidResponse
        case multipleIdsForRename
        case serverError(String)
    }
    
    /// Deletes one or more torrents with optional local data deletion
    /// - Parameters:
    ///   - ids: Array of torrent IDs to delete
    ///   - deleteLocalData: Whether to also delete the downloaded files
    /// - Returns: True if deletion was successful
    func deleteTorrents(ids: [Int], deleteLocalData: Bool) async throws -> Bool {
        struct DeleteRequest: Codable {
            var method = "torrent-remove"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
                let deleteLocalData: Bool
                
                enum CodingKeys: String, CodingKey {
                    case ids
                    case deleteLocalData = "delete-local-data"
                }
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = DeleteRequest(arguments: .init(ids: ids, deleteLocalData: deleteLocalData))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await deleteTorrents(ids: ids, deleteLocalData: deleteLocalData)
                }
                throw TorrentOperationError.serverError("Session ID not found in 409 response")
            }
        }
        
        struct Response: Codable {
            let result: String
        }
        
        let response = try JSONDecoder().decode(Response.self, from: data)
        let success = response.result == "success"
        
        if success {
            // Trigger a refresh to update the torrents list
            try? await fetchUpdates()
        }
        
        return success
    }
    
    /// Moves one or more torrents to a new location
    /// - Parameters:
    ///   - ids: Array of torrent IDs to move
    ///   - location: New location path
    ///   - move: If true, physically move files. If false, just update the location
    /// - Returns: True if move was successful
    func moveTorrents(ids: [Int], to location: String, move: Bool = true) async throws -> Bool {
        struct MoveRequest: Codable {
            var method = "torrent-set-location"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
                let location: String
                let move: Bool
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = MoveRequest(arguments: .init(ids: ids, location: location, move: move))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await moveTorrents(ids: ids, to: location, move: move)
                }
                throw TorrentOperationError.serverError("Session ID not found in 409 response")
            }
        }
        
        struct Response: Codable {
            let result: String
        }
        
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.result == "success"
    }
    
    
    
    /// Renames a path within a torrent
    /// - Parameters:
    ///   - ids: Single torrent ID (array must contain exactly one ID)
    ///   - path: Path to the file or folder to rename
    ///   - newName: New name for the file or folder
    /// - Returns: Tuple containing the old path, new name, and torrent ID if successful
    func renamePath(ids: [Int], path: String, newName: String) async throws -> (path: String, name: String, id: Int) {
        // Verify we only have one ID as required by the API
        guard ids.count == 1 else {
            throw TorrentOperationError.multipleIdsForRename
        }
        
        struct RenameRequest: Codable {
            var method = "torrent-rename-path"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
                let path: String
                let name: String
            }
        }
        
        struct RenameResponse: Codable {
            let result: String
            let arguments: Arguments
            
            struct Arguments: Codable {
                let path: String
                let name: String
                let id: Int
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = RenameRequest(arguments: .init(ids: ids, path: path, name: newName))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await renamePath(ids: ids, path: path, newName: newName)
                }
                throw TorrentOperationError.serverError("Session ID not found in 409 response")
            }
        }
        
        let response = try JSONDecoder().decode(RenameResponse.self, from: data)
        
        if response.result == "success" {
            // Refresh torrent data to update files and name
            try? await fetchUpdates()
            return (response.arguments.path, response.arguments.name, response.arguments.id)
        } else {
            throw TorrentOperationError.invalidResponse
        }
    }
}

// Example usage:
//
// Delete torrents:
// try await torrentManager.deleteTorrents(ids: [1, 2], deleteLocalData: true)
//
// Move torrents:
// try await torrentManager.moveTorrents(ids: [1, 2], to: "/new/download/path", move: true)
//
// Rename a path within a torrent:
// try await torrentManager.renamePath(ids: [1], path: "old/path/name", newName: "new_name")




// MARK: - Additional Operations Extension
extension TorrentManager {
    
    /// Stops one or more torrents.
    /// - Parameter ids: Array of torrent IDs to stop
    /// - Returns: True if the stop operation was successful
    func stopTorrents(ids: [Int]) async throws -> Bool {
        struct StopRequest: Codable {
            var method = "torrent-stop"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = StopRequest(arguments: .init(ids: ids))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode == 409 {
            if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                sessionId = newSessionId
                return try await stopTorrents(ids: ids)
            }
            throw TorrentOperationError.serverError("Session ID not found")
        }
        
        struct Response: Codable {
            let result: String
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        
        if response.result == "success" {
            try? await fetchUpdates()
        }
        
        return response.result == "success"
    }
    
    /// Starts one or more torrents.
    /// - Parameter ids: Array of torrent IDs to start
    /// - Returns: True if the start operation was successful
    func startTorrents(ids: [Int]) async throws -> Bool {
        struct StartRequest: Codable {
            var method = "torrent-start"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = StartRequest(arguments: .init(ids: ids))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode == 409 {
            if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                sessionId = newSessionId
                return try await startTorrents(ids: ids)
            }
            throw TorrentOperationError.serverError("Session ID not found in 409 response")
        }
        
        struct Response: Codable {
            let result: String
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        
        if response.result == "success" {
            try? await fetchUpdates()
        }
        
        return response.result == "success"
    }
    
    /// Reannounces one or more torrents.
    /// - Parameter ids: Array of torrent IDs to reannounce
    /// - Returns: True if the reannounce operation was successful
    func reannounceTorrents(ids: [Int]) async throws -> Bool {
        struct ReannounceRequest: Codable {
            var method = "torrent-reannounce"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = ReannounceRequest(arguments: .init(ids: ids))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode == 409 {
            if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                sessionId = newSessionId
                return try await reannounceTorrents(ids: ids)
            }
            throw TorrentOperationError.serverError("Session ID not found in 409 response")
        }
        
        struct Response: Codable {
            let result: String
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        
        if response.result == "success" {
            try? await fetchUpdates()
        }
        
        return response.result == "success"
    }
    
    /// Verifies one or more torrents.
    /// - Parameter ids: Array of torrent IDs to verify
    /// - Returns: True if the verify operation was successful
    func verifyTorrents(ids: [Int]) async throws -> Bool {
        struct VerifyRequest: Codable {
            var method = "torrent-verify"
            let arguments: Arguments
            
            struct Arguments: Codable {
                let ids: [Int]
            }
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = VerifyRequest(arguments: .init(ids: ids))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode == 409 {
            if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                sessionId = newSessionId
                return try await verifyTorrents(ids: ids)
            }
            throw TorrentOperationError.serverError("Session ID not found in 409 response")
        }
        
        struct Response: Codable {
            let result: String
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        
        if response.result == "success" {
            try? await fetchUpdates()
        }
        
        return response.result == "success"
    }
}
