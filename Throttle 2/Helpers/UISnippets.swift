//
//  Componenets.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 18/2/2025.
//

//MARK: Close Button
import SwiftUI

struct MacCloseButton: View {
    @State private var isHovering = false
    @State private var isPressed = false
    
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isPressed ? Color.red.opacity(0.5) :
                      isHovering ? Color.red :
                      Color(red: 1, green: 0.25, blue: 0.2))
                .overlay(
                    Group {
                        if isHovering {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.black.opacity(0.5))
                        }
                    }
                )
                .frame(width: 12, height: 12)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

//// Example usage in a window
//struct ExampleWindow: View {
//    var body: some View {
//        VStack(spacing: 0) {
//            HStack {
//                MacCloseButton {
//                    // Handle close action
//                    print("Window close requested")
//                }
//                Spacer()
//            }
//            .padding(.horizontal, 8)
//            .padding(.vertical, 6)
//            .background(Color(white: 0.95))
//            
//            // Window content goes here
//            Text("Window Content")
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .background(Color.white)
//        }
//        .frame(width: 300, height: 200)
//        .clipShape(RoundedRectangle(cornerRadius: 10))
//        .shadow(radius: 5)
//    }
//}
