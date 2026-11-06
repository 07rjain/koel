pub mod audio;
pub mod config;
pub mod groq;
pub mod models;
pub mod transcription;
pub mod updates;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char};

/// Shared JSON protocol used by the CLI and the native macOS shell.
pub fn handle(request: &Value) -> Result<Value> {
    let operation = request["op"].as_str().context("Missing operation")?;
    match operation {
        "version" => {
            return Ok(
                json!({"version": updates::CURRENT_VERSION, "repository": updates::repository()?}),
            );
        }
        "check_update" => return Ok(json!(updates::check()?)),
        _ => {}
    }
    let paths = config::Paths::discover()?;
    match operation {
        "status" => Ok(json!({
            "config": config::load(&paths)?,
            "models": models::catalog(&paths),
            "data_dir": paths.root,
            "engine": "transcribe.cpp 0.4.1 / Metal",
            "version": updates::CURRENT_VERSION,
            "repository": updates::repository()?,
        })),
        "configure" => {
            let config: config::Config = serde_json::from_value(request["config"].clone())?;
            let previous = config::load(&paths)?;
            config::save(&paths, &config)?;
            if previous.provider != config.provider || previous.local_model != config.local_model {
                transcription::release_model();
            }
            Ok(json!(config))
        }
        "download" => {
            let id = request["model"].as_str().context("Missing model ID")?;
            models::install(&paths, id)?;
            Ok(json!({"model": id, "installed": true}))
        }
        "transcribe" => {
            let config = config::load(&paths)?;
            let path = request["path"].as_str().context("Missing WAV path")?;
            let key = request["api_key"].as_str();
            Ok(json!(transcription::transcribe(
                &paths,
                &config,
                path.as_ref(),
                key
            )?))
        }
        _ => bail!("Unknown operation"),
    }
}

pub fn reply(request: &str) -> String {
    let result = serde_json::from_str(request)
        .context("Invalid request JSON")
        .and_then(|request| handle(&request));
    match result {
        Ok(data) => json!({"ok": true, "data": data}).to_string(),
        Err(error) => json!({"ok": false, "error": format!("{error:#}")}).to_string(),
    }
}

/// # Safety
/// `request` must point to a live, NUL-terminated UTF-8 string for this call.
/// Free the returned allocation exactly once with `lw_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_call(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() {
            return json!({"ok": false, "error": "Null request"}).to_string();
        }
        // SAFETY: the caller guarantees a valid NUL-terminated pointer.
        match unsafe { CStr::from_ptr(request) }.to_str() {
            Ok(request) => reply(request),
            Err(_) => json!({"ok": false, "error": "Request is not UTF-8"}).to_string(),
        }
    })
    .unwrap_or_else(|_| json!({"ok": false, "error": "Rust engine panicked"}).to_string());
    // JSON encoding escapes NULs, so this string cannot contain an interior NUL.
    CString::new(result)
        .expect("JSON contains no NUL")
        .into_raw()
}

/// # Safety
/// `response` must be null or an allocation returned by `lw_call`, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lw_free(response: *mut c_char) {
    if !response.is_null() {
        // SAFETY: ownership of this allocation is transferred back by the caller.
        drop(unsafe { CString::from_raw(response) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lw_shutdown() {
    transcription::release_model();
}
