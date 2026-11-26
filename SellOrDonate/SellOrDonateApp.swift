import SwiftUI

@main
@MainActor
struct SellOrDonateApp: App {
    @StateObject private var workspace: Workspace
    @StateObject private var purchases: Purchases

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let workspace = Workspace(arguments: arguments)
        _workspace = StateObject(wrappedValue: workspace)
        _purchases = StateObject(wrappedValue: Purchases(disk: workspace.disk, test: workspace.test, arguments: arguments))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(workspace: workspace, purchases: purchases)
                .preferredColorScheme(.light)
        }
    }
}
