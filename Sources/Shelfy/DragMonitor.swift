import AppKit

/// Watches system-wide mouse drags. Reports when a real drag (something on the drag pasteboard)
/// starts/ends, and when the pointer is shaken side to side during one.
final class DragMonitor {
    var onShake: ((NSPoint) -> Void)?
    var onDragChanged: ((Bool) -> Void)?

    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var baseline = 0
    private(set) var isDragging = false
    private var shookThisDrag = false

    private var lastX: CGFloat = 0
    private var direction: CGFloat = 0
    private var segmentStart: CGFloat = 0
    private var turns: [TimeInterval] = []

    func start() {
        baseline = dragPasteboard.changeCount
        let down: (NSEvent) -> Void = { [weak self] _ in self?.mouseDown() }
        let dragged: (NSEvent) -> Void = { [weak self] e in self?.mouseDragged(e) }
        let up: (NSEvent) -> Void = { [weak self] _ in self?.mouseUp() }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragged) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: up) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown,
            handler: {
                down($0)
                return $0
            })
        {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp,
            handler: {
                up($0)
                return $0
            })
        {
            monitors.append(m)
        }
    }

    private func mouseDown() {
        baseline = dragPasteboard.changeCount
        shookThisDrag = false
    }

    private func mouseUp() {
        shookThisDrag = false
        if isDragging {
            isDragging = false
            onDragChanged?(false)
        }
    }

    private func mouseDragged(_ event: NSEvent) {
        let x = NSEvent.mouseLocation.x
        if !isDragging {
            guard dragPasteboard.changeCount != baseline else { return }
            isDragging = true
            lastX = x
            segmentStart = x
            direction = 0
            turns = []
            onDragChanged?(true)
        }
        guard Settings.shared.shakeEnabled, !shookThisDrag else { return }

        let dx = x - lastX
        guard abs(dx) >= 2 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if dir != direction {
            if direction != 0, abs(lastX - segmentStart) >= minimumSegment { turns.append(event.timestamp) }
            segmentStart = lastX
            direction = dir
        }
        lastX = x
        turns.removeAll { event.timestamp - $0 > 0.75 }
        if turns.count >= 3 {
            shookThisDrag = true
            turns = []
            onShake?(NSEvent.mouseLocation)
        }
    }

    private var minimumSegment: CGFloat {
        switch Settings.shared.shakeSensitivity {
        case 0: return 70
        case 2: return 25
        default: return 45
        }
    }
}

// MARK: - Notch drop zone

/// A black pill over the MacBook notch that grows when something is dragged onto it.
final class NotchDropZone {
    var onDrop: (([ShelfItem], NSPoint) -> Void)?
    private var panel: NSPanel?
    private var view: NotchView?
    private var notchRect: NSRect = .zero

    func show() {
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) && $0.safeAreaInsets.top > 0 })
                ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
            let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return }
        let height = screen.safeAreaInsets.top
        let minX = screen.frame.minX + left.width
        let maxX = screen.frame.maxX - right.width
        notchRect = NSRect(x: minX, y: screen.frame.maxY - height, width: maxX - minX, height: height)

        if panel == nil {
            let p = NSPanel(
                contentRect: notchRect, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            let v = NotchView(frame: NSRect(origin: .zero, size: notchRect.size))
            v.autoresizingMask = [.width, .height]
            v.onHover = { [weak self] hovering in self?.setExpanded(hovering) }
            v.onDrop = { [weak self] items in
                guard let self else { return }
                self.onDrop?(items, NSPoint(x: self.notchRect.midX, y: self.notchRect.minY))
                self.hide()
            }
            p.contentView = v
            panel = p
            view = v
        }
        panel?.setFrame(notchRect, display: true)
        view?.expanded = false
        panel?.orderFrontRegardless()
    }

    func hide() {
        // Give a pending drop time to land before removing the target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.view?.expanded = false
            self?.panel?.orderOut(nil)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        var frame = notchRect
        if expanded {
            frame = notchRect.insetBy(dx: -70, dy: 0)
            frame.origin.y -= 44
            frame.size.height += 44
        }
        view?.expanded = expanded
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private final class NotchView: DropZoneView {
    var expanded = false {
        didSet {
            label.isHidden = !expanded
            needsDisplay = true
        }
    }
    private let label = NSTextField(labelWithString: "Drop to open a shelf")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let r: CGFloat = expanded ? 18 : 10
        let path = NSBezierPath()
        let b = bounds
        path.move(to: NSPoint(x: b.minX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.minY + r))
        path.appendArc(
            withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 0, endAngle: 270, clockwise: true)
        path.line(to: NSPoint(x: b.minX + r, y: b.minY))
        path.appendArc(
            withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
        path.close()
        path.fill()
        if expanded {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}
