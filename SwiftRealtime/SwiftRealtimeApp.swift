import SwiftUI

@main
struct SwiftRealtimeApp: App {
    private let credentials: WiroCredentials

    init() {
        do {
            credentials = try WiroEnvironment.fromLaunchEnvironment()
        } catch {
            fatalError(String(describing: error))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(credentials: credentials)
                .appAppearance()
        }
    }
}
