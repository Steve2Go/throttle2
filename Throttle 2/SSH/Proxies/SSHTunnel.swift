import Foundation
@preconcurrency import Citadel
import NIO
import NIOSSH
import SwiftUI

//enum SSHTunnelError: Error {
//    case missingCredentials
//    case connectionFailed(Error)
//    case tunnelEstablishmentFailed(Error)
//    case portForwardingFailed(Error)
//    case localProxyFailed(Error)
//    case reconnectFailed(Error)
//    case invalidServerConfiguration
//    case tunnelAlreadyConnected
//    case tunnelNotConnected
//}

/// Manages SSH tunnels for port forwarding
class TunnelManagerHolder {
    static let shared = TunnelManagerHolder()
    private var activeTunnels: [String: SSHTunnelManager] = [:]
    private let tunnelLock = NSLock()
    @AppStorage("trigger") var trigger = true

    private init() {}
    
    /// Store a tunnel with a custom identifier
    func storeTunnel(_ tunnel: SSHTunnelManager, withIdentifier identifier: String) {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        activeTunnels[identifier] = tunnel
        trigger.toggle()
    }
    
    /// Get a tunnel by its identifier
    func getTunnel(withIdentifier identifier: String) -> SSHTunnelManager? {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        return activeTunnels[identifier]
    }
    
    /// Remove a tunnel by its identifier
    func removeTunnel(withIdentifier identifier: String) {
        tunnelLock.lock()
        let tunnel = activeTunnels[identifier]
        tunnelLock.unlock()
        
        if let tunnel = tunnel {
            tunnel.stop()
            
            tunnelLock.lock()
            activeTunnels.removeValue(forKey: identifier)
            tunnelLock.unlock()
        }
    }
    
    /// Tear down all tunnels
    func tearDownAllTunnels() {
        print("TunnelManagerHolder: Tearing down all tunnels")
        
        tunnelLock.lock()
        let tunnels = activeTunnels.values
        activeTunnels.removeAll()
        tunnelLock.unlock()
        
        for tunnel in tunnels {
            tunnel.stop()
        }
        
        print("TunnelManagerHolder: All tunnels have been torn down")
    }
}

class SSHTunnelManager {
    private var client: SSHClient?
    private var localServer: Channel?
    
    var localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    private let server: ServerEntity
    private var isStarted = false
    private let tunnelLock = NSLock()
    
    init(server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int) throws {
        self.server = server
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        
        guard server.sftpHost != nil,
              server.sftpPort != 0,
              server.sftpUser != nil else {
            throw SSHTunnelError.invalidServerConfiguration
        }
    }
    
    deinit {
        print("SSHTunnelManager: Deinitializing")
        stop()
    }
    
    func start() async throws {
        tunnelLock.lock()
        guard !isStarted else {
            tunnelLock.unlock()
            throw SSHTunnelError.tunnelAlreadyConnected
        }
        isStarted = true
        tunnelLock.unlock()
        
        do {
            // 1. Connect to SSH server
            client = try await ServerManager.shared.connectSSH(server)
            
            // 2. Setup local proxy server
            try await setupLocalProxy()
            
            print("SSH Tunnel established: localhost:\(localPort) -> \(remoteHost):\(remotePort)")
        } catch {
            tunnelLock.lock()
            isStarted = false
            tunnelLock.unlock()
            stop()
            throw SSHTunnelError.connectionFailed(error)
        }
    }
    
    private func setupLocalProxy() async throws {
        guard let client = client else {
            throw SSHTunnelError.tunnelNotConnected
        }
        
        // Create a server bootstrap that forwards connections through the SSH tunnel
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] localChannel in
                guard let self = self else {
                    return localChannel.eventLoop.makeFailedFuture(SSHTunnelError.tunnelNotConnected)
                }
                
                let promise = localChannel.eventLoop.makePromise(of: Void.self)
                
                Task {
                    do {
                        // Create a DirectTCPIP tunnel through the SSH connection
                        let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        let settings = SSHChannelType.DirectTCPIP(
                            targetHost: self.remoteHost,
                            targetPort: self.remotePort,
                            originatorAddress: originAddress
                        )
                        
                        // The magic happens here - Citadel does most of the work for us
                        let sshChannel = try await client.createDirectTCPIPChannel(using: settings) { channel in
                            return channel.eventLoop.makeSucceededVoidFuture()
                        }
                        
                        // Connect the two channels with simple relay handlers
                        try await self.connectChannels(localChannel: localChannel, sshChannel: sshChannel)
                        promise.succeed(())
                    } catch {
                        localChannel.close(promise: nil)
                        promise.fail(error)
                    }
                }
                
                return promise.futureResult
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        
        // Start the local server
        localServer = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        print("Local proxy server listening on 127.0.0.1:\(localPort)")
    }
    
    // Simple method to connect the two channels bidirectionally
    private func connectChannels(localChannel: Channel, sshChannel: Channel) async throws {
        // Add handlers to relay data between channels
        try await localChannel.pipeline.addHandler(SimpleRelayHandler(targetChannel: sshChannel)).get()
        try await sshChannel.pipeline.addHandler(SimpleRelayHandler(targetChannel: localChannel)).get()
    }
    
    func stop() {
        tunnelLock.lock()
        isStarted = false
        tunnelLock.unlock()
        
        // Close the local server
        localServer?.close(promise: nil)
        localServer = nil
        
        // Close the SSH client
        if let client = client {
            Task {
                try? await client.close()
            }
            self.client = nil
        }
        
        print("SSHTunnelManager: Tunnel stopped")
    }
}

// Simple relay handler to forward data between channels
private class SimpleRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let targetChannel: Channel
    
    init(targetChannel: Channel) {
        self.targetChannel = targetChannel
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        targetChannel.writeAndFlush(buffer, promise: nil)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        // Close the target channel when this channel closes
        targetChannel.close(promise: nil)
        context.fireChannelInactive()
    }
}
