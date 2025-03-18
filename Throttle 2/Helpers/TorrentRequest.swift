//
//  TorrentRequest.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 20/2/2025.
//
import SwiftUI

// MARK: - Models
struct TorrentRequest: Codable {
    var method = "torrent-get"
    let arguments: Arguments
    
    struct Arguments: Codable {
        let fields: [String]
        let ids: [Int]?
    }
    
    init(fields: [String], ids: [Int]? = nil) {
        self.arguments = Arguments(fields: fields, ids: ids)
    }
}

struct TorrentResponse: Codable {
    let arguments: Arguments
    let result: String
    
    struct Arguments: Codable {
        let torrents: [Torrent]
        let removed: [Int]?
    }
}

struct TorrentFile: Codable, Identifiable {
    let name: String
    let length: Int64
    let bytesCompleted: Int64
    
    // Computed properties
    var id: String { name } // Using name as identifier since files have unique paths
    var progress: Double {
        length > 0 ? Double(bytesCompleted) / Double(length) : 0
    }
    
    // For debug purposes
    func debugPrint() {
        print("File: \(name)")
        print("- Length: \(length)")
        print("- Completed: \(bytesCompleted)")
        print("- Progress: \(Int(progress * 100))%")
    }
}

extension Torrent {
    var addedDate: Date? {
        if let timestamp = dynamicFields["addedDate"]?.value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return nil
    }
    
    var activityDate: Date? {
        if let timestamp = dynamicFields["activityDate"]?.value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return nil
    }
}



struct Torrent: Codable, Identifiable, Observable {
    var dynamicFields: [String: AnyCodable]
    
    var id: Int {
        dynamicFields["id"]?.value as? Int ?? 0
    }
    var trackerStats: [[String: Any]]? {
            guard let anyCodable = dynamicFields["trackerStats"],
                  let array = anyCodable.value as? [[String: Any]] else {
                print("⚠️ trackerStats not found or incorrect format")
                
                return nil
            }
            return array
        }
    
    
    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        
        init?(intValue: Int) {
            return nil
        }
        
    }
    
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var fields: [String: AnyCodable] = [:]
        
        for key in container.allKeys {
            fields[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
        }
        
        self.dynamicFields = fields
    }
    
    var name: String? { dynamicFields["name"]?.value as? String }
    
    // Progress related fields
    var percentDone: Double? {
        if let value = dynamicFields["percentDone"]?.value {
            return (value as? Double) ?? (value as? Int).map(Double.init)
        }
        return nil
    }
    
    var percentComplete: Double? {
        if let value = dynamicFields["percentComplete"]?.value {
            return (value as? Double) ?? (value as? Int).map(Double.init)
        }
        return nil
    }
    
    // Size related fields
    var downloadedEver: Int64? {
        if let value = dynamicFields["downloadedEver"]?.value {
            return (value as? Int64) ?? (value as? Int).map(Int64.init)
        }
        return nil
    }
    
    var totalSize: Int64? {
        if let value = dynamicFields["totalSize"]?.value {
            return (value as? Int64) ?? (value as? Int).map(Int64.init)
        }
        return nil
    }
    
    // Status and error fields
    var status: Int? { dynamicFields["status"]?.value as? Int }
    var error: Int? { dynamicFields["error"]?.value as? Int }
    var errorString: String? { dynamicFields["errorString"]?.value as? String }
    
    // Tracker related fields
    var trackers: [[String: Any]]? { dynamicFields["trackers"]?.value as? [[String: Any]] }
    //var trackerStats: [[String: Any]]? { dynamicFields["trackerStats"]?.value as? [[String: Any]] }
    
    // Files
    var files: [TorrentFile] {
        guard let filesData = dynamicFields["files"]?.value as? [[String: Any]] else {
            return []
        }
        
        return filesData.compactMap { dict -> TorrentFile? in
            guard let name = dict["name"] as? String,
                  let length = (dict["length"] as? Int64) ?? (dict["length"] as? Int).map(Int64.init),
                  let bytesCompleted = (dict["bytesCompleted"] as? Int64) ?? (dict["bytesCompleted"] as? Int).map(Int64.init)
            else {
                print("Failed to parse file: \(dict)")
                return nil
            }
            return TorrentFile(name: name, length: length, bytesCompleted: bytesCompleted)
        }
    }
    
    // Progress computation
    var progress: Double {
        if let pDone = percentDone {
            return pDone
        }
        if let pComplete = percentComplete {
            return pComplete
        }
        if let downloaded = downloadedEver, let total = totalSize, total > 0 {
            return Double(downloaded) / Double(total)
        }
        return 0
    }
}

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self.value = NSNull()
        } else if let value = try? container.decode(Bool.self) {
            self.value = value
        } else if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let value = try? container.decode(Double.self) {
            self.value = value
        } else if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode([AnyCodable].self) {
            self.value = value.map(\.value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self.value = value.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let value as Bool:
            try container.encode(value)
        case let value as Int:
            try container.encode(value)
        case let value as Double:
            try container.encode(value)
        case let value as String:
            try container.encode(value)
        case let value as [Any]:
            try container.encode(value.map(AnyCodable.init))
        case let value as [String: Any]:
            try container.encode(value.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Invalid JSON value"
            ))
        }
    }
}

// MARK: - Store
class TorrentManager: ObservableObject {
    @Published  var torrents: [Torrent] = []
    @Published  var isLoading = false
    
     var fetchTimer: Timer?
     var baseURL: URL?
     var sessionId: String?
     var torrentCache: [Int: [String: AnyCodable]] = [:] // Cache for maintaining complete torrent data
    
//    init(baseURL: URL) {
//        self.baseURL = baseURL
//    }
    
    func sortBy (field: String){
        
    }
    
    func reset() {
        torrents = []
        torrentCache = [:]
        sessionId = nil
    }
    
    func updateBaseURL(_ url: URL) {
        baseURL = url
        reset()
    }
    
    func updateTorrentsFromResponse(_ response: TorrentResponse, requestedFields: [String]) {
        //print("🔄 Updating torrents with fields: \(requestedFields)")
        
        // Get set of current torrent IDs from response
        let responseIds = Set(response.arguments.torrents.map { $0.id })
        
        // Find IDs that are in our cache but not in the response
        let removedIds = Set(torrentCache.keys).subtracting(responseIds)
        if !removedIds.isEmpty {
            print("🗑️ Removing torrents not in response: \(removedIds)")
            for id in removedIds {
                torrentCache.removeValue(forKey: id)
            }
        }
        
        // Handle explicit removals if present
        if let removed = response.arguments.removed {
            print("🗑️ Removing explicitly removed torrents: \(removed)")
            for id in removed {
                torrentCache.removeValue(forKey: id)
            }
        }
        
        // Keep track of new torrents that need full details
        var newTorrentIds: [Int] = []
        
        // Update cache with new data
        for torrent in response.arguments.torrents {
            //print("Processing torrent ID: \(torrent.id)")
           // print("🚀 Full Torrent dynamicFields: \(torrent.dynamicFields)")
            if torrentCache[torrent.id] == nil {
                // New torrent - store current fields and mark for full fetch
                print("New torrent detected - storing current fields and queuing full fetch")
                torrentCache[torrent.id] = torrent.dynamicFields
                newTorrentIds.append(torrent.id)
            } else {
                // Existing torrent - update only requested fields
                for field in requestedFields {
                    if let value = torrent.dynamicFields[field] {
                        //print("Updating field: \(field)")
                        torrentCache[torrent.id]?[field] = value
                    }
                }
            }
        }
        
        // Rebuild torrents array from cache
        torrents = torrentCache.map { (id, fields) in
            var torrent = Torrent(from: fields)
            torrent.dynamicFields = fields
            return torrent
        }.sorted { ($0.name ?? "") < ($1.name ?? "") }
        
        // If we found any new torrents, fetch their full details
        if !newTorrentIds.isEmpty {
            print("🔄 Fetching full details for new torrents: \(newTorrentIds)")
            Task {
                try? await fetchUpdates(fields: [
                    "id", "name", "percentDone", "status",
                    "downloadedEver", "uploadedEver", "totalSize",
                    "error", "errorString", "files", "activityDate", "addedDate"
                ])
            }
        }
    }
    
    
    func fetchUpdates(ids: [Int]? = nil, fields: [String], isFullRefresh: Bool = false) async throws {
        if baseURL == nil { return }
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        
        print("🔄 Starting fetch with fields:", fields, "isFullRefresh:", isFullRefresh)
        
        // If it's a full refresh, clear the cache first
        if isFullRefresh {
            torrentCache.removeAll()
        }
        
        let request = TorrentRequest(fields: fields, ids: ids)
        
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await fetchUpdates(ids: ids, fields: fields, isFullRefresh: isFullRefresh)
                }
                
                if let responseText = String(data: data, encoding: .utf8),
                   let range = responseText.range(of: "X-Transmission-Session-Id: "),
                   let endRange = responseText[range.upperBound...].range(of: "</code>") {
                    let newSessionId = String(responseText[range.upperBound..<endRange.lowerBound])
                    sessionId = newSessionId
                    return try await fetchUpdates(ids: ids, fields: fields, isFullRefresh: isFullRefresh)
                }
                
                throw NSError(domain: "TransmissionClient", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "Could not find session ID in 409 response"
                ])
            }
            
            if let sessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                self.sessionId = sessionId
            }
        }
        
        let decodedResponse = try JSONDecoder().decode(TorrentResponse.self, from: data)
        
        await MainActor.run {
            updateTorrentsFromResponse(decodedResponse, requestedFields: fields)
        }
    }
    
    func startPeriodicUpdates(interval: TimeInterval = 5.0) {
        fetchTimer?.invalidate()
        
        // Initial fetch with all fields
        Task {
            try? await fetchUpdates(fields: [
                "id", "name", "percentDone", "status",
                "downloadedEver", "uploadedEver", "totalSize",
                "error", "errorString", "files", "addedDate" , "activityDate", "fileStats", "trackerStats"
            ], isFullRefresh: true)
        }
        
        // Periodic updates with essential fields including files
        fetchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                try? await self?.fetchUpdates(fields: [
                    "id", "percentDone", "percentComplete", "status",
                    "downloadedEver", "uploadedEver",
                    "error", "errorString","activityDate"
                ])
            }
        }
    }
    
    func stopPeriodicUpdates() {
        fetchTimer?.invalidate()
        fetchTimer = nil
    }
    
    // Add these to TorrentManager class:
    struct TorrentAddRequest: Codable {
        var method = "torrent-add"
        let arguments: Arguments
        
        struct Arguments: Codable {
            let filename: String?
            let metainfo: String?
            let downloadDir: String?
            
            enum CodingKeys: String, CodingKey {
                case filename
                case metainfo
                case downloadDir = "download-dir"
            }
        }
    }

    struct TorrentAddResponse: Codable {
        let arguments: Arguments
        let result: String
        
        struct Arguments: Codable {
            let torrentAdded: TorrentAdded?
            let torrentDuplicate: TorrentAdded?
            
            enum CodingKeys: String, CodingKey {
                case torrentAdded = "torrent-added"
                case torrentDuplicate = "torrent-duplicate"
            }
        }
        
        struct TorrentAdded: Codable {
            let id: Int
            let name: String
            let hashString: String
        }
    }

    func addTorrent(fileURL: URL? = nil, magnetLink: String? = nil, downloadDir: String? = nil) async throws -> TorrentAddResponse {
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let arguments: TorrentAddRequest.Arguments
        
        if let fileURL = fileURL {
            // Handle torrent file
            let data = try Data(contentsOf: fileURL)
            let base64String = data.base64EncodedString()
            arguments = .init(filename: nil, metainfo: base64String, downloadDir: downloadDir)
        } else if let magnetLink = magnetLink {
            // Handle magnet link
            arguments = .init(filename: magnetLink, metainfo: nil, downloadDir: downloadDir)
        } else {
            throw NSError(domain: "TorrentManager", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Either file URL or magnet link must be provided"
            ])
        }
        
        let request = TorrentAddRequest(arguments: arguments)
        
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await addTorrent(fileURL: fileURL, magnetLink: magnetLink, downloadDir: downloadDir)
                }
                throw NSError(domain: "TransmissionClient", code: 409)
            }
        }
        
        let response = try JSONDecoder().decode(TorrentAddResponse.self, from: data)
        
        // If successful, trigger a refresh
        if response.result == "success" {
            Task {
                try? await self.fetchUpdates(fields: [
                    "id", "name", "percentDone", "status",
                    "downloadedEver", "uploadedEver", "totalSize",
                    "error", "errorString", "files", "fileStats", "trackerStats"
                ], isFullRefresh: true)
            }
        }
        
        return response
    }
}

// Extension to create Torrent from cached fields
extension Torrent {
    init(from fields: [String: AnyCodable]) {
        self.dynamicFields = fields
    }
}

enum SortOption: String, CaseIterable {
    case name = "Name"
    case dateAdded = "Date Added"
    case activity = "Last Active"
}

extension SortOption {
    static let defaultSort: SortOption = .dateAdded
    
    static let userDefaultsKey = "TorrentListSortOption"
    
    static func saveToDefaults(_ option: SortOption) {
        UserDefaults.standard.set(option.rawValue, forKey: userDefaultsKey)
    }
    
    static func loadFromDefaults() -> SortOption {
        guard let savedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
              let savedOption = SortOption(rawValue: savedValue) else {
            return defaultSort
        }
        return savedOption
    }
}

extension TorrentManager {
    /// Fetches specific fields from the server for all torrents
    /// - Parameter fields: Array of field names to fetch from the server
    /// - Returns: A dictionary mapping torrent IDs to their requested field values
    func getFields(_ fields: [String]) async throws -> [Int: [String: Any]] {
        // Add 'id' to the fields if not present, as we need it for mapping
        var requestFields = fields
        if !fields.contains("id") {
            requestFields.append("id")
        }
        
        // Fetch the updates from server
        try await fetchUpdates(fields: requestFields)
        
        // Create result dictionary
        var result: [Int: [String: Any]] = [:]
        
        // Map the requested fields for each torrent
        for torrent in torrents {
            var torrentFields: [String: Any] = [:]
            for field in fields {
                if let value = torrent.dynamicFields[field]?.value {
                    torrentFields[field] = value
                }
            }
            if !torrentFields.isEmpty {
                result[torrent.id] = torrentFields
            }
        }
        
        return result
    }
    
    /// Fetches a single field from the server for all torrents
    /// - Parameter field: The field name to fetch from the server
    /// - Returns: A dictionary mapping torrent IDs to the requested field value
    func getField<T>(_ field: String) async throws -> [Int: T] {
        let results = try await getFields([field])
        
        // Convert and filter the results to the requested type
        var typedResults: [Int: T] = [:]
        for (id, fields) in results {
            if let value = fields[field] as? T {
                typedResults[id] = value
            }
        }
        
        return typedResults
    }
    
    /// Fetches specific fields from the server for specific torrents
    /// - Parameters:
    ///   - fields: Array of field names to fetch
    ///   - ids: Array of torrent IDs to fetch data for
    /// - Returns: A dictionary mapping torrent IDs to their requested field values
    func getFields(_ fields: [String], forIds ids: [Int]) async throws -> [Int: [String: Any]] {
        // Add 'id' to the fields if not present
        var requestFields = fields
        if !fields.contains("id") {
            requestFields.append("id")
        }
        
        // Fetch updates for specific torrents
        try await fetchUpdates(ids: ids, fields: requestFields)
        
        // Filter results for requested torrents only
        var result: [Int: [String: Any]] = [:]
        for torrent in torrents where ids.contains(torrent.id) {
            var torrentFields: [String: Any] = [:]
            for field in fields {
                if let value = torrent.dynamicFields[field]?.value {
                    torrentFields[field] = value
                }
            }
            if !torrentFields.isEmpty {
                result[torrent.id] = torrentFields
            }
        }
        
        return result
    }
}

//let results = try await torrentManager.getFields(["name", "percentDone", "totalSize"])
//for (id, fields) in results {
//    print("Torrent \(id):")
//    print("- Name: \(fields["name"] as? String ?? "")")
//    print("- Progress: \(fields["percentDone"] as? Double ?? 0)")
//}
//let names = try await torrentManager.getField<String>("name")
//for (id, name) in names {
//    print("Torrent \(id): \(name)")
//}

//let specificTorrents = try await torrentManager.getFields(["name", "percentDone"], forIds: [1, 2, 3])




// MARK: - Session Models
struct SessionRequest: Codable {
    var method = "session-get"
    let arguments: Arguments?
    
    struct Arguments: Codable {
        let fields: [String]?
    }
    
    init(fields: [String]? = nil) {
        self.arguments = fields.map { Arguments(fields: $0) }
    }
}

struct SessionResponse: Codable {
    let arguments: [String: AnyCodable]
    let result: String
    
    struct Units: Codable {
        let speedUnits: [String]
        let speedBytes: Int
        let sizeUnits: [String]
        let sizeBytes: Int
        let memoryUnits: [String]
        let memoryBytes: Int
        
        enum CodingKeys: String, CodingKey {
            case speedUnits = "speed-units"
            case speedBytes = "speed-bytes"
            case sizeUnits = "size-units"
            case sizeBytes = "size-bytes"
            case memoryUnits = "memory-units"
            case memoryBytes = "memory-bytes"
        }
    }
}

// MARK: - Session Manager Extension
extension TorrentManager {
    /// Fetches all session information
    /// - Returns: Dictionary containing all session fields and their values
    func getSession() async throws -> [String: Any] {
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = SessionRequest()
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        // Handle 409 response for session ID
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await getSession()
                }
                throw NSError(domain: "TransmissionClient", code: 409)
            }
        }
        
        let response = try JSONDecoder().decode(SessionResponse.self, from: data)
        return response.arguments.mapValues { $0.value }
    }
    
    /// Fetches specific session fields
    /// - Parameter fields: Array of field names to fetch
    /// - Returns: Dictionary containing requested session fields and their values
    func getSession(fields: [String]) async throws -> [String: Any] {
        var urlRequest = URLRequest(url: baseURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let request = SessionRequest(fields: fields)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        // Handle 409 response for session ID
        if let httpResponse = httpResponse as? HTTPURLResponse {
            if httpResponse.statusCode == 409 {
                if let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                    sessionId = newSessionId
                    return try await getSession(fields: fields)
                }
                throw NSError(domain: "TransmissionClient", code: 409)
            }
        }
        
        let response = try JSONDecoder().decode(SessionResponse.self, from: data)
        var result: [String: Any] = [:]
        
        for field in fields {
            if let value = response.arguments[field]?.value {
                result[field] = value
            }
        }
        
        return result
    }
    
    /// Fetches a single session field with type safety
    /// - Parameter field: The field name to fetch
    /// - Returns: The value of the requested field
    func getSessionField<T>(_ field: String) async throws -> T? {
        let result = try await getSession(fields: [field])
        return result[field] as? T
    }
    
    /// Convenience method to get download directory
    /// - Returns: The configured download directory path
    func getDownloadDirectory() async throws -> String? {
        return try await getSessionField("download-dir")
    }
    
    /// Convenience method to get current speed limits
    /// - Returns: Tuple containing up and down speed limits and their enabled status
    func getSpeedLimits() async throws -> (up: Int?, down: Int?, upEnabled: Bool?, downEnabled: Bool?) {
        let fields = [
            "speed-limit-up",
            "speed-limit-down",
            "speed-limit-up-enabled",
            "speed-limit-down-enabled"
        ]
        
        let result = try await getSession(fields: fields)
        
        return (
            up: result["speed-limit-up"] as? Int,
            down: result["speed-limit-down"] as? Int,
            upEnabled: result["speed-limit-up-enabled"] as? Bool,
            downEnabled: result["speed-limit-down-enabled"] as? Bool
        )
    }
    
    /// Convenience method to get units configuration
    /// - Returns: The units configuration object
    func getUnits() async throws -> SessionResponse.Units? {
        let result = try await getSession(fields: ["units"])
        if let unitsDict = result["units"] as? [String: Any] {
            let unitsData = try JSONSerialization.data(withJSONObject: unitsDict)
            return try JSONDecoder().decode(SessionResponse.Units.self, from: unitsData)
        }
        return nil
    }
}

//let allSessionInfo = try await torrentManager.getSession()
//print("All settings:", allSessionInfo)

//let fields = ["download-dir", "peer-port", "encryption"]
//let specificInfo = try await torrentManager.getSession(fields: fields)
//print("Specific settings:", specificInfo)


//// Get download directory
//if let downloadDir = try await torrentManager.getDownloadDirectory() {
//    print("Downloads go to:", downloadDir)
//}
//
//// Get speed limits
//let speedLimits = try await torrentManager.getSpeedLimits()
//print("Upload limit: \(speedLimits.up ?? 0) KB/s (enabled: \(speedLimits.upEnabled ?? false))")
//print("Download limit: \(speedLimits.down ?? 0) KB/s (enabled: \(speedLimits.downEnabled ?? false))")
//
//// Get units configuration
//if let units = try await torrentManager.getUnits() {
//    print("Speed units:", units.speedUnits)
//    print("Size units:", units.sizeUnits)
//}


