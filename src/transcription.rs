use crate::{
    audio,
    config::{Config, Paths, Provider},
    groq, models,
};
use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
    time::Instant,
};
use transcribe_cpp::{Model, RunOptions, Session};

static SESSION: Mutex<Option<(PathBuf, Session)>> = Mutex::new(None);

/// Rust statics are not dropped at exit. Release the session before ggml's
/// process-level Metal destructors run, and when changing providers.
pub fn release_model() {
    if let Ok(mut cache) = SESSION.lock() {
        *cache = None;
    }
}

#[derive(Debug, Serialize)]
pub struct Transcript {
    pub text: String,
    pub provider: Provider,
    pub model: String,
    pub elapsed_ms: u128,
}

pub fn transcribe(
    paths: &Paths,
    config: &Config,
    path: &Path,
    key: Option<&str>,
) -> Result<Transcript> {
    config.validate()?;
    ensure!(
        config.provider != Provider::Apple,
        "Apple Speech is provided by the macOS app. Use Local Whisper.app, or its --apple-transcribe command."
    );
    let start = Instant::now();
    let samples = audio::read_wav(path)?;
    let model = if config.provider == Provider::Groq {
        &config.groq_model
    } else {
        &config.local_model
    };
    let text = if audio::is_silent(&samples) {
        String::new()
    } else {
        match config.provider {
            Provider::Local => local(paths, config, &samples)?,
            Provider::Groq => groq::transcribe(
                path,
                config,
                key.context("Add a Groq API key from the menu bar first")?,
            )?,
            Provider::Apple => unreachable!(),
        }
    };
    Ok(Transcript {
        text,
        provider: config.provider,
        model: model.clone(),
        elapsed_ms: start.elapsed().as_millis(),
    })
}

fn local(paths: &Paths, config: &Config, samples: &[f32]) -> Result<String> {
    let definition = models::definition(&config.local_model)?;
    let path = paths.models().join(definition.filename);
    ensure!(
        path.exists(),
        "Download {} from the Local Models menu first",
        definition.name
    );
    let mut cache = SESSION
        .lock()
        .map_err(|_| anyhow::anyhow!("Local model session failed; restart the app"))?;
    if cache.as_ref().is_none_or(|(loaded, _)| *loaded != path) {
        // Verify once per session load, before exposing any bytes to the native parser.
        models::verify(&path, definition)?;
        *cache = None;
        transcribe_cpp::init_backends_default()
            .context("Cannot initialize local inference backends")?;
        let model = Model::load(&path).context("Cannot load the local model")?;
        *cache = Some((
            path,
            model
                .session()
                .context("Cannot create a transcription session")?,
        ));
    }
    let Some((_, session)) = cache.as_mut() else {
        bail!("Local model was not loaded");
    };
    let options = RunOptions {
        // Parakeet v3 detects its own language and does not accept hints.
        language: if config.local_model == "parakeet-v3" {
            None
        } else {
            config.language.clone()
        },
        ..RunOptions::default()
    };
    let transcript = session
        .run(samples, &options)
        .context("Local speech recognition failed")?;
    Ok(transcript.text.trim().into())
}
