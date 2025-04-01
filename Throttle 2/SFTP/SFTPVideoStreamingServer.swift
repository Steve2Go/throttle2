//import Foundation
//import FlyingFox
//import NIOCore
//import KeychainAccess
//import mft
//
//class SFTPVideoStreamingServer {
//    private let port: UInt16
//    private let server: HTTPServer
//    private let serverEntity: ServerEntity
//    private var sftpConnection: MFTSftpConnection?
//    
//    init(port: UInt16, serverEntity: ServerEntity) {
//        self.port = port
//        self.serverEntity = serverEntity
//        self.server = HTTPServer(port: port)
//    }
//    
//    func start() async throws {
//        // Initialize SFTP connection using MFT
//        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
//        
//        if serverEntity.sftpUsesKey {
//            // Key-based authentication
//            let key = keychain["sftpKey" + (serverEntity.name ?? "")] ?? ""
//            let password = keychain["sftpPassword" + (serverEntity.name ?? "")] ?? ""
//            
//            self.sftpConnection = MFTSftpConnection(
//                hostname: serverEntity.sftpHost ?? "",
//                port: Int(serverEntity.sftpPort),
//                username: serverEntity.sftpUser ?? "",
//                prvKey: key,
//                passphrase: password
//            )
//        } else {
//            // Password authentication
//            let password = keychain["sftpPassword" + (serverEntity.name ?? "")] ?? ""
//            
//            self.sftpConnection = MFTSftpConnection(
//                hostname: serverEntity.sftpHost ?? "",
//                port: Int(serverEntity.sftpPort),
//                username: serverEntity.sftpUser ?? "",
//                password: password
//            )
//        }
//        
//        do {
//            try self.sftpConnection?.connect()
//            try self.sftpConnection?.authenticate()
//        } catch {
//            throw error
//        }
//        
//        // Register a route handler for media files
//        await server.appendRoute("/*") { [weak self] request in
//            guard let self = self, let sftpConnection = self.sftpConnection else {
//                return HTTPResponse(statusCode: .internalServerError)
//            }
//            
//            do {
//                return try await self.handleMediaRequest(request, sftpConnection: sftpConnection)
//            } catch {
//                print("Error handling request: \(error)")
//                return HTTPResponse(statusCode: .internalServerError)
//            }
//        }
//        
//        // Start the server
//        try await server.start()
//        try await server.waitUntilListening()
//        print("SFTP media streaming server started on port \(port)")
//    }
//    
//    func stop() async {
//        await server.stop()
//        self.sftpConnection = nil
//        print("SFTP media streaming server stopped")
//    }
//    
//    private func handleMediaRequest(_ request: HTTPRequest, sftpConnection: MFTSftpConnection) async throws -> HTTPResponse {
//        // Get the path from the request
//        let remotePath = request.path
//        
//        // Get file info
//        let fileInfo: MFTSftpItem
//        
//        do {
//            fileInfo = try sftpConnection.infoForFile(atPath: remotePath)
//        } catch {
//            return HTTPResponse(statusCode: .notFound)
//        }
//        
//        let fileSize = fileInfo.size
//        
//        // Parse range header if present
//        var rangeStart: UInt64 = 0
//        var rangeEnd: UInt64 = fileSize - 1
//        var isPartialRequest = false
//        
//        if let rangeHeader = request.headers[HTTPHeader("Range")] {
//            if rangeHeader.hasPrefix("bytes=") {
//                let rangeString = rangeHeader.dropFirst(6)
//                let components = rangeString.split(separator: "-")
//                
//                if components.count > 0, let start = UInt64(components[0]) {
//                    rangeStart = start
//                    isPartialRequest = true
//                
//                    if components.count > 1, !components[1].isEmpty, let end = UInt64(components[1]) {
//                        rangeEnd = min(end, fileSize - 1)
//                    }
//                }
//            }
//        }
//        
//        // Make sure the range is valid
//        if rangeStart >= fileSize || rangeEnd < rangeStart {
//            return HTTPResponse(statusCode: .badRequest)
//        }
//        
//        // Calculate length to read (capped at 8MB for efficiency)
//        let length = min(rangeEnd - rangeStart + 1, 8 * 1024 * 1024)
//        
//        // Create an output stream that writes to memory
//        let outputStream = OutputStream.toMemory()
//        outputStream.open()
//        
//        // Define a progress handler that returns true to continue
//        let progressHandler: (UInt64, UInt64) -> Bool = { _, _ in
//            return true // Always continue
//        }
//        
//        do {
//            // Read the specific part of the file
//            try sftpConnection.contents(
//                atPath: remotePath,
//                toStream: outputStream,
//                fromPosition: rangeStart,
//                progress: progressHandler
//            )
//        } catch let error as NSError {
//            // Ignore error 999 (expected when closing streams early)
//            if error.code != 999 {
//                throw error
//            }
//        }
//        
//        // Get the data from the output stream
//        var responseData = Data()
//        if let nsData = outputStream.property(forKey: .dataWrittenToMemoryStreamKey) as? NSData {
//            responseData = Data(referencing: nsData)
//        }
//        
//        outputStream.close()
//        
//        // Prepare response headers
////        var headers = [HTTPHeader: String]()
//        headers[HTTPHeader("Content-Type")] = mimeType(for: remotePath)
//        headers[HTTPHeader("Accept-Ranges")] = "bytes"
//        headers[HTTPHeader("Content-Length")] = String(responseData.count)
//        
//        if isPartialRequest {
//            headers[HTTPHeader("Content-Range")] = "bytes \(rangeStart)-\(rangeStart + UInt64(responseData.count) - 1)/\(fileSize)"
//            return HTTPResponse(
//                version: .http11,
//                statusCode: .partialContent,
//                headers: headers,
//                body: responseData
//            )
//        } else {
//            return HTTPResponse(
//                version: .http11,
//                statusCode: .ok,
//                headers: headers,
//                body: responseData
//            )
//        }
//    }
//    
//    private func mimeType(for path: String) -> String {
//        let ext = path.split(separator: ".").last?.lowercased() ?? ""
//        switch ext {
//            case "mp4": return "video/mp4"
//            case "mov": return "video/quicktime"
//            case "mkv": return "video/x-matroska"
//            case "avi": return "video/x-msvideo"
//            case "m4v": return "video/x-m4v"
//            case "webm": return "video/webm"
//            case "jpeg", "jpg": return "image/jpeg"
//            case "png": return "image/png"
//            case "gif": return "image/gif"
//            case "webp": return "image/webp"
//            case "heic": return "image/heic"
//            default: return "application/octet-stream"
//        }
//    }
//}
