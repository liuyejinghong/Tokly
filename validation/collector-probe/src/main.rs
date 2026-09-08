use std::env;
use std::path::PathBuf;
use std::time::Instant;

use tokens_core::bucket_tz::{parse_bucket_timezone, set_bucket_timezone};
use tokens_core::{generate_graph, ReportOptions};

fn usage() -> &'static str {
    "usage: collector-probe --home <ABS> [--clients <a,b,c>] [--today] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--timezone <TZ>] --output <ABS>"
}

fn fail(msg: &str) -> ! {
    eprintln!("collector-probe: error: {msg}");
    eprintln!("{}", usage());
    std::process::exit(2);
}

fn parse_args() -> (
    String,
    Vec<String>,
    bool,
    Option<String>,
    Option<String>,
    String,
    PathBuf,
) {
    let mut home: Option<String> = None;
    let mut clients: Option<String> = None;
    let mut today = false;
    let mut since: Option<String> = None;
    let mut until: Option<String> = None;
    let mut timezone: Option<String> = None;
    let mut output: Option<String> = None;

    let mut it = env::args().skip(1).peekable();
    while let Some(arg) = it.next() {
        if let Some((k, v)) = arg.split_once('=') {
            match k {
                "--home" => home = Some(v.to_string()),
                "--clients" => clients = Some(v.to_string()),
                "--since" => since = Some(v.to_string()),
                "--until" => until = Some(v.to_string()),
                "--timezone" => timezone = Some(v.to_string()),
                "--output" => output = Some(v.to_string()),
                "--today" => fail("--today takes no value"),
                _ => fail(&format!("unknown argument: {arg}")),
            }
            continue;
        }
        match arg.as_str() {
            "--today" => today = true,
            "--home" | "--clients" | "--since" | "--until" | "--timezone" | "--output" => {
                let val = it.next().unwrap_or_else(|| fail(&format!("{arg} requires a value")));
                match arg.as_str() {
                    "--home" => home = Some(val),
                    "--clients" => clients = Some(val),
                    "--since" => since = Some(val),
                    "--until" => until = Some(val),
                    "--timezone" => timezone = Some(val),
                    "--output" => output = Some(val),
                    _ => unreachable!(),
                }
            }
            _ => fail(&format!("unknown argument: {arg}")),
        }
    }

    let home = home.unwrap_or_else(|| fail("--home <ABS> is required"));
    let output = output.unwrap_or_else(|| fail("--output <ABS> is required"));
    if !PathBuf::from(&home).is_absolute() {
        fail("--home must be an absolute path");
    }
    let output_path = PathBuf::from(&output);
    if !output_path.is_absolute() {
        fail("--output must be an absolute path");
    }

    let client_list: Vec<String> = clients
        .unwrap_or_else(|| "codex,claude,opencode".to_string())
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let timezone = timezone.unwrap_or_else(|| "Asia/Shanghai".to_string());

    (
        home,
        client_list,
        today,
        since,
        until,
        timezone,
        output_path,
    )
}

fn require_isolated_config_dir() -> PathBuf {
    let dir = env::var("TOKENS_CONFIG_DIR").unwrap_or_else(|_| {
        eprintln!("collector-probe: error: TOKENS_CONFIG_DIR must be set to an absolute path (refusing to write to user default cache)");
        std::process::exit(2);
    });
    let p = PathBuf::from(&dir);
    if !p.is_absolute() {
        eprintln!("collector-probe: error: TOKENS_CONFIG_DIR must be an absolute path");
        std::process::exit(2);
    }
    p
}

#[tokio::main]
async fn main() {
    let (home, clients, today_only, since, until, timezone, output) = parse_args();
    let _config_dir = require_isolated_config_dir();

    let bucket = match parse_bucket_timezone(&timezone) {
        Some(b) => b,
        None => {
            eprintln!("collector-probe: error: unknown timezone: {timezone}");
            std::process::exit(2);
        }
    };
    set_bucket_timezone(bucket);

    let started = Instant::now();
    let opts = ReportOptions {
        home_dir: Some(home),
        clients: Some(clients),
        today_only,
        since,
        until,
        use_env_roots: false,
        ..Default::default()
    };

    let graph = match generate_graph(opts).await {
        Ok(g) => g,
        Err(e) => {
            eprintln!("collector-probe: error: generate_graph failed: {e}");
            std::process::exit(1);
        }
    };

    let elapsed_ms = started.elapsed().as_millis() as u64;

    let graph_value = match serde_json::to_value(&graph) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("collector-probe: error: graph is not JSON-serializable: {e:#}");
            std::process::exit(1);
        }
    };

    let pretty = serde_json::to_string(&graph_value).unwrap_or_else(|e| {
        eprintln!("collector-probe: error: failed to serialize graph JSON: {e:#}");
        std::process::exit(1);
    });
    if let Err(e) = std::fs::write(&output, &pretty) {
        eprintln!(
            "collector-probe: error: failed to write output {}: {e:#}",
            output.display()
        );
        std::process::exit(1);
    }

    let summary = serde_json::json!({
        "elapsedMs": elapsed_ms,
        "totalTokens": graph.summary.total_tokens,
        "totalCost": graph.summary.total_cost,
        "totalDays": graph.summary.total_days,
        "activeDays": graph.summary.active_days,
        "contributionDays": graph.contributions.len(),
    });
    println!("{}", serde_json::to_string(&summary).unwrap_or_default());
}
