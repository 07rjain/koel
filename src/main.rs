use serde_json::json;
use std::io::{self, Read};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args
        .first()
        .is_some_and(|arg| arg == "--version" || arg == "-V")
    {
        println!(
            "Local Whisper {}",
            local_whisper_core::updates::CURRENT_VERSION
        );
        return;
    }
    if args.is_empty() || args[0] == "--help" {
        println!(
            "Local Whisper Rust engine\n\n  local-whisper --version\n  local-whisper check-update\n  local-whisper status\n  local-whisper download MODEL_ID\n  local-whisper transcribe FILE.wav\n  local-whisper request < request.json\n\nUse the menu bar app to select a provider or configure settings.\nGROQ_API_KEY is used only by the CLI and is never persisted.\nApple Speech: 'Local Whisper.app/Contents/MacOS/Local Whisper' --apple-transcribe FILE.wav en-US"
        );
        return;
    }
    let request = match args[0].as_str() {
        "check-update" => json!({"op":"check_update"}),
        "status" => json!({"op":"status"}),
        "download" if args.len() == 2 => json!({"op":"download", "model": args[1]}),
        "transcribe" if args.len() == 2 => {
            json!({"op":"transcribe", "path": args[1], "api_key": std::env::var("GROQ_API_KEY").ok()})
        }
        "request" => {
            let mut input = String::new();
            io::stdin()
                .read_to_string(&mut input)
                .expect("Cannot read request");
            let response = local_whisper_core::reply(&input);
            local_whisper_core::transcription::release_model();
            println!("{response}");
            if !serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"]
                .as_bool()
                .unwrap_or(false)
            {
                std::process::exit(1);
            }
            return;
        }
        _ => {
            eprintln!("Invalid command; use --help");
            std::process::exit(2);
        }
    };
    let response = local_whisper_core::reply(&request.to_string());
    local_whisper_core::transcription::release_model();
    println!("{response}");
    if !serde_json::from_str::<serde_json::Value>(&response).unwrap()["ok"]
        .as_bool()
        .unwrap_or(false)
    {
        std::process::exit(1);
    }
}
