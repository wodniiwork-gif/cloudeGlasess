import MWDATCore
import SwiftUI

@main
struct ClaudeGlassesApp: App {
  @StateObject private var assistant: Assistant

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[ClaudeGlasses] Wearables.configure failed: \(error)")
    }
    _assistant = StateObject(wrappedValue: Assistant())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(assistant: assistant)
        // Meta AI returns here after registration / permission screens.
        .onOpenURL { url in assistant.glasses.handle(url: url) }
    }
  }
}
