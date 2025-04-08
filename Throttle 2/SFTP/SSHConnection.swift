import Foundation
import Citadel
import NIOCore
// tunnel via ssh for rpc.
//also attempted a pythoin server for file streaming running on the server, but it would crash the app every time we stopped a download in progress. 
class SSHConnection {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var client: SSHClient?
    
    init(host: String, port: Int = 22, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
    
    func connect() async throws {
        client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }
    
    func executeCommand(_ command: String, maxResponseSize: Int? = nil, mergeStreams: Bool = false) async throws -> (status: Int32, output: String) {
        if client == nil {
            try await connect()
        }
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let buffer: ByteBuffer
        if let maxSize = maxResponseSize {
            buffer = try await client.executeCommand(command, maxResponseSize: maxSize, mergeStreams: mergeStreams)
        } else {
            buffer = try await client.executeCommand(command)
        }
        
        let output = String(buffer: buffer)
        return (0, output)
    }
    
    func executeCommandWithStreams(_ command: String) async throws -> ExecCommandStream {
        if client == nil {
            try await connect()
        }
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        return try await client.executeCommandPair(command)
    }
    
    func disconnect() {
        client = nil
    }
    
    deinit {
        disconnect()
    }
}
