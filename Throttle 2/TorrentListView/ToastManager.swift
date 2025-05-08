import SwiftUI
import SimpleToast

// Create the toast manager class
class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var toastIcon = "info.square"
    @Published var toastColor = Color.blue
    
    let toastOptions = SimpleToastOptions(hideAfter: 5)
    
    func show(message: String, icon: String = "info.square", color: Color = .blue) {
        DispatchQueue.main.async {
            self.toastMessage = message
            self.toastIcon = icon
            self.toastColor = color
            self.showToast = true
        }
    }
}

// Root view modifier to apply to your app
struct ToastViewModifier: ViewModifier {
    @ObservedObject var toastManager = ToastManager.shared
    
    func body(content: Content) -> some View {
        content
            .simpleToast(isPresented: $toastManager.showToast, options: toastManager.toastOptions) {
                Label(toastManager.toastMessage, systemImage: toastManager.toastIcon)
                    .padding()
                    .background(toastManager.toastColor)
                    .foregroundColor(Color.white)
                    .cornerRadius(10)
                    .padding(.top)
            }
    }
}

extension View {
    func withToast() -> some View {
        self.modifier(ToastViewModifier())
    }
}
