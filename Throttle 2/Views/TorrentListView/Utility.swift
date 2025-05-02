//
//  AnyViewModifier.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//
import SwiftUI

// Custom ViewModifier for type erasure
struct AnyViewModifier: ViewModifier {
    let modifier: (Content) -> any View
    
    init<M: ViewModifier>(_ modifier: M) {
        self.modifier = { content in
            content.modifier(modifier)
        }
    }
    
    func body(content: Content) -> some View {
        AnyView(modifier(content))
    }
}

// String extension for UI truncation
extension String {
    func truncatedMiddle() -> String {
        
        #if os(iOS)
        guard self.count > 35 else { return self }
        let prefix = String(self.prefix(15))
        let suffix = String(self.suffix(10))
        #else
        guard self.count > 45 else { return self }
        let prefix = String(self.prefix(25))
        let suffix = String(self.suffix(10))
                            #endif
        return "\(prefix)...\(suffix)"
    }
}

extension String {
    func truncatedMiddleMore() -> String {
        guard self.count > 30 else { return self }
        let prefix = String(self.prefix(15))
        let suffix = String(self.suffix(10))
        return "\(prefix)...\(suffix)"
    }
}

// Utility function for formatting bytes
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
