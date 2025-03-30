import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSH
import KeychainAccess
import mft

// Custom error type for SSHTunnelManager
enum SSHTunnelError: Error {
    case missingCredentials
    case connectionFailed(Error)
    case portForwardingFailed(Error)
    case localProxyFailed(Error)
    case reconnectFailed(Error)
    case invalidServerConfiguration
    case tunnelAlreadyConnected
    case tunnelNotConnected
}

class SSHTunnelManager {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private var localPort: Int
    private var remoteHost: String
    private var remotePort: Int
    private var server: ServerEntity
    private var isConnected: Bool = false
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private let reconnectDelay: TimeAmount = .seconds(5)
    private let connectionCheckInterval: TimeAmount = .seconds(10)
    private var connectionCheckTask: RepeatedTask?

    init(server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int) throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.server = server
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort

        guard let _ = server.sftpHost,
              let _ = server.sftpPort,
              let _ = server.sftpUser else {
            throw SSHTunnelError.invalidServerConfiguration
        }
    }

    deinit {
        stop()
        try? group.syncShutdownGracefully()
    }

    func start() throws {
        guard !isConnected else {
            throw SSHTunnelError.tunnelAlreadyConnected
        }
        try connect()
        startConnectionCheck()
    }

    private func connect() throws {
        let promise = group.next().makePromise(of: Channel.self)

        guard let password = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")["sftpPassword" + (server.name ?? "")] else {
            throw SSHTunnelError.missingCredentials
        }

        let clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: PasswordAuthenticationDelegate(username: server.sftpUser!, password: password),
            hostKeyValidator: AcceptAnyHostKeyValidator()
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(clientConfiguration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { channel in
                            channel.pipeline.addHandler(HTTPProxyHandler(remoteHost: self.remoteHost, remotePort: self.remotePort))
                        }
                    )
                ])
            }

        bootstrap.connect(host: server.sftpHost!, port: Int(server.sftpPort)).cascade(to: promise)

        do {
            channel = try promise.futureResult.wait()
            isConnected = true
            reconnectAttempts = 0
            print("SSH Tunnel connected to \(server.sftpHost!):\(server.sftpPort)")
            // Start listening on the local port
            startLocalProxy()
        } catch {
            throw SSHTunnelError.connectionFailed(error)
        }
    }

    private func startLocalProxy() {
        let localBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(LocalHTTPProxyHandler(tunnelChannel: self.channel!))
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        do {
            let localChannel = try localBootstrap.bind(host: "127.0.0.1", port: localPort).wait()
            print("Local HTTP proxy listening on port \(localPort)")

            // Keep the local proxy running
            try localChannel.closeFuture.wait()
        } catch {
            print("Error starting local proxy: \(error)")
        }
    }

    func stop() {
        isConnected = false
        connectionCheckTask?.cancel()
        connectionCheckTask = nil
        channel?.close(mode: .all, promise: nil)
        channel = nil
        print("SSH Tunnel stopped")
    }

    private func startConnectionCheck() {
        connectionCheckTask = group.next().scheduleRepeatedTask(initialDelay: connectionCheckInterval, delay: connectionCheckInterval) { _ in
            self.checkConnection()
        }
    }

    private func checkConnection() {
        guard isConnected else {
            print("Connection is down, attempting to reconnect...")
            reconnect()
            return
        }

        // Add more robust connection checking here if needed
        if let channel = channel, !channel.isActive {
            print("Connection is down, attempting to reconnect...")
            reconnect()
        }
    }

    private func reconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("Max reconnect attempts reached. Giving up.")
            stop()
            return
        }

        reconnectAttempts += 1
        print("Attempting to reconnect (attempt \(reconnectAttempts) of \(maxReconnectAttempts))...")

        group.next().scheduleTask(in: reconnectDelay) {
            do {
                try self.connect()
            } catch {
                print("Reconnect failed: \(error)")
                self.reconnect() // Try again
            }
        }
    }
}

// Example HTTP Proxy Handler (Conceptual)
class HTTPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let remoteHost: String
    private let remotePort: Int

    init(remoteHost: String, remotePort: Int) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Forward the HTTP request over the SSH tunnel
        var buffer = self.unwrapInboundIn(data)
        print("HTTPProxyHandler: Forwarding data to \(remoteHost):\(remotePort)")
        // ... (Send the buffer over the SSH tunnel) ...
    }
}

// Example Local HTTP Proxy Handler (Conceptual)
class LocalHTTPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let tunnelChannel: Channel

    init(tunnelChannel: Channel) {
        self.tunnelChannel = tunnelChannel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Receive the HTTP request from the local client
        var buffer = self.unwrapInboundIn(data)
        print("LocalHTTPProxyHandler: Received data from local client")
        // Forward the buffer to the tunnel channel
        tunnelChannel.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
    }
}

// Example Usage
// Replace with your actual server details
//let serverHost = "your_server_ip"
//let serverPort = 22
//let serverUsername = "your_username"
//let serverPassword = "your_password"
//let localPort = 8080
//let remoteHost = "localhost"
//let remotePort = 8080
//
//let tunnelManager = try SSHTunnelManager(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort, serverHost: serverHost, serverPort: serverPort, serverUsername: serverUsername, serverPassword: serverPassword)
//
//try tunnelManager.start()
//
//// Keep the program running
//RunLoop.main.run()
