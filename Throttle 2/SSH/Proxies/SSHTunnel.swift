import Foundation
@preconcurrency import Citadel
import NIO
import NIOSSH
import SwiftUI

/// Manages SSH tunnels for port forwarding
class TunnelManagerHolder {
    static let shared = TunnelManagerHolder()
    var activeTunnels: [String: SSHTunnelManager] = [:]
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

// Actor to manage tunnel state safely in async contexts
actor TunnelState {
    private var _isStarted: Bool = false
    var isStarted: Bool { _isStarted }
    func setStarted(_ value: Bool) { _isStarted = value }
}

class SSHTunnelManager {
    private var client: SSHClient?
    private var localServer: Channel?
    
    var localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    private let server: ServerEntity
    private let state = TunnelState()
    
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
        let alreadyStarted = await state.isStarted
        if alreadyStarted {
            throw SSHTunnelError.tunnelAlreadyConnected
        }
        await state.setStarted(true)
        
        do {
            // 1. Connect to SSH server
            client = try await ServerManager.shared.connectSSH(server)
            
            // 2. Setup local proxy server
            try await setupLocalProxy()
            
            print("SSH Tunnel established: localhost:\(localPort) -> \(remoteHost):\(remotePort)")
        } catch {
            await state.setStarted(false)
            stop()
            throw SSHTunnelError.connectionFailed(error)
        }
    }
    
    private static func connectChannels(localChannel: Channel, sshChannel: Channel) async throws {
        // Add handlers to relay data between channels
        try await localChannel.pipeline.addHandler(SimpleRelayHandler(targetChannel: sshChannel)).get()
        try await sshChannel.pipeline.addHandler(SimpleRelayHandler(targetChannel: localChannel)).get()
    }

    private func setupLocalProxy() async throws {
        guard let client = client else {
            throw SSHTunnelError.tunnelNotConnected
        }
        let remoteHost = self.remoteHost
        let remotePort = self.remotePort
        let localPort = self.localPort
        let connectChannels = SSHTunnelManager.connectChannels
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { localChannel in
                let promise = localChannel.eventLoop.makePromise(of: Void.self)
                Task {
                    do {
                        let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        let settings = SSHChannelType.DirectTCPIP(
                            targetHost: remoteHost,
                            targetPort: remotePort,
                            originatorAddress: originAddress
                        )
                        let sshChannel = try await client.createDirectTCPIPChannel(using: settings) { channel in
                            return channel.eventLoop.makeSucceededVoidFuture()
                        }
                        try await connectChannels(localChannel, sshChannel)
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
    
    func stop() {
        Task { [weak self] in await self?.state.setStarted(false) }
        
        // Close the local server
        localServer?.close(promise: nil)
        localServer = nil
        
        // Close the SSH client
        if let client = client {
            Task { [weak self] in
                try? await client.close()
                self?.client = nil
            }
        }
        
        print("SSHTunnelManager: Tunnel stopped")
    }
}

// Simple relay handler to forward data between channels
private class SimpleRelayHandler: ChannelInboundHandler, @unchecked Sendable {
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
