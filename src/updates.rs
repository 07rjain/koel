use anyhow::{Context, Result, bail, ensure};
use reqwest::blocking::Client;
use semver::Version;
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Deserialize)]
struct ReleaseConfig {
    github_repository: String,
}

pub fn repository() -> Result<String> {
    let config: ReleaseConfig = serde_json::from_str(include_str!("../release.json"))?;
    validate_repository(&config.github_repository)?;
    Ok(config.github_repository)
}

fn validate_repository(repository: &str) -> Result<()> {
    let parts: Vec<_> = repository.split('/').collect();
    ensure!(
        parts.len() == 2
            && parts.iter().all(|part| {
                !part.is_empty()
                    && *part != "."
                    && *part != ".."
                    && part
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
            }),
        "Release repository must have the form owner/repository"
    );
    Ok(())
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStatus {
    Available,
    UpToDate,
    NoReleases,
}

#[derive(Debug, Serialize)]
pub struct UpdateInfo {
    pub status: UpdateStatus,
    pub current_version: String,
    pub latest_version: Option<String>,
    pub release_url: String,
    pub download_url: Option<String>,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    state: String,
    size: u64,
    browser_download_url: String,
}

fn no_releases(current: &str, repository: &str) -> UpdateInfo {
    UpdateInfo {
        status: UpdateStatus::NoReleases,
        current_version: current.into(),
        latest_version: None,
        release_url: format!("https://github.com/{repository}/releases"),
        download_url: None,
    }
}

fn evaluate(current: &str, repository: &str, release: Release) -> Result<UpdateInfo> {
    validate_repository(repository)?;
    let installed = Version::parse(current).context("Installed app version is invalid")?;
    let latest = Version::parse(
        release
            .tag_name
            .strip_prefix('v')
            .unwrap_or(&release.tag_name),
    )
    .context("The latest release tag is not a semantic version")?;
    if release.draft || release.prerelease || !latest.pre.is_empty() {
        return Ok(no_releases(current, repository));
    }
    // Stable tags must be vMAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH.
    ensure!(
        latest.build.is_empty(),
        "Release tags must not contain build metadata"
    );
    let asset_name = format!("LocalWhisper-{latest}-macos-arm64.zip");
    let expected_url = format!(
        "https://github.com/{repository}/releases/download/{}/{asset_name}",
        release.tag_name
    );
    let download_url = release
        .assets
        .iter()
        .find(|asset| {
            asset.name == asset_name
                && asset.state == "uploaded"
                && asset.size > 0
                && asset.browser_download_url == expected_url
        })
        .map(|_| expected_url);
    Ok(UpdateInfo {
        status: if latest > installed {
            UpdateStatus::Available
        } else {
            UpdateStatus::UpToDate
        },
        current_version: current.into(),
        latest_version: Some(latest.to_string()),
        release_url: format!(
            "https://github.com/{repository}/releases/tag/{}",
            release.tag_name
        ),
        download_url,
    })
}

pub fn check() -> Result<UpdateInfo> {
    let repository = repository()?;
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .user_agent(format!("LocalWhisper/{CURRENT_VERSION}"))
        .build()?;
    check_at(
        &client,
        &format!("https://api.github.com/repos/{repository}/releases/latest"),
        CURRENT_VERSION,
        &repository,
    )
}

fn check_at(
    client: &Client,
    endpoint: &str,
    current: &str,
    repository: &str,
) -> Result<UpdateInfo> {
    let response = client
        .get(endpoint)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .context("Could not check for updates; check your internet connection")?;
    match response.status().as_u16() {
        404 => return Ok(no_releases(current, repository)),
        403 | 429 => bail!("GitHub has temporarily limited update checks; try again later"),
        200 => {}
        _ => bail!("GitHub could not provide release information; try again later"),
    }
    let release = response
        .json()
        .context("GitHub returned invalid release information")?;
    evaluate(current, repository, release)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    fn release(tag: &str) -> Release {
        let version = tag.strip_prefix('v').unwrap_or(tag);
        serde_json::from_value(json!({
            "tag_name": tag, "draft": false, "prerelease": false,
            "assets": [{"name": format!("LocalWhisper-{version}-macos-arm64.zip"),
                "state": "uploaded", "size": 123,
                "browser_download_url": format!("https://github.com/07rjain/koel/releases/download/{tag}/LocalWhisper-{version}-macos-arm64.zip") }]
        })).unwrap()
    }

    #[test]
    fn compares_numeric_versions_and_never_offers_a_downgrade() {
        let update = evaluate("0.9.0", "07rjain/koel", release("v0.10.0")).unwrap();
        assert_eq!(update.status, UpdateStatus::Available);
        assert!(
            update
                .download_url
                .unwrap()
                .ends_with("LocalWhisper-0.10.0-macos-arm64.zip")
        );
        for tag in ["v0.9.0", "v0.8.0"] {
            assert_eq!(
                evaluate("0.9.0", "07rjain/koel", release(tag))
                    .unwrap()
                    .status,
                UpdateStatus::UpToDate
            );
        }
    }

    #[test]
    fn rejects_preview_releases_and_untrusted_downloads() {
        for (draft, prerelease) in [(true, false), (false, true)] {
            let mut candidate = release("v1.0.0");
            candidate.draft = draft;
            candidate.prerelease = prerelease;
            assert_eq!(
                evaluate("0.2.0", "07rjain/koel", candidate).unwrap().status,
                UpdateStatus::NoReleases
            );
        }
        let preview = release("v1.0.0-beta.1");
        assert_eq!(
            evaluate("0.2.0", "07rjain/koel", preview).unwrap().status,
            UpdateStatus::NoReleases
        );
        let mut candidate = release("v1.0.0");
        candidate.assets[0].browser_download_url = "https://example.com/other.zip".into();
        assert!(
            evaluate("0.2.0", "07rjain/koel", candidate)
                .unwrap()
                .download_url
                .is_none()
        );
        assert!(evaluate("0.2.0", "07rjain/koel", release("latest")).is_err());
        assert!(validate_repository("../other/path").is_err());
        assert_eq!(repository().unwrap(), "07rjain/koel");
    }

    #[test]
    fn handles_an_empty_repository_rate_limits_and_malformed_responses() {
        for (status, body) in [(404, "{}"), (429, "{}"), (200, "{}"), (200, "not json")] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let endpoint = format!("http://{}/releases/latest", listener.local_addr().unwrap());
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                let mut buffer = [0; 2048];
                while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                    let count = stream.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&buffer[..count]);
                }
                let request = String::from_utf8_lossy(&request).to_lowercase();
                assert!(request.starts_with("get /releases/latest "));
                assert!(!request.contains("authorization:"));
                write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            });
            let result = check_at(&Client::new(), &endpoint, "0.2.0", "07rjain/koel");
            if status == 404 {
                assert_eq!(result.unwrap().status, UpdateStatus::NoReleases);
            } else {
                assert!(result.is_err());
            }
            server.join().unwrap();
        }
    }
}
