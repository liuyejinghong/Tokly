//! Offline scan → cached-price estimation → protocol v1 snapshot.
//!
//! Buckets derive from each message's record timestamp in the requested IANA
//! timezone; per-message pricing gates on lookup completeness before calling
//! `calculate_cost_with_provider` (`UnifiedMessage.cost` is never used).
//! Only existing local price caches are read; `TOKENS_CONFIG_DIR` is pinned
//! to the caller config dir. Diagnostics carry client ids and actionable
//! text only — no message text, titles, workspace paths, or file paths.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use tokens_core::pricing::{ModelPricing, PricingService};
use tokens_core::{
    canonical_model_id, collect_messages, parse_bucket_timezone,
    scan_all_clients_with_scanner_settings, set_bucket_timezone, BucketTimezone, ClientId,
    ReportOptions, ScanResult, ScannerSettings, UnifiedMessage,
};

pub mod price_update;

/// Warning codes surfaced in the snapshot `warnings` array.
pub const WARN_PRICE_CACHE_STALE: &str = "PRICE_CACHE_STALE";
pub const WARN_PRICE_CACHE_MISSING: &str = "PRICE_CACHE_MISSING";
pub const WARN_PRICE_CACHE_UNREADABLE: &str = "PRICE_CACHE_UNREADABLE";

const PRICE_CACHE_FILES: [&str; 3] = [
    "pricing-litellm.json",
    "pricing-openrouter.json",
    "pricing-models-dev.json",
];
const PRICE_CACHE_TTL_SECS: u64 = 3600;

/// Exit-code-carrying scan failure. `code` is the process exit code (1 or 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanError {
    pub code: i32,
    pub message: String,
}

impl ScanError {
    fn arg(message: impl Into<String>) -> Self {
        Self {
            code: 2,
            message: message.into(),
        }
    }

    fn fail(message: impl Into<String>) -> Self {
        Self {
            code: 1,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ScanError {}

/// Caller-supplied scan parameters. Mirrors the protocol CLI surface:
/// explicit home/config/timezone/since/until/hourly-date plus optional
/// selected clients (`None` = the full upstream registry).
#[derive(Debug, Clone)]
pub struct ScanRequest {
    pub home: String,
    pub config_dir: String,
    pub timezone: String,
    pub since: String,
    pub until: String,
    pub hourly_date: String,
    pub clients: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TokensOut {
    pub input: i64,
    pub output: i64,
    #[serde(rename = "cacheRead")]
    pub cache_read: i64,
    #[serde(rename = "cacheWrite")]
    pub cache_write: i64,
    pub reasoning: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct EstimatedCost {
    #[serde(rename = "amountUsd")]
    pub amount_usd: Option<f64>,
    pub complete: bool,
    #[serde(rename = "unpricedTokens")]
    pub unpriced_tokens: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelUsage {
    #[serde(rename = "modelId")]
    pub model_id: String,
    pub tokens: TokensOut,
    #[serde(rename = "estimatedCost")]
    pub estimated_cost: EstimatedCost,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClientUsage {
    #[serde(rename = "clientId")]
    pub client_id: String,
    pub models: Vec<ModelUsage>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DayBucket {
    pub date: String,
    pub clients: Vec<ClientUsage>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HourBucket {
    pub hour: u8,
    pub clients: Vec<ClientUsage>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SourceStatus {
    #[serde(rename = "clientId")]
    pub client_id: String,
    pub status: String,
    #[serde(rename = "sourceCount")]
    pub source_count: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Warning {
    pub code: String,
    #[serde(rename = "clientId")]
    pub client_id: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RangeOut {
    pub since: String,
    pub until: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u8,
    #[serde(rename = "generatedAt")]
    pub generated_at: String,
    pub timezone: String,
    pub range: RangeOut,
    #[serde(rename = "hourlyDate")]
    pub hourly_date: String,
    #[serde(rename = "pricingAsOf")]
    pub pricing_as_of: Option<String>,
    pub daily: Vec<DayBucket>,
    pub hourly: Vec<HourBucket>,
    pub sources: Vec<SourceStatus>,
    pub warnings: Vec<Warning>,
}

struct Validated {
    home: String,
    config_dir: String,
    bucket_tz: BucketTimezone,
    timezone: String,
    since: String,
    until: String,
    hourly_date: String,
    clients: Option<Vec<String>>,
}

/// Split and validate a `--clients a,b,c` value. Unknown names are errors.
pub fn parse_clients_arg(raw: &str) -> Result<Vec<String>, ScanError> {
    let mut out: Vec<String> = Vec::new();
    for part in raw.split(',') {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        let lower = trimmed.to_lowercase();
        let canonical =
            if ClientId::from_str(&lower).is_some() || lower == "synthetic" || lower == "9router" {
                lower
            } else {
                return Err(ScanError::arg(format!("unknown client '{trimmed}'")));
            };
        if !out.contains(&canonical) {
            out.push(canonical);
        }
    }
    if out.is_empty() {
        return Err(ScanError::arg(
            "--clients must name at least one client",
        ));
    }
    Ok(out)
}

fn parse_day(raw: &str) -> Option<NaiveDate> {
    let trimmed = raw.trim();
    let date = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d").ok()?;
    if date.format("%Y-%m-%d").to_string() == trimmed {
        Some(date)
    } else {
        None
    }
}

fn validate_request(request: &ScanRequest) -> Result<Validated, ScanError> {
    if request.home.is_empty() || !Path::new(&request.home).is_absolute() {
        return Err(ScanError::arg("--home must be an absolute path"));
    }
    if request.config_dir.is_empty() || !Path::new(&request.config_dir).is_absolute() {
        return Err(ScanError::arg("--config-dir must be an absolute path"));
    }
    if let Ok(metadata) = std::fs::metadata(&request.config_dir) {
        if !metadata.is_dir() {
            return Err(ScanError::arg("--config-dir must be a directory"));
        }
    }
    let timezone = request.timezone.trim().to_string();
    let bucket_tz = parse_bucket_timezone(&timezone)
        .ok_or_else(|| ScanError::arg("--timezone must be a known IANA name"))?;
    let since = parse_day(&request.since)
        .ok_or_else(|| ScanError::arg("--since must be YYYY-MM-DD"))?;
    let until = parse_day(&request.until)
        .ok_or_else(|| ScanError::arg("--until must be YYYY-MM-DD"))?;
    let hourly_date = parse_day(&request.hourly_date)
        .ok_or_else(|| ScanError::arg("--hourly-date must be YYYY-MM-DD"))?;
    if since > until {
        return Err(ScanError::arg("--since must not be after --until"));
    }
    if hourly_date < since || hourly_date > until {
        return Err(ScanError::arg(
            "--hourly-date must satisfy since <= hourly-date <= until",
        ));
    }
    let clients = match &request.clients {
        Some(selected) => {
            if selected.is_empty() {
                return Err(ScanError::arg("--clients must name at least one client"));
            }
            let mut normalized = Vec::with_capacity(selected.len());
            for name in selected {
                let lower = name.to_lowercase();
                let known = ClientId::from_str(&lower).is_some()
                    || lower == "synthetic"
                    || lower == "9router";
                if !known {
                    return Err(ScanError::arg(format!("unknown client '{name}'")));
                }
                if !normalized.contains(&lower) {
                    normalized.push(lower);
                }
            }
            Some(normalized)
        }
        None => None,
    };
    Ok(Validated {
        home: request.home.clone(),
        config_dir: request.config_dir.clone(),
        bucket_tz,
        timezone,
        since: since.format("%Y-%m-%d").to_string(),
        until: until.format("%Y-%m-%d").to_string(),
        hourly_date: hourly_date.format("%Y-%m-%d").to_string(),
        clients,
    })
}

fn ensure_home_readable(home: &str) -> Result<(), ScanError> {
    let path = Path::new(home);
    let metadata =
        std::fs::metadata(path).map_err(|_| ScanError::fail("scan home is not accessible"))?;
    if !metadata.is_dir() {
        return Err(ScanError::fail("scan home is not a directory"));
    }
    std::fs::read_dir(path)
        .map(|_| ())
        .map_err(|_| ScanError::fail("scan home is not readable"))?;
    Ok(())
}

/// Readability probe over discovered files/DBs. Vanished paths are ignored;
/// anything else that cannot be opened fails instead of reading as zero.
fn ensure_discovered_readable(scan: &ScanResult, clients: &[String]) -> Result<(), ScanError> {
    for client in clients {
        for path in discovered_paths_for_name(scan, client) {
            if let Err(err) = std::fs::File::open(&path) {
                if err.kind() == std::io::ErrorKind::NotFound {
                    continue;
                }
                return Err(ScanError::fail(
                    "a discovered source is not readable; keeping the previous snapshot",
                ));
            }
        }
    }
    Ok(())
}

fn discovered_paths_for_name(scan: &ScanResult, client: &str) -> Vec<PathBuf> {
    if client == "synthetic" {
        return scan.synthetic_db.iter().cloned().collect();
    }
    let id = if client == "9router" {
        ClientId::from_str("gjc")
    } else {
        ClientId::from_str(client)
    };
    id.map_or(Vec::new(), |id| discovered_paths(scan, id))
}

/// Probe primary roots and the verified clients' built-in alternate roots, including
/// nested directory traversal. Absent paths mean `notFound`; anything else
/// unreadable fails. Symlinked dirs are not descended and regular files are
/// never opened here (discovered-file checks cover those).
fn ensure_sources_readable(home: &str, clients: &[String]) -> Result<(), ScanError> {
    let enabled = clients.iter().filter_map(|id| ClientId::from_str(id)).collect();
    let mut roots: Vec<PathBuf> = clients.iter()
        .filter_map(|client| primary_source_path(home, client)).collect();
    roots.extend(tokens_core::scanner::built_in_extra_scan_paths_for(home, &enabled)
        .into_iter().map(|(_, path)| path));
    for client in clients {
        match client.as_str() {
            "codex" => roots.push(Path::new(home).join(".codex/archived_sessions")),
            "claude" => roots.push(Path::new(home).join(".cc-mirror")),
            "opencode" => roots.push(Path::new(home).join(".local/share/opencode")),
            _ => {}
        }
        if matches!(client.as_str(), "codex" | "claude" | "opencode") {
            roots.extend(tokens_core::scanner::headless_roots_with_env_strategy(home, false)
                .into_iter().map(|root| root.join(client)));
        }
    }
    roots.sort();
    roots.dedup();
    for path in roots {
        match std::fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(unreadable_source()),
        }
        let is_dir = match std::fs::metadata(&path) {
            Ok(metadata) => metadata.is_dir(),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(unreadable_source()),
        };
        if !is_dir {
            if std::fs::File::open(&path).is_err() {
                return Err(unreadable_source());
            }
            continue;
        }
        if std::fs::read_dir(&path).is_err() {
            return Err(unreadable_source());
        }
        ensure_tree_traversable(&path)?;
    }
    Ok(())
}

fn unreadable_source() -> ScanError {
    ScanError::fail("a discovered source is not readable; keeping the previous snapshot")
}

fn ensure_tree_traversable(root: &Path) -> Result<(), ScanError> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(unreadable_source()),
        };
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => return Err(unreadable_source()),
            };
            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => return Err(unreadable_source()),
            };
            if file_type.is_dir() {
                pending.push(entry.path());
            }
        }
    }
    Ok(())
}

fn primary_source_path(home: &str, client: &str) -> Option<PathBuf> {
    let id = if client == "9router" {
        ClientId::from_str("gjc")?
    } else {
        ClientId::from_str(client)?
    };
    Some(PathBuf::from(
        id.data().resolve_path_with_env_strategy(home, false),
    ))
}

#[derive(Deserialize)]
struct CachedPriceFile {
    timestamp: u64,
    #[allow(dead_code)]
    data: HashMap<String, ModelPricing>,
}

fn rfc3339_utc(secs: u64) -> Option<String> {
    let stamp = i64::try_from(secs).ok()?;
    chrono::DateTime::from_timestamp(stamp, 0)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

/// Price-cache time from the isolated config dir. Only files that decode as
/// the loader's `CachedData<HashMap<String, ModelPricing>>` with a
/// non-future timestamp count; the reported time is the oldest usable one.
fn price_cache_meta(config_dir: &str) -> (Option<String>, Vec<Warning>) {
    let cache_dir = Path::new(config_dir).join("cache");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut oldest: Option<u64> = None;
    let mut present = false;
    let mut rejected = false;
    for filename in PRICE_CACHE_FILES {
        let content = match std::fs::read_to_string(cache_dir.join(filename)) {
            Ok(content) => content,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                rejected = true;
                continue;
            }
        };
        present = true;
        match serde_json::from_str::<CachedPriceFile>(&content)
            .ok()
            .filter(|file| file.timestamp <= now)
            .map(|file| file.timestamp)
        {
            Some(stamp) => oldest = Some(oldest.map_or(stamp, |best| best.min(stamp))),
            None => rejected = true,
        }
    }

    let mut warnings = Vec::new();
    if rejected {
        warnings.push(Warning {
            code: WARN_PRICE_CACHE_UNREADABLE.to_string(),
            client_id: None,
            message: "a cached pricing file was unreadable or invalid; costs may be incomplete"
                .to_string(),
        });
    }
    if !present {
        warnings.push(Warning {
            code: WARN_PRICE_CACHE_MISSING.to_string(),
            client_id: None,
            message: "no cached pricing available; costs are reported as unknown".to_string(),
        });
    }
    if let Some(stamp) = oldest {
        if now.saturating_sub(stamp) > PRICE_CACHE_TTL_SECS {
            warnings.push(Warning {
                code: WARN_PRICE_CACHE_STALE.to_string(),
                client_id: None,
                message: "cached pricing is older than one hour; costs still use the cache"
                    .to_string(),
            });
        }
    }
    (oldest.and_then(rfc3339_utc), warnings)
}

fn valid_rate(rate: Option<f64>) -> bool {
    rate.is_some_and(|value| value.is_finite() && value >= 0.0)
}

fn provider_hint(message: &UnifiedMessage) -> Option<&str> {
    if message.provider_id.trim().is_empty() {
        None
    } else {
        Some(message.provider_id.as_str())
    }
}

/// Price one normalized message. `None` means the whole event is unpriced:
/// no lookup hit, or a nonzero token category without a valid finite
/// nonnegative base rate. Zero-volume events price at 0.0. The source
/// billing amount (`UnifiedMessage.cost`) is never consulted.
fn price_message(message: &UnifiedMessage, pricing: Option<&PricingService>) -> Option<f64> {
    let zero_volume = message.tokens.input <= 0
        && message.tokens.output <= 0
        && message.tokens.cache_read <= 0
        && message.tokens.cache_write <= 0
        && message.tokens.reasoning <= 0;
    if zero_volume {
        return Some(0.0);
    }
    let pricing = pricing?;
    let provider = provider_hint(message);
    let lookup = pricing.lookup_with_source_and_provider(&message.model_id, None, provider)?;
    let rates = &lookup.pricing;
    if message.tokens.input > 0 && !valid_rate(rates.input_cost_per_token) {
        return None;
    }
    if (message.tokens.output > 0 || message.tokens.reasoning > 0)
        && !valid_rate(rates.output_cost_per_token)
    {
        return None;
    }
    if message.tokens.cache_read > 0 && !valid_rate(rates.cache_read_input_token_cost) {
        return None;
    }
    if message.tokens.cache_write > 0 && !valid_rate(rates.cache_creation_input_token_cost) {
        return None;
    }
    let cost = pricing.calculate_cost_with_provider(&message.model_id, provider, &message.tokens);
    if cost.is_finite() && cost >= 0.0 {
        Some(cost)
    } else {
        None
    }
}

#[derive(Debug, Clone)]
struct BucketAcc {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
    priced_sum: f64,
    priced_events: u64,
    complete: bool,
    unpriced_tokens: i64,
    has_volume: bool,
}

impl Default for BucketAcc {
    fn default() -> Self {
        Self {
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            reasoning: 0,
            priced_sum: 0.0,
            priced_events: 0,
            complete: true,
            unpriced_tokens: 0,
            has_volume: false,
        }
    }
}

impl BucketAcc {
    fn add(&mut self, message: &UnifiedMessage, priced: Option<f64>) {
        self.input = self.input.saturating_add(message.tokens.input);
        self.output = self.output.saturating_add(message.tokens.output);
        self.cache_read = self
            .cache_read
            .saturating_add(message.tokens.cache_read);
        self.cache_write = self
            .cache_write
            .saturating_add(message.tokens.cache_write);
        self.reasoning = self.reasoning.saturating_add(message.tokens.reasoning);
        let volume = message.tokens.input != 0
            || message.tokens.output != 0
            || message.tokens.cache_read != 0
            || message.tokens.cache_write != 0
            || message.tokens.reasoning != 0;
        if volume {
            self.has_volume = true;
        }
        match priced {
            Some(cost) if volume => {
                self.priced_sum += cost;
                self.priced_events += 1;
            }
            Some(_) => {}
            None => {
                self.complete = false;
                self.unpriced_tokens = self
                    .unpriced_tokens
                    .saturating_add(message.tokens.total().max(0));
            }
        }
    }

    fn estimated_cost(&self) -> EstimatedCost {
        if !self.has_volume {
            return EstimatedCost {
                amount_usd: Some(0.0),
                complete: true,
                unpriced_tokens: 0,
            };
        }
        let amount_usd = if self.priced_events > 0 {
            Some(self.priced_sum)
        } else {
            None
        };
        EstimatedCost {
            amount_usd,
            complete: self.complete,
            unpriced_tokens: self.unpriced_tokens,
        }
    }

    fn model_usage(&self, model_id: String) -> ModelUsage {
        ModelUsage {
            model_id,
            tokens: TokensOut {
                input: self.input,
                output: self.output,
                cache_read: self.cache_read,
                cache_write: self.cache_write,
                reasoning: self.reasoning,
            },
            estimated_cost: self.estimated_cost(),
        }
    }
}

fn hour_of(bucket_tz: BucketTimezone, timestamp_ms: i64) -> Option<u8> {
    let stamped = bucket_tz.date_hour_of_ms(timestamp_ms)?;
    let hour_part = stamped.split(' ').nth(1)?;
    hour_part
        .split(':')
        .next()?
        .parse::<u8>()
        .ok()
        .filter(|hour| *hour < 24)
}

/// Testable aggregation path: bucket synthetic or collected messages with an
/// explicit pricing service. Returns sorted daily buckets (date ascending)
/// and hourly buckets for `hourly_date` (hour ascending). Only dates inside
/// `[since, until]` are kept; only `hourly_date` rows enter hourly buckets.
pub fn aggregate_messages(
    messages: &[UnifiedMessage],
    pricing: Option<&PricingService>,
    bucket_tz: BucketTimezone,
    since: &str,
    until: &str,
    hourly_date: &str,
) -> (Vec<DayBucket>, Vec<HourBucket>) {
    let mut daily: BTreeMap<(String, String, String), BucketAcc> = BTreeMap::new();
    let mut hourly: BTreeMap<(u8, String, String), BucketAcc> = BTreeMap::new();
    for message in messages {
        let date = bucket_tz.date_of_ms(message.timestamp);
        if date.is_empty() || date.as_str() < since || date.as_str() > until {
            continue;
        }
        let model_id = canonical_model_id(&message.model_id);
        let priced = price_message(message, pricing);
        daily
            .entry((date.clone(), message.client.clone(), model_id.clone()))
            .or_default()
            .add(message, priced);
        if date.as_str() == hourly_date {
            if let Some(hour) = hour_of(bucket_tz, message.timestamp) {
                hourly
                    .entry((hour, message.client.clone(), model_id))
                    .or_default()
                    .add(message, priced);
            }
        }
    }
    (into_day_buckets(daily), into_hour_buckets(hourly))
}

fn into_day_buckets(grouped: BTreeMap<(String, String, String), BucketAcc>) -> Vec<DayBucket> {
    let mut days: Vec<DayBucket> = Vec::new();
    for ((date, client_id, model_id), acc) in grouped {
        if days.last().is_none_or(|day: &DayBucket| day.date != date) {
            days.push(DayBucket {
                date: date.clone(),
                clients: Vec::new(),
            });
        }
        let day = days.last_mut().expect("day bucket exists");
        if day
            .clients
            .last()
            .is_none_or(|client| client.client_id != client_id)
        {
            day.clients.push(ClientUsage {
                client_id: client_id.clone(),
                models: Vec::new(),
            });
        }
        let client = day.clients.last_mut().expect("client bucket exists");
        client.models.push(acc.model_usage(model_id));
    }
    days
}

fn into_hour_buckets(grouped: BTreeMap<(u8, String, String), BucketAcc>) -> Vec<HourBucket> {
    let mut hours: Vec<HourBucket> = Vec::new();
    for ((hour, client_id, model_id), acc) in grouped {
        if hours.last().is_none_or(|bucket: &HourBucket| bucket.hour != hour) {
            hours.push(HourBucket {
                hour,
                clients: Vec::new(),
            });
        }
        let bucket = hours.last_mut().expect("hour bucket exists");
        if bucket
            .clients
            .last()
            .is_none_or(|client| client.client_id != client_id)
        {
            bucket.clients.push(ClientUsage {
                client_id: client_id.clone(),
                models: Vec::new(),
            });
        }
        let client = bucket.clients.last_mut().expect("client bucket exists");
        client.models.push(acc.model_usage(model_id));
    }
    hours
}

fn default_client_ids() -> Vec<String> {
    let mut ids: Vec<String> = ClientId::ALL
        .iter()
        .map(|client| client.as_str().to_string())
        .collect();
    ids.push("synthetic".to_string());
    ids.sort();
    ids
}

/// Every discovered file/DB backing one client: transcript buckets plus the
/// client's SQLite/special sources. Shared by statuses and readability.
fn discovered_paths(scan: &ScanResult, client: ClientId) -> Vec<PathBuf> {
    if client == ClientId::Hermes {
        return scan.hermes_db_paths();
    }
    if client == ClientId::Zed {
        return scan.zed_db_paths();
    }
    let mut paths: Vec<PathBuf> = scan.get(client).clone();
    match client {
        ClientId::OpenCode => paths.extend(scan.opencode_dbs.iter().cloned()),
        ClientId::MiMoCode => paths.extend(scan.micode_dbs.iter().cloned()),
        ClientId::Copilot => {
            paths.extend(scan.copilot_desktop_db.iter().cloned());
            paths.extend(scan.copilot_vscode_sessions.iter().cloned());
        }
        ClientId::Goose => paths.extend(scan.goose_db.iter().cloned()),
        ClientId::Kiro => paths.extend(scan.kiro_db.iter().cloned()),
        ClientId::Kilo => paths.extend(scan.kilo_db.iter().cloned()),
        ClientId::Crush => paths.extend(scan.crush_dbs.iter().map(|source| source.db_path.clone())),
        ClientId::Zcode => paths.extend(scan.zcode_db.iter().cloned()),
        ClientId::DevinCli => paths.extend(scan.devin_dbs.iter().cloned()),
        _ => {}
    }
    paths
}

fn source_count_for(scan: &ScanResult, client: ClientId) -> u64 {
    discovered_paths(scan, client).len() as u64
}

fn build_sources(effective: &[String], scan: &ScanResult) -> Vec<SourceStatus> {
    effective
        .iter()
        .map(|client| {
            let count = if client == "synthetic" {
                u64::from(scan.synthetic_db.is_some())
            } else if client == "9router" {
                ClientId::from_str("gjc").map_or(0, |id| source_count_for(scan, id))
            } else {
                ClientId::from_str(client).map_or(0, |id| source_count_for(scan, id))
            };
            SourceStatus {
                client_id: client.clone(),
                status: if count > 0 { "found" } else { "notFound" }.to_string(),
                source_count: count,
            }
        })
        .collect()
}

/// Full scan path: validate, isolate caches, collect with the original
/// parsers (`today_only=false`, `use_env_roots=false`), price from existing
/// caches only, aggregate into a protocol v1 snapshot.
pub fn run_scan(request: &ScanRequest) -> Result<Snapshot, ScanError> {
    let valid = validate_request(request)?;
    std::env::set_var("TOKENS_CONFIG_DIR", &valid.config_dir);
    set_bucket_timezone(valid.bucket_tz);
    ensure_home_readable(&valid.home)?;

    let effective = match &valid.clients {
        Some(selected) => {
            let mut sorted = selected.clone();
            sorted.sort();
            sorted
        }
        None => default_client_ids(),
    };
    ensure_sources_readable(&valid.home, &effective)?;

    // One selected discovery backs statuses and the nested readability probe.
    // An empty client list scans the full registry, covering both cases.
    let scan = scan_all_clients_with_scanner_settings(
        &valid.home,
        valid.clients.as_deref().unwrap_or(&[]),
        false,
        &ScannerSettings::default(),
    );
    ensure_discovered_readable(&scan, &effective)?;

    let pricing = PricingService::load_cached_any_age();
    let (pricing_as_of, warnings) = price_cache_meta(&valid.config_dir);

    let options = ReportOptions {
        home_dir: Some(valid.home.clone()),
        use_env_roots: false,
        clients: valid.clients.clone(),
        since: Some(valid.since.clone()),
        until: Some(valid.until.clone()),
        today_only: false,
        ..Default::default()
    };
    let messages =
        collect_messages(&options, pricing.as_ref()).map_err(ScanError::fail)?;

    let sources = build_sources(&effective, &scan);
    let (daily, hourly) = aggregate_messages(
        &messages,
        pricing.as_ref(),
        valid.bucket_tz,
        &valid.since,
        &valid.until,
        &valid.hourly_date,
    );

    Ok(Snapshot {
        schema_version: 1,
        generated_at: Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        timezone: valid.timezone,
        range: RangeOut {
            since: valid.since,
            until: valid.until,
        },
        hourly_date: valid.hourly_date,
        pricing_as_of,
        daily,
        hourly,
        sources,
        warnings,
    })
}
