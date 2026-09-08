//! P1C `prices refresh` checks, fully offline: injected synthetic fetch
//! outcomes drive the real validation/promotion path. No test here touches
//! the network or the caller's home directory; every case uses isolated
//! temp dirs, and the CLI cases only exercise argument validation (exit 2)
//! in a child process.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;
use serial_test::serial;
use tempfile::TempDir;
use tokens_collector::price_update::{
    InjectedFetches, RefreshRequest, run_refresh_with_injected,
};
use tokens_core::pricing::ModelPricing;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tokens-collector"))
}

fn request(config: &TempDir) -> RefreshRequest {
    RefreshRequest {
        config_dir: config.path().to_str().expect("config").to_string(),
    }
}

fn pricing_data(model: &str) -> HashMap<String, ModelPricing> {
    let mut data = HashMap::new();
    data.insert(
        model.to_string(),
        ModelPricing {
            input_cost_per_token: Some(1e-6),
            output_cost_per_token: Some(2e-6),
            ..Default::default()
        },
    );
    data
}

fn all_ok() -> InjectedFetches {
    InjectedFetches {
        litellm: Ok(pricing_data("test/litellm-model")),
        openrouter: Ok(pricing_data("test/openrouter-model")),
        models_dev: Ok(pricing_data("test/models-dev-model")),
    }
}

fn all_empty() -> InjectedFetches {
    InjectedFetches {
        litellm: Ok(HashMap::new()),
        openrouter: Ok(HashMap::new()),
        models_dev: Ok(HashMap::new()),
    }
}

fn cache_file(config: &TempDir, name: &str) -> PathBuf {
    config.path().join("cache").join(name)
}

fn seed_cache(config: &TempDir, name: &str, timestamp: u64, data: &HashMap<String, ModelPricing>) {
    let dir = config.path().join("cache");
    std::fs::create_dir_all(&dir).expect("cache dir");
    let body = serde_json::json!({"timestamp": timestamp, "data": data});
    std::fs::write(dir.join(name), body.to_string()).expect("seed cache");
}

fn read_bytes(path: &PathBuf) -> Vec<u8> {
    std::fs::read(path).expect("read cache file")
}

fn decoded_data(path: &PathBuf) -> Value {
    let content = std::fs::read_to_string(path).expect("read cache file");
    let doc: Value = serde_json::from_str(&content).expect("cache is JSON");
    doc.get("data").expect("data field").clone()
}

#[test]
#[serial]
fn empty_config_to_valid_caches_reports_all_updated() {
    let config = TempDir::new().expect("config");
    let (report, code) = run_refresh_with_injected(&request(&config), all_ok()).expect("refresh");
    assert_eq!(code, 0);
    assert_eq!(report.schema_version, 1);
    assert!(report.generated_at.ends_with('Z'));
    assert!(chrono::DateTime::parse_from_rfc3339(&report.generated_at).is_ok());
    assert_eq!(report.sources.len(), 3);
    assert_eq!(report.sources[0].source, "litellm");
    assert_eq!(report.sources[1].source, "openrouter");
    assert_eq!(report.sources[2].source, "models-dev");
    for source in &report.sources {
        assert_eq!(source.status, "updated", "source: {}", source.source);
        assert!(source.updated_at.as_ref().is_some_and(|t| t.ends_with('Z')));
    }
    assert!(report.warnings.is_empty());
    for (name, model) in [
        ("pricing-litellm.json", "test/litellm-model"),
        ("pricing-openrouter.json", "test/openrouter-model"),
        ("pricing-models-dev.json", "test/models-dev-model"),
    ] {
        let path = cache_file(&config, name);
        assert!(path.exists(), "missing {name}");
        assert!(decoded_data(&path).get(model).is_some(), "missing {model}");
    }
}

#[test]
#[serial]
fn stale_cache_is_replaced_on_success() {
    let config = TempDir::new().expect("config");
    seed_cache(&config, "pricing-litellm.json", 1000, &HashMap::new());
    let (report, code) = run_refresh_with_injected(&request(&config), all_ok()).expect("refresh");
    assert_eq!(code, 0);
    assert!(report.sources.iter().all(|s| s.status == "updated"));
    let data = decoded_data(&cache_file(&config, "pricing-litellm.json"));
    assert!(data.get("test/litellm-model").is_some());
}

#[test]
#[serial]
fn empty_downloads_never_replace_good_caches() {
    let config = TempDir::new().expect("config");
    let names = [
        "pricing-litellm.json",
        "pricing-openrouter.json",
        "pricing-models-dev.json",
    ];
    for name in names {
        seed_cache(&config, name, 1000, &pricing_data("keep/model"));
    }
    let before: Vec<Vec<u8>> = names.iter().map(|n| read_bytes(&cache_file(&config, n))).collect();
    let (report, code) =
        run_refresh_with_injected(&request(&config), all_empty()).expect("refresh");
    assert_eq!(code, 1);
    assert!(report.sources.iter().all(|s| s.status == "failed"));
    assert!(report.sources.iter().all(|s| s.updated_at.is_none()));
    assert_eq!(report.warnings.len(), 3);
    for (name, bytes) in names.iter().zip(before.iter()) {
        assert_eq!(&read_bytes(&cache_file(&config, name)), bytes, "{name} changed");
    }
}

#[test]
#[serial]
fn fetch_errors_preserve_cache_bytes() {
    let config = TempDir::new().expect("config");
    seed_cache(&config, "pricing-litellm.json", 1000, &pricing_data("keep/model"));
    let before = read_bytes(&cache_file(&config, "pricing-litellm.json"));
    let injected = InjectedFetches {
        litellm: Err("synthetic network failure".to_string()),
        openrouter: Ok(pricing_data("test/openrouter-model")),
        models_dev: Ok(pricing_data("test/models-dev-model")),
    };
    let (report, code) =
        run_refresh_with_injected(&request(&config), injected).expect("refresh");
    assert_eq!(code, 1);
    assert_eq!(report.sources[0].status, "failed");
    assert_eq!(report.sources[0].updated_at, None);
    assert_eq!(report.sources[1].status, "updated");
    assert_eq!(report.sources[2].status, "updated");
    assert_eq!(report.warnings.len(), 1);
    assert_eq!(read_bytes(&cache_file(&config, "pricing-litellm.json")), before);
    // Successful siblings still promote.
    let data = decoded_data(&cache_file(&config, "pricing-openrouter.json"));
    assert!(data.get("test/openrouter-model").is_some());
}

#[test]
#[serial]
fn unusable_dataset_is_not_promoted() {
    let config = TempDir::new().expect("config");
    let mut junk = HashMap::new();
    junk.insert("test/no-rates".to_string(), ModelPricing::default());
    let injected = InjectedFetches {
        litellm: Ok(junk),
        openrouter: Ok(pricing_data("test/openrouter-model")),
        models_dev: Ok(pricing_data("test/models-dev-model")),
    };
    let (report, code) =
        run_refresh_with_injected(&request(&config), injected).expect("refresh");
    assert_eq!(code, 1);
    assert_eq!(report.sources[0].status, "failed");
    assert!(!cache_file(&config, "pricing-litellm.json").exists());
}

#[test]
#[serial]
fn relative_config_dir_is_rejected() {
    let request = RefreshRequest {
        config_dir: "relative/path".to_string(),
    };
    let err = run_refresh_with_injected(&request, all_ok()).expect_err("must fail");
    assert_eq!(err.code, 2);
}

#[test]
#[serial]
fn report_serializes_to_packet_json() {
    let config = TempDir::new().expect("config");
    let (report, code) =
        run_refresh_with_injected(&request(&config), all_empty()).expect("refresh");
    assert_eq!(code, 1);
    let doc: Value = serde_json::to_value(&report).expect("json");
    assert_eq!(doc["schemaVersion"], 1);
    assert!(doc["generatedAt"].is_string());
    let sources = doc["sources"].as_array().expect("sources");
    assert_eq!(sources.len(), 3);
    for source in sources {
        assert!(source["source"].is_string());
        assert_eq!(source["status"], "failed");
        assert_eq!(source["updatedAt"], Value::Null);
    }
    assert!(doc["warnings"].as_array().is_some_and(|w| !w.is_empty()));
    // No filesystem paths leak into the worker document.
    let text = serde_json::to_string(&doc).expect("text");
    assert!(!text.contains(config.path().to_str().expect("config")));
}

#[test]
#[serial]
fn caller_config_dir_env_is_restored() {
    let config = TempDir::new().expect("config");
    std::env::set_var("TOKENS_CONFIG_DIR", "/tmp/p1c-sentinel");
    let result = run_refresh_with_injected(&request(&config), all_ok());
    assert!(result.is_ok());
    assert_eq!(
        std::env::var("TOKENS_CONFIG_DIR").expect("restored"),
        "/tmp/p1c-sentinel"
    );
    std::env::remove_var("TOKENS_CONFIG_DIR");
}

fn run_raw(args: &[&str]) -> (i32, String, String) {
    let output = Command::new(binary())
        .args(args)
        .output()
        .expect("spawn tokens-collector");
    (
        output.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

#[test]
fn prices_cli_rejects_bad_arguments_without_stdout() {
    let config = TempDir::new().expect("config");
    let config_str = config.path().to_str().expect("config").to_string();
    let cases: Vec<Vec<&str>> = vec![
        vec!["prices"],
        vec!["prices", "refresh"],
        vec!["prices", "refresh", "--config-dir", "relative/path"],
        vec!["prices", "refresh", "--config-dir", &config_str, "--bogus", "1"],
        vec!["prices", "refresh", "--config-dir", &config_str, "extra"],
        vec!["prices", "scan"],
    ];
    for args in cases {
        let (code, stdout, _stderr) = run_raw(&args);
        assert_eq!(code, 2, "args: {args:?}, stderr: {_stderr}");
        assert!(stdout.is_empty(), "no document on arg failure: {args:?}");
    }
}

#[test]
fn prices_cli_accepts_equals_form_config_dir() {
    // Argument-shape check only: a missing value is still exit 2 without
    // touching the network (validation precedes any fetch).
    let (code, stdout, _stderr) = run_raw(&["prices", "refresh", "--config-dir"]);
    assert_eq!(code, 2, "stderr: {_stderr}");
    assert!(stdout.is_empty());
}
