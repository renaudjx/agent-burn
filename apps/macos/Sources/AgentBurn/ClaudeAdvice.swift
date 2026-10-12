import SwiftUI

/// The active Claude Code profile's recent spend by model and effort, from `harness claude`.
struct UsageMix: Codable, Sendable {
  let days: Int
  let models: [ModelMix]
  let efforts: [EffortMix]

  struct ModelMix: Codable, Sendable {
    let model: String
    let family: String
    let cost: Double
    /// The same tokens priced at the newest Sonnet in the window.
    let sonnetEquivalentCost: Double
    let outputTokens: UInt64
    let thinkingTokens: UInt64
    let turns: Int
  }

  struct EffortMix: Codable, Sendable {
    let effort: String
    let cost: Double
    let thinkingCost: Double
    let turns: Int
  }

  var totalCost: Double { models.reduce(0) { $0 + $1.cost } }
  /// Opus and Fable, the models a switch to Sonnet would save on.
  var premium: [ModelMix] { models.filter { ["opus", "fable"].contains($0.family) } }
  var premiumCost: Double { premium.reduce(0) { $0 + $1.cost } }
  var highEfforts: [EffortMix] { efforts.filter { ["high", "xhigh", "max"].contains($0.effort) } }
}

struct ClaudeAdvice: Equatable, Identifiable {
  enum Kind: String { case switchToSonnet, lowerEffort, leaveScopedModel, headroom, lean }
  let kind: Kind
  let headline: String
  let detail: String
  /// Projection points the change would save, or the room left; orders the advice.
  let impact: Double
  var id: String { kind.rawValue + headline }
}

/// A projection taken this early in a window says little about where it ends.
private let minimumElapsed = 0.1
/// Share of the premium turns the switch advice assumes move to Sonnet.
private let switchedShare = 0.5
/// Smallest projection change, in points, worth suggesting a switch for.
private let minimumImpact = 3.0
/// Share of high-effort thinking the effort advice assumes medium effort saves.
private let thinkingSaved = 0.5

/// Model and effort changes for the active profile, most useful first, at most three.
/// The estimates assume Anthropic's limits weigh a model like its API price, which it
/// does not publish.
func claudeAdvice(
  weekly: Forecast?, session: Forecast?, scoped: [ClaudeScopedLimit], mix: UsageMix?, now: Date
) -> [ClaudeAdvice] {
  let weeklyProjection = weekly.flatMap(projection)
  let sessionProjection = session.flatMap { forecast in
    forecast.remaining <= 0 ? max(100, forecast.projectedUse ?? 100) : projection(forecast)
  }
  let pressure = [weeklyProjection, sessionProjection].compactMap { $0 }.filter { $0 >= 100 }
    .max()
  var advice: [ClaudeAdvice] = []

  if let pressure, let mix, mix.totalCost > 0 {
    let limit = (weeklyProjection ?? 0) >= 100 ? "weekly" : "5-hour"
    let total = mix.totalCost
    let premiumShare = mix.premiumCost / total
    let premiumSonnet = mix.premium.reduce(0) { $0 + $1.sonnetEquivalentCost }
    // With Opus or Fable a large share, half of it is routine work; a small share moves whole.
    let moved = premiumShare >= 0.3 ? switchedShare : 1
    let switchAfter = pressure * (1 - moved * max(0, mix.premiumCost - premiumSonnet) / total)
    if premiumShare >= 0.1, pressure - switchAfter >= minimumImpact {
      let names = Set(mix.premium.map { $0.family.capitalized }).sorted().joined(separator: "/")
      let portion = moved < 1 ? "half of those turns" : "those turns"
      advice.append(
        ClaudeAdvice(
          kind: .switchToSonnet, headline: "Move routine work to Sonnet.",
          detail:
            "\(names) made \(percent(premiumShare * 100)) of this profile's spend over \(mix.days) days. "
            + "Running \(portion) on Sonnet would bring the \(limit) projection from "
            + "\(percent(pressure)) to about \(percent(switchAfter)).",
          impact: pressure - switchAfter))
    }
    let highThinking = mix.highEfforts.reduce(0) { $0 + $1.thinkingCost }
    if highThinking / total >= 0.2 {
      let after = pressure * (1 - thinkingSaved * highThinking / total)
      let levels = mix.highEfforts.map(\.effort).joined(separator: "/")
      advice.append(
        ClaudeAdvice(
          kind: .lowerEffort, headline: "Lower the default effort to medium.",
          detail:
            "Thinking at \(levels) effort was \(percent(highThinking / total * 100)) of the spend. "
            + "Keeping it for hard problems would bring the \(limit) projection to about "
            + "\(percent(after)).",
          impact: pressure - after))
    }
  }

  if let pressure, advice.isEmpty, let mix, mix.totalCost > 0 {
    let lean = mix.models.filter { $0.family != "opus" && $0.family != "fable" }
      .reduce(0) { $0 + $1.cost } / mix.totalCost
    advice.append(
      ClaudeAdvice(
        kind: .lean, headline: "Model and effort are already lean.",
        detail:
          "\(percent(lean * 100)) of the last \(mix.days) days' spend ran outside Opus and Fable, "
          + "with little high-effort thinking. At \(percent(pressure)) projected, only a slower pace "
          + "keeps the limit until reset.",
        impact: 0))
  }

  if (weeklyProjection ?? 0) < 100 {
    for limit in scoped {
      guard let used = limit.usedPercent, let reset = claudeDate(limit.resetsAtMs),
        let projected = scopedProjection(used: used, reset: reset, now: now), projected >= 100
      else { continue }
      let resetText = reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
      advice.append(
        ClaudeAdvice(
          kind: .leaveScopedModel, headline: "Leave \(limit.name) before its cap.",
          detail:
            "\(limit.name) is on pace for \(percent(projected)) of its own weekly limit before "
            + "\(resetText). Switch to another model for the rest of the week.",
          impact: projected - 100))
    }
  }

  if let weekly, let weeklyProjection, weeklyProjection <= 60, pressure == nil,
    weekly.reset.timeIntervalSince(now) >= 2 * 86_400, let mix, mix.totalCost > 0
  {
    let lowCost = mix.efforts.filter { ["low", "medium"].contains($0.effort) }
      .reduce(0) { $0 + $1.cost }
    if mix.premiumCost / mix.totalCost < 0.2 || lowCost / mix.totalCost > 0.8 {
      advice.append(
        ClaudeAdvice(
          kind: .headroom, headline: "You have room for heavier work.",
          detail:
            "The weekly limit is on pace for \(percent(weeklyProjection)) at reset. "
            + "Opus or a higher effort on hard tasks fits in the \(percent(100 - weeklyProjection)) left.",
          impact: 0))
    }
  }

  return Array(advice.sorted { $0.impact > $1.impact }.prefix(3))
}

private func projection(_ forecast: Forecast) -> Double? {
  forecast.elapsed >= minimumElapsed ? forecast.projectedUse : nil
}

/// Model-scoped limits only report use and reset; their window is a week.
private func scopedProjection(used: Double, reset: Date, now: Date) -> Double? {
  let week = 7 * 86_400.0
  let elapsed = 1 - reset.timeIntervalSince(now) / week
  guard elapsed >= minimumElapsed, elapsed <= 1, used > 0 else { return nil }
  return used / elapsed
}

private func percent(_ value: Double) -> String {
  value.formatted(.number.precision(.fractionLength(0))) + "%"
}

/// Model and effort changes suggested from the active profile's trend.
struct ClaudeAdviceView: View {
  let advice: [ClaudeAdvice]
  private var tint: Color { BurnTheme.color(for: "claude") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CardHeader(title: "Advice", symbol: "lightbulb", tint: tint)
      ForEach(advice) { item in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: symbol(item.kind))
            .font(.system(size: 13)).foregroundStyle(
              item.kind == .headroom ? BurnTheme.ahead : tint)
          (Text(item.headline).fontWeight(.semibold).foregroundStyle(BurnTheme.ink)
            + Text(" " + item.detail).foregroundStyle(BurnTheme.muted))
            .font(.system(size: 13)).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(
        "Estimates assume each model weighs on the limits like its API price; Anthropic does not publish the exact weights."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .burnCard(padding: 18)
  }

  private func symbol(_ kind: ClaudeAdvice.Kind) -> String {
    switch kind {
    case .switchToSonnet: "arrow.triangle.swap"
    case .lowerEffort: "brain"
    case .leaveScopedModel: "exclamationmark.triangle"
    case .headroom: "arrow.up.right"
    case .lean: "gauge.with.dots.needle.67percent"
    }
  }
}
