#if DEBUG
import AppKit
import SwiftUI

/// Debug aid: `ALTER_SNAPSHOT_DIR=/path` renders the main views to PNGs on launch.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["ALTER_SNAPSHOT_DIR"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let url = URL(fileURLWithPath: dir)
            render(MenuContentView().environment(model), size: CGSize(width: 340, height: 720), to: url.appendingPathComponent("menu.png"))
            render(EffectsWindow().environment(model), size: CGSize(width: 1000, height: 1500), to: url.appendingPathComponent("effects.png"))
            NSLog("Alter: snapshots written to \(dir)")
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
