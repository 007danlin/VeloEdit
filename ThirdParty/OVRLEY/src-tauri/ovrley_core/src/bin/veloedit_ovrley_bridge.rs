//! VeloEdit's local process bridge to the vendored OVRLEY Rust core.
//!
//! The bridge deliberately keeps the upstream JSON contract intact. VeloEdit
//! launches this executable locally, decodes `ParsedActivity`, and continues
//! editing in its native Swift timeline. No telemetry or media leaves the Mac.

use ovrley_core::activity::finalize::FinalizeActivityResponse;
use ovrley_core::activity::{build_dense_activity_report_validated, parse_activity_json};
use ovrley_core::normalize::{parse_template_json, validate_render_config};
use ovrley_core::paths::AppPaths;
use ovrley_core::render::render_preview_to_path;
use ovrley_core::render::{
    prepare_preview_assets, render_preview_with_prepared_assets, LabelCacheStatus,
    PreparedPreviewAssets, PreviewRenderRequest,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

#[derive(Serialize)]
struct BridgeResponse<T: Serialize> {
    ok: bool,
    engine: &'static str,
    upstream_revision: &'static str,
    result: Option<T>,
    error: Option<String>,
}

fn main() {
    if let Err(error) = run() {
        let response = BridgeResponse::<serde_json::Value> {
            ok: false,
            engine: "OVRLEY",
            upstream_revision: "0db9be5f775c6e3716407f4a37175c916b8065f1",
            result: None,
            error: Some(error),
        };
        println!("{}", serde_json::to_string(&response).unwrap_or_else(|_| "{\"ok\":false}".into()));
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    let command = args.get(1).map(String::as_str).unwrap_or("health");
    match command {
        "health" => write_success(json!({
            "ready": true,
            "license": "GPL-3.0-or-later",
            "transport": "local-json-process"
        })),
        "parse" => {
            let input = required_arg("--input", &args)?;
            let repo_root = optional_arg("--resource-root", &args)
                .map(PathBuf::from)
                .unwrap_or_else(compiled_repo_root);
            let response = parse_activity(Path::new(&input), &repo_root)?;
            write_success(response)
        }
        "render-frame" => {
            let payload = PathBuf::from(required_arg("--payload", &args)?);
            let config = PathBuf::from(required_arg("--config", &args)?);
            let output = PathBuf::from(required_arg("--out", &args)?);
            let second = required_arg("--second", &args)?
                .parse::<f64>()
                .map_err(|error| format!("Invalid --second: {error}"))?;
            let repo_root = optional_arg("--resource-root", &args)
                .map(PathBuf::from)
                .unwrap_or_else(compiled_repo_root);
            render_frame(&payload, &config, &output, second, &repo_root)?;
            write_success(json!({ "path": output, "second": second }))
        }
        "render-server" => {
            let repo_root = optional_arg("--resource-root", &args)
                .map(PathBuf::from)
                .unwrap_or_else(compiled_repo_root);
            render_server(&repo_root)
        }
        _ => Err(format!("Unknown bridge command: {command}")),
    }
}

#[derive(Deserialize)]
struct RenderServerRequest {
    session_id: String,
    payload_path: Option<PathBuf>,
    config_path: Option<PathBuf>,
    out_path: PathBuf,
    second: f64,
}

struct RenderSession {
    dense: ovrley_core::activity::schema::DenseActivityReport,
    prepared: PreparedPreviewAssets,
}

fn render_server(repo_root: &Path) -> Result<(), String> {
    let paths = AppPaths::from_repo_root(repo_root.to_path_buf());
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let mut sessions: HashMap<String, RenderSession> = HashMap::new();
    for line in stdin.lock().lines() {
        let response = match line {
            Ok(line) => render_server_request(&line, &paths, &mut sessions),
            Err(error) => Err(format!("Failed to read render request: {error}")),
        };
        let value = match response {
            Ok(result) => json!({ "ok": true, "result": result }),
            Err(error) => json!({ "ok": false, "error": error }),
        };
        writeln!(stdout, "{}", serde_json::to_string(&value).map_err(|e| e.to_string())?)
            .map_err(|error| error.to_string())?;
        stdout.flush().map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn render_server_request(
    line: &str,
    paths: &AppPaths,
    sessions: &mut HashMap<String, RenderSession>,
) -> Result<serde_json::Value, String> {
    let request: RenderServerRequest =
        serde_json::from_str(line).map_err(|error| format!("Invalid render request: {error}"))?;
    if !sessions.contains_key(&request.session_id) {
        let payload_path = request
            .payload_path
            .as_deref()
            .ok_or_else(|| "New render session requires payload_path".to_string())?;
        let config_path = request
            .config_path
            .as_deref()
            .ok_or_else(|| "New render session requires config_path".to_string())?;
        let payload = fs::read_to_string(payload_path)
            .map_err(|error| format!("Failed to read {}: {error}", payload_path.display()))?;
        let config = fs::read_to_string(config_path)
            .map_err(|error| format!("Failed to read {}: {error}", config_path.display()))?;
        let activity = parse_activity_json(&payload).map_err(|error| error.to_string())?;
        let raw_config = parse_template_json(&config).map_err(|error| error.to_string())?;
        let validated = validate_render_config(raw_config).map_err(|error| error.to_string())?;
        let dense = build_dense_activity_report_validated(&activity, &validated)
            .map_err(|error| error.to_string())?;
        let (prepared, _, _, _) = prepare_preview_assets(paths, &validated, &activity, &dense)
            .map_err(|error| error.to_string())?;
        if sessions.len() >= 16 {
            if let Some(key) = sessions.keys().next().cloned() {
                sessions.remove(&key);
            }
        }
        sessions.insert(request.session_id.clone(), RenderSession { dense, prepared });
    }
    let session = sessions
        .get(&request.session_id)
        .ok_or_else(|| "Render session disappeared".to_string())?;
    if let Some(parent) = request.out_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Failed to create {}: {error}", parent.display()))?;
    }
    let report = render_preview_with_prepared_assets(PreviewRenderRequest {
        paths,
        dense_activity: &session.dense,
        prepared_preview_assets: &session.prepared,
        second: request.second,
        prepare_timings: BTreeMap::new(),
        label_cache_status: LabelCacheStatus::Hit,
        extra_total_ms: 0.0,
        out_path: &request.out_path,
    })
    .map_err(|error| error.to_string())?;
    Ok(json!({
        "path": request.out_path,
        "second": request.second,
        "render_ms": report.total_ms,
        "session_count": sessions.len()
    }))
}

fn render_frame(
    payload_path: &Path,
    config_path: &Path,
    output_path: &Path,
    second: f64,
    repo_root: &Path,
) -> Result<(), String> {
    let payload = fs::read_to_string(payload_path)
        .map_err(|error| format!("Failed to read {}: {error}", payload_path.display()))?;
    let config = fs::read_to_string(config_path)
        .map_err(|error| format!("Failed to read {}: {error}", config_path.display()))?;
    let activity = parse_activity_json(&payload).map_err(|error| error.to_string())?;
    let raw_config = parse_template_json(&config).map_err(|error| error.to_string())?;
    let validated = validate_render_config(raw_config).map_err(|error| error.to_string())?;
    let dense = build_dense_activity_report_validated(&activity, &validated)
        .map_err(|error| error.to_string())?;
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Failed to create {}: {error}", parent.display()))?;
    }
    let paths = AppPaths::from_repo_root(repo_root.to_path_buf());
    render_preview_to_path(
        &paths,
        &validated,
        &activity,
        &dense,
        second,
        output_path,
    )
    .map_err(|error| error.to_string())?;
    Ok(())
}

fn parse_activity(path: &Path, repo_root: &Path) -> Result<FinalizeActivityResponse, String> {
    if !path.is_file() {
        return Err(format!("Telemetry source does not exist: {}", path.display()));
    }
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let path_string = path.to_string_lossy();
    let mut response = match extension.as_str() {
        "csv" => ovrley_core::activity::csv::parse_csv_activity_path(path, Some(repo_root)),
        "vbo" => ovrley_core::activity::vbo::parse_vbo_activity_path(path, Some(repo_root)),
        "mp4" | "mov" | "m4v" | "insv" | "360" => ovrley_core::media::mp4_telemetry::extract_activity(
            repo_root,
            &path_string,
        )
        .and_then(|value| value.ok_or_else(|| {
            ovrley_core::error::CoreError::Activity(
                "No supported OVRLEY embedded telemetry stream was found".into(),
            )
        })),
        _ => Err(ovrley_core::error::CoreError::Activity(format!(
            "OVRLEY native bridge does not parse .{extension}; VeloEdit's native parser handles this format"
        ))),
    }
    .map_err(|error| error.to_string())?;
    response.debug_payload = None;
    Ok(response)
}

fn write_success<T: Serialize>(result: T) -> Result<(), String> {
    let response = BridgeResponse {
        ok: true,
        engine: "OVRLEY",
        upstream_revision: "0db9be5f775c6e3716407f4a37175c916b8065f1",
        result: Some(result),
        error: None,
    };
    println!(
        "{}",
        serde_json::to_string(&response).map_err(|error| error.to_string())?
    );
    Ok(())
}

fn compiled_repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn required_arg(flag: &str, args: &[String]) -> Result<String, String> {
    optional_arg(flag, args).ok_or_else(|| format!("Missing required argument: {flag}"))
}

fn optional_arg(flag: &str, args: &[String]) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == flag)
        .map(|pair| pair[1].clone())
}

#[allow(dead_code)]
fn _paths_for_health(repo_root: PathBuf) -> AppPaths {
    AppPaths::from_repo_root(repo_root)
}
