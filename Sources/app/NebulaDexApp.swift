import SwiftUI

@main
struct NebulaDexApp: App {

    @StateObject private var state = SDRAppState.shared
    @StateObject private var logs = SDRLogStore.shared

    init() {
        SDRLogger.i("app", "NebulaDex 启动：iOS \(SDRVersionAdapter.systemVersion)")
        SDRAppState.shared.reloadApps()
        _ = SDRAppContainer.shared
    }

    var body: some Scene {
        WindowGroup {
            SDRRootView()
                .environmentObject(state)
                .environmentObject(logs)
                .onOpenURL { url in
                    SDRAppContainer.shared.handleIncoming(url: url)
                }
        }
    }
}
