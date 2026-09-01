import SwiftUI
import AppKit

/// One shared AppState. The app scene and the `--preview` window both observe it, so preview
/// screenshots show the same live data the menu bar is showing rather than a second set of
/// polls against AWS.
@MainActor
enum Shared {
    static let state = AppState()
}

@main
struct WatchtowerApp: App {
    @ObservedObject private var state = Shared.state

    init() {
        let arguments = CommandLine.arguments

        // Login-item management from the terminal. The panel's toggle is the normal way in,
        // but a login item that has gone wrong is exactly the case where the app is not
        // running and so the toggle cannot be reached — which is how a stale registration
        // pointing at a deleted directory survived two reboots unnoticed.
        //
        // `status` also prints where the registration would point, because the failure this
        // exists for is a login item that looks perfectly healthy in System Settings and
        // names a path that is no longer there.
        if let index = arguments.firstIndex(of: "--login-item"),
           arguments.indices.contains(index + 1) {
            LoginItemCommand.runAndExit(arguments[index + 1])
        }

        // Terminal entry point, checked before any window exists.
        if arguments.contains("--selftest") {
            let profile = arguments.firstIndex(of: "--profile")
                .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            SelfTest.runAndExit(profileOverride: profile,
                                includeCost: arguments.contains("--cost"))
        }

        // `--preview` renders the panel in an ordinary window, side by side in light and
        // dark. The status-item popover cannot be opened programmatically on macOS 13 and
        // clicking it from a script needs Accessibility permission, so this is how the panel
        // gets screenshotted for the README. Same view, same live data, different container.
        // `--render <path>` draws the panel straight to a PNG with no screen involved.
        // Screenshotting needs Screen Recording permission, cannot open the status-item
        // popover without Accessibility permission, and lands on whichever of several
        // displays happens to be primary. Rendering offscreen sidesteps all three.
        if let index = arguments.firstIndex(of: "--render"),
           arguments.indices.contains(index + 1) {
            let path = arguments[index + 1]
            NSApplication.shared.setActivationPolicy(.accessory)
            let scale = arguments.firstIndex(of: "--scale")
                .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                PreviewWindow.render(to: path, scale: scale)
            }
        }

        if arguments.contains("--preview") {
            NSApplication.shared.setActivationPolicy(.regular)   // LSUIElement hides windows
            // Delay so NSApp has finished launching; otherwise activation gets reset.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { PreviewWindow.show() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(state)
        } label: {
            // SF Symbols are template images, so macOS tints the glyph for light and dark
            // menu bars, and for the highlighted state, with no asset work on our part.
            Image(systemName: state.health.systemImage)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum PreviewWindow {
    private static var window: NSWindow?

    /// Draw both panes to a PNG offscreen, then exit.
    static func render(to path: String, scale: Int = 2) {
        let (container, size) = build()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.frame = NSRect(origin: .zero, size: size)
        container.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Render at 2x by giving the bitmap a backing store twice the logical size. Setting
        // rep.size to the point size while pixelsWide/High are doubled is what tells AppKit
        // this is a 2x backing store, so text is drawn crisp rather than upscaled after.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write(Data("render: could not create bitmap\n".utf8))
            exit(1)
        }
        rep.size = size
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render: could not encode PNG\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("rendered \(Int(size.width) * scale)x\(Int(size.height) * scale) (\(scale)x) to \(path)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Builds the two-pane container and returns it with its intended size.
    private static func build() -> (NSView, NSSize) {
        func pane(_ appearance: NSAppearance.Name) -> NSView {
            // The real panel sits on the menu-bar popover's material, so PanelView draws no
            // background of its own. Rendering it standalone needs one, or dark-mode text
            // comes out white on transparency.
            let root = PanelView()
                .environmentObject(Shared.state)
                .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: appearance)
            view.layout()
            view.setFrameSize(view.fittingSize)
            return view
        }
        let light = pane(.aqua)
        let dark = pane(.darkAqua)
        let paneWidth = max(light.fittingSize.width, 330)
        let height = max(light.fittingSize.height, dark.fittingSize.height, 400)
        light.frame = NSRect(x: 0, y: 0, width: paneWidth, height: height)
        dark.frame = NSRect(x: paneWidth, y: 0, width: paneWidth, height: height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth * 2, height: height))
        container.autoresizesSubviews = false
        container.addSubview(light)
        container.addSubview(dark)
        return (container, container.frame.size)
    }

    static func show() {
        // Two separate hosting views, each pinned to an explicit NSAppearance. A single
        // SwiftUI hierarchy cannot show both schemes at once: preferredColorScheme resolves
        // against the window, so the last one applied would win for the whole panel.
        func pane(_ appearance: NSAppearance.Name) -> NSView {
            // The real panel sits on the menu-bar popover's material, so PanelView draws no
            // background of its own. Rendering it standalone needs one, or dark-mode text
            // comes out white on transparency.
            let root = PanelView()
                .environmentObject(Shared.state)
                .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: appearance)
            view.layout()
            view.setFrameSize(view.fittingSize)
            return view
        }

        let light = pane(.aqua)
        let dark = pane(.darkAqua)

        // NSStackView returned a zero fittingSize here (the hosting views are not yet in a
        // window when it measures), which produced an invisible zero-size window. Lay the
        // two panes out manually instead.
        let paneWidth = max(light.fittingSize.width, 330)
        let height = max(light.fittingSize.height, dark.fittingSize.height, 400)
        light.frame = NSRect(x: 0, y: 0, width: paneWidth, height: height)
        dark.frame = NSRect(x: paneWidth, y: 0, width: paneWidth, height: height)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth * 2, height: height))
        // Assigning a view as contentView makes it adopt the window's content rect, so the
        // intended size has to be captured before that happens or setContentSize gets 0x0.
        let contentSize = stack.frame.size
        stack.autoresizesSubviews = false
        stack.addSubview(light)
        stack.addSubview(dark)

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Watchtower — light / dark"
        window.contentView = stack
        window.setContentSize(contentSize)
        // Pinned to a fixed top-left origin rather than centred, so a screenshot can target
        // exactly this rect instead of grabbing the whole screen.
        // screens.first is the display holding the menu bar. NSScreen.main follows
        // keyboard focus, which on a multi-display setup can place the window on a monitor
        // the screenshot never sees.
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40,
                                          y: screen.frame.maxY - contentSize.height - 80))
        }
        window.level = .floating          // keeps it visible for screenshots
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("preview window frame: \(window.frame) on \(NSScreen.screens.count) screen(s)\n".utf8))
        self.window = window
    }
}
