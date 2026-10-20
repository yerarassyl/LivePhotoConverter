import SwiftUI
import Photos

@main
struct LivePhotoConverterApp: App {
    @StateObject private var manager = PhotoLibraryManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
