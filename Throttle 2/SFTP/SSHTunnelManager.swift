import Foundation
import Citadel
import KeychainAccess

class SSHTunnelManager {
    static let shared = SSHTunnelManager()
    private var tunnels: [String: (client: SSHClient, channel: Channel)] = [:]
    private let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    
    private init() {}
    
    func getOrCreateTunnel(for server: ServerEntity) async throws -> String {
        let tunnelKey = server.name ?? server.sftpHost ?? ""
        
        // Check if we already have an active tunnel
        if let existingTunnel = tunnels[tunnelKey],
           existingTunnel.channel.isActive {
            return "http://localhost:\(server.sftpRpc)"
        }
        
        // Clean up any existing inactive tunnel
        if let existingTunnel = tunnels[tunnelKey] {
            try? await existingTunnel.channel.close()
            try? await existingTunnel.client.close()
            tunnels.removeValue(forKey: tunnelKey)
        }
        
        // Create new SSH client
        let client: SSHClient
        if server.sftpUsesKey {
            guard let keyString = keychain["sftpKey" + (server.name ?? "")] else {
                throw NSError(domain: "SSHTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: "No key found"])
            }
            let passphrase = keychain["sftpPassword" + (server.name ?? "")]
            
            client = try await SSHClient.connect(
                host: server.sftpHost ?? "",
                port: Int(server.sftpPort),
                authenticationMethod: .privateKey(key: keyString, passphrase: passphrase),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } else {
            guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
                throw NSError(domain: "SSHTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: "No password found"])
            }
            
            client = try await SSHClient.connect(
                host: server.sftpHost ?? "",
                port: Int(server.sftpPort),
                authenticationMethod: .passwordBased(username: server.sftpUser ?? "", password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        }
        
        // Setup local port forwarding
        let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: Int(server.sftpRpc))
        let channel = try await client.createDirectTCPIPChannel(
            using: .init(
                targetHost: "localhost",
                targetPort: 9091, // Default Transmission RPC port
                originatorAddress: originAddress
            )
        ) { channel in
            // Basic channel setup for TCP forwarding
            channel.pipeline.addHandler(BackPressureHandler())
        }
        
        // Store the new tunnel
        tunnels[tunnelKey] = (client: client, channel: channel)
        
        return "http://localhost:\(server.sftpRpc)"
    }
    
    func closeTunnel(for server: ServerEntity) async {
        let tunnelKey = server.name ?? server.sftpHost ?? ""
        if let tunnel = tunnels[tunnelKey] {
            try? await tunnel.channel.close()
            try? await tunnel.client.close()
            tunnels.removeValue(forKey: tunnelKey)
        }
    }
    
    func closeAllTunnels() async {
        for (_, tunnel) in tunnels {
            try? await tunnel.channel.close()
            try? await tunnel.client.close()
        }
        tunnels.removeAll()
    }
}

class BackPressureHandler: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}