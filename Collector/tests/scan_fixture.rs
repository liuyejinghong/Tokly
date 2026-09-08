use std::process::Command;

use serde_json::{json, Value};
use tempfile::TempDir;

fn binary() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_tokens-collector"))
}

fn usage(input: i64, output: i64, cached: i64, reasoning: i64, total: i64) -> Value {
    json!({
        "input_tokens": input,
        "output_tokens": output,
        "cached_input_tokens": cached,
        "reasoning_output_tokens": reasoning,
        "total_tokens": total,
    })
}

#[test]
fn codex_fixture_dedupes_old_mtime_and_matches_hour_to_day() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let dir = home.path().join(".codex/sessions/2026/09");
    std::fs::create_dir_all(&dir).expect("session dir");
    let unit = usage(100, 50, 20, 10, 180);
    let doubled = usage(200, 100, 40, 20, 360);
    let rows = [
        json!({"timestamp": "2026-09-08T08:00:00+08:00", "type": "session_meta",
               "payload": {"id": "cli-fixture", "model_provider": "openai"}}),
        json!({"timestamp": "2026-09-08T08:15:00+08:00", "type": "event_msg",
               "payload": {"type": "token_count",
                           "info": {"model": "fixture-model", "last_token_usage": unit,
                                    "total_token_usage": unit}}}),
        json!({"timestamp": "2026-09-08T08:15:00+08:00", "type": "event_msg",
               "payload": {"type": "token_count",
                           "info": {"model": "fixture-model", "last_token_usage": unit,
                                    "total_token_usage": unit}}}),
        json!({"timestamp": "2026-09-08T08:45:00+08:00", "type": "event_msg",
               "payload": {"type": "token_count",
                           "info": {"model": "fixture-model", "last_token_usage": unit,
                                    "total_token_usage": doubled}}}),
    ];
    let file = dir.join("session.jsonl");
    std::fs::write(&file, rows.iter().map(|row| row.to_string() + "\n").collect::<String>())
        .expect("write fixture");
    let mtime: std::time::SystemTime =
        chrono::DateTime::parse_from_rfc3339("2026-08-20T00:00:00Z").expect("mtime").into();
    std::fs::File::options().write(true).open(&file).expect("open").set_modified(mtime).expect("mtime");

    let cache_dir = config.path().join("cache");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");
    std::fs::write(
        cache_dir.join("pricing-litellm.json"),
        json!({"timestamp": 1_788_220_800u64, "data": {"fixture-model": {
            "input_cost_per_token": 1e-6,
            "output_cost_per_token": 2e-6,
            "cache_read_input_token_cost": 1e-7,
        }}}).to_string(),
    )
    .expect("write cache");

    let output = Command::new(binary())
        .args([
            "scan",
            "--home", home.path().to_str().expect("home"),
            "--config-dir", config.path().to_str().expect("config"),
            "--timezone", "Asia/Shanghai",
            "--since", "2026-08-25",
            "--until", "2026-09-08",
            "--hourly-date", "2026-09-08",
            "--clients", "codex",
        ])
        .output()
        .expect("spawn");
    assert_eq!(output.status.code().unwrap_or(-1), 0, "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let snapshot: Value =
        serde_json::from_slice(&output.stdout).expect("stdout is one JSON document");

    assert_eq!(snapshot["pricingAsOf"], "2026-09-01T00:00:00Z");
    let sources = snapshot["sources"].as_array().expect("sources");
    assert_eq!(sources.len(), 1);
    assert_eq!(sources[0]["clientId"], "codex");
    assert_eq!(sources[0]["status"], "found");
    assert_eq!(sources[0]["sourceCount"], 1);

    let daily = snapshot["daily"].as_array().expect("daily");
    assert_eq!(daily.len(), 1);
    assert_eq!(daily[0]["date"], "2026-09-08");
    let model = &daily[0]["clients"][0]["models"][0];
    assert_eq!(model["modelId"], "fixture-model");
    assert_eq!(model["tokens"], json!({"input": 160, "output": 100, "cacheRead": 40, "cacheWrite": 0, "reasoning": 20}));
    let amount = model["estimatedCost"]["amountUsd"].as_f64().expect("priced");
    assert!((amount - 0.000_404).abs() < 1e-12, "got {amount}");
    assert_eq!(model["estimatedCost"]["complete"], true);
    assert_eq!(model["estimatedCost"]["unpricedTokens"], 0);

    let hourly = snapshot["hourly"].as_array().expect("hourly");
    assert_eq!(hourly.len(), 1);
    assert_eq!(hourly[0]["hour"], 8);
    assert_eq!(hourly[0]["clients"][0]["models"][0]["tokens"], model["tokens"]);
}
