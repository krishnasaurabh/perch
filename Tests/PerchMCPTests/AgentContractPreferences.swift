import PlannerCore

/// Existing protocol tests exercise enabled operations. Permission defaults have
/// separate tests and are never changed by this fixture.
enum AgentContractPreferences {
    static func enabled() -> MemoryPlannerPreferences {
        var preferences = Preferences()
        preferences.agentsCanControlTime = true
        preferences.agentsCanReadParkingLot = true
        preferences.confirmAgentDeletes = false
        return MemoryPlannerPreferences(DevicePreferences(preferences))
    }
}
