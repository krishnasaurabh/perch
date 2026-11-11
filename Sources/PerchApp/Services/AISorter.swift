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
                case .unavailable(.deviceNotEligible):
                    return AppL10n.text("Apple Intelligence isn't available on this Mac.")
                case .unavailable(.appleIntelligenceNotEnabled):
                    return AppL10n.text("Apple Intelligence is switched off. Enable it in System Settings first.")
                case .unavailable(.modelNotReady):
                    return AppL10n.text("The on-device model isn't ready yet. Try again shortly.")
                default: return AppL10n.text("Apple Intelligence isn't available.")
                }
            }
        #endif
        return AppL10n.text("Available from macOS 26, on Macs with Apple Intelligence.")
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
                    PlatformLog.sorting.debug("sort started count=\(tasks.count, privacy: .public)")
                    for t in tasks {
                        do {
                            let s = try await suggest(title: t.title, projects: projects)
                            let project = store.planner.projects.first {
                                $0.name.caseInsensitiveCompare(s.project) == .orderedSame
                            }?.id
                            store.send(
                                .suggest(t.id, priority: s.priority.taskPriority, projectID: project),
                                origin: .background)
                            PlatformLog.sorting.debug("sort completed id=\(t.id.uuidString, privacy: .private)")
                        } catch {
                            PlatformLog.sorting.error(
                                "sort failed code=\(PlatformLog.errorCode(error), privacy: .public)")
                            store.lastError = .aiSorting(error.localizedDescription)
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
            @Guide(
                description:
                    "A single project name from the list if the task obviously belongs to it; empty string if none fits"
            )
            var project: String
        }

        @available(macOS 26.0, *)
        @Generable
        enum SortedPriority {
            case low, medium, high
            var taskPriority: TaskPriority {
                switch self {
                case .low: .low;
                case .medium: .medium;
                case .high: .high
                }
            }
        }

        @available(macOS 26.0, *)
        static func suggest(title: String, projects: [String]) async throws -> SortedTask {
            let session = LanguageModelSession(
                instructions: """
                    You sort to-do items for a personal planner. Judge how important or urgent each task is, and pick a project \
                    only when one of the user's projects clearly fits. Most everyday tasks are low or medium priority; reserve high \
                    for deadlines, bills, health and anything someone is waiting on.
                    """)
            let prompt =
                "Available projects: \(projects.isEmpty ? "none" : projects.joined(separator: ", ")).\nTask: \(title)"
            return try await session.respond(to: prompt, generating: SortedTask.self).content
        }
    #endif
}
