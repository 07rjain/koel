use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{fs, io::Write, path::PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    #[default]
    Apple,
    Local,
    Groq,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub provider: Provider,
    pub local_model: String,
    pub apple_locale: String,
    pub language: Option<String>,
    pub groq_model: String,
    pub paste_after_transcription: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            provider: Provider::Apple,
            local_model: "whisper-tiny".into(),
            apple_locale: "en-US".into(),
            language: None,
            groq_model: "whisper-large-v3-turbo".into(),
            paste_after_transcription: true,
        }
    }
}

impl Config {
    pub fn validate(&self) -> Result<()> {
        crate::models::definition(&self.local_model)?;
        ensure!(
            ["whisper-large-v3-turbo", "whisper-large-v3"].contains(&self.groq_model.as_str()),
            "Unsupported Groq speech model"
        );
        ensure!(
            !self.apple_locale.is_empty()
                && self.apple_locale.len() < 40
                && self
                    .apple_locale
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-'),
            "Invalid Apple locale"
        );
        if let Some(language) = &self.language {
            ensure!(
                (2..=3).contains(&language.len())
                    && language.chars().all(|c| c.is_ascii_lowercase()),
                "Language must be an ISO language code, or null for automatic detection"
            );
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn discover() -> Result<Self> {
        let root = if let Some(path) = std::env::var_os("LOCAL_WHISPER_DATA_DIR") {
            PathBuf::from(path)
        } else {
            dirs::data_local_dir()
                .context("Cannot locate Application Support")?
                .join("LocalWhisper")
        };
        fs::create_dir_all(root.join("models"))?;
        Ok(Self { root })
    }

    pub fn models(&self) -> PathBuf {
        self.root.join("models")
    }
}

pub fn load(paths: &Paths) -> Result<Config> {
    let path = paths.root.join("config.json");
    let config: Config = match fs::read(&path) {
        Ok(contents) => serde_json::from_slice(&contents)
            .with_context(|| format!("Invalid settings in {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Config::default(),
        Err(error) => return Err(error.into()),
    };
    config.validate()?;
    Ok(config)
}

pub fn save(paths: &Paths, config: &Config) -> Result<()> {
    config.validate()?;
    let mut file = tempfile::NamedTempFile::new_in(&paths.root)?;
    file.write_all(&serde_json::to_vec_pretty(config)?)?;
    file.as_file().sync_all()?;
    file.persist(paths.root.join("config.json"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_configuration_does_not_overwrite_saved_preferences() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths {
            root: dir.path().into(),
        };
        let mut config = Config {
            provider: Provider::Local,
            ..Config::default()
        };
        save(&paths, &config).unwrap();
        config.local_model = "../../outside".into();
        assert!(save(&paths, &config).is_err());
        assert_eq!(load(&paths).unwrap().provider, Provider::Local);
        fs::write(paths.root.join("config.json"), "broken").unwrap();
        assert!(load(&paths).is_err());
    }
}
