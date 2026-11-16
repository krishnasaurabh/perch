import AppKit
import SwiftUI

/// Project cards share the dashboard window and its Undo routing.
struct ProjectsView: View {
    @EnvironmentObject private var store: PlannerStore

    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("Group the tasks that belong together.")
    }

    var body: some View {
        ProjectsList()
            .modifier(DashboardPaneDiagnostic(name: "Projects tab host", store: store, dumpTree: true))
    }

    #if DEBUG || PERCH_TESTING
        static func preview(_ mode: ProjectsPreviewState.Mode, app: AppDelegate) {
            ProjectsPreviewState.shared.mode = mode
            DashboardWindow.show(store: app.store, tab: .projects)
        }
    #endif
}

struct DashboardPaneDiagnostic: ViewModifier {
    let name: String
    let store: PlannerStore
    var dumpTree = false

    private var enabled: Bool { store.planner.tasks.contains { $0.title == "Finished synthetic task" } }

    func body(content: Content) -> some View {
        DashboardDiagnosticLayout(name: name, enabled: enabled) { content }
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear {
                        guard enabled else { return }
                        print("PANE-DIAG \(name) resolved=\(geometry.size) global=\(geometry.frame(in: .global))")
                        print(
                            "PANE-DIAG \(name) projects=\(store.planner.projects.count) tasks=\(store.planner.tasks.map(\.title))"
                        )
                    }
                    .onChange(of: geometry.size) { _, size in
                        if enabled { print("PANE-DIAG \(name) resolved-change=\(size)") }
                    }
                }
                if enabled && dumpTree { DashboardDiagnosticTree(name: name) }
            }
    }
}

struct DashboardDiagnosticLayout: Layout {
    let name: String
    let enabled: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        if enabled { print("PANE-DIAG \(name) proposed=\(proposal) measured=\(size)") }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if enabled { print("PANE-DIAG \(name) place proposed=\(proposal) actual=\(bounds)") }
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

private struct DashboardDiagnosticTree: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> DashboardDiagnosticTreeView {
        let view = DashboardDiagnosticTreeView()
        view.name = name
        return view
    }

    func updateNSView(_ view: DashboardDiagnosticTreeView, context: Context) {}
}

private final class DashboardDiagnosticTreeView: NSView {
    var name = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for delay in [0.05, 0.25, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.dump(window, delay: delay)
            }
        }
    }

    private func dump(_ window: NSWindow, delay: Double) {
        var seen = Set<ObjectIdentifier>()
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let frame = (node as? NSAccessibility)?.accessibilityFrame() ?? (node as? NSView)?.frame ?? .zero
            print(
                "PANE-DIAG \(name) NODE \(type(of: node)) role=\(attribute(node, "accessibilityRole") ?? "?") "
                    + "label=\(attribute(node, "accessibilityLabel") ?? "?") frame=\(frame)")
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            children.forEach { walk($0, depth + 1) }
        }
        print(
            "PANE-DIAG \(name) TREE-BEGIN delay=\(delay) window=\(window.frame) content=\(String(describing: window.contentView?.frame))"
        )
        walk(window, 0)
        print("PANE-DIAG \(name) TREE-END count=\(seen.count)")
    }
}
