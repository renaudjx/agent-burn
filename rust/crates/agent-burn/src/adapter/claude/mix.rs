//! How the active Claude Code profile spent the last few days, by model and by
//! effort level, so the app can tell which change would move its limits most.
//!
//! Only the profile whose limits are shown is read: usage merged from several
//! profiles would credit one account with another's habits.

use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    CacheCreationRaw, PricingMap, Speed, TimestampMs, TokenUsageRaw, calculate_cost_for_usage,
    cli::CostMode, fast::byte_lines, parse_ts_timestamp, utc_now,
};

use super::{paths::collect_usage_files, profile::Profile};

/// Priced when no Sonnet turn is in the window to name a newer one.
const FALLBACK_SONNET: &str = "claude-sonnet-4-5";

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Family {
    Fable,
    Opus,
    Sonnet,
    Haiku,
    Other,
}

impl Family {
    fn name(self) -> &'static str {
        match self {
            Family::Fable => "fable",
            Family::Opus => "opus",
            Family::Sonnet => "sonnet",
            Family::Haiku => "haiku",
            Family::Other => "other",
        }
    }
}

pub(crate) fn model_family(model: &str) -> Family {
    let model = model.to_ascii_lowercase();
    [
        ("fable", Family::Fable),
        ("opus", Family::Opus),
        ("sonnet", Family::Sonnet),
        ("haiku", Family::Haiku),
    ]
    .into_iter()
    .find(|(marker, _)| model.contains(marker))
    .map_or(Family::Other, |(_, family)| family)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Line {
    message: Message,
    request_id: Option<String>,
    per_turn_effort: Option<String>,
    effort: Option<String>,
}

#[derive(Deserialize)]
struct Message {
    usage: Usage,
    model: Option<String>,
    id: Option<String>,
}

/// The counts `TokenUsageRaw` reads, plus the thinking share of the output.
#[derive(Deserialize)]
struct Usage {
    input_tokens: u64,
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    speed: Option<Speed>,
    #[serde(default)]
    cache_creation: Option<CacheCreationRaw>,
    #[serde(default)]
    output_tokens_details: Option<OutputDetails>,
}

impl Usage {
    fn raw(&self) -> TokenUsageRaw {
        TokenUsageRaw {
            input_tokens: self.input_tokens,
            output_tokens: self.output_tokens,
            cache_creation_input_tokens: self.cache_creation_input_tokens,
            cache_read_input_tokens: self.cache_read_input_tokens,
            speed: self.speed,
            cache_creation: self.cache_creation,
        }
    }

    fn thinking_tokens(&self) -> u64 {
        self.output_tokens_details
            .map_or(0, |details| details.thinking_tokens)
            .min(self.output_tokens)
    }
}

#[derive(Deserialize, Clone, Copy)]
struct OutputDetails {
    #[serde(default)]
    thinking_tokens: u64,
}

/// One priced assistant turn.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Turn {
    pub(crate) model: String,
    pub(crate) effort: String,
    pub(crate) cost: f64,
    pub(crate) sonnet_cost: f64,
    pub(crate) thinking_cost: f64,
    pub(crate) output_tokens: u64,
    pub(crate) thinking_tokens: u64,
}

#[derive(Default, Debug, PartialEq)]
struct Sum {
    cost: f64,
    sonnet_cost: f64,
    thinking_cost: f64,
    output_tokens: u64,
    thinking_tokens: u64,
    turns: u64,
}

impl Sum {
    fn add(&mut self, turn: &Turn) {
        self.cost += turn.cost;
        self.sonnet_cost += turn.sonnet_cost;
        self.thinking_cost += turn.thinking_cost;
        self.output_tokens += turn.output_tokens;
        self.thinking_tokens += turn.thinking_tokens;
        self.turns += 1;
    }
}

/// The active profile's usage lines from the window, deduplicated, not yet priced.
pub(crate) struct RecentLines {
    days: i64,
    lines: Vec<Line>,
}

/// Reads the active profile's recent turns. Pricing is left to `usage_mix`, so
/// this file work can run beside the report while the price tables load.
pub(crate) fn recent_lines(days: i64) -> Option<RecentLines> {
    let profile = Profile::current()?;
    Some(RecentLines {
        days,
        lines: profile_lines(profile.dir(), days),
    })
}

/// The `usageMix` object of `harness claude --json`, or `None` without any turn.
pub(crate) fn usage_mix(recent: RecentLines, pricing: &PricingMap) -> Option<Value> {
    let sonnet = newest_sonnet(
        recent
            .lines
            .iter()
            .map(|line| line.message.model.as_deref()),
    );
    let turns: Vec<Turn> = recent
        .lines
        .into_iter()
        .filter_map(|line| price_turn(line, &sonnet, pricing))
        .collect();
    (!turns.is_empty()).then(|| mix_to_json(recent.days, &turns))
}

fn profile_lines(dir: &Path, days: i64) -> Vec<Line> {
    let mut files: Vec<PathBuf> = Vec::new();
    collect_usage_files(&dir.join("projects"), &mut files);
    // Older files cannot hold a turn from the window; skipping them keeps this cheap.
    let modified_after = SystemTime::now() - Duration::from_secs(days.max(0) as u64 * 86_400);
    files.retain(|file| {
        fs::metadata(file)
            .and_then(|meta| meta.modified())
            .is_ok_and(|modified| modified >= modified_after)
    });
    let start = utc_now()
        .checked_sub_millis(days * crate::MILLIS_PER_DAY)
        .unwrap_or_else(utc_now);
    let mut lines = Vec::new();
    for file in files {
        let Ok(content) = fs::read(&file) else {
            continue;
        };
        lines.extend(byte_lines(&content).filter_map(|line| parse_line(line, start)));
    }
    let mut seen = HashSet::new();
    lines.retain(|line: &Line| {
        let key = (line.message.id.clone(), line.request_id.clone());
        key == (None, None) || seen.insert(key)
    });
    lines
}

/// A usage line from `start` on. The timestamp is read before the full parse,
/// since a long session file is mostly older turns.
fn parse_line(line: &[u8], start: TimestampMs) -> Option<Line> {
    memchr::memmem::find(line, br#""usage":{"#)?;
    let marker = br#""timestamp":""#;
    let from = memchr::memmem::find(line, marker)? + marker.len();
    let to = memchr::memchr(b'"', &line[from..])? + from;
    let stamp = parse_ts_timestamp(std::str::from_utf8(&line[from..to]).ok()?)?;
    if stamp < start {
        return None;
    }
    serde_json::from_slice(line).ok()
}

/// The most recent Sonnet in the window, compared by name, which carries the version.
fn newest_sonnet<'a>(models: impl Iterator<Item = Option<&'a str>>) -> String {
    models
        .flatten()
        .filter(|model| model_family(model) == Family::Sonnet)
        .max()
        .unwrap_or(FALLBACK_SONNET)
        .to_string()
}

fn price_turn(line: Line, sonnet: &str, pricing: &PricingMap) -> Option<Turn> {
    let model = line.message.model?;
    if model == "<synthetic>" {
        return None;
    }
    let thinking = line.message.usage.thinking_tokens();
    let usage = line.message.usage.raw();
    let price = |name: &str| {
        calculate_cost_for_usage(Some(name), usage, None, CostMode::Calculate, Some(pricing))
    };
    let cost = price(&model);
    let sonnet_cost = if model_family(&model) == Family::Sonnet {
        cost
    } else {
        price(sonnet)
    };
    let thinking_cost = pricing
        .find(&model)
        .map_or(0.0, |found| found.output * thinking as f64);
    Some(Turn {
        effort: line
            .per_turn_effort
            .or(line.effort)
            .unwrap_or_else(|| "unknown".to_string()),
        model,
        cost,
        sonnet_cost,
        thinking_cost,
        output_tokens: usage.output_tokens,
        thinking_tokens: thinking,
    })
}

pub(crate) fn mix_to_json(days: i64, turns: &[Turn]) -> Value {
    let mut models: BTreeMap<&str, Sum> = BTreeMap::new();
    let mut efforts: BTreeMap<&str, Sum> = BTreeMap::new();
    for turn in turns {
        models.entry(&turn.model).or_default().add(turn);
        efforts.entry(&turn.effort).or_default().add(turn);
    }
    let mut models: Vec<_> = models.into_iter().collect();
    models.sort_by(|left, right| right.1.cost.total_cmp(&left.1.cost));
    let mut efforts: Vec<_> = efforts.into_iter().collect();
    efforts.sort_by(|left, right| right.1.cost.total_cmp(&left.1.cost));
    json!({
        "days": days,
        "models": models.iter().map(|(model, sum)| json!({
            "model": model,
            "family": model_family(model).name(),
            "cost": sum.cost,
            "sonnetEquivalentCost": sum.sonnet_cost,
            "outputTokens": sum.output_tokens,
            "thinkingTokens": sum.thinking_tokens,
            "turns": sum.turns,
        })).collect::<Vec<_>>(),
        "efforts": efforts.iter().map(|(effort, sum)| json!({
            "effort": effort,
            "cost": sum.cost,
            "thinkingCost": sum.thinking_cost,
            "turns": sum.turns,
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn families_follow_the_model_name() {
        assert_eq!(model_family("claude-opus-4-8"), Family::Opus);
        assert_eq!(model_family("claude-fable-5-1"), Family::Fable);
        assert_eq!(model_family("claude-sonnet-5-5"), Family::Sonnet);
        assert_eq!(model_family("claude-haiku-4-5-20251001"), Family::Haiku);
        assert_eq!(model_family("gpt-5"), Family::Other);
    }

    #[test]
    fn a_line_yields_its_effort_and_thinking_tokens() {
        let line = br#"{"timestamp":"2026-10-11T22:32:23.969Z","requestId":"r1","effort":"low","perTurnEffort":"max","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":1198,"output_tokens_details":{"thinking_tokens":124}}}}"#;
        let start = parse_ts_timestamp("2026-10-11T00:00:00Z").unwrap();
        let parsed = parse_line(line, start).expect("usage line");
        assert_eq!(parsed.message.usage.thinking_tokens(), 124);
        assert_eq!(parsed.per_turn_effort.as_deref(), Some("max"));
        assert_eq!(parsed.message.model.as_deref(), Some("claude-opus-5-5"));
        assert!(parse_line(br#"{"type":"user","message":{"content":"hi"}}"#, start).is_none());
        let later = parse_ts_timestamp("2026-10-12T00:00:00Z").unwrap();
        assert!(
            parse_line(line, later).is_none(),
            "turns before the window are skipped"
        );
    }

    #[test]
    fn the_newest_sonnet_in_the_window_is_the_reference() {
        let models = [
            Some("claude-sonnet-4-5"),
            Some("claude-opus-5-5"),
            Some("claude-sonnet-5-5"),
            None,
        ];
        assert_eq!(newest_sonnet(models.into_iter()), "claude-sonnet-5-5");
        assert_eq!(
            newest_sonnet([Some("claude-opus-4-8")].into_iter()),
            FALLBACK_SONNET
        );
    }

    #[test]
    fn turns_add_up_by_model_and_effort() {
        let turn = |model: &str, effort: &str, cost: f64| Turn {
            model: model.to_string(),
            effort: effort.to_string(),
            cost,
            sonnet_cost: cost / 2.0,
            thinking_cost: cost / 4.0,
            output_tokens: 10,
            thinking_tokens: 4,
        };
        let mix = mix_to_json(
            7,
            &[
                turn("claude-opus-5-5", "max", 8.0),
                turn("claude-opus-5-5", "low", 2.0),
                turn("claude-sonnet-5-5", "low", 1.0),
            ],
        );
        assert_eq!(mix["days"], 7);
        assert_eq!(mix["models"][0]["model"], "claude-opus-5-5");
        assert_eq!(mix["models"][0]["family"], "opus");
        assert_eq!(mix["models"][0]["cost"], 10.0);
        assert_eq!(mix["models"][0]["sonnetEquivalentCost"], 5.0);
        assert_eq!(mix["models"][0]["turns"], 2);
        assert_eq!(mix["efforts"][0]["effort"], "max");
        assert_eq!(mix["efforts"][0]["thinkingCost"], 2.0);
        assert_eq!(mix["efforts"][1]["effort"], "low");
        assert_eq!(mix["efforts"][1]["cost"], 3.0);
    }
}
