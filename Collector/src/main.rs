//! tokens-collector CLI: argument handling, filesystem boundaries, and JSON
//! output. All pricing/aggregation logic lives in the library so synthetic
//! inputs stay directly testable without spawning a process.

use std::io::Write as _;

use tokens_collector::{
    parse_clients_arg,
    price_update::{RefreshRequest, run_refresh},
    run_scan, ScanRequest,
};

const USAGE: &str = "usage: tokens-collector scan --home ABS --config-dir ABS --timezone IANA --since YYYY-MM-DD --until YYYY-MM-DD --hourly-date YYYY-MM-DD [--clients a,b,c]\nusage: tokens-collector prices refresh --config-dir ABS";

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let argv: Vec<String> = std::env::args().collect();
    if argv.iter().any(|arg| arg == "-h" || arg == "--help") {
        return match emit(USAGE) {
            Ok(()) => 0,
            Err(message) => {
                eprintln!("tokens-collector: {message}");
                1
            }
        };
    }
    let request = match parse_argv(&argv) {
        Ok(request) => request,
        Err(message) => {
            eprintln!("tokens-collector: {message}");
            eprintln!("{USAGE}");
            return 2;
        }
    };
    match &request {
        CollectorRequest::Scan(scan) => run_scan_command(scan),
        CollectorRequest::PricesRefresh(refresh) => run_prices_command(refresh),
    }
}

enum CollectorRequest {
    Scan(ScanRequest),
    PricesRefresh(RefreshRequest),
}

fn run_scan_command(request: &ScanRequest) -> i32 {
    match run_scan(request) {
        Ok(snapshot) => match serde_json::to_string_pretty(&snapshot) {
            Ok(document) => match emit(&document) {
                Ok(()) => 0,
                Err(message) => {
                    eprintln!("tokens-collector: {message}");
                    1
                }
            },
            Err(err) => {
                eprintln!("tokens-collector: failed to encode snapshot: {err}");
                1
            }
        },
        Err(err) => {
            eprintln!("tokens-collector: {err}");
            err.code
        }
    }
}

fn emit(document: &str) -> Result<(), String> {
    let mut out = std::io::stdout().lock();
    out.write_all(document.as_bytes())
        .and_then(|()| out.write_all(b"\n"))
        .and_then(|()| out.flush())
        .map_err(|err| format!("failed to write snapshot: {err}"))
}

fn take_value(flag: &str, rest: &mut std::vec::Vec<String>) -> Result<String, String> {
    rest.pop()
        .filter(|value| !value.starts_with("--"))
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn parse_argv(argv: &[String]) -> Result<CollectorRequest, String> {
    match argv.get(1).map(String::as_str) {
        Some("scan") => parse_scan_argv(argv).map(CollectorRequest::Scan),
        Some("prices") => parse_prices_argv(argv).map(CollectorRequest::PricesRefresh),
        _ => Err("expected the 'scan' or 'prices refresh' subcommand".to_string()),
    }
}

fn run_prices_command(request: &RefreshRequest) -> i32 {
    match run_refresh(request) {
        Ok((report, code)) => match serde_json::to_string_pretty(&report) {
            Ok(document) => match emit(&document) {
                Ok(()) => code,
                Err(message) => {
                    eprintln!("tokens-collector: {message}");
                    1
                }
            },
            Err(err) => {
                eprintln!("tokens-collector: failed to encode refresh report: {err}");
                1
            }
        },
        Err(err) => {
            eprintln!("tokens-collector: {err}");
            err.code
        }
    }
}

fn split_flag(arg: &str) -> (String, Option<String>) {
    match arg.split_once('=') {
        Some((flag, value)) if flag.starts_with("--") => {
            (flag.to_string(), Some(value.to_string()))
        }
        _ => (arg.to_string(), None),
    }
}

fn parse_prices_argv(argv: &[String]) -> Result<RefreshRequest, String> {
    if argv.get(2).is_none_or(|sub| sub != "refresh") {
        return Err("expected 'prices refresh'".to_string());
    }
    let mut config_dir: Option<String> = None;
    let mut rest: Vec<String> = argv[3..].iter().rev().cloned().collect();
    while let Some(arg) = rest.pop() {
        let (flag, inline) = split_flag(&arg);
        let mut value_of = |flag: &str| -> Result<String, String> {
            if let Some(inline) = inline.clone() {
                Ok(inline)
            } else {
                take_value(flag, &mut rest)
            }
        };
        match flag.as_str() {
            "--config-dir" => config_dir = Some(value_of("--config-dir")?),
            other if other.starts_with("--") => {
                return Err(format!("unknown option '{other}'"));
            }
            _ => return Err(format!("unexpected argument '{arg}'")),
        }
    }
    Ok(RefreshRequest {
        config_dir: config_dir.ok_or_else(|| "--config-dir is required".to_string())?,
    })
}

fn parse_scan_argv(argv: &[String]) -> Result<ScanRequest, String> {
    let mut home: Option<String> = None;
    let mut config_dir: Option<String> = None;
    let mut timezone: Option<String> = None;
    let mut since: Option<String> = None;
    let mut until: Option<String> = None;
    let mut hourly_date: Option<String> = None;
    let mut clients: Option<Vec<String>> = None;

    // Reverse so `pop` yields arguments in order; `--flag value` pairs are
    // reassembled by pushing the value back when a bare flag is seen.
    let mut rest: Vec<String> = argv[2..].iter().rev().cloned().collect();
    while let Some(arg) = rest.pop() {
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => {
                (flag.to_string(), Some(value.to_string()))
            }
            _ => (arg.clone(), None),
        };
        let mut value_of = |flag: &str| -> Result<String, String> {
            if let Some(inline) = inline.clone() {
                Ok(inline)
            } else {
                take_value(flag, &mut rest)
            }
        };
        match flag.as_str() {
            "--home" => home = Some(value_of("--home")?),
            "--config-dir" => config_dir = Some(value_of("--config-dir")?),
            "--timezone" => timezone = Some(value_of("--timezone")?),
            "--since" => since = Some(value_of("--since")?),
            "--until" => until = Some(value_of("--until")?),
            "--hourly-date" => hourly_date = Some(value_of("--hourly-date")?),
            "--clients" => {
                let raw = value_of("--clients")?;
                clients = Some(parse_clients_arg(&raw).map_err(|err| err.message)?);
            }
            other if other.starts_with("--") => {
                return Err(format!("unknown option '{other}'"));
            }
            _ => return Err(format!("unexpected argument '{arg}'")),
        }
    }

    Ok(ScanRequest {
        home: home.ok_or_else(|| "--home is required".to_string())?,
        config_dir: config_dir.ok_or_else(|| "--config-dir is required".to_string())?,
        timezone: timezone.ok_or_else(|| "--timezone is required".to_string())?,
        since: since.ok_or_else(|| "--since is required".to_string())?,
        until: until.ok_or_else(|| "--until is required".to_string())?,
        hourly_date: hourly_date.ok_or_else(|| "--hourly-date is required".to_string())?,
        clients,
    })
}
