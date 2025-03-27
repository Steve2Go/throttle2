//
//  Messages.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//

import SwiftUI

struct AddFirstServer: View {
    @ObservedObject var presenting : Presenting
    
    var body: some View {
#if os(macOS)
                            let word = "Click"
            #else
                            let word = "Tap"
                            #endif
                            ContentUnavailableView("Add a server to Begin",
                                systemImage: "figure.wave",
                                description: Text("\(word) here to get started.")

                            ).onTapGesture {
                                presenting.activeSheet = "servers"
                            }
    }
}
