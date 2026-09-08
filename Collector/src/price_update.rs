//! Independent public-price refresh (`prices refresh`).
//!
//! Fetches only the three public pricing datasets through the original
//! `tokens_core` adapters (`litellm::fetch`, `openrouter::fetch_all_mapped`,
//! `models_dev::fetch`). Those adapters write their target cache directory
//! directly and may return empty maps on failure, so downloads run against a
//! temporary isolated config directory; only validated non-empty datasets
//! are promoted into the real cache with atomic writes. Failed or empty
//! downloads leave existing cache files byte-identical.
//!
//! Never reads sessions and never sends local model usage or credentials.
//! `scan` stays fully offline; this module is the only networking path.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tokens_core::pricing::{cache, litellm, models_dev, openrouter, ModelPricing};

/// Source ids used in the refresh report, in promotion order.
pub const SOURCE_LITELLM: &str = "litellm";
pub const SOURCE_OPENROUTER: &str = "openrouter";
pub const SOURCE_MODELS_DEV: &str = "models-dev";

const FILE_LITELLM: &str = "pricing-litellm.json";
const FILE_OPENROUTER: &str = "pricing-openrouter.json";
const FILE_MODELS_DEV: &str = "pricing-models-dev.json";

/// Caller-supplied refresh parameters: the real config dir whose
/// `<config>/cache` holds the public price files.
#[derive(Debug, Clone)]
pub struct RefreshRequest {
    pub config_dir: String,
}

/// Refresh failure. `code` is the process exit code (1 or 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefreshError {
    pub code: i32,
    pub message: String,
}

impl RefreshError {
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

impl std::fmt::Display for RefreshError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for RefreshError {}

/// One source row in the refresh report.
#[derive(Debug, Clone, Serialize)]
pub struct SourceResult {
    pub source: String,
    pub status: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: Option<String>,
}

/// Non-fatal refresh note. Diagnostics carry source ids and actionable
/// text only — no paths, prompts, or credentials.
#[derive(Debug, Clone, Serialize)]
pub struct RefreshWarning {
    pub code: String,
    pub message: String,
}

/// `prices refresh` stdout document.
#[derive(Debug, Clone, Serialize)]
pub struct RefreshReport {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u8,
    #[serde(rename = "generatedAt")]
    pub generated_at: String,
    pub sources: Vec<SourceResult>,
    pub warnings: Vec<RefreshWarning>,
}

/// A single fetch outcome: `Ok` dataset or `Err` reason. Empty datasets
/// count as failures at promotion time so they never replace good caches.
pub type FetchOutcome = Result<HashMap<String, ModelPricing>, String>;

/// Offline test seam: injected per-source fetch outcomes used instead of
/// the network adapters. Production calls [`run_refresh`], which always
/// uses the live adapters; no product URL flags or test switches exist.
#[derive(Debug)]
pub struct InjectedFetches {
    pub litellm: FetchOutcome,
    pub openrouter: FetchOutcome,
    pub models_dev: FetchOutcome,
}

/// Restores the previous `TOKENS_CONFIG_DIR` on drop, covering every
/// return path while the isolated or real dir is selected.
struct ConfigDirGuard {
    saved: Option<OsString>,
}

impl ConfigDirGuard {
    fn capture() -> Self {
        Self {
            saved: std::env::var_os("TOKENS_CONFIG_DIR"),
        }
    }
}

impl Drop for ConfigDirGuard {
    fn drop(&mut self) {
        match self.saved.take() {
            Some(value) => std::env::set_var("TOKENS_CONFIG_DIR", value),
            None => std::env::remove_var("TOKENS_CONFIG_DIR"),
        }
    }
}

fn validate(request: &RefreshRequest) -> Result<String, RefreshError> {
    if request.config_dir.is_empty() || !Path::new(&request.config_dir).is_absolute() {
        return Err(RefreshError::arg("--config-dir must be an absolute path"));
    }
    if let Ok(metadata) = std::fs::metadata(&request.config_dir) {
        if !metadata.is_dir() {
            return Err(RefreshError::arg("--config-dir must be a directory"));
        }
    }
    Ok(request.config_dir.clone())
}

fn valid_rate(rate: Option<f64>) -> bool {
    rate.is_some_and(|value| value.is_finite() && value >= 0.0)
}

/// A downloaded dataset is promotable only when it is non-empty and holds
/// at least one entry with a usable input or output base rate. This is a
/// promotion gate, not pricing math: no provider conversion is duplicated.
fn dataset_is_valid(data: &HashMap<String, ModelPricing>) -> bool {
    if data.is_empty() {
        return false;
    }
    data.values().any(|pricing| {
        valid_rate(pricing.input_cost_per_token) || valid_rate(pricing.output_cost_per_token)
    })
}

fn rfc3339_utc(secs: u64) -> String {
    chrono::DateTime::from_timestamp(i64::try_from(secs).unwrap_or(0), 0)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}

struct PendingSource {
    source: &'static str,
    filename: &'static str,
    outcome: FetchOutcome,
}

/// Validate outcomes and atomically promote the good ones into the real
/// cache via the shared [`cache::save_cache`] helper (temp-file rename,
/// fresh timestamp). Failed, empty, or invalid downloads never touch the
/// real files. Returns the report plus the process exit code: 0 when every
/// source updated, 1 on any partial failure.
fn promote(config_dir: &str, pending: Vec<PendingSource>) -> (RefreshReport, i32) {
    let _guard = ConfigDirGuard::capture();
    std::env::set_var("TOKENS_CONFIG_DIR", config_dir);
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let stamp = rfc3339_utc(now_secs);
    let mut sources = Vec::with_capacity(pending.len());
    let mut warnings = Vec::new();
    let mut failed = 0u32;
    for item in pending {
        let usable = match &item.outcome {
            Ok(data) => dataset_is_valid(data),
            Err(_) => false,
        };
        let saved = if usable {
            // Safe: `usable` implies `Ok`.
            let data = item.outcome.unwrap_or_default();
            cache::save_cache(item.filename, &data).is_ok()
        } else {
            false
        };
        if saved {
            sources.push(SourceResult {
                source: item.source.to_string(),
                status: "updated".to_string(),
                updated_at: Some(stamp.clone()),
            });
        } else {
            failed += 1;
            sources.push(SourceResult {
                source: item.source.to_string(),
                status: "failed".to_string(),
                updated_at: None,
            });
            warnings.push(RefreshWarning {
                code: "PRICE_SOURCE_FAILED".to_string(),
                message: format!(
                    "{} price refresh failed; kept the previous cache",
                    item.source
                ),
            });
        }
    }
    let code = if failed > 0 { 1 } else { 0 };
    (
        RefreshReport {
            schema_version: 1,
            generated_at: stamp,
            sources,
            warnings,
        },
        code,
    )
}

/// Live refresh: stage downloads in a temporary isolated config dir, then
/// promote validated datasets into the real cache. The global config
/// selection is set once before fetching and left untouched until all
/// three adapters finish; the scoped guard restores the caller's value on
/// every return.
pub fn run_refresh(request: &RefreshRequest) -> Result<(RefreshReport, i32), RefreshError> {
    let config_dir = validate(request)?;
    let staging = tempfile::TempDir::new()
        .map_err(|err| RefreshError::fail(format!("failed to create staging dir: {err}")))?;
    let staging_path = staging
        .path()
        .to_str()
        .ok_or_else(|| RefreshError::fail("staging path is not UTF-8"))?
        .to_string();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|err| RefreshError::fail(format!("failed to start runtime: {err}")))?;
    let pending = {
        let _guard = ConfigDirGuard::capture();
        std::env::set_var("TOKENS_CONFIG_DIR", &staging_path);
        // Sequential while the staging dir is selected; the adapters read
        // the selection on each cache access, so it must not change
        // mid-flight. Network diagnostics go to stderr inside the adapters.
        let litellm = runtime.block_on(litellm::fetch()).map_err(|err| err.to_string());
        let openrouter: FetchOutcome = Ok(runtime.block_on(openrouter::fetch_all_mapped()));
        let models_dev = runtime
            .block_on(models_dev::fetch())
            .map_err(|err| err.to_string());
        vec![
            PendingSource {
                source: SOURCE_LITELLM,
                filename: FILE_LITELLM,
                outcome: litellm,
            },
            PendingSource {
                source: SOURCE_OPENROUTER,
                filename: FILE_OPENROUTER,
                outcome: openrouter,
            },
            PendingSource {
                source: SOURCE_MODELS_DEV,
                filename: FILE_MODELS_DEV,
                outcome: models_dev,
            },
        ]
    };
    Ok(promote(&config_dir, pending))
}

/// Offline refresh used by synthetic tests: identical validation and
/// atomic promotion, but the fetch outcomes are injected instead of
/// hitting the network. Never performs I/O outside the given config dir.
pub fn run_refresh_with_injected(
    request: &RefreshRequest,
    injected: InjectedFetches,
) -> Result<(RefreshReport, i32), RefreshError> {
    let config_dir = validate(request)?;
    Ok(promote(
        &config_dir,
        vec![
            PendingSource {
                source: SOURCE_LITELLM,
                filename: FILE_LITELLM,
                outcome: injected.litellm,
            },
            PendingSource {
                source: SOURCE_OPENROUTER,
                filename: FILE_OPENROUTER,
                outcome: injected.openrouter,
            },
            PendingSource {
                source: SOURCE_MODELS_DEV,
                filename: FILE_MODELS_DEV,
                outcome: injected.models_dev,
            },
        ],
    ))
}
