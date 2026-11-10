import PlannerCore

extension PlannerStore {
    /// Engine bookkeeping the user didn't do (launch recovery, timer ticks): a locked write like `apply`,
    /// but kept off the undo stack. Undoing a recovery would resume a timer from before the crash and
    /// credit the offline gap; a checkpoint every 30 s would bury the user's own edits and clear redo.
    @discardableResult
    func applyUntracked<T>(_ body: (PlannerCommands) throws -> T) -> T? {
        performMutation(origin: .background, body)
    }
}
