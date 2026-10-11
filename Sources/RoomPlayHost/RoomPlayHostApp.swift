import SwiftUI

@main
struct RoomPlayHostApp: App {
    @StateObject private var model = HostModel()

    var body: some Scene {
        WindowGroup("JoyArk Host") { HostView(model: model) }
            .defaultSize(width: 740, height: 850)
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandGroup(after: .appInfo) {
                    Button("Stop Host") { model.stopHost() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
    }
}
