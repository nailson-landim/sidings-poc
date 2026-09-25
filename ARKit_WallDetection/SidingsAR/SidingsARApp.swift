import SwiftUI

@main
struct SidingsARApp: App {
    @State private var controller = ARSessionController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
