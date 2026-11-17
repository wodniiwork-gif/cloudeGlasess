import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// Thread-safe holder for the latest camera frame from the glasses.
final class FrameStore: @unchecked Sendable {
  private let lock = NSLock()
  private var image: UIImage?

  func set(_ newImage: UIImage) {
    lock.lock(); image = newImage; lock.unlock()
  }

  func latest() -> UIImage? {
    lock.lock(); defer { lock.unlock() }
    return image
  }

  func clear() {
    lock.lock(); image = nil; lock.unlock()
  }
}

/// Everything about the glasses: registration with Meta AI, the device session
/// and the camera stream. Keeps the most recent frame so we can send it to Claude.
@MainActor
final class GlassesManager: ObservableObject {
  @Published var registrationState: RegistrationState
  @Published var hasActiveDevice = false
  @Published var sessionState: DeviceSessionState = .idle
  @Published var streamState: StreamState = .stopped
  @Published var preview: UIImage?
  @Published var errorMessage: String?

  let frames = FrameStore()

  private let wearables: WearablesInterface
  private let selector: AutoDeviceSelector
  private var session: DeviceSession?
  private var camera: MWDATCamera.Camera?
  private let sessionTokens = ListenerTokenBag()
  private let streamTokens = ListenerTokenBag()
  private var lastPreviewUpdate = Date.distantPast

  /// Called after the camera is added but before the stream starts.
  /// Meta's docs: the HFP microphone must be ready before the stream starts.
  var prepareAudioBeforeStream: (() async -> Void)?

  var isRegistered: Bool { registrationState == .registered }
  var isStreaming: Bool { streamState == .streaming }
  var isConnecting: Bool {
    sessionState == .starting || streamState == .starting || streamState == .waitingForDevice
  }

  init() {
    let wearables = Wearables.shared
    self.wearables = wearables
    self.selector = AutoDeviceSelector(wearables: wearables)
    self.registrationState = wearables.registrationState

    Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.registrationState = state
      }
    }
    Task { [weak self] in
      guard let selector = self?.selector else { return }
      for await deviceId in selector.activeDeviceStream() {
        self?.hasActiveDevice = deviceId != nil
      }
    }
  }

  // MARK: Registration

  func register() {
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        report("Не удалось подключить очки: \(error.localizedDescription)")
      }
    }
  }

  func unregister() {
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        report("Не удалось отключить: \(error.localizedDescription)")
      }
    }
  }

  /// Meta AI sends us back here after registration or a permission request.
  func handle(url: URL) {
    guard
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      items.contains(where: { $0.name == "metaWearablesAction" })
    else { return }
    Task {
      do {
        _ = try await Wearables.shared.handleUrl(url)
      } catch {
        report("Ошибка ответа от Meta AI: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Start / stop

  /// Starts the session and the camera stream. Safe to call repeatedly.
  func start() async {
    guard isRegistered else {
      report("Сначала подключи очки (кнопка «Подключить очки»).")
      return
    }

    // 1. Camera permission (opens Meta AI the first time).
    do {
      var status = try await wearables.checkPermissionStatus(.camera)
      if status != .granted {
        status = try await wearables.requestPermission(.camera)
      }
      guard status == .granted else {
        report("Нет разрешения на камеру очков. Разреши его в приложении Meta AI.")
        return
      }
    } catch {
      report("Не удалось получить доступ к камере: \(error.localizedDescription)")
      return
    }

    // 2. Device session.
    if session == nil {
      do {
        let newSession = try wearables.createSession(deviceSelector: selector)
        session = newSession
        newSession.statePublisher.listen { [weak self] state in
          Task { @MainActor in self?.sessionChanged(state) }
        }.store(in: sessionTokens)
        newSession.errorPublisher.listen { [weak self] error in
          Task { @MainActor in self?.report("Сессия: \(error.localizedDescription)") }
        }.store(in: sessionTokens)
        sessionState = .starting
        try newSession.start()
      } catch {
        session = nil
        sessionTokens.clear()
        sessionState = .idle
        report("Не удалось начать сессию: \(error.localizedDescription)")
        return
      }
    }

    // 3. Wait for the session to be live (up to 20 s).
    for _ in 0..<80 {
      if session?.state == .started { break }
      if session == nil { return }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    guard let liveSession = session, liveSession.state == .started else {
      report("Очки не ответили. Надень их, открой дужки и попробуй ещё раз.")
      return
    }

    // 4. Camera stream. Low resolution and few frames per second give
    //    sharper pictures over Bluetooth and save battery.
    guard camera == nil else { return }
    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.medium,
      frameRate: 7
    )
    do {
      guard let newCamera = try liveSession.addCamera(config: config) else {
        report("Не удалось включить камеру очков.")
        return
      }
      camera = newCamera
      listen(to: newCamera.stream)
      // HFP microphone must be ready before the stream starts.
      await prepareAudioBeforeStream?()
      streamState = .starting
      newCamera.stream.start()
    } catch {
      camera = nil
      report("Камера: \(error.localizedDescription)")
    }
  }

  func stop() {
    camera?.stop()
    session?.stop()
  }

  // MARK: Listeners

  private func listen(to stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.streamChanged(state) }
    }.store(in: streamTokens)

    let frames = self.frames
    stream.videoFramePublisher.listen { [weak self] frame in
      guard let image = frame.makeUIImage() else { return }
      frames.set(image)
      Task { @MainActor in self?.updatePreview(image) }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.report("Камера: \(error.localizedDescription)") }
    }.store(in: streamTokens)
  }

  private func updatePreview(_ image: UIImage) {
    // Refresh the on-screen preview at most twice a second.
    let now = Date()
    guard now.timeIntervalSince(lastPreviewUpdate) > 0.5 else { return }
    lastPreviewUpdate = now
    preview = image
  }

  private func sessionChanged(_ state: DeviceSessionState) {
    sessionState = state
    if state == .stopped {
      sessionTokens.clear()
      session = nil
      tearDownStream()
    }
  }

  private func streamChanged(_ state: StreamState) {
    streamState = state
    if state == .stopped { tearDownStream() }
  }

  private func tearDownStream() {
    streamTokens.clear()
    camera?.stop()
    camera = nil
    streamState = .stopped
    frames.clear()
    preview = nil
  }

  private func report(_ message: String) {
    errorMessage = message
  }
}
