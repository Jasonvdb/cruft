import CruftKit
import SwiftUI

/// Menu bar shell. Every display rule lives in CruftKit's `MenuState`; this
/// target only renders it. LSUIElement: no dock icon, no main window — the
/// status item (and its Quit button) is the entire surface.
@main
struct CruftApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            if let title = model.menuBarTitle {
                Text(title)
            } else {
                Image(systemName: "internaldrive")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
