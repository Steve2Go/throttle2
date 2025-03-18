//
//  TorrentLabels.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/2/2025.
//

import SwiftUI
extension TorrentManager {
    struct LabelRequest: Codable {
        var method = "torrent-set"
        let arguments: Arguments
        
        struct Arguments: Codable {
            let ids: [Int]
            let labels: [String]
        }
    }
    
    func getLabels(for torrentId: Int) -> [String] {
        return torrentCache[torrentId]?["labels"]?.value as? [String] ?? []
    }
    
    func isStarred(_ torrentId: Int) -> Bool {
        let labels = getLabels(for: torrentId)
        return labels.contains("starred")
    }
    
    func toggleStar(for torrentId: Int) async throws {
        var currentLabels = getLabels(for: torrentId)
        let isCurrentlyStarred = currentLabels.contains("starred")
        
        // Prepare new labels array
        if isCurrentlyStarred {
            currentLabels.removeAll { $0 == "starred" }
        } else {
            currentLabels.append("starred")
        }
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = LabelRequest(arguments: .init(ids: [torrentId], labels: currentLabels))
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await toggleStar(for: torrentId)
                }
                throw TorrentOperationError.serverError("Session ID not found in 409 response")
            }
        }
        
        struct Response: Codable {
            let result: String
        }
        
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.result == "success" {
            // Update the local cache immediately
            await MainActor.run {
                if var fields = torrentCache[torrentId] {
                    fields["labels"] = AnyCodable(currentLabels)
                    torrentCache[torrentId] = fields
                }
            }
        } else {
            throw TorrentOperationError.serverError("Failed to update labels")
        }
    }
}
