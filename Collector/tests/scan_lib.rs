use serial_test::serial;
use tempfile::TempDir;
use tokens_collector::{parse_clients_arg, run_scan, ScanRequest};

fn request(home: &TempDir, config: &TempDir) -> ScanRequest {
    ScanRequest {
        home: home.path().to_str().expect("home").to_string(),
        config_dir: config.path().to_str().expect("config").to_string(),
        timezone: "Asia/Shanghai".to_string(),
        since: "2026-09-01".to_string(),
        until: "2026-09-08".to_string(),
        hourly_date: "2026-09-08".to_string(),
        clients: None,
    }
}

#[test]
#[serial]
fn full_scan_path_succeeds_on_empty_home() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let snapshot = run_scan(&request(&home, &config)).expect("scan");
    assert_eq!(snapshot.schema_version, 1);
    assert_eq!(snapshot.timezone, "Asia/Shanghai");
    assert!(snapshot.daily.is_empty());
    assert!(snapshot.hourly.is_empty());
    assert_eq!(snapshot.pricing_as_of, None);
    assert!(snapshot.warnings.iter().any(|w| w.code == "PRICE_CACHE_MISSING"));
    assert!(!snapshot.sources.is_empty());
    assert!(snapshot.sources.iter().all(|s| s.status == "notFound"));
}

#[test]
#[serial]
fn scan_rejects_unknown_client_with_arg_error() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let mut req = request(&home, &config);
    req.clients = Some(vec!["nope".to_string()]);
    let err = run_scan(&req).expect_err("must fail");
    assert_eq!(err.code, 2);
}

#[test]
#[serial]
fn scan_rejects_bad_range_with_arg_error() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let mut req = request(&home, &config);
    req.since = "2026-09-08".to_string();
    req.until = "2026-09-01".to_string();
    let err = run_scan(&req).expect_err("must fail");
    assert_eq!(err.code, 2);
}

#[test]
#[serial]
fn scan_fails_when_home_is_a_file() {
    let file = tempfile::NamedTempFile::new().expect("temp file");
    let config = TempDir::new().expect("config");
    let req = ScanRequest {
        home: file.path().to_str().expect("path").to_string(),
        config_dir: config.path().to_str().expect("config").to_string(),
        timezone: "Asia/Shanghai".to_string(),
        since: "2026-09-01".to_string(),
        until: "2026-09-08".to_string(),
        hourly_date: "2026-09-08".to_string(),
        clients: None,
    };
    let err = run_scan(&req).expect_err("must fail");
    assert_eq!(err.code, 1);
}

#[test]
#[serial]
fn scan_rejects_empty_client_selection() {
    let home = TempDir::new().expect("home");
    let config = TempDir::new().expect("config");
    let mut req = request(&home, &config);
    req.clients = Some(vec![]);
    let err = run_scan(&req).expect_err("must fail");
    assert_eq!(err.code, 2);
}

#[test]
fn clients_arg_parsing() {
    assert_eq!(
        parse_clients_arg("codex, claude,codex").expect("parse"),
        vec!["codex".to_string(), "claude".to_string()]
    );
    assert_eq!(
        parse_clients_arg("CODEX").expect("parse"),
        vec!["codex".to_string()]
    );
    assert!(parse_clients_arg("zzz-unknown").is_err());
    assert!(parse_clients_arg("").is_err());
    assert!(parse_clients_arg("  , ").is_err());
}
