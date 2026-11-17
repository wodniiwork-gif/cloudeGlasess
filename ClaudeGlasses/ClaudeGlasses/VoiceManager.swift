import AVFoundation
import Foundation
import Speech

/// Microphone of the glasses (Bluetooth HFP) → text, and text → speech in the
/// glasses speakers.
///
/// Two ways to ask:
///  • "Слушать всегда": the app listens all the time and reacts only to phrases
///    that contain the wake word «Клод» (e.g. «Клод, что это за кроссовки?»).
///  • The big button: one question, no wake word needed.
@MainActor
final class VoiceManager: NSObject, ObservableObject {
  @Published var isListening = false
  @Published var isSpeaking = false
  @Published var liveText = ""
  @Published var usingGlassesMic = false
  @Published var errorMessage: String?

  /// Called with the finished question (wake word already removed).
  var onQuestion: ((String) -> Void)?

  /// Words that wake the assistant. Recognition of names is not perfect,
  /// so we accept several spellings.
  private let wakeWords = ["клод", "клоод", "клауд", "клот", "claude", "cloud", "клад"]

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
  private let engine = AVAudioEngine()
  private let synthesizer = AVSpeechSynthesizer()
  /// The audio thread reads the current request through this lock-protected box.
  private nonisolated let activeRequest = RequestBox()
  private var request: SFSpeechAudioBufferRecognitionRequest? {
    didSet { activeRequest.set(request) }
  }
  private var task: SFSpeechRecognitionTask?
  private var silenceTimer: Timer?
  private var requireWakeWord = true
  private var continuous = false
  private var audioReady = false
  private var handledCurrentRequest = false

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  // MARK: Permissions + audio route

  func requestPermissions() async -> Bool {
    let mic = await AVAudioApplication.requestRecordPermission()
    let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
    }
    if !mic { errorMessage = "Нет доступа к микрофону. Включи его в Настройках iPhone." }
    if !speech { errorMessage = "Нет доступа к распознаванию речи. Включи его в Настройках iPhone." }
    return mic && speech
  }

  /// Routes audio through the glasses (HFP: their mic and speakers).
  /// Meta's docs: do this before the camera stream starts, then wait ~2 s.
  func prepareGlassesAudio() async {
    let audio = AVAudioSession.sharedInstance()
    do {
      try audio.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
      try audio.setActive(true, options: .notifyOthersOnDeactivation)
      if let hfp = audio.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try audio.setPreferredInput(hfp)
      }
      try startEngine()
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      usingGlassesMic = audio.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
      audioReady = true
    } catch {
      errorMessage = "Звук: \(error.localizedDescription)"
    }
  }

  private func startEngine() throws {
    guard !engine.isRunning else { return }
    let input = engine.inputNode
    let format = input.inputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(activeRequest))
    engine.prepare()
    try engine.start()
  }

  /// Built outside the main actor: the tap runs on an audio thread.
  private nonisolated static func makeTap(_ box: RequestBox) -> AVAudioNodeTapBlock {
    return { buffer, _ in box.get()?.append(buffer) }
  }

  /// Built outside the main actor: Speech calls it on its own queue.
  private nonisolated static func makeResultHandler(
    _ owner: VoiceManager
  ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    return { [weak owner] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      Task { @MainActor in owner?.handle(text: text, isFinal: isFinal, failed: failed) }
    }
  }

  // MARK: Listening

  /// Always-on listening with the wake word.
  func startContinuous() {
    continuous = true
    beginRecognition(requireWakeWord: true)
  }

  func stopContinuous() {
    continuous = false
    endRecognition()
  }

  /// One question right now, no wake word.
  func askOnce() {
    synthesizer.stopSpeaking(at: .immediate)
    beginRecognition(requireWakeWord: false)
  }

  private func beginRecognition(requireWakeWord: Bool) {
    guard let recognizer, recognizer.isAvailable else {
      errorMessage = "Распознавание речи сейчас недоступно (нужен интернет)."
      return
    }
    if !audioReady {
      Task {
        await prepareGlassesAudio()
        if audioReady { beginRecognition(requireWakeWord: requireWakeWord) }
      }
      return
    }
    endRecognition()
    self.requireWakeWord = requireWakeWord
    handledCurrentRequest = false
    liveText = ""

    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    newRequest.addsPunctuation = true
    request = newRequest
    isListening = true

    task = recognizer.recognitionTask(with: newRequest, resultHandler: Self.makeResultHandler(self))
  }

  private func endRecognition() {
    silenceTimer?.invalidate()
    silenceTimer = nil
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    isListening = false
  }

  private func handle(text: String?, isFinal: Bool, failed: Bool) {
    guard !handledCurrentRequest else { return }
    if let text, !text.isEmpty {
      liveText = text
      // A pause of 1.5 s after speech = the question is finished.
      silenceTimer?.invalidate()
      silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.finishUtterance() }
      }
      if isFinal { finishUtterance() }
    } else if failed || isFinal {
      // Apple stops recognition after ~1 minute or on silence; restart if needed.
      endRecognition()
      if continuous && !isSpeaking { restartSoon() }
    }
  }

  private func finishUtterance() {
    guard !handledCurrentRequest else { return }
    handledCurrentRequest = true
    let text = liveText
    endRecognition()

    if let question = extractQuestion(from: text) {
      onQuestion?(question)
    } else if continuous {
      restartSoon()
    }
  }

  /// Returns the question, or nil if the wake word is required but missing.
  private func extractQuestion(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard requireWakeWord else { return trimmed }

    let lower = trimmed.lowercased()
    var best: Range<String.Index>?
    for word in wakeWords {
      if let range = lower.range(of: word, options: .backwards),
        best == nil || range.lowerBound > best!.lowerBound
      {
        best = range
      }
    }
    guard let found = best else { return nil }
    // Skip to the end of the word (e.g. «Клоду», «Клод,»).
    var end = found.upperBound
    while end < lower.endIndex, lower[end].isLetter { end = lower.index(after: end) }
    let offset = lower.distance(from: lower.startIndex, to: end)
    let rest = String(trimmed.dropFirst(offset))
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    return rest.isEmpty ? "Что ты видишь?" : rest
  }

  private func restartSoon() {
    Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      if continuous && !isSpeaking && !isListening { beginRecognition(requireWakeWord: true) }
    }
  }

  /// Call after an answer has been spoken (or failed) to keep listening.
  func resumeIfContinuous() {
    if continuous { restartSoon() }
  }

  // MARK: Speaking

  func speak(_ text: String) {
    endRecognition()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
    isSpeaking = true
    synthesizer.speak(utterance)
  }

  func stopSpeaking() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}

final class RequestBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: SFSpeechAudioBufferRecognitionRequest?

  func set(_ newValue: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock(); value = newValue; lock.unlock()
  }

  func get() -> SFSpeechAudioBufferRecognitionRequest? {
    lock.lock(); defer { lock.unlock() }
    return value
  }
}

extension VoiceManager: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    Task { @MainActor in
      self.isSpeaking = false
      self.resumeIfContinuous()
    }
  }

  nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
    Task { @MainActor in self.isSpeaking = false }
  }
}
