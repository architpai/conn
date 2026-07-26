public enum ConnCompositeModelControlPresentation {
    public static func label(
        modelName: String?,
        reasoningName: String?,
        isLoading: Bool
    ) -> String {
        if isLoading { return "Loading models…" }
        switch (modelName, reasoningName) {
        case let (modelName?, reasoningName?):
            return "\(modelName) · \(reasoningName)"
        case let (modelName?, nil):
            return modelName
        case let (nil, reasoningName?):
            return reasoningName
        case (nil, nil):
            return "Model & reasoning"
        }
    }
}
