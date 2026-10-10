import Foundation

struct SummaryQuery: Equatable {
  let period: UsagePeriod
  let agent: String?
  var cacheKey: String { period.rawValue + (agent.map { ":" + $0 } ?? "") }
  var arguments: [String] { period.arguments + (agent.map { ["--agents", $0] } ?? []) }
}

enum SourcePaths {
  static func codexHomes(home: String, inherited: String?) -> String {
    let candidates = [home + "/.codex"] + (inherited ?? "").split(separator: ",").map(String.init)
    var paths: [String] = []
    for candidate in candidates {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let path = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        .standardizedFileURL.resolvingSymlinksInPath().path
      if !paths.contains(path) { paths.append(path) }
    }
    return paths.joined(separator: ",")
  }

  /// Claude Code profile folders. Unlike Codex, nothing is added to the list and symlinks are not
  /// resolved: Claude Code names a profile's Keychain item after the folder exactly as launched.
  static func claudeConfigDirs(inherited: String?) -> String {
    var paths: [String] = []
    for candidate in (inherited ?? "").split(separator: ",") {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let path = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        .standardizedFileURL.path
      if !paths.contains(path) { paths.append(path) }
    }
    return paths.joined(separator: ",")
  }
}

struct CachedReport<Report: Codable>: Codable {
  let report: Report
  let date: Date
}

struct ReportCache: Codable {
  let source: String
  var summaries: [String: CachedReport<SummaryReport>]
  var harnesses: [String: CachedReport<HarnessReport>]
  var agentNames: [String] {
    Set(summaries.values.flatMap { $0.report.agents.map(\.agent) }).sorted()
  }
}

/// One Claude Code profile folder from the comma-separated "Claude config dirs" setting.
struct ClaudeProfile: Identifiable, Equatable {
  let path: String
  var id: String { path }

  /// The account's e-mail when Claude Code recorded it in the profile, else the folder name.
  var name: String {
    let state = URL(fileURLWithPath: path).appendingPathComponent(".claude.json")
    if let data = try? Data(contentsOf: state),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let account = json["oauthAccount"] as? [String: Any],
      let email = account["emailAddress"] as? String, !email.isEmpty
    {
      return email
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  /// Folders as the user typed them, tildes expanded, empty entries and repeats dropped.
  static func list(_ configured: String) -> [ClaudeProfile] {
    var seen: [String] = []
    for entry in configured.split(separator: ",") {
      let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let path = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        .standardizedFileURL.path
      if !seen.contains(path) { seen.append(path) }
    }
    return seen.map(ClaudeProfile.init(path:))
  }

  /// The list with `active` moved first; an unknown or empty `active` leaves the order alone.
  static func ordered(_ configured: String, active: String) -> String {
    let paths = list(configured).map(\.path)
    guard paths.contains(active) else { return configured }
    return ([active] + paths.filter { $0 != active }).joined(separator: ",")
  }
}
