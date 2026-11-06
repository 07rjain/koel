fn main() {
    println!("cargo:rerun-if-changed=VERSION");
    let version = std::fs::read_to_string("VERSION").expect("Cannot read VERSION");
    let package_version =
        std::env::var("CARGO_PKG_VERSION").expect("Cargo package version is missing");
    assert_eq!(
        version.trim(),
        package_version,
        "VERSION and Cargo.toml disagree; run python3 scripts/version.py sync"
    );
}
