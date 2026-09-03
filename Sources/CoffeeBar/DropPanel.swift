import AppKit

/// 面板里的一个图标：有截图就显示截图，没有就显示 App 名字。左键 / 右键都转发。
final class ItemView: NSView {
    let item: MenuBarItem
    private let image: NSImage?
    private var hovered = false { didSet { needsDisplay = true } }
    var onClick: ((MenuBarItem, Bool) -> Void)?

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor,
    ]

    let itemWidth: CGFloat

    init(item: MenuBarItem, image: NSImage?) {
        self.item = item
        self.image = image
        if image != nil {
            itemWidth = item.bounds.width
        } else {
            let textWidth = (item.ownerName as NSString).size(withAttributes: Self.labelAttributes).width
            itemWidth = ceil(textWidth) + 16
        }
        super.init(frame: NSRect(x: 0, y: 0, width: itemWidth, height: item.bounds.height))
        toolTip = item.ownerName
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: itemWidth).isActive = true
        heightAnchor.constraint(equalToConstant: item.bounds.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(item, false) }
    override func rightMouseUp(with event: NSEvent) { onClick?(item, true) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if let image {
            image.draw(in: bounds)
        } else {
            let text = item.ownerName as NSString
            let size = text.size(withAttributes: Self.labelAttributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                      withAttributes: Self.labelAttributes)
        }
    }
}

/// 挂在菜单栏下方的浮动面板，相当于 Bartender Bar。
final class DropPanel: NSPanel {
    var onItemClick: ((MenuBarItem, Bool) -> Void)?
    private var outsideClickMonitor: Any?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    }

    // MARK: - 内容

    typealias NoticeButton = (title: String, action: () -> Void)

    func showItems(_ entries: [(MenuBarItem, NSImage?)], notice: (text: String, buttons: [NoticeButton])?, anchor: NSRect) {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 6

        if let notice {
            column.addArrangedSubview(makeNotice(notice.text, buttons: notice.buttons))
        }

        if entries.isEmpty, notice == nil {
            column.addArrangedSubview(makeLabel("没有隐藏的图标。按住 ⌘ 把图标拖到 “/” 左边即可隐藏。"))
        }

        // 简单的流式布局：一行放不下就换行。
        let maxRowWidth = min(720, (NSScreen.main?.frame.width ?? 1440) * 0.6)
        var row = makeRow()
        var rowWidth: CGFloat = 0
        for (item, image) in entries {
            let view = ItemView(item: item, image: image)
            if rowWidth > 0, rowWidth + view.itemWidth > maxRowWidth {
                column.addArrangedSubview(row)
                row = makeRow()
                rowWidth = 0
            }
            view.onClick = { [weak self] item, right in self?.onItemClick?(item, right) }
            row.addArrangedSubview(view)
            rowWidth += view.itemWidth
        }
        if !row.arrangedSubviews.isEmpty {
            column.addArrangedSubview(row)
        }

        present(column, anchor: anchor)
    }

    private func makeRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        return row
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 320
        return label
    }

    private var noticeActions: [() -> Void] = []

    private func makeNotice(_ text: String, buttons: [NoticeButton]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(makeLabel(text))
        noticeActions = buttons.map(\.action)
        if !buttons.isEmpty {
            let row = makeRow()
            row.spacing = 8
            for (index, button) in buttons.enumerated() {
                let control = NSButton(title: button.title, target: self, action: #selector(noticeButtonClicked(_:)))
                control.bezelStyle = .rounded
                control.controlSize = .small
                control.tag = index
                row.addArrangedSubview(control)
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func noticeButtonClicked(_ sender: NSButton) {
        dismiss()
        if noticeActions.indices.contains(sender.tag) {
            noticeActions[sender.tag]()
        }
    }

    private func present(_ content: NSView, anchor: NSRect) {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        let inset: CGFloat = 8
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
        ])

        contentView = background
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize

        // 右对齐到开关按钮下方，并且不出屏幕。
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 4)
        if let screen {
            origin.x = max(screen.visibleFrame.minX + 4, min(origin.x, screen.visibleFrame.maxX - size.width - 4))
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
        startOutsideClickMonitor()
    }

    // MARK: - 关闭

    func dismiss() {
        stopOutsideClickMonitor()
        orderOut(nil)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return }
            // 全局事件的 locationInWindow 就是屏幕坐标。
            if !self.frame.contains(event.locationInWindow) {
                self.dismiss()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
