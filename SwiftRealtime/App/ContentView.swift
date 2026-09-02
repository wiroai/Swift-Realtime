import SwiftUI

struct ContentView: View {
    let credentials: WiroCredentials

    var body: some View {
        RealtimeHomeView(credentials: credentials)
    }
}

#Preview {
    ContentView(
        // swiftlint:disable:next force_try
        credentials: try! WiroEnvironment.fromValues(
            apiKey: "preview",
        ),
    )
    .appAppearance()
}
