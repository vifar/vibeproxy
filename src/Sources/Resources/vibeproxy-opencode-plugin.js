// VibeProxy opencode plugin — live model pull.
//
// opencode's @ai-sdk/openai-compatible provider has no listModels support, so
// opencode cannot enumerate a provider's models from /v1/models on its own.
// This plugin supplies the `provider.models` hook: opencode calls it at
// runtime and the model list is fetched from the VibeProxy proxy's /v1/models
// endpoint on every request. There is NO static model data anywhere — whatever
// the proxy serves today is exactly what opencode lists.
export const VibeProxyModels = async () => {
  const baseURL = "http://127.0.0.1:8318/v1"
  return {
    provider: {
      id: "vibeproxy",
      models: async () => {
        try {
          const response = await fetch(`${baseURL}/models`, {
            headers: { Accept: "application/json" },
          })
          if (!response.ok) {
            return {}
          }
          const payload = await response.json()
          const models = {}
          for (const entry of payload.data || []) {
            const id = entry.id
            if (!id) continue
            models[id] = {
              id,
              name: id,
              providerID: "vibeproxy",
              api: {
                id: "vibeproxy",
                url: baseURL,
                npm: "@ai-sdk/openai-compatible",
              },
              capabilities: {
                temperature: true,
                reasoning: false,
                attachment: false,
                toolcall: true,
                input: {
                  text: true,
                  audio: false,
                  image: false,
                  video: false,
                  pdf: false,
                },
                output: {
                  text: true,
                  audio: false,
                  image: false,
                  video: false,
                  pdf: false,
                },
                interleaved: false,
              },
              cost: { input: 0, output: 0, cache: { read: 0, write: 0 } },
              limit: { context: 128000, output: 8192 },
              status: "active",
              options: {},
              headers: {},
              release_date: "2025-01-01",
            }
          }
          return models
        } catch (error) {
          console.error("[vibeproxy-models] failed to fetch model list:", error)
          return {}
        }
      },
    },
  }
}
