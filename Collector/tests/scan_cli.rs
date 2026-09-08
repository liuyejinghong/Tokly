use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;
use tempfile::TempDir;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tokens-collector"))
}

fn base_args(home: &TempDir, config: &TempDir) -> Vec<String> {
    [
        "scan",
        "--home",
        home.path().to_str().expect("home"),
        "--config-dir",
        config.path().to_str().expect("config"),
        "--timezone",
        "Asia/Shanghai",
        "--since",
        "2026-09-01",
        "--until",
        "2026-09-08",
        "--hourly-date",
        "2026-09-08",
    ]
    .iter()
    .map(ToString::to_string)
    .collect()
}

fn run_with(home: &TempDir, config: &TempDir, extra: &[&str]) -> (i32, String, String) {
    let mut args = base_args(home, config);
    args.extend(extra.iter().map(ToString::to_string));
    run_raw(&args)
}

fn run_raw(args: &[String]) -> (i32, String, String) {
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

fn raw_args(pairs: &[&str]) -> Vec<String> {
    pairs.iter().map(ToString::to_string).collect()
}

#[test]
fn empty_home_scans_successfully_with_unknown_costs() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let (code, stdout, _stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {_stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("stdout is one JSON document");
    assert_eq!(snapshot["schemaVersion"], 1);
    assert_eq!(snapshot["timezone"], "Asia/Shanghai");
    assert_eq!(snapshot["range"]["since"], "2026-09-01");
    assert_eq!(snapshot["range"]["until"], "2026-09-08");
    assert_eq!(snapshot["hourlyDate"], "2026-09-08");
    assert_eq!(snapshot["daily"], Value::Array(vec![]));
    assert_eq!(snapshot["hourly"], Value::Array(vec![]));
    assert_eq!(snapshot["pricingAsOf"], Value::Null);
    let warnings = snapshot["warnings"].as_array().expect("warnings array");
    assert!(
        warnings.iter().any(|w| w["code"] == "PRICE_CACHE_MISSING"),
        "warnings: {warnings:?}"
    );
    // Sources cover the registry; an empty home finds nothing but still succeeds.
    let sources = snapshot["sources"].as_array().expect("sources array");
    assert!(!sources.is_empty());
    for source in sources {
        assert_eq!(source["status"], "notFound", "source: {source}");
        assert_eq!(source["sourceCount"], 0);
    }
    // No workspace paths, prompts, or home paths leak into the worker document.
    assert!(!stdout.contains(home.path().to_str().expect("home")));
    assert!(sources.iter().any(|s| s["clientId"] == "synthetic"));
}

#[test]
fn explicit_clients_restrict_sources() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let (code, stdout, stderr) = run_with(&home, &config, &["--clients", "codex,claude"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    let sources = snapshot["sources"].as_array().expect("sources");
    assert_eq!(sources.len(), 2);
    assert_eq!(sources[0]["clientId"], "claude");
    assert_eq!(sources[1]["clientId"], "codex");
}

#[test]
fn clients_equals_form_is_accepted() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let (code, _stdout, stderr) = run_with(&home, &config, &["--clients=codex"]);
    assert_eq!(code, 0, "stderr: {stderr}");
}

fn replaced(args: &[String], key: &str, value: &str) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        if arg == key {
            out.push(arg.clone());
            assert!(iter.peek().is_some(), "missing value for {key}");
            iter.next();
            out.push(value.to_string());
        } else {
            out.push(arg.clone());
        }
    }
    out
}

#[test]
fn invalid_arguments_exit_two_without_stdout() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let home_str = home.path().to_str().expect("home").to_string();
    let config_str = config.path().to_str().expect("config").to_string();

    let valid = base_args(&home, &config);
    let mut cases: Vec<Vec<String>> = vec![
        replaced(&valid, "--home", "relative/path"),
        replaced(&valid, "--since", "2026-13-01"),
        replaced(&valid, "--since", "2026-9-8"),
        replaced(&valid, "--until", "not-a-date"),
        replaced(&valid, "--timezone", "Mars/Olympus"),
        // since after until.
        replaced(&replaced(&valid, "--since", "2026-09-08"), "--until", "2026-09-01"),
        // hourly-date outside the range.
        replaced(&valid, "--hourly-date", "2026-09-09"),
        replaced(&valid, "--hourly-date", "2026-08-31"),
    ];
    let mut rebuilt = vec!["scan".to_string(), "--home".to_string(), home_str.clone()];
    rebuilt.extend([
        "--config-dir",
        &config_str,
        "--timezone",
        "Asia/Shanghai",
        "--since",
        "2026-09-01",
        "--hourly-date",
        "2026-09-08",
    ].iter().map(ToString::to_string));
    cases.push(rebuilt);
    cases.push(raw_args(&[
        "scan", "--home", &home_str, "--config-dir", &config_str, "--timezone", "Asia/Shanghai",
        "--since", "2026-09-01", "--until", "2026-09-08", "--hourly-date", "2026-09-08",
        "--clients", "no-such-client",
    ]));
    cases.push(raw_args(&[
        "scan", "--home", &home_str, "--config-dir", &config_str, "--timezone", "Asia/Shanghai",
        "--since", "2026-09-01", "--until", "2026-09-08", "--hourly-date", "2026-09-08",
        "--bogus", "1",
    ]));
    cases.push(raw_args(&["summarize"]));

    for args in cases {
        let (code, stdout, _stderr) = run_raw(&args);
        assert_eq!(code, 2, "args: {args:?}, stderr: {_stderr}");
        assert!(stdout.is_empty(), "no success document on failure: {args:?}");
    }
}

#[test]
fn unreadable_home_fails_without_forged_zero_document() {
    let config = TempDir::new().expect("config");
    let file_home = tempfile::NamedTempFile::new().expect("temp file");
    let args = raw_args(&[
        "scan",
        "--home",
        file_home.path().to_str().expect("path"),
        "--config-dir",
        config.path().to_str().expect("config"),
        "--timezone",
        "Asia/Shanghai",
        "--since",
        "2026-09-01",
        "--until",
        "2026-09-08",
        "--hourly-date",
        "2026-09-08",
    ]);
    let (code, stdout, stderr) = run_raw(&args);
    assert_eq!(code, 1, "stderr: {stderr}");
    assert!(stdout.is_empty());
    assert!(!stderr.is_empty());
}

#[test]
fn stale_cache_sets_pricing_as_of_and_warns() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let cache_dir = config.path().join("cache");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");
    std::fs::write(
        cache_dir.join("pricing-litellm.json"),
        r#"{"timestamp":1000,"data":{}}"#,
    )
    .expect("write cache");
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    assert_eq!(snapshot["pricingAsOf"], "1970-01-01T00:16:40Z");
    let warnings = snapshot["warnings"].as_array().expect("warnings");
    assert!(warnings.iter().any(|w| w["code"] == "PRICE_CACHE_STALE"));
    assert!(!warnings.iter().any(|w| w["code"] == "PRICE_CACHE_MISSING"));
}

#[test]
fn fresh_cache_has_no_stale_or_missing_warning() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let cache_dir = config.path().join("cache");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("time")
        .as_secs();
    std::fs::write(
        cache_dir.join("pricing-openrouter.json"),
        format!(r#"{{"timestamp":{now},"data":{{}}}}"#),
    )
    .expect("write cache");
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    assert!(snapshot["pricingAsOf"].is_string());
    let warnings = snapshot["warnings"].as_array().expect("warnings");
    assert!(!warnings.iter().any(|w| w["code"] == "PRICE_CACHE_STALE"));
    assert!(!warnings.iter().any(|w| w["code"] == "PRICE_CACHE_MISSING"));
}

#[test]
fn corrupt_cache_warns_and_nulls_pricing_time() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let cache_dir = config.path().join("cache");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");
    std::fs::write(cache_dir.join("pricing-litellm.json"), "not json{{{").expect("write");
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    assert_eq!(snapshot["pricingAsOf"], Value::Null);
    let warnings = snapshot["warnings"].as_array().expect("warnings");
    assert!(warnings.iter().any(|w| w["code"] == "PRICE_CACHE_UNREADABLE"));
}

#[test]
fn generated_at_is_utc_rfc3339() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    let generated = snapshot["generatedAt"].as_str().expect("generatedAt");
    assert!(generated.ends_with('Z'), "got {generated}");
    assert!(chrono::DateTime::parse_from_rfc3339(generated).is_ok());
}

fn write_cache(config: &TempDir, name: &str, body: &str) {
    let cache_dir = config.path().join("cache");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");
    std::fs::write(cache_dir.join(name), body).expect("write cache");
}

#[test]
fn pricing_time_is_oldest_usable_cache() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    write_cache(&config, "pricing-litellm.json", r#"{"timestamp":1000,"data":{}}"#);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("time")
        .as_secs();
    write_cache(
        &config,
        "pricing-openrouter.json",
        &format!(r#"{{"timestamp":{now},"data":{{}}}}"#),
    );
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    assert_eq!(snapshot["pricingAsOf"], "1970-01-01T00:16:40Z");
    let warnings = snapshot["warnings"].as_array().expect("warnings");
    assert!(warnings.iter().any(|w| w["code"] == "PRICE_CACHE_STALE"));
    assert!(!warnings.iter().any(|w| w["code"] == "PRICE_CACHE_MISSING"));
    assert!(!warnings.iter().any(|w| w["code"] == "PRICE_CACHE_UNREADABLE"));
}

#[test]
fn invalid_price_data_never_counts_as_snapshot() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    write_cache(&config, "pricing-litellm.json", r#"{"timestamp":1000,"data":42}"#);
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    assert_eq!(snapshot["pricingAsOf"], Value::Null);
    let warnings = snapshot["warnings"].as_array().expect("warnings");
    assert!(warnings.iter().any(|w| w["code"] == "PRICE_CACHE_UNREADABLE"));
}

#[test]
fn future_price_timestamp_is_rejected() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let future = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("time")
        .as_secs()
        + 3600;
    write_cache(
        &config,
        "pricing-litellm.json",
        &format!(r#"{{"timestamp":{future},"data":{{}}}}"#),
    );
    let (code, stdout, stderr) = run_with(&home, &config, &[]);
    assert_eq!(code, 0, "stderr: {stderr}");
    let snapshot: Value = serde_json::from_str(&stdout).expect("json");
    assert_eq!(snapshot["pricingAsOf"], Value::Null);
    let warnings = snapshot["warnings"].as_array().expect("warnings");
    assert!(warnings.iter().any(|w| w["code"] == "PRICE_CACHE_UNREADABLE"));
}

#[test]
#[cfg(unix)]
fn unreadable_nested_session_fails() {
    use std::os::unix::fs::PermissionsExt;
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let dir = home.path().join(".codex/sessions/2026/09");
    std::fs::create_dir_all(&dir).expect("session dir");
    let file = dir.join("session.jsonl");
    std::fs::write(&file, "{}\n").expect("write session");
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000))
        .expect("chmod");
    if std::fs::File::open(&file).is_ok() {
        return;
    }
    let (code, stdout, _stderr) = run_with(&home, &config, &["--clients", "codex"]);
    assert_eq!(code, 1, "stderr: {_stderr}");
    assert!(stdout.is_empty());
}

#[test]
#[cfg(unix)]
fn unreadable_nested_directory_fails() {
    use std::os::unix::fs::PermissionsExt;
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let dir = home.path().join(".codex/sessions/2026/09");
    std::fs::create_dir_all(&dir).expect("session dir");
    std::fs::write(dir.join("session.jsonl"), "{}\n").expect("write session");
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).expect("chmod");
    if std::fs::read_dir(&dir).is_ok() {
        return;
    }
    let (code, stdout, _stderr) = run_with(&home, &config, &["--clients", "codex"]);
    assert_eq!(code, 1, "stderr: {_stderr}");
    assert!(stdout.is_empty());
}

#[test]
#[cfg(unix)]
fn closed_stdout_exits_one() {
    use std::os::unix::io::OwnedFd;
    use std::os::unix::net::UnixStream;
    use std::process::Stdio;
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let (peer, child_end) = UnixStream::pair().expect("socket pair");
    drop(peer);
    let output = Command::new(binary())
        .args(base_args(&home, &config))
        .stdout(Stdio::from(OwnedFd::from(child_end)))
        .output()
        .expect("spawn");
    assert_eq!(output.status.code().unwrap_or(-1), 1);
}

#[test]
#[cfg(unix)]
fn unreadable_default_alternate_roots_fail_only_when_selected() {
    use std::os::unix::fs::PermissionsExt;
    for (client, root) in [
        ("codex", ".codex/archived_sessions/2026"),
        ("claude", ".claude/transcripts/nested"),
        ("opencode", ".local/share/opencode"),
        ("codex", ".config/tokens/headless/codex"),
        ("claude", "Library/Application Support/tokens/headless/claude"),
    ] {
        let home = TempDir::new().unwrap();
        let config = TempDir::new().unwrap();
        let dir = home.path().join(root);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::read_dir(&dir).is_err() {
            let (code, stdout, _) = run_with(&home, &config, &["--clients", client]);
            assert_eq!(code, 1, "selected {client}");
            assert!(stdout.is_empty());
            let other = if client == "codex" { "claude" } else { "codex" };
            assert_eq!(run_with(&home, &config, &["--clients", other]).0, 0);
        }
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
}
