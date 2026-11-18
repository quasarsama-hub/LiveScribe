import SwiftUI

@main
struct LiveScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.onLaunch() }
        }
    }
}

enum Theme {
    static let system = Color(red: 0.45, green: 0.36, blue: 0.96)   // violet
    static let mic = Color(red: 0.98, green: 0.40, blue: 0.38)      // coral
    static let accent = Color(red: 0.45, green: 0.36, blue: 0.96)
}
