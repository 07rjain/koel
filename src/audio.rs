use anyhow::{Context, Result, ensure};
use std::path::Path;

pub const SAMPLE_RATE: u32 = 16_000;
pub const MAX_SECONDS: usize = 5 * 60;

/// The recorder and CLI share one unambiguous format across all providers.
pub fn read_wav(path: &Path) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path).context("Cannot read WAV audio")?;
    let spec = reader.spec();
    ensure!(
        spec.channels == 1
            && spec.sample_rate == SAMPLE_RATE
            && spec.bits_per_sample == 16
            && spec.sample_format == hound::SampleFormat::Int,
        "Audio must be a mono, 16 kHz, 16-bit PCM WAV. Convert with: ffmpeg -i input -ar 16000 -ac 1 -c:a pcm_s16le output.wav"
    );
    ensure!(
        reader.len() as usize <= SAMPLE_RATE as usize * MAX_SECONDS,
        "Recording exceeds the five-minute limit"
    );
    let samples = reader
        .samples::<i16>()
        .map(|sample| sample.map(|s| s as f32 / 32768.0))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    ensure!(
        samples.len() >= 1600,
        "Recording is too short; record at least 0.1 seconds"
    );
    Ok(samples)
}

pub fn is_silent(samples: &[f32]) -> bool {
    let power = samples.iter().map(|s| s * s).sum::<f32>() / samples.len().max(1) as f32;
    power.sqrt() < 0.0001
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_pcm_and_rejects_the_wrong_sample_rate() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.wav");
        for rate in [16000, 48000] {
            let spec = hound::WavSpec {
                channels: 1,
                sample_rate: rate,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            };
            let mut writer = hound::WavWriter::create(&path, spec).unwrap();
            for _ in 0..2000 {
                writer.write_sample(16384_i16).unwrap();
            }
            writer.finalize().unwrap();
            let result = read_wav(&path);
            if rate == 16000 {
                assert_eq!(result.unwrap()[0], 0.5);
            } else {
                assert!(result.is_err());
            }
        }
        assert!(is_silent(&[0.0; 100]));
        assert!(!is_silent(&[0.1; 100]));
    }
}
