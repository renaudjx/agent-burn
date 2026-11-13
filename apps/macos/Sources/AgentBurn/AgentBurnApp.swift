import SwiftUI

@main
enum AgentBurnMain {
  @MainActor static func main() async {
    if CommandLine.arguments.contains("--collect-quotas") {
      do { try await QuotaCollector.collect() } catch {
        FileHandle.standardError.write(
          Data("Quota collection failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    } else {
      AgentBurnApp.main()
    }
  }
}

struct AgentBurnApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store: UsageStore

  init() {
    let store = UsageStore()
    _store = State(initialValue: store)
    Task { await store.start() }
  }
  var body: some Scene {
    Window("Agent Burn", id: "overview") {
      DashboardView().environment(store)
    }
    .defaultSize(width: 1240, height: 820)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    .commands {
      UpdateCommands()
      UsageCommands(store: store)
    }
    MenuBarExtra {
      MenuPopover().environment(store)
    } label: {
      // TimelineView in a MenuBarExtra label can continuously invalidate the status item.
      MenuBarLabel(readings: store.menuBarReadings, text: store.menuBarText)
    }
    .menuBarExtraStyle(.window)
    Settings { SettingsView().environment(store) }
  }
}

struct UsageCommands: Commands {
  let store: UsageStore

  var body: some Commands {
    CommandMenu("Usage") {
      Button("Refresh") { Task { await store.refreshAll() } }
        .keyboardShortcut("r")
      Button("Check Live Usage Now") { Task { await store.refreshAll(hard: true) } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
  }
}

/// The status item: the logo, then each limit tinted green ahead of an even pace and
/// red behind it. Several readings stack in two rows so they stay narrow. The text is
/// drawn into an image, since the menu bar renders label text as a monochrome template.
struct MenuBarLabel: View {
  let readings: [MenuBarReading]
  let text: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 4) {
      Image(nsImage: AppLogo.menuBar)
        .resizable()
        .renderingMode(.original)
        .frame(width: 18, height: 18)
      Image(nsImage: rendered)
    }
    .accessibilityLabel("Agent Burn \(text)")
  }

  private var rendered: NSImage {
    let renderer = ImageRenderer(content: MenuBarValues(readings: readings, scheme: scheme))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = false
    return image
  }
}

private struct MenuBarValues: View {
  let readings: [MenuBarReading]
  let scheme: ColorScheme
  private var neutral: Color { scheme == .dark ? .white : .black }

  var body: some View {
    let stacked = readings.count > 1
    // Two rows fit the menu bar's height; more accounts add columns, read top to bottom.
    let rows =
      stacked
      ? (0..<2).map { row in stride(from: row, to: readings.count, by: 2).map { readings[$0] } }
      : [readings]
    VStack(alignment: .trailing, spacing: -1) {
      ForEach(rows.indices, id: \.self) { row in
        HStack(spacing: 4) {
          ForEach(rows[row].indices, id: \.self) { index in
            value(rows[row][index], size: stacked ? 9 : 13)
          }
        }
      }
    }
    .fixedSize()
    .environment(\.colorScheme, scheme)
  }

  private func value(_ reading: MenuBarReading, size: CGFloat) -> some View {
    let color: Color =
      switch reading.isBehind {
      case true?: Color(red: 1, green: 0.35, blue: 0.33)
      case false?: Color(red: 0.3, green: 0.85, blue: 0.45)
      case nil: neutral
      }
    return Text(reading.remaining.map { "\(Int($0))%" } ?? "–")
      .font(.system(size: size, weight: .semibold)).monospacedDigit()
      .foregroundStyle(color)
  }
}
