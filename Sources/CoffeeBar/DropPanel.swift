import AppKit

/// 面板里的一个图标：显示所属 App 的图标，认不出 App 时显示名字。左键 / 右键都转发。
final class ItemView: NSView {
    let item: MenuBarItem
    private let image: NSImage?
    private var hovered = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: ((MenuBarItem, Bool) -> Void)?

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor,
    ]
    private static let iconSize: CGFloat = 20
    private static let cellHeight: CGFloat = 30

    let itemWidth: CGFloat

    init(item: MenuBarItem, image: NSImage?) {
        self.item = item
        self.image = image
        if image != nil {
            itemWidth = Self.cellHeight + 4
        } else {
            let textWidth = (item.ownerName as NSString).size(withAttributes: Self.labelAttributes).width
            itemWidth = ceil(textWidth) + 16
        }
        super.init(frame: NSRect(x: 0, y: 0, width: itemWidth, height: Self.cellHeight))
        toolTip = item.ownerName
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: itemWidth).isActive = true
        heightAnchor.constraint(equalToConstant: Self.cellHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    /// 面板是非激活窗口，不加这个的话第一次点击会被 AppKit 用来"激活窗口"而不派发给视图。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(item, false) }
    override func rightMouseUp(with event: NSEvent) { onClick?(item, true) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isSelected {
            NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.4 : 0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if let image {
            let side = Self.iconSize
            let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            let text = item.ownerName as NSString
            let size = text.size(withAttributes: Self.labelAttributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                      withAttributes: Self.labelAttributes)
        }
    }
}

/// 挂在菜单栏下方的浮动面板，相当于 Bartender Bar。
/// 顶部有搜索框：直接打字按 App 名过滤，← → 选择，回车触发，Esc 关闭。
final class DropPanel: NSPanel, NSTextFieldDelegate {
    typealias NoticeButton = (title: String, action: () -> Void)

    var onItemClick: ((MenuBarItem, Bool) -> Void)?

    private var outsideClickMonitor: Any?
    private var allEntries: [(MenuBarItem, NSImage?)] = []
    private var filtered: [(MenuBarItem, NSImage?)] = []
    private var itemViews: [ItemView] = []
    private var selectedIndex = 0
    private var anchor: NSRect = .zero
    private let searchField = NSTextField()
    private let rowsContainer = NSStackView()
    private var noticeActions: [() -> Void] = []

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

        searchField.placeholderString = "输入 App 名过滤，回车打开"
        searchField.font = .systemFont(ofSize: 12)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        if ProcessInfo.processInfo.environment["COFFEEBAR_DEBUG"] != nil {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                NSLog("CoffeeBar local keyDown code=\(event.keyCode) chars=\(event.characters ?? "") keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
                return event
            }
        }
    }

    /// 非激活面板也能成为 key window，这样搜索框才收得到键盘输入，而且不会把当前 App 切走。
    override var canBecomeKey: Bool { true }

    /// Esc 不一定走到搜索框的 delegate（字段编辑器有时把它交给窗口），窗口这层兜底。
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func keyDown(with event: NSEvent) {
        if ProcessInfo.processInfo.environment["COFFEEBAR_DEBUG"] != nil { NSLog("CoffeeBar panel keyDown code=\(event.keyCode)") }
        if event.keyCode == 53 { dismiss(); return }
        super.keyDown(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { dismiss(); return }
        super.sendEvent(event)
    }

    // MARK: - 内容

    func showItems(_ entries: [(MenuBarItem, NSImage?)], notice: (text: String, buttons: [NoticeButton])?, anchor: NSRect) {
        self.anchor = anchor
        allEntries = entries
        searchField.stringValue = ""

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 6

        if let notice {
            column.addArrangedSubview(makeNotice(notice.text, buttons: notice.buttons))
        }
        if entries.isEmpty, notice == nil {
            column.addArrangedSubview(makeLabel("没有隐藏的图标。右键 “<” 选「整理图标…」，把要藏的拖到 “/” 左边。"))
        }
        if !entries.isEmpty {
            let searchRow = NSStackView()
            searchRow.orientation = .horizontal
            searchRow.spacing = 4
            let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            searchRow.addArrangedSubview(icon)
            searchRow.addArrangedSubview(searchField)
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            column.addArrangedSubview(searchRow)
            searchRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            rowsContainer.orientation = .vertical
            rowsContainer.alignment = .trailing
            rowsContainer.spacing = 0
            column.addArrangedSubview(rowsContainer)
            applyFilter()
        }

        present(column)
        if !entries.isEmpty {
            makeKey()
            makeFirstResponder(searchField)
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = query.isEmpty ? allEntries : allEntries.filter { $0.0.ownerName.lowercased().contains(query) }
        selectedIndex = 0
        rebuildRows()
    }

    private func rebuildRows() {
        rowsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        itemViews = []
        let maxRowWidth = min(720, (NSScreen.main?.frame.width ?? 1440) * 0.6)
        var row = makeRow()
        var rowWidth: CGFloat = 0
        for (index, (item, image)) in filtered.enumerated() {
            let view = ItemView(item: item, image: image)
            view.isSelected = index == selectedIndex && !searchField.stringValue.isEmpty
            if rowWidth > 0, rowWidth + view.itemWidth > maxRowWidth {
                rowsContainer.addArrangedSubview(row)
                row = makeRow()
                rowWidth = 0
            }
            view.onClick = { [weak self] item, right in self?.onItemClick?(item, right) }
            row.addArrangedSubview(view)
            itemViews.append(view)
            rowWidth += view.itemWidth
        }
        if !row.arrangedSubviews.isEmpty {
            rowsContainer.addArrangedSubview(row)
        }
        if filtered.isEmpty {
            rowsContainer.addArrangedSubview(makeLabel("没有匹配的 App"))
        }
        relayout()
    }

    private func updateSelection() {
        for (index, view) in itemViews.enumerated() {
            view.isSelected = index == selectedIndex
        }
    }

    // MARK: - 键盘

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if ProcessInfo.processInfo.environment["COFFEEBAR_DEBUG"] != nil { NSLog("CoffeeBar panel command: \(commandSelector)") }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if filtered.indices.contains(selectedIndex) {
                onItemClick?(filtered[selectedIndex].0, false)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            // 字段编辑器里 Esc 有时映射成 complete:（自动补全），两个都当关闭。
            dismiss()
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveDown(_:)):
            if !filtered.isEmpty { selectedIndex = (selectedIndex + 1) % filtered.count; updateSelection() }
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveUp(_:)):
            if !filtered.isEmpty { selectedIndex = (selectedIndex - 1 + filtered.count) % filtered.count; updateSelection() }
            return true
        default:
            return false
        }
    }

    // MARK: - 组件

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

    // MARK: - 显示 / 布局

    private func present(_ content: NSView) {
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
        relayout()
        orderFrontRegardless()
        startOutsideClickMonitor()
    }

    /// 按内容尺寸重新摆放：右对齐到开关按钮下方，并且不出屏幕。
    private func relayout() {
        guard let background = contentView else { return }
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 4)
        if let screen {
            origin.x = max(screen.visibleFrame.minX + 4, min(origin.x, screen.visibleFrame.maxX - size.width - 4))
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - 关闭

    func dismiss() {
        stopOutsideClickMonitor()
        searchField.stringValue = ""
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
