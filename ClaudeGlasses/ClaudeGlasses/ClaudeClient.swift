import Foundation
import UIKit

/// Minimal client for the Claude Messages API (https://docs.claude.com).
struct ClaudeClient {
  struct Turn {
    let role: String  // "user" or "assistant"
    let text: String
  }

  enum ClientError: LocalizedError {
    case noKey
    case http(Int, String)
    case empty

    var errorDescription: String? {
      switch self {
      case .noKey: return "Не задан ключ API. Открой настройки (шестерёнка)."
      case .http(let code, let message): return "Ошибка Claude (\(code)): \(message)"
      case .empty: return "Claude ничего не ответил."
      }
    }
  }


  let apiKey: String
  let model: String
  let systemPrompt: String

  func ask(question: String, image: UIImage?, history: [Turn]) async throws -> String {
    guard !apiKey.isEmpty else { throw ClientError.noKey }

    var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }

    var content: [[String: Any]] = []
    if let image, let jpeg = Self.jpeg(image) {
      content.append([
        "type": "image",
        "source": [
          "type": "base64",
          "media_type": "image/jpeg",
          "data": jpeg.base64EncodedString(),
        ],
      ])
    }
    content.append(["type": "text", "text": question])
    messages.append(["role": "user", "content": content])

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 400,
      "system": systemPrompt,
      "messages": messages,
    ]

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

    guard status == 200 else {
      let message = ((json?["error"] as? [String: Any])?["message"] as? String)
        ?? String(data: data, encoding: .utf8) ?? ""
      throw ClientError.http(status, message)
    }

    let blocks = json?["content"] as? [[String: Any]] ?? []
    let text = blocks
      .filter { $0["type"] as? String == "text" }
      .compactMap { $0["text"] as? String }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ClientError.empty }
    return text
  }

  /// Scales the frame down so requests stay small and cheap.
  private static func jpeg(_ image: UIImage) -> Data? {
    let maxSide: CGFloat = 1024
    let size = image.size
    let scale = min(1, maxSide / max(size.width, size.height))
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: 0.7)
  }
}
