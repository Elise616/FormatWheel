import AppKit

/// Notices "a file is being dragged and Shift was just pressed" anywhere on the system.
///
/// Needs no permissions: global *mouse* monitors are allowed without Accessibility access, the
/// modifier state is polled from `NSEvent.modifierFlags`, and a new drag is detected by the drag
/// pasteboard's change count moving while the button is held.
final class DragWatcher {
    var onShift: (([URL]) -> Void)?
    var onRelease: (() -> Void)?
    var isWheelOpen: () -> Bool = { false }

    private var monitors: [Any] = []
    private var timer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var baseline = 0
    private var files: [URL]?
    private var lastShift = false

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in self?.mouseDown() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in self?.dragged() }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func mouseDown() {
        baseline = dragPasteboard.changeCount
        files = nil
        lastShift = NSEvent.modifierFlags.contains(.shift)
        startPolling()
    }

    private func dragged() {
        guard timer == nil else { return }
        // We missed the mouse-down; only a drag that starts from now on counts.
        baseline = dragPasteboard.changeCount
        files = nil
        lastShift = NSEvent.modifierFlags.contains(.shift)
        startPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            timer?.invalidate()
            timer = nil
            if files?.isEmpty == false { Log.write("drag: mouse released") }
            files = nil
            onRelease?()
            return
        }
        if files == nil, dragPasteboard.changeCount != baseline {
            files = (dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            Log.write("drag: started with \(files?.count ?? 0) file(s)")
        }
        let shift = NSEvent.modifierFlags.contains(.shift)
        defer { lastShift = shift }
        guard shift, !lastShift, let files, !files.isEmpty, !isWheelOpen() else { return }
        Log.write("drag: shift pressed → open wheel")
        onShift?(files)
    }
}
