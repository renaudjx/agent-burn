import Foundation
import Testing

@testable import AgentBurn

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func weekly(used: Double, elapsed: Double) -> Forecast {
  Forecast(
    window: QuotaWindow(
      windowMinutes: 7 * 1440, usedPercent: used, elapsedPercent: elapsed,
      apiEquivalentSpent: 0),
    observedAt: now)
}

private func mix(
  opus: Double, opusAsSonnet: Double, sonnet: Double, efforts: [UsageMix.EffortMix] = []
) -> UsageMix {
  UsageMix(
    days: 7,
    models: [
      .init(
        model: "claude-opus-5-5", family: "opus", cost: opus, sonnetEquivalentCost: opusAsSonnet,
        outputTokens: 0, thinkingTokens: 0, turns: 10),
      .init(
        model: "claude-sonnet-5-5", family: "sonnet", cost: sonnet, sonnetEquivalentCost: sonnet,
        outputTokens: 0, thinkingTokens: 0, turns: 10),
    ],
    efforts: efforts)
}

@Test func overPaceWithMostlyOpusAdvisesSonnetWithTheNewProjection() {
  // 65% used at half the week projects 130%; Opus is 80% of spend at twice Sonnet's price.
  let advice = claudeAdvice(
    weekly: weekly(used: 65, elapsed: 50), session: nil, scoped: [],
    mix: mix(opus: 80, opusAsSonnet: 40, sonnet: 20), now: now)
  #expect(advice.map(\.kind) == [.switchToSonnet])
  // Half of the 40 saved out of 100 spent: 130 × 0.8 = 104.
  #expect(abs(advice[0].impact - 26) < 0.001)
  #expect(advice[0].detail.contains("130%") && advice[0].detail.contains("104%"))
}

@Test func overPaceWithHighEffortThinkingAdvisesMediumEffort() {
  let efforts: [UsageMix.EffortMix] = [
    .init(effort: "max", cost: 60, thinkingCost: 40, turns: 5),
    .init(effort: "low", cost: 40, thinkingCost: 1, turns: 50),
  ]
  let advice = claudeAdvice(
    weekly: weekly(used: 60, elapsed: 50), session: nil, scoped: [],
    mix: mix(opus: 10, opusAsSonnet: 5, sonnet: 90, efforts: efforts), now: now)
  #expect(advice.map(\.kind) == [.lowerEffort])
  // 120 × (1 − 0.5 × 40/100) = 96.
  #expect(advice[0].detail.contains("96%"))
}

@Test func aScopedLimitOnPaceToRunOutIsFlaggedWhileTheWeekIsFine() {
  let reset = now.addingTimeInterval(3.5 * 86_400)
  let fable = ClaudeScopedLimit(
    name: "Fable", usedPercent: 70, resetsAtMs: reset.timeIntervalSince1970 * 1000)
  let advice = claudeAdvice(
    weekly: weekly(used: 30, elapsed: 50), session: nil, scoped: [fable], mix: nil, now: now)
  #expect(advice.map(\.kind) == [.leaveScopedModel])
  #expect(advice[0].headline == "Leave Fable before its cap.")
}

@Test func roomToSpareSuggestsHeavierWorkOnlyWithDaysLeft() {
  let light = mix(opus: 5, opusAsSonnet: 2, sonnet: 95)
  let early = claudeAdvice(
    weekly: weekly(used: 20, elapsed: 50), session: nil, scoped: [], mix: light, now: now)
  #expect(early.map(\.kind) == [.headroom])
  let lastDay = claudeAdvice(
    weekly: weekly(used: 20, elapsed: 90), session: nil, scoped: [], mix: light, now: now)
  #expect(lastDay.isEmpty)
}

@Test func tooEarlyInTheWindowGivesNoAdvice() {
  let advice = claudeAdvice(
    weekly: weekly(used: 9, elapsed: 5), session: nil, scoped: [],
    mix: mix(opus: 80, opusAsSonnet: 40, sonnet: 20), now: now)
  #expect(advice.isEmpty)
}

@Test func harnessReportDecodesTheUsageMix() throws {
  let json = """
    {"agent":"claude","plan":null,"liveLimits":true,"window":null,"apiEquivalentPerMonth":0,
     "daily":[],"topModels":[],"pricePerMonth":null,"economics":null,"estimate":null,
     "spendMix":null,"weeklyTrend":null,"imageGenerations":null,
     "usageMix":{"days":7,"models":[{"model":"claude-opus-5-5","family":"opus","cost":3,
       "sonnetEquivalentCost":1.5,"outputTokens":10,"thinkingTokens":4,"turns":2}],
       "efforts":[{"effort":"low","cost":3,"thinkingCost":0.1,"turns":2}]}}
    """
  let report = try JSONDecoder().decode(HarnessReport.self, from: Data(json.utf8))
  #expect(report.usageMix?.premiumCost == 3)
  #expect(report.usageMix?.efforts.first?.effort == "low")
}
