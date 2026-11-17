import Combine
import Foundation
import UIKit

/// Glues it together: question from the voice → frame from the glasses →
/// Claude → answer spoken in the glasses.
@MainActor
final class Assistant: ObservableObject {
  struct Exchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: String?
    let image: UIImage?
  }

  @Published var log: [Exchange] = []
  @Published var isThinking = false
  @Published var alwaysListening = false {
    didSet { alwaysListening ? voice.startContinuous() : voice.stopContinuous() }
  }
  @Published var sendPicture = true
  @Published var mode: AssistantMode =
    AssistantMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .general
  {
    didSet {
      UserDefaults.standard.set(mode.rawValue, forKey: "mode")
      newConversation()  // a fresh start so the old topic doesn't leak in
    }
  }
  @Published var apiKey: String = Keychain.load("apiKey") {
    didSet { Keychain.save(apiKey, for: "apiKey") }
  }
  @Published var model: String = UserDefaults.standard.string(forKey: "model") ?? "claude-sonnet-5-5" {
    didSet { UserDefaults.standard.set(model, forKey: "model") }
  }

  let glasses = GlassesManager()
  let voice = VoiceManager()
  private var history: [ClaudeClient.Turn] = []
  private var bag = Set<AnyCancellable>()

  init() {
    voice.onQuestion = { [weak self] question in
      Task { await self?.ask(question) }
    }
    glasses.prepareAudioBeforeStream = { [weak self] in
      await self?.voice.prepareGlassesAudio()
    }
    // Re-publish changes of the child objects so SwiftUI refreshes.
    glasses.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
  }

  /// Connect everything: permissions, audio through the glasses, camera.
  func start() async {
    guard await voice.requestPermissions() else { return }
    await glasses.start()
    if !glasses.isStreaming {
      // Camera may still be starting; audio is set up anyway.
      await voice.prepareGlassesAudio()
    }
  }

  func ask(_ question: String) async {
    guard !isThinking else { return }

    // Voice switch: «Клод, режим барбера» / «Клод, обычный режим».
    let lower = question.lowercased()
    if lower.contains("режим") && lower.count < 40 {
      if lower.contains("барбер") || lower.contains("стрижк") {
        mode = .barber; announceMode(); return
      }
      if lower.contains("обычн") {
        mode = .general; announceMode(); return
      }
    }

    isThinking = true
    let image = sendPicture ? glasses.frames.latest() : nil
    let entry = Exchange(question: question, answer: nil, image: image)
    log.insert(entry, at: 0)
    func setAnswer(_ text: String) {
      if let i = log.firstIndex(where: { $0.id == entry.id }) { log[i].answer = text }
    }

    let client = ClaudeClient(apiKey: apiKey, model: model, systemPrompt: mode.systemPrompt)
    do {
      let answer = try await client.ask(question: question, image: image, history: history)
      setAnswer(answer)
      remember(question: question, answer: answer)
      isThinking = false
      voice.speak(answer)
    } catch {
      let message = error.localizedDescription
      setAnswer("⚠️ \(message)")
      isThinking = false
      voice.speak("Не получилось. \(message)")
    }
  }

  func newConversation() {
    history.removeAll()
    log.removeAll()
  }

  /// Short sentence to confirm a mode switch in the glasses.
  func announceMode() {
    voice.speak(mode == .barber ? "Режим барбера. Спрашивай, я смотрю." : "Обычный режим.")
  }

  /// Keep the last 6 exchanges as text so follow-up questions make sense.
  private func remember(question: String, answer: String) {
    history.append(.init(role: "user", text: question))
    history.append(.init(role: "assistant", text: answer))
    let limit = mode == .barber ? 20 : 12
    if history.count > limit { history.removeFirst(history.count - limit) }
  }
}
