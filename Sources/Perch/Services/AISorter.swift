import PlannerCore
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Auto-sort new tasks": on-device Apple Intelligence flags clearly important tasks and matches a project.
/// It never overrides what the user typed (#project, !high), and never sets effort or timers.
enum AISorter {
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(.deviceNotEligible): return "Apple Intelligence isn't available on this Mac."
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is switched off. Enable it in System Settings first."
            case .unavailable(.modelNotReady): return "The on-device model isn't ready yet. Try again shortly."
            default: return "Apple Intelligence isn't available."
            }
        }
        #endif
        return "Available from macOS 26, on Macs with Apple Intelligence."
    }

    /// Sorts tasks added since `ids`, in the background, then writes back only untouched fields.
    @MainActor
    static func sort(_ ids: [UUID], store: PlannerStore) {
        guard store.prefs.sortWithAI, isSupported else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let tasks = store.planner.tasks.filter { ids.contains($0.id) && $0.priority == .none }
            let projects = store.planner.projects.map(\.name)
            guard !tasks.isEmpty else { return }
            Task {
                for t in tasks {
                    guard let s = try? await suggest(title: t.title, projects: projects) else { continue }
                    store.updateTask(t.id) { cur in
                        if cur.priority == .none { cur.priority = s.priority.taskPriority }
                        if cur.projectID == nil, !s.project.isEmpty,
                           let p = store.planner.projects.first(where: { $0.name.caseInsensitiveCompare(s.project) == .orderedSame }) {
                            cur.projectID = p.id
                        }
                    }
                }
            }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct SortedTask {
        @Guide(description: "Priority of the task, based on how pressing it sounds")
        var priority: SortedPriority
        @Guide(description: "A single project name from the list if the task obviously belongs to it; empty string if none fits")
        var project: String
    }

    @available(macOS 26.0, *)
    @Generable
    enum SortedPriority {
        case low, medium, high
        var taskPriority: TaskPriority { switch self { case .low: .low; case .medium: .medium; case .high: .high } }
    }

    @available(macOS 26.0, *)
    static func suggest(title: String, projects: [String]) async throws -> SortedTask {
        let session = LanguageModelSession(instructions: """
            You sort to-do items for a personal planner. Judge how important or urgent each task is, and pick a project \
            only when one of the user's projects clearly fits. Most everyday tasks are low or medium priority; reserve high \
            for deadlines, bills, health and anything someone is waiting on.
            """)
        let prompt = "Available projects: \(projects.isEmpty ? "none" : projects.joined(separator: ", ")).\nTask: \(title)"
        return try await session.respond(to: prompt, generating: SortedTask.self).content
    }
    #endif
}

/// A small burst from the top center when a task is checked off.
struct ConfettiBurst: View {
    @State private var bursts: [UUID] = []
    var body: some View {
        ZStack {
            ForEach(bursts, id: \.self) { id in Burst().id(id) }
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: .init("PerchConfetti"))) { _ in
            let id = UUID()
            bursts.append(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { bursts.removeAll { $0 == id } }
        }
    }

    private struct Burst: View {
        @State private var go = false
        let pieces: [(angle: Double, dist: CGFloat, color: Color, size: CGFloat)] = (0..<26).map { _ in
            (Double.random(in: 200...340), CGFloat.random(in: 60...170),
             [Theme.accent, Theme.done, Color(hex: "#8E8CF5"), Color(hex: "#F57FA3"), .white].randomElement()!, CGFloat.random(in: 4...7))
        }
        var body: some View {
            ZStack {
                ForEach(0..<pieces.count, id: \.self) { i in
                    let p = pieces[i]
                    RoundedRectangle(cornerRadius: 1.5).fill(p.color).frame(width: p.size, height: p.size * 1.6)
                        .rotationEffect(.degrees(go ? p.angle * 3 : 0))
                        .offset(x: go ? cos(p.angle * .pi / 180) * p.dist : 0, y: go ? -sin(p.angle * .pi / 180) * p.dist + 40 : 0)
                        .opacity(go ? 0 : 1)
                }
            }
            .onAppear { withAnimation(.easeOut(duration: 1.2)) { go = true } }
        }
    }
}
