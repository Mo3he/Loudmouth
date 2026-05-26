import SwiftUI

@main
struct KenopsiaWatchApp: App {
    @StateObject private var phone = PhoneConnectivityService.shared

    var body: some Scene {
        WindowGroup {
            NowPlayingView()
                .environmentObject(phone)
                .onAppear {
                    if CommandLine.arguments.contains("--demo-mode") {
                        phone.injectDemoState()
                    } else {
                        phone.activate()
                    }
                }
        }
    }
}
