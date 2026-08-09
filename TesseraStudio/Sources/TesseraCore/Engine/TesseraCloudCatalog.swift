import Foundation

/// One entry in the cloud-provider catalog. Mirrors the Linux
/// `tessera-studio-linux/src/core/config.cpp` cloud catalog so the Mac
/// settings UI offers the same provider picker as the Linux app.
public struct TesseraCloudEntry: Sendable, Identifiable, Hashable {
    public let id: String          // stable provider id, e.g. "openai"
    public let label: String       // display name
    public let baseURL: String     // OpenAI-compatible base URL
    public let defaultModel: String
    public let keychainAccount: String

    public init(id: String, label: String, baseURL: String, defaultModel: String, keychainAccount: String? = nil) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.keychainAccount = keychainAccount ?? "cloud-\(id)"
    }
}

/// The catalog of cloud providers the user can configure keys for. Each
/// entry's API key lives in the Keychain under its `keychainAccount`. The
/// Test button in the settings UI fires a one-token stream ping.
public enum TesseraCloudCatalog {
    public static let entries: [TesseraCloudEntry] = [
        TesseraCloudEntry(id: "openai", label: "OpenAI",
                          baseURL: "https://api.openai.com/v1",
                          defaultModel: "gpt-4o-mini"),
        TesseraCloudEntry(id: "anthropic", label: "Anthropic",
                          baseURL: "https://api.anthropic.com/v1",
                          defaultModel: "claude-3-5-sonnet-20241022"),
        TesseraCloudEntry(id: "google", label: "Google (Gemini)",
                          baseURL: "https://generativelanguage.googleapis.com/v1beta",
                          defaultModel: "gemini-2.0-flash"),
        TesseraCloudEntry(id: "openrouter", label: "OpenRouter",
                          baseURL: "https://openrouter.ai/api/v1",
                          defaultModel: "openai/gpt-4o-mini"),
        TesseraCloudEntry(id: "deepseek", label: "DeepSeek",
                          baseURL: "https://api.deepseek.com/v1",
                          defaultModel: "deepseek-chat"),
        TesseraCloudEntry(id: "zai", label: "Z.ai",
                          baseURL: "https://api.z.ai/api/paas/v4",
                          defaultModel: "glm-4-flash"),
        TesseraCloudEntry(id: "glm", label: "Zhipu (GLM)",
                          baseURL: "https://open.bigmodel.cn/api/paas/v4",
                          defaultModel: "glm-4-flash"),
        TesseraCloudEntry(id: "alibaba", label: "Alibaba (DashScope)",
                          baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                          defaultModel: "qwen-turbo"),
        TesseraCloudEntry(id: "minimax", label: "MiniMax",
                          baseURL: "https://api.minimax.chat/v1",
                          defaultModel: "abab6.5-chat"),
        TesseraCloudEntry(id: "meta", label: "Meta (Llama)",
                          baseURL: "https://api.together.xyz/v1",
                          defaultModel: "meta-llama/Llama-3-70b-chat-hf"),
    ]

    public static func entry(for id: String) -> TesseraCloudEntry? {
        entries.first(where: { $0.id == id })
    }
}
