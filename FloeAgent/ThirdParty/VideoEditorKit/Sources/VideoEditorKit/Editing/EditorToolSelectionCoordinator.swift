public enum EditorToolSelectionCoordinator {

    // MARK: - Public Methods

    public static func enabledTools(
        from availabilities: [ToolAvailability]
    ) -> Set<ToolEnum> {
        Set(availabilities.filter(\.isEnabled).map(\.tool))
    }

    public static func resolvedSelection(
        currentSelection: ToolEnum?,
        enabledTools: Set<ToolEnum>
    ) -> ToolEnum? {
        guard let currentSelection else { return nil }
        return enabledTools.contains(currentSelection) ? currentSelection : nil
    }

    public static func selectTool(
        _ tool: ToolEnum,
        enabledTools: Set<ToolEnum>
    ) -> ToolEnum? {
        enabledTools.contains(tool) ? tool : nil
    }

    public static func closeSelectedTool() -> ToolEnum? {
        nil
    }

}
