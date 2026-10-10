import Foundation
import Testing

@testable import AgentBurn

@Test func includesStandardCodexLogsAlongsideHarnessSpecificHome() {
  #expect(
    SourcePaths.codexHomes(home: "/Users/test", inherited: "/Users/test/.codex-video")
      == "/Users/test/.codex,/Users/test/.codex-video")
}

@Test func avoidsCountingTheSameCodexHomeTwice() {
  #expect(
    SourcePaths.codexHomes(
      home: "/Users/test", inherited: "/Users/test/.codex/, /Users/test/.codex")
      == "/Users/test/.codex")
}

@Test func claudeProfilesKeepTheFoldersAsLaunched() {
  #expect(SourcePaths.claudeConfigDirs(inherited: nil) == "")
  #expect(
    SourcePaths.claudeConfigDirs(
      inherited: "/Users/test/.claude-work/, /Users/test/.claude-personal,/Users/test/.claude-work")
      == "/Users/test/.claude-work,/Users/test/.claude-personal")
}

@Test func claudeProfilesReachTheCLIOnlyWhenConfigured() {
  #expect(
    CLIClient.environment(codexHomes: "/codex", claudeConfigDirs: "")
      == ["CODEX_HOME": "/codex"])
  #expect(
    CLIClient.environment(codexHomes: "/codex", claudeConfigDirs: "/a,/b")
      == ["CODEX_HOME": "/codex", "CLAUDE_CONFIG_DIR": "/a,/b"])
}

@Test func collectorConfigWithoutClaudeProfilesKeepsItsSource() throws {
  let old = Data(#"{"customPath":"","codexHomes":"/codex"}"#.utf8)
  let decoded = try JSONDecoder().decode(QuotaCollectorConfig.self, from: old)
  #expect(decoded.claudeConfigDirs == nil)
  #expect(decoded.source == "|/codex")
  let profiled = QuotaCollectorConfig(customPath: "", codexHomes: "/codex", claudeConfigDirs: "/a")
  #expect(profiled.source == "|/codex|claude=/a")
}

@Test func allTimeDoesNotPassAnUnsupportedRangeToCLI() {
  #expect(UsagePeriod.all.arguments == ["summary", "--value"])
  #expect(UsagePeriod.mtd.arguments == ["summary", "mtd", "--value"])
  #expect(UsagePeriod.rtd.arguments == ["summary", "--value"])
}

@Test func reportCachePreservesHistoricalDailyUsage() throws {
  let report = try JSONDecoder().decode(
    SummaryReport.self,
    from: Data(
      """
      {"totals":{"totalCost":1234,"totalTokens":1000},"agents":[],"models":[],"daily":[{"date":"2025-01-01","cost":1234}]}
      """.utf8))
  let cache = ReportCache(
    source: "source",
    summaries: ["all": CachedReport(report: report, date: Date(timeIntervalSince1970: 10))],
    harnesses: [:])
  let restored = try JSONDecoder().decode(ReportCache.self, from: JSONEncoder().encode(cache))
  #expect(restored.summaries["all"]?.report.daily?.first?.date == "2025-01-01")
  #expect(restored.summaries["all"]?.report.totals.totalCost == 1234)
}

@Test func retainsHarnessNavigationAcrossCachedDateRanges() throws {
  let old = try JSONDecoder().decode(
    SummaryReport.self,
    from: Data(
      """
      {"totals":{"totalCost":10,"totalTokens":100},"agents":[{"agent":"opencode","totalCost":10,"totalTokens":100}],"models":[]}
      """.utf8))
  let recent = try JSONDecoder().decode(
    SummaryReport.self,
    from: Data(
      """
      {"totals":{"totalCost":0,"totalTokens":0},"agents":[],"models":[]}
      """.utf8))
  let cache = ReportCache(
    source: "source",
    summaries: [
      "all": CachedReport(report: old, date: .now),
      "today": CachedReport(report: recent, date: .now),
    ], harnesses: [:])
  #expect(cache.agentNames == ["opencode"])
}
