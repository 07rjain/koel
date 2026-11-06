use crate::config::Config;
use anyhow::{Context, Result, bail, ensure};
use reqwest::blocking::{Client, multipart};
use serde::Deserialize;
use std::{path::Path, time::Duration};

pub const ENDPOINT: &str = "https://api.groq.com/openai/v1/audio/transcriptions";

#[derive(Deserialize)]
struct GroqResponse {
    text: String,
}

pub fn transcribe(path: &Path, config: &Config, api_key: &str) -> Result<String> {
    ensure!(
        !api_key.trim().is_empty(),
        "Add a Groq API key from the menu bar first"
    );
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(120))
        .build()?;
    transcribe_at(&client, ENDPOINT, path, config, api_key)
}

fn transcribe_at(
    client: &Client,
    endpoint: &str,
    path: &Path,
    config: &Config,
    api_key: &str,
) -> Result<String> {
    let file = multipart::Part::file(path)?
        .file_name("recording.wav")
        .mime_str("audio/wav")?;
    let mut form = multipart::Form::new()
        .part("file", file)
        .text("model", config.groq_model.clone())
        .text("response_format", "json")
        .text("temperature", "0");
    if let Some(language) = &config.language {
        form = form.text("language", language.clone());
    }
    let response = client
        .post(endpoint)
        .bearer_auth(api_key)
        .multipart(form)
        .send()
        .context("Could not reach Groq; check your connection")?;
    let status = response.status();
    if !status.is_success() {
        // Do not echo provider response bodies: they may contain user audio metadata.
        bail!(match status.as_u16() {
            401 | 403 => "Groq rejected the API key; replace it from the menu",
            429 => "Groq rate limit reached; wait before trying again",
            413 => "Groq rejected the recording as too large",
            500..=599 => "Groq is temporarily unavailable",
            _ => "Groq rejected the transcription request",
        });
    }
    let result: GroqResponse = response
        .json()
        .context("Groq returned an invalid transcription response")?;
    Ok(result.text.trim().into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    #[test]
    fn sends_real_multipart_audio_and_parses_or_classifies_the_response() {
        for (status, body) in [
            (200, "{\"text\":\" hello world \"}"),
            (401, "{}"),
            (200, "{\"wrong\":true}"),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let endpoint = format!("http://{}/transcribe", listener.local_addr().unwrap());
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0_u8; 8192];
                loop {
                    let count = stream.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    bytes.extend_from_slice(&buffer[..count]);
                    if let Some(position) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        let header = String::from_utf8_lossy(&bytes[..position]).to_lowercase();
                        let length: usize = header
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length: "))
                            .unwrap()
                            .parse()
                            .unwrap();
                        if bytes.len() >= position + 4 + length {
                            break;
                        }
                    }
                }
                let request = String::from_utf8_lossy(&bytes);
                assert!(request.contains("Bearer test-key"));
                assert!(request.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"));
                assert!(request.contains("name=\"file\"; filename=\"recording.wav\""));
                assert!(request.contains("sample-audio"));
                write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            });
            let file = tempfile::NamedTempFile::new().unwrap();
            std::fs::write(file.path(), "sample-audio").unwrap();
            let result = transcribe_at(
                &Client::new(),
                &endpoint,
                file.path(),
                &Config::default(),
                "test-key",
            );
            if status == 200 && body.contains("text") {
                assert_eq!(result.unwrap(), "hello world");
            } else {
                assert!(result.is_err());
            }
            server.join().unwrap();
        }
    }
}
