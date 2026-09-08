use std::collections::HashMap;

use chrono::{FixedOffset, NaiveDate};
use tokens_collector::aggregate_messages;
use tokens_core::pricing::{ModelPricing, PricingService};
use tokens_core::{parse_bucket_timezone, BucketTimezone, CostSource, TokenBreakdown, UnifiedMessage};

fn shanghai() -> BucketTimezone {
    parse_bucket_timezone("Asia/Shanghai").expect("known IANA timezone")
}

/// Millis for a wall-clock time in Asia/Shanghai (fixed +08:00, no DST).
fn ts(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
    let offset = FixedOffset::east_opt(8 * 3600).expect("offset");
    NaiveDate::from_ymd_opt(year, month, day)
        .expect("date")
        .and_hms_opt(hour, minute, 0)
        .expect("time")
        .and_local_timezone(offset)
        .single()
        .expect("local time")
        .timestamp_millis()
}

fn tokens(input: i64, output: i64, cache_read: i64, cache_write: i64, reasoning: i64) -> TokenBreakdown {
    TokenBreakdown {
        input,
        output,
        cache_read,
        cache_write,
        reasoning,
    }
}

fn message(
    client: &str,
    model: &str,
    provider: &str,
    timestamp: i64,
    breakdown: TokenBreakdown,
    cost: f64,
) -> UnifiedMessage {
    UnifiedMessage::new(client, model, provider, "session-1", timestamp, breakdown, cost)
}

/// input $1/1M, output $2/1M, cache-read $0.1/1M, no cache-write rate.
/// 80 in + 50 out + 20 read + 10 reasoning prices at exactly 0.000202.
fn fixture_pricing() -> PricingService {
    PricingService::new(
        HashMap::from([(
            "fixture-model".to_string(),
            ModelPricing {
                input_cost_per_token: Some(1e-6),
                output_cost_per_token: Some(2e-6),
                cache_read_input_token_cost: Some(1e-7),
                cache_creation_input_token_cost: None,
                ..Default::default()
            },
        )]),
        HashMap::new(),
    )
}

fn find_model<'a>(
    daily: &'a [tokens_collector::DayBucket],
    date: &str,
    client: &str,
    model: &str,
) -> &'a tokens_collector::ModelUsage {
    daily
        .iter()
        .find(|day| day.date == date)
        .unwrap_or_else(|| panic!("missing day {date}"))
        .clients
        .iter()
        .find(|entry| entry.client_id == client)
        .unwrap_or_else(|| panic!("missing client {client}"))
        .models
        .iter()
        .find(|entry| entry.model_id == model)
        .unwrap_or_else(|| panic!("missing model {model}"))
}

#[test]
fn priced_event_matches_sample_math() {
    let pricing = fixture_pricing();
    let messages = vec![message(
        "codex",
        "fixture-model",
        "openai",
        ts(2026, 9, 8, 8, 0),
        tokens(80, 50, 20, 0, 10),
        0.0,
    )];
    let (daily, hourly) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    let amount = usage.estimated_cost.amount_usd.expect("priced");
    assert!((amount - 0.000_202).abs() < 1e-12, "got {amount}");
    assert!(usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 0);
    assert_eq!(usage.tokens.input, 80);
    assert_eq!(usage.tokens.cache_read, 20);
    assert_eq!(usage.tokens.reasoning, 10);
    assert_eq!(hourly.len(), 1);
    assert_eq!(hourly[0].hour, 8);
}

#[test]
fn source_billing_amount_is_ignored() {
    let pricing = fixture_pricing();
    let mut priced = message(
        "codex",
        "fixture-model",
        "openai",
        ts(2026, 9, 8, 8, 0),
        tokens(80, 50, 20, 0, 10),
        12345.678,
    );
    priced.cost_source = CostSource::ProviderReported;
    let (daily, _) = aggregate_messages(&[priced], Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    let amount = usage.estimated_cost.amount_usd.expect("priced");
    assert!((amount - 0.000_202).abs() < 1e-12, "got {amount}");
}

#[test]
fn missing_price_is_unpriced_not_free() {
    let pricing = fixture_pricing();
    let messages = vec![message(
        "codex",
        "zzz-unpriced-qqq",
        "openai",
        ts(2026, 9, 8, 8, 0),
        tokens(10, 5, 0, 0, 0),
        0.0,
    )];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "zzz-unpriced-qqq");
    assert_eq!(usage.estimated_cost.amount_usd, None);
    assert!(!usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 15);
    assert_eq!(usage.tokens.input, 10);
    assert_eq!(usage.tokens.output, 5);
}

#[test]
fn explicit_zero_price_stays_complete() {
    let pricing = PricingService::new(
        HashMap::from([(
            "free-model".to_string(),
            ModelPricing {
                input_cost_per_token: Some(0.0),
                output_cost_per_token: Some(0.0),
                cache_read_input_token_cost: Some(0.0),
                cache_creation_input_token_cost: Some(0.0),
                ..Default::default()
            },
        )]),
        HashMap::new(),
    );
    let messages = vec![message(
        "claude",
        "free-model",
        "anthropic",
        ts(2026, 9, 8, 9, 0),
        tokens(100, 200, 30, 40, 50),
        0.0,
    )];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "claude", "free-model");
    assert_eq!(usage.estimated_cost.amount_usd, Some(0.0));
    assert!(usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 0);
}

#[test]
fn incomplete_category_pricing_unprices_whole_event() {
    // Fixture has no cache-write rate, so an event with cache_write usage is
    // wholly unpriced: every token counts toward unpricedTokens.
    let pricing = fixture_pricing();
    let messages = vec![message(
        "codex",
        "fixture-model",
        "openai",
        ts(2026, 9, 8, 8, 0),
        tokens(80, 50, 20, 7, 10),
        0.0,
    )];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    assert_eq!(usage.estimated_cost.amount_usd, None);
    assert!(!usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 80 + 50 + 20 + 7 + 10);
}

#[test]
fn mixed_priced_and_unpriced_keeps_partial_sum() {
    let pricing = fixture_pricing();
    let messages = vec![
        message(
            "codex",
            "fixture-model",
            "openai",
            ts(2026, 9, 8, 8, 0),
            tokens(80, 50, 20, 0, 10),
            0.0,
        ),
        message(
            "codex",
            "zzz-unpriced-qqq",
            "openai",
            ts(2026, 9, 8, 8, 5),
            tokens(10, 5, 0, 0, 0),
            0.0,
        ),
    ];
    // Same client but different models: each bucket keeps its own verdict.
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let priced = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    assert!((priced.estimated_cost.amount_usd.expect("priced") - 0.000_202).abs() < 1e-12);
    assert!(priced.estimated_cost.complete);
    let unpriced = find_model(&daily, "2026-09-08", "codex", "zzz-unpriced-qqq");
    assert_eq!(unpriced.estimated_cost.amount_usd, None);
    assert!(!unpriced.estimated_cost.complete);
}

#[test]
fn zero_volume_event_does_not_fabricate_known_subtotal() {
    let pricing = fixture_pricing();
    let moment = ts(2026, 9, 8, 8, 0);
    let messages = vec![
        message("codex", "zzz-unpriced-qqq", "openai", moment, tokens(10, 5, 0, 0, 0), 0.0),
        message("codex", "zzz-unpriced-qqq", "openai", moment + 1, tokens(0, 0, 0, 0, 0), 0.0),
    ];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-08", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "zzz-unpriced-qqq");
    assert_eq!(usage.estimated_cost.amount_usd, None);
    assert!(!usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 15);
}

#[test]
fn zero_token_group_is_complete_zero() {
    let pricing = fixture_pricing();
    let messages = vec![message(
        "codex",
        "zzz-unpriced-qqq",
        "openai",
        ts(2026, 9, 8, 8, 0),
        tokens(0, 0, 0, 0, 0),
        0.0,
    )];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "zzz-unpriced-qqq");
    assert_eq!(usage.estimated_cost.amount_usd, Some(0.0));
    assert!(usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 0);
}

#[test]
fn canonical_grouping_and_client_separation() {
    let pricing = fixture_pricing();
    let moment = ts(2026, 9, 8, 8, 0);
    let messages = vec![
        message("codex", "Fixture-Model", "openai", moment, tokens(10, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-model", "openai", moment, tokens(20, 0, 0, 0, 0), 0.0),
        message("claude", "fixture-model", "openai", moment, tokens(30, 0, 0, 0, 0), 0.0),
    ];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    assert_eq!(daily.len(), 1);
    let codex = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    assert_eq!(codex.tokens.input, 30);
    let claude = find_model(&daily, "2026-09-08", "claude", "fixture-model");
    assert_eq!(claude.tokens.input, 30);
}

#[test]
fn provider_rates_stay_distinct() {
    let pricing = PricingService::new(
        HashMap::from([
            (
                "openai/fixture-p".to_string(),
                ModelPricing {
                    input_cost_per_token: Some(1e-6),
                    output_cost_per_token: Some(1e-6),
                    ..Default::default()
                },
            ),
            (
                "anthropic/fixture-p".to_string(),
                ModelPricing {
                    input_cost_per_token: Some(10e-6),
                    output_cost_per_token: Some(10e-6),
                    ..Default::default()
                },
            ),
        ]),
        HashMap::new(),
    );
    let moment = ts(2026, 9, 8, 8, 0);
    let messages = vec![
        message("codex", "fixture-p", "openai", moment, tokens(100, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-p", "anthropic", moment + 1, tokens(100, 0, 0, 0, 0), 0.0),
    ];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-01", "2026-09-08", "2026-09-08");
    // Same grouping key, but per-event provider pricing is preserved in the sum.
    let usage = find_model(&daily, "2026-09-08", "codex", "fixture-p");
    let amount = usage.estimated_cost.amount_usd.expect("priced");
    assert!((amount - (100e-6 + 1000e-6)).abs() < 1e-12, "got {amount}");
    assert_eq!(usage.tokens.input, 200);
}

#[test]
fn dates_hours_and_range_filtering() {
    let pricing = fixture_pricing();
    let messages = vec![
        // Late-August message: inside an early-month cross-month window.
        message("codex", "fixture-model", "openai", ts(2026, 8, 30, 23, 0), tokens(1, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-model", "openai", ts(2026, 9, 7, 10, 0), tokens(2, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-model", "openai", ts(2026, 9, 8, 8, 15), tokens(4, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-model", "openai", ts(2026, 9, 8, 8, 45), tokens(8, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-model", "openai", ts(2026, 9, 8, 22, 0), tokens(16, 0, 0, 0, 0), 0.0),
    ];
    let (daily, hourly) =
        aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-08-30", "2026-09-08", "2026-09-08");
    assert_eq!(daily.len(), 3);
    assert_eq!(daily[0].date, "2026-08-30");
    assert_eq!(daily[1].date, "2026-09-07");
    assert_eq!(daily[2].date, "2026-09-08");
    assert_eq!(find_model(&daily, "2026-09-08", "codex", "fixture-model").tokens.input, 28);

    // Hourly covers only hourly-date; repeated clock hours merge by label.
    assert_eq!(hourly.len(), 2);
    assert_eq!(hourly[0].hour, 8);
    assert_eq!(hourly[1].hour, 22);
    let hour8: i64 = hourly[0].clients.iter().flat_map(|c| c.models.iter().map(|m| m.tokens.input)).sum();
    assert_eq!(hour8, 12);

    // Narrower window drops out-of-range days from both outputs.
    let (daily_narrow, hourly_narrow) =
        aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-08", "2026-09-08", "2026-09-08");
    assert_eq!(daily_narrow.len(), 1);
    assert_eq!(hourly_narrow.len(), 2);
}

#[test]
fn hierarchy_conservation_parent_equals_children() {
    let pricing = fixture_pricing();
    let messages = vec![
        message("codex", "fixture-model", "openai", ts(2026, 9, 8, 8, 0), tokens(80, 50, 20, 0, 10), 0.0),
        message("codex", "zzz-unpriced-qqq", "openai", ts(2026, 9, 8, 9, 0), tokens(10, 5, 0, 0, 0), 0.0),
        message("claude", "fixture-model", "openai", ts(2026, 9, 8, 9, 30), tokens(7, 0, 0, 0, 0), 0.0),
    ];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-08", "2026-09-08", "2026-09-08");
    assert_eq!(daily.len(), 1);
    let leaf_input: i64 = daily[0]
        .clients
        .iter()
        .flat_map(|client| client.models.iter().map(|model| model.tokens.input))
        .sum();
    assert_eq!(leaf_input, 80 + 10 + 7);
    let leaf_unpriced: i64 = daily[0]
        .clients
        .iter()
        .flat_map(|client| client.models.iter().map(|model| model.estimated_cost.unpriced_tokens))
        .sum();
    assert_eq!(leaf_unpriced, 15);
}

#[test]
fn int64_precision_survives_aggregation_and_json() {
    let pricing = fixture_pricing();
    let big = i64::MAX - 10;
    let messages = vec![
        message("codex", "fixture-model", "openai", ts(2026, 9, 8, 8, 0), tokens(big, 0, 0, 0, 0), 0.0),
        message("codex", "fixture-model", "openai", ts(2026, 9, 8, 8, 1), tokens(20, 0, 0, 0, 0), 0.0),
    ];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-08", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    assert_eq!(usage.tokens.input, i64::MAX);

    // No Double transit: exact integers round-trip through JSON.
    let encoded = serde_json::to_value(&usage.tokens).expect("encode");
    assert_eq!(encoded["input"], serde_json::Value::from(i64::MAX));
    let decoded: serde_json::Value =
        serde_json::from_str(&serde_json::to_string(&usage.tokens).expect("encode")).expect("decode");
    assert_eq!(decoded["input"].as_i64(), Some(i64::MAX));
}

#[test]
fn unpriced_tokens_saturate_at_int64_max() {
    let pricing = fixture_pricing();
    let big = i64::MAX - 10;
    let messages = vec![
        message("codex", "zzz-unpriced-qqq", "openai", ts(2026, 9, 8, 8, 0), tokens(big, 0, 0, 0, 0), 0.0),
        message("codex", "zzz-unpriced-qqq", "openai", ts(2026, 9, 8, 8, 1), tokens(20, 0, 0, 0, 0), 0.0),
    ];
    let (daily, _) = aggregate_messages(&messages, Some(&pricing), shanghai(), "2026-09-08", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "zzz-unpriced-qqq");
    assert_eq!(usage.estimated_cost.unpriced_tokens, i64::MAX);
    assert_eq!(usage.estimated_cost.amount_usd, None);
}

#[test]
fn offline_without_pricing_leaves_costs_unknown() {
    let messages = vec![message(
        "codex",
        "fixture-model",
        "openai",
        ts(2026, 9, 8, 8, 0),
        tokens(80, 50, 20, 0, 10),
        0.0,
    )];
    let (daily, _) = aggregate_messages(&messages, None, shanghai(), "2026-09-08", "2026-09-08", "2026-09-08");
    let usage = find_model(&daily, "2026-09-08", "codex", "fixture-model");
    assert_eq!(usage.estimated_cost.amount_usd, None);
    assert!(!usage.estimated_cost.complete);
    assert_eq!(usage.estimated_cost.unpriced_tokens, 160);
    // Token counts still aggregate without any price table.
    assert_eq!(usage.tokens.input, 80);
}
