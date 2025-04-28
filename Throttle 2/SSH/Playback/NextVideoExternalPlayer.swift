//
//  NextVideo.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//
#if os(iOS)
import SwiftUI
// used when we were using VLC itself, an artificial "Playlist" of sorts.
struct NextVideo: View {
    @StateObject var viewModel: SFTPFileBrowserViewModel
    var body: some View {
        ZStack {
                            // Black background that fills the entire screen
                            Color.black.edgesIgnoringSafeArea(.all)
                            
                            VStack(spacing: 16) {
                                Spacer()
                                
                                // Content unavailable view
                                VStack(spacing: 20) {
                                    Image(systemName: "play.rectangle.on.rectangle")
                                        .font(.system(size: 60))
                                        .foregroundColor(.white)
                                    
                                    Text("Continue Playback?")
                                        .font(.title)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                    
                                    if let nextVideo = viewModel.nextVideoItem {
                                        Text(nextVideo.name)
                                            .font(.headline)
                                            .foregroundColor(.white.opacity(0.8))
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal)
                                    }
                                    
                                    Text("Playback will begin in \(viewModel.nextVideoCountdown) seconds")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.7))
                                    
                                    Text("Tap anywhere to play now")
                                        .font(.callout)
                                        .foregroundColor(.white.opacity(0.9))
                                        .padding(.top, 8)
                                }
                                .padding()
                                
                                Spacer()
                                
                                // Cancel button
                                Button("Stop Playing") {
                                    viewModel.cancelNextVideo()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(.white)
                                .padding(.bottom, 50)
                            }
                            .padding()
                        }

    }
}
#endif
