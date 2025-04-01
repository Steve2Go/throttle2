import Foundation
import FlyingFox
import Citadel
import NIOCore
import NIOPosix

class SFTPVideoStreamingServer {
    private let port: UInt16
    private let sshClient: SSHClient
    private let server: HTTPServer
    private var sftp: SFTPClient?
    
    init(port: UInt16, sshClient: SSHClient) {
        self.port = port
        self.sshClient = sshClient
        self.server = HTTPServer(port: port)
    }
    
    func start() async throws {
        // Initialize SFTP client
        self.sftp = try await sshClient.openSFTP()
        
        // Register a single route handler for all media files
        server.register { [weak self] request in
            guard let self = self else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            return try await self.handleMediaRequest(request)
        }
        
        // Start the server
        try await server.start()
        print("SFTP media streaming server started on port \(port)")
    }
    
    func stop() async {
        await server.stop()
        print("SFTP media streaming server stopped")
    }
    
    private func handleMediaRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let sftp = self.sftp else {
            return HTTPResponse(statusCode: .serviceUnavailable)
        }
        
        // Get the path from the request
        let remotePath = request.path
        
        // Check if the file exists and get its attributes
        let attributes: SFTPFileAttributes
        do {
            attributes = try await sftp.stat(path: remotePath)
        } catch {
            return HTTPResponse(statusCode: .notFound)
        }
        
        // Get file size
        let fileSize = attributes.size
        
        // Parse range header if present
        var rangeStart: UInt64 = 0
        var rangeEnd: UInt64 = fileSize - 1
        var isPartialRequest = false
        
        if let rangeHeader = request.headers.first(where: { $0.name.lowercased() == "range" })?.value {
            if let rangeValue = rangeHeader.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
               rangeValue.hasPrefix("bytes") {
                let rangeString = rangeValue.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let components = rangeString.split(separator: "-")
                
                if components.count > 0 {
                    if let start = UInt64(components[0]) {
                        rangeStart = start
                        isPartialRequest = true
                    }
                    
                    if components.count > 1, !components[1].isEmpty, let end = UInt64(components[1]) {
                        rangeEnd = min(end, fileSize - 1)
                    }
                }
            }
        }
        
        // Make sure the range is valid
        if rangeStart >= fileSize || rangeEnd < rangeStart {
            return HTTPResponse(statusCode: .requestedRangeNotSatisfiable)
        }
        
        // Calculate the length to read
        let length = min(UInt32(rangeEnd - rangeStart + 1), UInt32(8 * 1024 * 1024)) // Limit to 8MB chunks
        
        // Open the file
        let handle = try await sftp.openFile(path: remotePath, flags: .read)
        defer {
            Task {
                try? await sftp.closeFile(handle: handle)
            }
        }
        
        // Read the requested range
        let data = try await sftp.readFile(handle: handle, offset: rangeStart, length: length)
        
        // Prepare response headers
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: mimeType(for: remotePath))
        headers.add(name: "Accept-Ranges", value: "bytes")
        
        if isPartialRequest {
            headers.add(name: "Content-Range", value: "bytes \(rangeStart)-\(rangeStart + UInt64(data.readableBytes) - 1)/\(fileSize)")
            return HTTPResponse(statusCode: .partialContent, headers: headers, body: data)
        } else {
            headers.add(name: "Content-Length", value: String(data.readableBytes))
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        }
    }
    
    private func mimeType(for path: String) -> String {
        let ext = path.split(separator: ".").last?.lowercased() ?? ""
        switch ext {
            case "mp4": return "video/mp4"
            case "mov": return "video/quicktime"
            case "mkv": return "video/x-matroska"
            case "avi": return "video/x-msvideo"
            case "jpeg", "jpg": return "image/jpeg"
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            default: return "application/octet-stream"
        }
    }
}

// Example usage:
// Create SSH client using Citadel
// let sshClient = try await SSHClient.connect(...)
// let server = SFTPVideoStreamingServer(port: 8080, sshClient: sshClient)
// try await server.start()