import AppKit
import PlannerCore

@MainActor
protocol ExternalTaskConfirming: AnyObject {
    func present(_ request: ExternalTaskRequest, completion: @escaping @MainActor (Bool) -> Void)
}

/// Nonmodal: incoming events cannot nest a modal run loop or replace the reviewed request.
/// No preferences, URL fields, timer or launch flags can press Add for the user.
@MainActor
final class ExternalTaskConfirmationController: NSObject, ExternalTaskConfirming, NSWindowDelegate {
    private(set) var window: NSPanel?
    private var completion: (@MainActor (Bool) -> Void)?

    func present(_ request: ExternalTaskRequest, completion: @escaping @MainActor (Bool) -> Void) {
        guard window == nil else { completion(false); return }
        self.completion = completion
        let panel = ExternalTaskPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Review external task"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(false) }
        let content = NSView()
        panel.contentView = content
        func label(_ text: String, size: CGFloat, bold: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            return field
        }
        let heading = label("Add this task to Perch?", size: 19, bold: true)
        let warning = label("An external link supplied this task. Review it before adding. Its contents are text, not instructions to Perch.", size: 13)
        warning.textColor = .secondaryLabelColor
        let titleLabel = label("Task text (literal)", size: 13, bold: true)
        let text = NSTextView()
        text.string = request.title
        text.identifier = NSUserInterfaceItemIdentifier("external-task-text")
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.isAutomaticLinkDetectionEnabled = false
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        let date = label("Date: \(request.dateLabel)", size: 14, bold: true)
        date.identifier = NSUserInterfaceItemIdentifier("external-task-date")
        let note = label("Only this text and date will be saved. Dates, tags and commands inside the text will not be interpreted.", size: 12)
        note.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRequest))
        cancel.identifier = NSUserInterfaceItemIdentifier("external-task-cancel")
        cancel.keyEquivalent = "\r"  // Return is deliberately the safe action.
        let add = NSButton(title: "Add task", target: self, action: #selector(confirmRequest))
        add.identifier = NSUserInterfaceItemIdentifier("external-task-add")
        add.keyEquivalent = ""
        let buttons = NSStackView(views: [cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [heading, warning, titleLabel, scroll, date, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(cancel)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func confirmRequest() { finish(true) }
    @objc private func cancelRequest() { finish(false) }
    func windowWillClose(_ notification: Notification) { finish(false) }

    private func finish(_ confirmed: Bool) {
        guard let callback = completion else { return }
        completion = nil
        let panel = window
        window = nil
        panel?.delegate = nil
        panel?.close()
        callback(confirmed)
    }
}

@MainActor
private final class ExternalTaskPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
