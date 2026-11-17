import MWDATCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var assistant: Assistant
  @State private var showSettings = false

  private var glasses: GlassesManager { assistant.glasses }
  private var voice: VoiceManager { assistant.voice }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          statusCard
          if glasses.isRegistered {
            cameraCard
            controls
          } else {
            connectCard
          }
          historyList
        }
        .padding()
      }
      .navigationTitle("Claude Очки")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
      }
      .sheet(isPresented: $showSettings) { SettingsView(assistant: assistant) }
      .alert("Что-то пошло не так", isPresented: errorBinding) {
        Button("OK") {
          glasses.errorMessage = nil
          voice.errorMessage = nil
        }
      } message: {
        Text(glasses.errorMessage ?? voice.errorMessage ?? "")
      }
      .onAppear {
        if assistant.apiKey.isEmpty { showSettings = true }
      }
    }
  }

  // MARK: Pieces

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      row("Очки", glasses.isRegistered ? "подключены к приложению" : "не подключены", glasses.isRegistered)
      row("Рядом и надеты", glasses.hasActiveDevice ? "да" : "нет", glasses.hasActiveDevice)
      row("Камера", glasses.isStreaming ? "работает" : streamText, glasses.isStreaming)
      row("Микрофон очков", voice.usingGlassesMic ? "да" : "нет (микрофон телефона)", voice.usingGlassesMic)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var streamText: String {
    switch glasses.streamState {
    case .starting: return "включается…"
    case .waitingForDevice: return "ждёт очки…"
    case .paused: return "на паузе (тапни по дужке)"
    case .stopping: return "выключается…"
    default: return "выключена"
    }
  }

  private func row(_ title: String, _ value: String, _ ok: Bool) -> some View {
    HStack {
      Circle().fill(ok ? Color.green : Color.orange).frame(width: 10, height: 10)
      Text(title).fontWeight(.semibold)
      Spacer()
      Text(value).foregroundStyle(.secondary).font(.subheadline)
    }
  }

  private var connectCard: some View {
    VStack(spacing: 12) {
      Text("Шаг 1. Подключи приложение к очкам. Откроется Meta AI — подтверди там и вернись сюда.")
        .multilineTextAlignment(.center)
      Button {
        glasses.register()
      } label: {
        Label(
          glasses.registrationState == .registering ? "Подключаю…" : "Подключить очки",
          systemImage: "eyeglasses"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding()
  }

  private var cameraCard: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.85))
      if let image = glasses.preview {
        Image(uiImage: image).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 16))
      } else if glasses.isConnecting {
        ProgressView("Включаю камеру очков…").tint(.white).foregroundStyle(.white)
      } else {
        Button {
          Task { await assistant.start() }
        } label: {
          Label("Запустить камеру и звук", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(height: 260)
  }

  private var controls: some View {
    VStack(spacing: 12) {
      Picker("Режим", selection: $assistant.mode) {
        ForEach(AssistantMode.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)

      if assistant.mode == .barber {
        Text("Смотри на зону, о которой спрашиваешь, 1–2 секунды, потом спрашивай: «Клод, где линия?», «Клод, есть ступеньки на затылке?»")
          .font(.caption).foregroundStyle(.secondary)
      }

      Toggle(isOn: $assistant.alwaysListening) {
        VStack(alignment: .leading) {
          Text("Слушать всегда").fontWeight(.semibold)
          Text("Говори «Клод, …» — и он ответит в очки").font(.caption).foregroundStyle(.secondary)
        }
      }

      Button {
        voice.askOnce()
      } label: {
        Label(buttonTitle, systemImage: voice.isListening ? "waveform" : "mic.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(assistant.isThinking)

      if voice.isSpeaking {
        Button("Замолчи") { voice.stopSpeaking() }.buttonStyle(.bordered)
      }

      if !voice.liveText.isEmpty && voice.isListening {
        Text("«\(voice.liveText)»").font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var buttonTitle: String {
    if assistant.isThinking { return "Claude думает…" }
    if voice.isListening && !assistant.alwaysListening { return "Слушаю…" }
    return "Спросить сейчас"
  }

  private var historyList: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(assistant.log) { item in
        HStack(alignment: .top, spacing: 10) {
          if let image = item.image {
            Image(uiImage: image).resizable().scaledToFill()
              .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(item.question).fontWeight(.semibold)
            Text(item.answer ?? "…").foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { glasses.errorMessage != nil || voice.errorMessage != nil },
      set: { if !$0 { glasses.errorMessage = nil; voice.errorMessage = nil } }
    )
  }
}

struct SettingsView: View {
  @ObservedObject var assistant: Assistant
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("sk-ant-…", text: $assistant.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Ключ API Claude")
        } footer: {
          Text("Получи на console.anthropic.com → API Keys. Хранится только на этом iPhone.")
        }

        Section("Модель") {
          Picker("Модель", selection: $assistant.model) {
            Text("Sonnet — умнее").tag("claude-sonnet-5-5")
            Text("Haiku — быстрее и дешевле").tag("claude-haiku-5-5")
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }

        Section {
          Toggle("Отправлять кадр с камеры", isOn: $assistant.sendPicture)
          Button("Новый разговор") { assistant.newConversation() }
        } footer: {
          Text("Каждый кадр — это платный запрос. Кадр отправляется только когда ты задаёшь вопрос.")
        }

        Section("Очки") {
          Button("Остановить камеру") { assistant.glasses.stop() }
          Button("Отключить очки от приложения", role: .destructive) {
            assistant.glasses.unregister()
          }
        }
      }
      .navigationTitle("Настройки")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
      }
    }
  }
}
