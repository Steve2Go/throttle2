//
//  ExternalDisplayManager.swift
//  Throttle 2
//
//  Created for handling external display connections
//
#if os(iOS)
import UIKit
import SwiftUI

class ExternalDisplayManager: ObservableObject {
    static let shared = ExternalDisplayManager()
    
    @Published var isExternalDisplayConnected = false
    
    private var externalWindow: UIWindow?
    private var isVideoPlayerActive = false
    
    // Notification observers
    private var screenDidConnectObserver: NSObjectProtocol?
    private var screenDidDisconnectObserver: NSObjectProtocol?
    
    private var monitoringTimer: Timer?
    
    private init() {
        // Register for screen connection/disconnection notifications
        screenDidConnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleExternalDisplayConnection()
        }
        
        screenDidDisconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleExternalDisplayDisconnection()
        }
        
        // Check if an external display is already connected
        configureExternalDisplayIfNeeded()
    }
    
    deinit {
        // Clean up observers when the manager is deallocated
        if let observer = screenDidConnectObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        if let observer = screenDidDisconnectObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Clean up timer
        stopMonitoringTimer()
    }
    
    // Public method to start monitoring
    func startMonitoring() {
        configureExternalDisplayIfNeeded()
        
        // Start a timer to periodically check for external displays
        startMonitoringTimer()
    }
    
    private func startMonitoringTimer() {
        // Cancel any existing timer
        monitoringTimer?.invalidate()
        
        // Create a new timer that checks every 1 second
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForExternalDisplays()
        }
    }
    
    private func stopMonitoringTimer() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    private func checkForExternalDisplays() {
        let hasExternalDisplay = UIScreen.screens.count > 1
        
        // If we detect a change in external display status, handle it
        if hasExternalDisplay != isExternalDisplayConnected {
            if hasExternalDisplay {
                handleExternalDisplayConnection()
            } else {
                handleExternalDisplayDisconnection()
            }
        }
    }
    
    // Public method to temporarily suspend the black screen for video player
    func suspendForVideoPlayer() {
        isVideoPlayerActive = true
        hideBlackScreen()
    }
    
    // Public method to restore the black screen after video player is dismissed
    func resumeAfterVideoPlayer() {
        isVideoPlayerActive = false
        showBlackScreen()
    }
    
    // Private methods
    private func configureExternalDisplayIfNeeded() {
        // Look for an external display
        if let externalScreen = UIScreen.screens.first(where: { $0 != UIScreen.main }) {
            createBlackScreenOnExternalDisplay(externalScreen)
            isExternalDisplayConnected = true
        } else {
            isExternalDisplayConnected = false
        }
    }
    
    private func handleExternalDisplayConnection() {
        if let externalScreen = UIScreen.screens.first(where: { $0 != UIScreen.main }) {
            createBlackScreenOnExternalDisplay(externalScreen)
            isExternalDisplayConnected = true
        }
    }
    
    private func handleExternalDisplayDisconnection() {
        tearDownExternalWindow()
        isExternalDisplayConnected = false
    }
    
    private func createBlackScreenOnExternalDisplay(_ screen: UIScreen) {
        // First clean up any existing windows
        tearDownExternalWindow()
        
        // Only create a new window if video player is not active
        guard !isVideoPlayerActive else { return }
        
        // Create a window scene for the external display
        if let windowScene = UIApplication.shared.connectedScenes.first(where: { scene in
            guard let windowScene = scene as? UIWindowScene else { return false }
            return windowScene.screen == screen
        }) as? UIWindowScene {
            // Create a window for the external display
            externalWindow = UIWindow(windowScene: windowScene)
            externalWindow?.frame = screen.bounds
            
            // Create a view controller with a welcome message
            let welcomeVC = WelcomeViewController()
            
            // Set the welcome view controller as the root
            externalWindow?.rootViewController = welcomeVC
            externalWindow?.isHidden = false
            
            print("Created welcome screen on external display")
        }
    }
    
    private func showBlackScreen() {
        if let externalScreen = UIScreen.screens.first(where: { $0 != UIScreen.main }) {
            createBlackScreenOnExternalDisplay(externalScreen)
        }
    }
    
    private func hideBlackScreen() {
        tearDownExternalWindow()
    }
    
    private func tearDownExternalWindow() {
        externalWindow?.isHidden = true
        externalWindow = nil
    }
}

// Welcome view controller with a nice message
class WelcomeViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Create and configure label for the welcome message
        let messageLabel = UILabel()
        messageLabel.text = "Select a Video or Image to Start Streaming"
        messageLabel.textColor = .white
        messageLabel.font = UIFont.systemFont(ofSize: 32, weight: .medium)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Create app icon/logo
        let logoImageView = UIImageView()
        if let appIcon = UIImage(named: "AppIcon") {
            logoImageView.image = appIcon
        } else {
            // Fallback if app icon isn't available
            logoImageView.image = UIImage(systemName: "play.circle")
            logoImageView.tintColor = .white
        }
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        
        // Add views to the main view
        view.addSubview(logoImageView)
        view.addSubview(messageLabel)
        
        // Set up constraints
        NSLayoutConstraint.activate([
            // Logo constraints
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            logoImageView.widthAnchor.constraint(equalToConstant: 120),
            logoImageView.heightAnchor.constraint(equalToConstant: 120),
            
            // Message label constraints
            messageLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 40),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])
    }
}

#if canImport(SwiftUI)
// SwiftUI wrapper for the ExternalDisplayManager
struct ExternalDisplayManagerKey: EnvironmentKey {
    static let defaultValue = ExternalDisplayManager.shared
}

extension EnvironmentValues {
    var externalDisplayManager: ExternalDisplayManager {
        get { self[ExternalDisplayManagerKey.self] }
        set { self[ExternalDisplayManagerKey.self] = newValue }
    }
}
#endif
#endif
