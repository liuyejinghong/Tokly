use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serial_test::serial;
use tokens_core::pricing::{ModelPricing, PricingService};
use tokens_core::ReportOptions;

fn total_tokens(messages: &[tokens_core::sessions::UnifiedMessage]) -> i64 {
    messages.iter().map(|m| m.tokens.total()).sum()
}

struct Isolated {
    _home: tempfile::TempDir,
    _config: tempfile::TempDir,
    home: PathBuf,
    previous_config: Option<std::ffi::OsString>,
}

impl Drop for Isolated {
    fn drop(&mut self) {
        match &self.previous_config {
            Some(value) => std::env::set_var("TOKENS_CONFIG_DIR", value),
            None => std::env::remove_var("TOKENS_CONFIG_DIR"),
        }
    }
}

fn setup_isolated() -> Isolated {
    let home = tempfile::tempdir().expect("temp home");
    let config = tempfile::tempdir().expect("temp config");
    // Keep TempDirs alive via returned struct; point caches at isolated config.
    let previous_config = std::env::var_os("TOKENS_CONFIG_DIR");
    std::env::set_var("TOKENS_CONFIG_DIR", config.path());
    Isolated {
        home: home.path().to_path_buf(),
        _home: home,
        _config: config,
        previous_config,
    }
}

fn codex_options(home: &Path, clients: Vec<&str>) -> ReportOptions {
    ReportOptions {
        home_dir: Some(home.to_string_lossy().into_owned()),
        use_env_roots: false,
        clients: Some(clients.into_iter().map(str::to_string).collect()),
        ..Default::default()
    }
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

fn usage_value() -> serde_json::Value {
    serde_json::json!({
        "input_tokens": 100,
        "output_tokens": 50,
        "cached_input_tokens": 20,
        "reasoning_output_tokens": 10,
        "total_tokens": 150
    })
}

fn doubled_usage_value() -> serde_json::Value {
    serde_json::json!({
        "input_tokens": 200,
        "output_tokens": 100,
        "cached_input_tokens": 40,
        "reasoning_output_tokens": 20,
        "total_tokens": 300
    })
}

fn write_codex_session(path: &Path, stamp: &str, session_id: &str, totals: &[serde_json::Value]) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create sessions dir");
    }
    let mut out = String::new();
    out.push_str(
        &serde_json::json!({
            "timestamp": stamp,
            "type": "session_meta",
            "payload": {"id": session_id, "model_provider": "openai"}
        })
        .to_string(),
    );
    out.push('\n');
    for total in totals {
        out.push_str(
            &serde_json::json!({
                "timestamp": stamp,
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "model": "fixture-model",
                        "last_token_usage": usage_value(),
                        "total_token_usage": total
                    }
                }
            })
            .to_string(),
        );
        out.push('\n');
    }
    fs::write(path, out).expect("write fixture");
}

fn append_codex_event(path: &Path, stamp: &str, total: &serde_json::Value) {
    let line = serde_json::json!({
        "timestamp": stamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "model": "fixture-model",
                "last_token_usage": usage_value(),
                "total_token_usage": total
            }
        }
    })
    .to_string()
        + "\n";
    use std::io::Write;
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(path)
        .expect("open fixture for append");
    file.write_all(line.as_bytes()).expect("append fixture");
}

fn backdate_mtime(path: &Path, days_ago: u64) {
    let old = SystemTime::now() - std::time::Duration::from_secs(days_ago * 24 * 3600);
    let file = fs::File::options()
        .write(true)
        .open(path)
        .expect("open for set_modified");
    file.set_modified(old).expect("backdate mtime");
}

fn seed_empty_pricing_cache(config_dir: &Path) {
    let cache_dir = config_dir.join("cache");
    fs::create_dir_all(&cache_dir).expect("create cache dir");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_secs();
    for name in [
        "pricing-litellm.json",
        "pricing-openrouter.json",
        "pricing-models-dev.json",
    ] {
        let payload = serde_json::json!({"timestamp": now, "data": {}});
        fs::write(cache_dir.join(name), payload.to_string()).expect("seed pricing cache");
    }
}

fn synthetic_pricing() -> PricingService {
    let mut litellm: HashMap<String, ModelPricing> = HashMap::new();
    litellm.insert(
        "fixture-model".to_string(),
        ModelPricing {
            input_cost_per_token: Some(1e-6),
            output_cost_per_token: Some(2e-6),
            cache_read_input_token_cost: Some(5e-7),
            ..Default::default()
        },
    );
    PricingService::new(litellm, HashMap::new())
}

#[test]
#[serial]
fn duplicate_token_count_counts_once_and_append_increments() {
    let iso = setup_isolated();
    let stamp = now_rfc3339();
    let session_path = iso.home.join(".codex/sessions/rollout-fixture.jsonl");
    let usage = usage_value();
    write_codex_session(&session_path, &stamp, "fixture-session", &[usage.clone(), usage]);

    let options = codex_options(&iso.home, vec!["codex"]);
    let first = tokens_core::collect_messages(&options, None).expect("collect");
    assert_eq!(total_tokens(&first), 160, "duplicate total counted once");

    append_codex_event(&session_path, &stamp, &doubled_usage_value());
    let second = tokens_core::collect_messages(&options, None).expect("recollect");
    assert_eq!(total_tokens(&second), 320, "appended usage increments total");
}

#[test]
#[serial]
fn archive_duplicate_counts_once_and_old_mtime_full_scan_keeps_today() {
    let iso = setup_isolated();
    let stamp = now_rfc3339();
    let session_path = iso.home.join(".codex/sessions/rollout-fixture.jsonl");
    let usage = usage_value();
    write_codex_session(&session_path, &stamp, "fixture-session", &[usage.clone(), usage]);

    let archive_path = iso.home.join(".codex/archived_sessions/rollout-fixture.jsonl");
    if let Some(parent) = archive_path.parent() {
        fs::create_dir_all(parent).expect("create archive dir");
    }
    fs::copy(&session_path, &archive_path).expect("copy to archive");

    let options = codex_options(&iso.home, vec!["codex"]);
    let dup = tokens_core::collect_messages(&options, None).expect("collect");
    assert_eq!(
        total_tokens(&dup),
        160,
        "same log in current and archive counts once"
    );

    backdate_mtime(&session_path, 2);
    backdate_mtime(&archive_path, 2);
    let mut full_options = codex_options(&iso.home, vec!["codex"]);
    full_options.today_only = false;
    let full = tokens_core::collect_messages(&full_options, None).expect("full scan");
    assert_eq!(
        total_tokens(&full),
        160,
        "old mtime does not drop today's records in full scan"
    );
}

#[test]
#[serial]
fn client_and_date_filters_apply() {
    let iso = setup_isolated();
    let stamp = now_rfc3339();
    let session_path = iso.home.join(".codex/sessions/rollout-fixture.jsonl");
    let usage = usage_value();
    write_codex_session(&session_path, &stamp, "fixture-session", &[usage.clone(), usage]);

    let codex = tokens_core::collect_messages(&codex_options(&iso.home, vec!["codex"]), None)
        .expect("collect codex");
    assert_eq!(total_tokens(&codex), 160);
    assert!(codex.iter().all(|m| m.client == "codex"));
    let date = codex.first().expect("one message").date.clone();

    let other = tokens_core::collect_messages(&codex_options(&iso.home, vec!["claude"]), None)
        .expect("collect claude");
    assert_eq!(total_tokens(&other), 0, "client filter excludes codex");

    let mut since_opts = codex_options(&iso.home, vec!["codex"]);
    since_opts.since = Some(date.clone());
    since_opts.until = Some(date.clone());
    let ranged = tokens_core::collect_messages(&since_opts, None).expect("ranged");
    assert_eq!(total_tokens(&ranged), 160, "matching date range keeps rows");

    let mut empty_opts = codex_options(&iso.home, vec!["codex"]);
    empty_opts.since = Some("9999-01-01".to_string());
    let empty = tokens_core::collect_messages(&empty_opts, None).expect("future");
    assert_eq!(total_tokens(&empty), 0, "future since drops all rows");
}

#[test]
#[serial]
fn pricing_none_needs_no_price_cache() {
    let iso = setup_isolated();
    // Fresh isolated config has no pricing-*.json files; this must still work.
    let cache_dir = std::env::var_os("TOKENS_CONFIG_DIR")
        .map(PathBuf::from)
        .expect("config dir")
        .join("cache");
    assert!(
        !cache_dir.join("pricing-litellm.json").exists(),
        "price cache must start absent"
    );

    let stamp = now_rfc3339();
    let session_path = iso.home.join(".codex/sessions/rollout-fixture.jsonl");
    let usage = usage_value();
    write_codex_session(&session_path, &stamp, "fixture-session", &[usage.clone(), usage]);

    let messages = tokens_core::collect_messages(&codex_options(&iso.home, vec!["codex"]), None)
        .expect("collect without pricing");
    assert_eq!(total_tokens(&messages), 160);
    assert!(messages.iter().all(|m| m.cost == 0.0));
}

#[test]
#[serial]
fn explicit_synthetic_pricing_valuates_without_network() {
    let iso = setup_isolated();
    let stamp = now_rfc3339();
    let session_path = iso.home.join(".codex/sessions/rollout-fixture.jsonl");
    let usage = usage_value();
    write_codex_session(&session_path, &stamp, "fixture-session", &[usage.clone(), usage]);

    let pricing = synthetic_pricing();
    let messages =
        tokens_core::collect_messages(&codex_options(&iso.home, vec!["codex"]), Some(&pricing))
            .expect("collect with pricing");
    assert_eq!(total_tokens(&messages), 160);
    // Breakdown for the fixture: input 80, output 50, cache_read 20, reasoning 10
    // (reasoning bills with output): 80*1e-6 + 60*2e-6 + 20*5e-7 = 0.00021.
    let cost: f64 = messages.iter().map(|m| m.cost).sum();
    assert!(
        (cost - 0.00021).abs() < 1e-9,
        "synthetic pricing valuates known model, got {cost}"
    );
}

#[tokio::test]
#[serial]
async fn collect_matches_generate_graph_tokens() {
    let iso = setup_isolated();
    let config_dir = std::env::var_os("TOKENS_CONFIG_DIR")
        .map(PathBuf::from)
        .expect("config dir");
    seed_empty_pricing_cache(&config_dir);

    let stamp = now_rfc3339();
    let session_path = iso.home.join(".codex/sessions/rollout-fixture.jsonl");
    let usage = usage_value();
    write_codex_session(&session_path, &stamp, "fixture-session", &[usage.clone(), usage]);

    let options = codex_options(&iso.home, vec!["codex"]);
    let collected = tokens_core::collect_messages(&options, None).expect("collect");
    let collected_tokens = total_tokens(&collected);

    let graph = tokens_core::generate_graph(options)
        .await
        .expect("generate_graph");
    assert_eq!(
        graph.summary.total_tokens, collected_tokens,
        "new API aggregates like generate_graph"
    );
    assert_eq!(collected_tokens, 160);
}
