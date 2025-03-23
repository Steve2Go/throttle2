
import SwiftUI

struct TorrentSetRequest: Codable {
    var method = "torrent-set"
    let arguments: Arguments
    
    struct Arguments: Codable {
        let ids: [Int]
        let filesWanted: [Int]?
        let filesUnwanted: [Int]?
        
        enum CodingKeys: String, CodingKey {
            case ids
            case filesWanted = "files-wanted"
            case filesUnwanted = "files-unwanted"
        }
    }
}
extension TorrentManager {
    func setTorrentFiles(id: Int, wanted: [Int]?, unwanted: [Int]?) async throws {
        print("📝 Setting files for torrent \(id)")
        print("   Wanted: \(wanted?.count ?? 0) files")
        print("   Unwanted: \(unwanted?.count ?? 0) files")
        
        // Send the torrent-set request
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let setRequest = TorrentSetRequest(arguments: .init(
            ids: [id],
            filesWanted: wanted,
            filesUnwanted: unwanted
        ))
        
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(setRequest)
        urlRequest.httpBody = requestData
        
        let (_, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await setTorrentFiles(id: id, wanted: wanted, unwanted: unwanted)
                }
                throw NSError(domain: "TransmissionClient", code: 409)
            }
        }
        
        print("✅ File selection updated, fetching new state")
        
        // Now fetch the updated torrent state
        let getRequest = TorrentRequest(
            fields: ["id", "files", "wanted", "percentDone", "fileStats"],
            ids: [id]
        )
        urlRequest.httpBody = try encoder.encode(getRequest)
        
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        let response = try JSONDecoder().decode(TorrentResponse.self, from: data)
        
        print("📥 Got updated torrent data")
        if let torrent = response.arguments.torrents.first {
            print("   Fields received: \(torrent.dynamicFields.keys.joined(separator: ", "))")
            if let files = torrent.dynamicFields["files"]?.value as? [[String: Any]] {
                print("   Files count: \(files.count)")
            }
        }
        
//        await MainActor.run {
//            // Update the cache with the new data
//            if let torrent = response.arguments.torrents.first {
//                print("🔄 Updating cache for torrent \(id)")
//                let oldFileCount = torrent.dynamicFields["files"]?.value as? [[String: Any]]
//                print("   Old files in cache: \(oldFileCount?.count ?? 0)")
//                
////                // Update cache
////                for (key, value) in torrent.dynamicFields {
////                    torrent.dynamicFields[key] = value
////                }
//                
//                let newFileCount = torrent.dynamicFields["files"]?.value as? [[String: Any]]
//                //print("   New files in cache: \(newFileCount?.count ?? 0)")
//                
//                // Update torrents array
//                if let index = torrents.firstIndex(where: { $0.id == id }) {
//                    //print("   Updating torrent at index \(index)")
////                    var updatedTorrent = torrents[index]
////                    updatedTorrent.dynamicFields = torrentCache[id] ?? [:]
////                    torrents[index] = updatedTorrent
//                }
//            }
//        }
    }
}
