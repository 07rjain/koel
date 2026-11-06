use crate::config::Paths;
use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::Path,
    time::Duration,
};

#[derive(Debug, Serialize)]
pub struct ModelDefinition {
    pub id: &'static str,
    pub name: &'static str,
    pub repository: &'static str,
    pub revision: &'static str,
    pub filename: &'static str,
    pub bytes: u64,
    pub sha256: &'static str,
    pub languages: &'static str,
}

pub const MODELS: &[ModelDefinition] = &[
    ModelDefinition {
        id: "whisper-tiny",
        name: "Whisper Tiny",
        languages: "Multilingual · quick start",
        repository: "handy-computer/whisper-tiny-gguf",
        revision: "1bd61cda36bbd22c88fc5a33842498a6e1d30f45",
        filename: "whisper-tiny-Q8_0.gguf",
        bytes: 45_981_088,
        sha256: "325b9c7997cd1eff81ef709d55766565e71be696130cc3a3d444713798706834",
    },
    ModelDefinition {
        id: "parakeet-v3",
        name: "Parakeet v3",
        languages: "25 European languages · automatic detection",
        repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
        revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de",
        filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
        bytes: 739_508_576,
        sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
    },
    ModelDefinition {
        id: "whisper-turbo",
        name: "Whisper large-v3-turbo",
        languages: "Multilingual · higher accuracy",
        repository: "handy-computer/whisper-large-v3-turbo-gguf",
        revision: "d222c9f621c1128299248f2ded4d8a1820519780",
        filename: "whisper-large-v3-turbo-Q8_0.gguf",
        bytes: 886_381_824,
        sha256: "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448",
    },
];

pub fn definition(id: &str) -> Result<&'static ModelDefinition> {
    MODELS
        .iter()
        .find(|model| model.id == id)
        .context("Unknown local model; choose a model from the catalog")
}

pub fn catalog(paths: &Paths) -> Vec<serde_json::Value> {
    MODELS
        .iter()
        .map(|model| {
            let mut value =
                serde_json::to_value(model).expect("Static model metadata is serializable");
            value["installed"] = serde_json::json!(
                fs::metadata(paths.models().join(model.filename))
                    .is_ok_and(|metadata| metadata.len() == model.bytes)
            );
            value
        })
        .collect()
}

pub fn verify(path: &Path, model: &ModelDefinition) -> Result<()> {
    let mut file = File::open(path)?;
    ensure!(
        file.metadata()?.len() == model.bytes,
        "Model size mismatch; download it again"
    );
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    ensure!(
        format!("{:x}", hasher.finalize()) == model.sha256,
        "Model SHA-256 mismatch; download it again"
    );
    Ok(())
}

pub fn install(paths: &Paths, id: &str) -> Result<()> {
    let model = definition(id)?;
    fs::create_dir_all(paths.models())?;
    let lock = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(paths.models().join("download.lock"))?;
    lock.try_lock_exclusive()
        .context("Another model download is in progress")?;
    let destination = paths.models().join(model.filename);
    if destination.exists() && verify(&destination, model).is_ok() {
        return Ok(());
    }
    let url = format!(
        "https://huggingface.co/{}/resolve/{}/{}",
        model.repository, model.revision, model.filename
    );
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(60 * 30))
        .user_agent(format!("LocalWhisper/{}", env!("CARGO_PKG_VERSION")))
        .build()?;
    let mut response = client
        .get(url)
        .send()
        .context("Cannot reach Hugging Face")?
        .error_for_status()
        .context("Model download failed")?;
    let mut temporary = tempfile::NamedTempFile::new_in(paths.models())?;
    let mut buffer = vec![0_u8; 1024 * 1024];
    let mut total = 0_u64;
    loop {
        let count = response
            .read(&mut buffer)
            .context("Model download interrupted; retry from the menu")?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > model.bytes {
            bail!("Model download is larger than the pinned artifact");
        }
        temporary.write_all(&buffer[..count])?;
    }
    temporary.flush()?;
    verify(temporary.path(), model)?;
    temporary.as_file().sync_all()?;
    temporary.persist(&destination)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_corrupted_and_truncated_artifacts() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let model = ModelDefinition {
            id: "fixture",
            name: "fixture",
            languages: "en",
            repository: "",
            revision: "",
            filename: "",
            bytes: 5,
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        };
        fs::write(file.path(), "hello").unwrap();
        verify(file.path(), &model).unwrap();
        fs::write(file.path(), "world").unwrap();
        assert!(verify(file.path(), &model).is_err());
        fs::write(file.path(), "hell").unwrap();
        assert!(verify(file.path(), &model).is_err());
        assert!(definition("../arbitrary.gguf").is_err());
    }
}
