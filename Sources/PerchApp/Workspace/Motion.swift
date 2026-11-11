import AppKit
import SwiftUI

// MARK: - Motion tokens

/// Critically damped spring tokens used by Perch's interface transitions.
/// Every token is ζ = 1.0 (no overshoot). `response` is the spring period, not a settle time.
enum Motion {
    /// Notch opening: spring R 0.30, ζ 1 (95 % at ≈ 200 ms).
    static let open = Animation.spring(response: 0.30, dampingFraction: 1.0)
    /// Notch closing is nearly a snap (gone in 133–150 ms).
    static let close = Animation.spring(response: 0.20, dampingFraction: 1.0)
    /// Activity strip drop from the notch: easeInOut ≈ 0.19 s (150 ms to 95 %).
    static let activity = Animation.easeInOut(duration: 0.19)
    static let activityDismiss = Animation.spring(response: 0.20, dampingFraction: 1.0)
    /// Page switch: in-place crossfade of ≈ 170 ms. The selected tab pill snaps.
    static let page = Animation.easeOut(duration: 0.18)
    /// Row tick and insert: the row fades in place while the rows below slide up. Spring R 0.24, ζ 1 (≈ 250 ms).
    static let row = Animation.spring(response: 0.24, dampingFraction: 1.0)
    /// Immediate tick feedback: the circle fills before the row leaves.
    static let tick = Animation.spring(response: 0.16, dampingFraction: 1.0)
    /// A card entering or leaving Home (the timer starts, today's events load).
    static let card = Animation.spring(response: 0.26, dampingFraction: 1.0)
    /// One Insights bar growing from the baseline: spring R 0.30, ζ 1 (≈ 200 ms), staggered 130 ms left to right.
    static let bar = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let barStagger = 0.13
    /// Reserved for opacity-only effects. Never substitute this on a layout/scale transaction.
    static let reduced = Animation.easeInOut(duration: 0.15)

    static var reduceMotion: Bool { MotionPolicy.system.reduceMotion }
    static func resolved(_ a: Animation) -> Animation? { MotionPolicy.system.animation(a) }

    /// Reduced mode snaps to the final state. `disablesAnimations` also prevents nested
    /// `.animation` modifiers from adding their own spatial animation to this transaction.
    @discardableResult
    static func animate<R>(_ a: Animation, policy: MotionPolicy = .system, _ body: () throws -> R) rethrows -> R {
        let transaction = policy.transaction(a)
        #if DEBUG || PERCH_TESTING
            MotionScript.recordTransaction(transaction, stage: "explicit-action")
        #endif
        return try withTransaction(transaction, body)
    }
}

/// One policy for explicit updates, implicit view animations and notch choreography.
/// Reduced mode intentionally omits the optional 150 ms opacity fade: no layout, scale,
/// travel or repeating effects may ride on a transaction intended only for opacity.
struct MotionPolicy: Equatable, Sendable {
    let reduceMotion: Bool
    static var system: Self {
        #if DEBUG || PERCH_TESTING
            if let override = MotionScript.policyOverride { return override }
        #endif
        return Self(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func animation(_ normal: Animation) -> Animation? { reduceMotion ? nil : normal }

    func enforce(on transaction: inout Transaction) {
        guard reduceMotion else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }

    func transaction(_ normal: Animation) -> Transaction {
        var transaction = Transaction(animation: animation(normal))
        enforce(on: &transaction)
        return transaction
    }

    var workspaceTransition: AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.5, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
    }
}

#if DEBUG || PERCH_TESTING
    private struct MotionPolicyOverrideKey: EnvironmentKey {
        static let defaultValue: MotionPolicy? = nil
    }

    extension EnvironmentValues {
        /// Injection seam for in-process tests; production follows live SwiftUI accessibility changes.
        var motionPolicyOverride: MotionPolicy? {
            get { self[MotionPolicyOverrideKey.self] }
            set { self[MotionPolicyOverrideKey.self] = newValue }
        }
    }
#endif

extension EnvironmentValues {
    var motionPolicy: MotionPolicy {
        #if DEBUG || PERCH_TESTING
            if let motionPolicyOverride { return motionPolicyOverride }
        #endif
        return MotionPolicy(reduceMotion: accessibilityReduceMotion)
    }
}

extension View {
    @ViewBuilder
    func motionDiagnostics(model: NotchModel) -> some View {
        #if DEBUG || PERCH_TESTING
            modifier(MotionScript.PolicyProbe()).environment(\.motionPolicyOverride, model.motionPolicyOverride)
        #else
            self
        #endif
    }

    func motion<V: Equatable>(_ a: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: a, value: value))
    }

    /// Place outside the animated subtree so descendants cannot re-enable interpolation.
    func motionBoundary() -> some View { modifier(MotionBoundary()) }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.motionPolicy) private var policy
    func body(content: Content) -> some View {
        content.animation(policy.animation(animation), value: value)
            .transaction { policy.enforce(on: &$0) }
    }
}

private struct MotionBoundary: ViewModifier {
    @Environment(\.motionPolicy) private var policy
    func body(content: Content) -> some View {
        content.transaction {
            policy.enforce(on: &$0)
            #if DEBUG || PERCH_TESTING
                MotionScript.recordTransaction($0, stage: "motion-boundary-after-enforce")
            #endif
        }
    }
}
