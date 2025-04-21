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
    var hashString: String? { dynamicFields["hashString"]?.value as? String }
    
    var id: Int {
        dynamicFields["id"]?.value as? Int ?? 0
    }
    var trackerStats: [[String: Any]]? {
            guard let anyCodable = dynamicFields["trackerStats"],
                  let array = anyCodable.value as? [[String: Any]] else {
                //print("⚠️ trackerStats not found or incorrect format")
                
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
@MainActor
class TorrentManager: ObservableObject {
    @Published var torrents: [Torrent] = []
    var fileCache: [String: [[String: Any]]] = [:]
    private var downloadingCount: Int = 0
    @Published var isLoading = false
    private var nextFull = 0
    
    var baseURL: URL?
    var sessionId: String?
     var fetchTimer: Timer?
    @AppStorage("refreshRate") var refreshRate = 6
    
    private let standardFields = [
        "id", "name", "percentDone", "percentComplete", "status", "addedDate",
        "downloadedEver", "uploadedEver", "totalSize", "activityDate",
        "error", "errorString", "labels", "downloadDir","hashString"
    ]
    
    private let fileFields = ["files", "fileStats"]
    
//    private let detailFields = [
//        "files",
//        "fileStats",
//        "uploadRatio",
//        "trackerStats",
//        "addedDate",
//    ]
    
    func updateBaseURL(_ url: URL) {
        print("Base Changed")
        baseURL = url
        reset()
    }

    func reset() {
        print("manger reset")
        torrents = []
        fileCache = [:]
        sessionId = nil
    }
    
    
    
    func getTorrentFiles(forHash hash: String) -> [TorrentFile] {
        guard let filesData = fileCache[hash] else { return [] }
        
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
    
    

    
    func addTorrent(fileURL: URL? = nil, magnetLink: String? = nil, downloadDir: String? = nil) async throws -> (result: String, id: Int?) {
           var arguments: [String: Any] = [:]
           
           if let downloadDir = downloadDir {
               arguments["download-dir"] = downloadDir
           }
           
           if let magnetLink = magnetLink {
               arguments["filename"] = magnetLink
           }
           
           if let fileURL = fileURL {
               arguments["metainfo"] = try Data(contentsOf: fileURL).base64EncodedString()
           }
           
           let (success, responseArgs) = try await makeRequest("torrent-add", arguments: arguments)
           
           if success {
               let addedTorrent = (responseArgs?["torrent-added"] as? [String: Any]) ??
                                 (responseArgs?["torrent-duplicate"] as? [String: Any])
               
               if let id = addedTorrent?["id"] as? Int {
                   return ("success", id)
               }
           }
           
           return ("failed", nil)
       }
    
    func fetchTorrentDetails(id: Int) async throws -> Torrent? {
        let detailFields = standardFields + [
            "files",
            "fileStats",
            "uploadRatio",
            "trackerStats",
            "addedDate",
            "activityDate",
            "downloadedEver",
            "uploadedEver",
            "totalSize",
            "magnetLink",
            "torrentFile"
        ]
        

        let (success, responseArgs) = try await makeRequest(
            "torrent-get",
            arguments: [
                "fields": detailFields,
                "ids": [id]
            ]
        )
        
        if success,
           let torrentData = (responseArgs?["torrents"] as? [[String: Any]])?.first {
            let decoder = JSONDecoder()
            let data = try JSONSerialization.data(withJSONObject: torrentData)
            return try decoder.decode(Torrent.self, from: data)
        }
        
        return nil
    }
    
    func makeRequest(_ method: String, arguments: [String: Any]) async throws -> (Bool, [String: Any]?) {
            guard let baseURL = baseURL else { return (false, nil) }
            
            var urlRequest = URLRequest(url: baseURL)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let sessionId = sessionId {
                urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
            }
            
            let requestDict: [String: Any] = ["method": method, "arguments": arguments]
            let requestData = try JSONSerialization.data(withJSONObject: requestDict)
            urlRequest.httpBody = requestData
            
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409,
               let newSessionId = httpResponse.allHeaderFields["X-Transmission-Session-Id"] as? String {
                sessionId = newSessionId
                return try await makeRequest(method, arguments: arguments)
            }
            
            let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let success = responseDict?["result"] as? String == "success"
            let responseArgs = responseDict?["arguments"] as? [String: Any]
            
            return (success, responseArgs)
        }
    
    func fetchUpdates(selectedId: Int? = nil, fullFetch: Bool = false) async throws {
        guard let baseURL = baseURL else { return }
        
        defer { isLoading = false }
       // await TunnelManagerHolder.shared.ensureAllTunnelsHealth()
        var fieldsToFetch: [String] = []
        
        let firstFetch = fullFetch == true ? true : fileCache.isEmpty
        
        
        
        
        
        //do a full fecth every 15.
//        //TODO: Do this only if there is a download
//        if firstFetch {
//            nextFull = 15
//        }else{
//            if nextFull == 0{
//                nextFull = 15
//                firstFetch = true
//                fileCache = [:]
//            }else {
//                nextFull = nextFull - 1
//            }
//        }
        
            
            fieldsToFetch = firstFetch ? standardFields + ["files"] : standardFields
     
        
        
        // Make base request
        let request = TorrentRequest(fields: fieldsToFetch)
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId = sessionId {
            urlRequest.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }
        
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        urlRequest.httpBody = requestData
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409 {
            if let responseText = String(data: data, encoding: .utf8),
               let range = responseText.range(of: "X-Transmission-Session-Id: "),
               let endRange = responseText[range.upperBound...].range(of: "</code>") {
                let newSessionId = String(responseText[range.upperBound..<endRange.lowerBound])
                sessionId = newSessionId
                return try await fetchUpdates(selectedId: selectedId)
            }
        }
        
        let decodedResponse = try JSONDecoder().decode(TorrentResponse.self, from: data)
        
        // Handle file caching
        if firstFetch && selectedId == nil {
            if fullFetch {
                fileCache = [:]
            }
            print("First fetch - caching files")
            print("Number of torrents: \(decodedResponse.arguments.torrents.count)")
            for torrent in decodedResponse.arguments.torrents {
                if let hash = torrent.hashString {
                   // print("Got hash: \(hash)")
                    print("Files data type: \(type(of: torrent.dynamicFields["files"]?.value ?? "none"))")
                    if let filesData = torrent.dynamicFields["files"]?.value as? [[String: Any]] {
                        print("Cast succeeded: \(filesData.count) files")
                        fileCache[hash] = filesData
                    } else {
                        print("Cast failed")
                    }
                }
            }
        }
        
        
        
        
        
        let torrentsToUpdate = decodedResponse.arguments.torrents
        
        
        //how many downloads?
        let thisDownloadingCount = torrentsToUpdate.filter({$0.percentComplete != 1}).count
        //print("Download Count: \(thisDownloadingCount)")
        
        if thisDownloadingCount < downloadingCount && !fullFetch {
            //fileCache = [:]
            try await fetchUpdates( fullFetch: true)
        }
        
        downloadingCount = thisDownloadingCount
        
        
        torrents = torrentsToUpdate
    }


    func startPeriodicUpdates(selectedId: Int? = nil) {
        // First, stop any existing timer to avoid duplicates
        stopPeriodicUpdates()
        
        // Initial fetch
//        Task {
//            try? await fetchUpdates(selectedId: selectedId)
//        }
        
        // Create new timer
        fetchTimer = Timer.scheduledTimer(withTimeInterval: Double(refreshRate), repeats: true) { [weak self] _ in
            Task {
                if let selectedId = selectedId {
                    try? await self?.fetchUpdates(selectedId: selectedId)
                } else {
                    try? await self?.fetchUpdates()
                }
            }
        }
    }

    func stopPeriodicUpdates() {
        fetchTimer?.invalidate()
        fetchTimer = nil
    }
}


// Extension to create Torrent from cached fields
extension Torrent {
    init(from fields: [String: AnyCodable]) {
        self.dynamicFields = fields
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
        try await fetchUpdates()
        
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
    
    func getFiles(forHash hash: String) -> [[String: Any]]? {
        return fileCache[hash]
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
        try await fetchUpdates()
        
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



