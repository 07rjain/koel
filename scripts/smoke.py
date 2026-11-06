#!/usr/bin/env python3
"""Real file-transcription smoke tests using synthetic speech, not microphone audio."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
PHRASE = "The quick brown fox jumps over the lazy dog. This is a test of local speech recognition."


def run(command, *, env=None, request=None):
    result = subprocess.run(
        [str(part) for part in command],
        input=json.dumps(request) if request is not None else None,
        text=True, capture_output=True, env=env, timeout=180,
    )
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr[-5000:]}")
    return result.stdout.strip()


def check_text(transcript):
    words = re.sub(r"[^a-z ]", "", transcript["text"].lower())
    assert "quick brown fox" in words, transcript
    assert "local speech recognition" in words, transcript


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=REPO / "dist/Local Whisper.app")
    parser.add_argument("--download", action="store_true", help="Download Whisper Tiny if absent (46 MB)")
    parser.add_argument("--apple", action="store_true", help="Also test installed Apple speech assets")
    parser.add_argument("--groq", action="store_true", help="Upload synthetic audio to Groq using the app's Keychain key")
    args = parser.parse_args()
    native = args.app / "Contents/MacOS/Local Whisper"
    cli = args.app / "Contents/MacOS/local-whisper"
    status = json.loads(run([cli, "status"]))["data"]
    tiny = next(model for model in status["models"] if model["id"] == "whisper-tiny")
    if not tiny["installed"]:
        if not args.download:
            raise RuntimeError("Download Whisper Tiny from the app or rerun with --download.")
        run([cli, "download", "whisper-tiny"])

    with tempfile.TemporaryDirectory(prefix="local-whisper-smoke-") as folder:
        root = Path(folder)
        (root / "models").symlink_to(Path(status["data_dir"]) / "models", target_is_directory=True)
        env = {**os.environ, "LOCAL_WHISPER_DATA_DIR": str(root)}
        aiff, wav = root / "fixture.aiff", root / "fixture.wav"
        run(["say", "-o", aiff, PHRASE])
        run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav])
        config = {**status["config"], "provider": "local", "local_model": "whisper-tiny", "language": "en"}
        run([cli, "request"], env=env, request={"op": "configure", "config": config})
        rust = json.loads(run([cli, "transcribe", wav], env=env))["data"]
        check_text(rust)
        print("PASS: Rust / transcribe.cpp / Metal recognizes speech and shuts down cleanly")
        swift = json.loads(run([native, "--transcribe", wav], env=env))
        check_text(swift)
        print("PASS: Swift → Rust FFI recognizes speech and shuts down cleanly")
        if args.apple:
            apple = json.loads(run([native, "--apple-transcribe", wav, "en-US"], env=env))
            check_text(apple)
            print("PASS: Apple Speech recognizes speech using installed on-device assets")
            # Match a common microphone format and exercise stateful sample-rate
            # conversion/downmixing in the actual live session implementation.
            streaming_wav = root / "streaming-48k-stereo.wav"
            run(["afconvert", "-f", "WAVE", "-d", "LEF32@48000", "-c", "2", wav, streaming_wav])
            events = [json.loads(line) for line in run([native, "--apple-stream-file", streaming_wav, "en-US", "--verify-cancellation"], env=env).splitlines()]
            ended = next(index for index, event in enumerate(events) if event["event"] == "input_finished")
            early = [event for event in events[:ended] if event["event"] == "update" and event.get("text")]
            assert early, "Apple Speech produced no text before input ended"
            assert any(not event["is_final"] for event in early), "No volatile hypotheses arrived while input was active"
            final = next(event["transcript"] for event in events if event["event"] == "final")
            check_text(final)
            assert final["text"].lower().count("quick brown fox") == 1, final
            print("PASS: live Apple Speech cancels/restarts, emits partial text before Stop, and finalizes without duplicate words (48 kHz stereo input)")
        if args.groq:
            config["provider"] = "groq"
            run([cli, "request"], env=env, request={"op": "configure", "config": config})
            groq = json.loads(run([native, "--transcribe", wav], env=env))
            check_text(groq)
            print("PASS: Groq recognizes uploaded synthetic speech using the Keychain key")
    print("User provider settings were left unchanged.")


if __name__ == "__main__":
    main()
