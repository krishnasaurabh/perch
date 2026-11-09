// Temporary app entry point for check_motion.sh. No system preferences or real planner changes.
import AppKit
import Combine
import PlannerCore
import SwiftUI

@MainActor
final class Evidence {
    var passed: [String] = []
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed.append(message)
        print("PASS: \(message)")
    }
}

@MainActor
final class FixtureState: ObservableObject {
    @Published var expanded = false
    // The observer sits INSIDE a deliberately uncooperative nested animation modifier.
    var transactions: [(animated: Bool, disabled: Bool)] = []
    var sizes: [CGSize] = []
}

struct SizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct NestedAnimationFixture: View {
    @ObservedObject var state: FixtureState
    var body: some View {
        Rectangle().fill(Color.orange)
            .frame(width: state.expanded ? 240 : 80, height: state.expanded ? 120 : 40)
            .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
            .onPreferenceChange(SizeKey.self) { state.sizes.append($0) }
            .scaleEffect(state.expanded ? 1 : 0.5)
            .transaction { state.transactions.append(($0.animation != nil, $0.disablesAnimations)) }
            .animation(.linear(duration: 0.25), value: state.expanded)
            .motion(Motion.card, value: state.expanded)
            .motionBoundary()
    }
}

@MainActor
func settle(_ seconds: Double = 0.4) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
func render<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor
func snapshot(_ view: NSView, to url: URL) -> Bool {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: url); return NSImage(data: png) != nil } catch { return false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOTION_PROBE_OUTPUT"]!)
    let evidence = Evidence()
    Task { @MainActor in
        let tokens: [(String, Animation, Animation)] = [
            ("open", Motion.open, .spring(response: 0.30, dampingFraction: 1)),
            ("close", Motion.close, .spring(response: 0.20, dampingFraction: 1)),
            ("activity", Motion.activity, .easeInOut(duration: 0.19)),
            ("activityDismiss", Motion.activityDismiss, .spring(response: 0.20, dampingFraction: 1)),
            ("page", Motion.page, .easeOut(duration: 0.18)),
            ("row", Motion.row, .spring(response: 0.24, dampingFraction: 1)),
            ("tick", Motion.tick, .spring(response: 0.16, dampingFraction: 1)),
            ("card", Motion.card, .spring(response: 0.26, dampingFraction: 1)),
            ("bar", Motion.bar, .spring(response: 0.30, dampingFraction: 1)),
        ]
        evidence.require(Motion.barStagger == 0.13, "normal bar stagger unchanged")
        evidence.require(Motion.reduced == .easeInOut(duration: 0.15), "opacity-only token remains 150 ms")
        var env = EnvironmentValues()
        env.accessibilityReduceMotion = true
        evidence.require(env.motionPolicy.reduceMotion, "environment follows enabled system preference")
        env.accessibilityReduceMotion = false
        evidence.require(!env.motionPolicy.reduceMotion, "environment follows disabled system preference")
        env.motionPolicyOverride = MotionPolicy(reduceMotion: true)
        evidence.require(env.motionPolicy.reduceMotion, "injected environment overrides host preference")

        let store = PlannerStore()
        store.updatePrefs { $0.catchCopies = false; $0.catchScreenshots = false; $0.welcomeCompleted = true }
        let services = Services(store: store)
        let geometry = NotchGeometry(screen: .init(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                  visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876)))
        for reduced in [false, true] {
            let policy = MotionPolicy(reduceMotion: reduced)
            let prefix = reduced ? "reduced" : "normal"
            for (name, token, expected) in tokens {
                evidence.require(token == expected, "\(prefix): \(name) token unchanged")
                let tx = policy.transaction(token)
                evidence.require(tx.animation == (reduced ? nil : expected), "\(prefix): \(name) transaction animation")
                evidence.require(tx.disablesAnimations == reduced, "\(prefix): \(name) nested-animation guard")
            }
            var inherited = Transaction(animation: .linear(duration: 9))
            policy.enforce(on: &inherited)
            evidence.require(inherited.animation == (reduced ? nil : .linear(duration: 9)),
                             "\(prefix): inherited animation handled without changing normal mode")

            let state = FixtureState()
            let fixture = NestedAnimationFixture(state: state).environment(\.motionPolicyOverride, policy)
            let (window, host) = render(fixture, size: CGSize(width: 400, height: 250))
            await settle()
            state.transactions.removeAll(); state.sizes.removeAll()
            // Explicit outer animation AND a nested implicit animation must not bypass the boundary.
            withAnimation(.linear(duration: 0.25)) { state.expanded = true }
            await settle()
            host.layoutSubtreeIfNeeded()
            evidence.require(!state.transactions.isEmpty, "\(prefix): observed real SwiftUI update transaction")
            if reduced {
                evidence.require(state.transactions.allSatisfy { !$0.animated && $0.disabled },
                                 "reduced: nested scale/frame animation cannot re-enable interpolation")
                evidence.require(!state.sizes.isEmpty && state.sizes.allSatisfy { $0 == CGSize(width: 240, height: 120) },
                                 "reduced: layout reports final dimensions only")
            } else {
                evidence.require(state.transactions.contains { $0.animated && !$0.disabled },
                                 "normal: positive control retains animated update")
            }
            evidence.require(state.sizes.last == CGSize(width: 240, height: 120), "\(prefix): final layout dimensions")
            window.close()

            let model = NotchModel(motionPolicy: policy)
            model.screenID = 1
            model.geometry = geometry
            let screen = NotchScreenState(id: 1, geometry: geometry)
            let root = NotchRootView().environmentObject(store).environmentObject(model)
                .environmentObject(services).environmentObject(screen)
                .environment(\.motionPolicyOverride, policy)
            let (rootWindow, rootHost) = render(root, size: geometry.window.size)
            model.open(page: .home, pinned: true)
            await settle()
            evidence.require(model.expanded && model.page == .home && model.pinned, "\(prefix): open final state")
            evidence.require(snapshot(rootHost, to: output.appendingPathComponent("\(prefix)-open.png")),
                             "\(prefix): actual root renders open state")
            Motion.animate(Motion.page, policy: policy) { model.page = .week }
            evidence.require(model.page == .week, "\(prefix): page final state")
            let activity = NotchActivity(kind: .message, title: "Motion policy probe", subtitle: "Isolated fixture")
            model.show(activity)
            evidence.require(model.activity?.id == activity.id, "\(prefix): activity final state")
            model.dismissActivity()
            evidence.require(model.activity == nil, "\(prefix): activity dismiss final state")
            model.close()
            await settle()
            evidence.require(!model.expanded && !model.pinned, "\(prefix): close final state")
            evidence.require(snapshot(rootHost, to: output.appendingPathComponent("\(prefix)-closed.png")),
                             "\(prefix): actual root renders closed state")
            rootWindow.close()

            // Repeated renders exercise the real owl, not a fake scheduler or a policy boolean.
            let (owlWindow, owlHost) = render(OwlMark(size: 40).environment(\.motionPolicyOverride, policy),
                                             size: CGSize(width: 60, height: 60))
            await settle()
            evidence.require(snapshot(owlHost, to: output.appendingPathComponent("\(prefix)-owl.png")),
                             "\(prefix): static owl renders")
            owlWindow.close()
        }
        let report: [String: Any] = ["assertions": evidence.passed, "passed": evidence.passed.count,
            "evidenceType": "in-process policy, transaction, layout and final-state assertions",
            "notProven": ["presentation-layer trajectory", "physical accessibility setting toggles", "VoiceOver", "hardware notch"]]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("motion-report.json"))
        print("Motion policy probe passed: \(evidence.passed.count) assertions. Not a video/presentation-layer measurement.")
        exit(0)
    }
    app.run()
}
