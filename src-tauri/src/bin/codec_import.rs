// Headless import/download/scan. Server imports are always additive.
// Credentials belong in --token-file or CODEC_AUTH_TOKEN, never in a URL.
use serde_json::{json, Value};
use std::{env, fs, path::Path, process::ExitCode};

struct Options {
    root: String,
    manifest: Option<String>,
    server: Option<String>,
    token_file: Option<String>,
    report: Option<String>,
    scan: bool,
    download: bool,
}

fn parse(args: &[String]) -> Result<Options, String> {
    if args.is_empty() || args[0].starts_with("--") {
        return Err(usage());
    }
    let mut options = Options {
        root: args[0].clone(),
        manifest: None,
        server: None,
        token_file: None,
        report: None,
        scan: false,
        download: false,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--server" | "--token-file" | "--report" => {
                let value = args.get(index + 1).filter(|value| !value.starts_with("--")).ok_or_else(usage)?.clone();
                let slot = match args[index].as_str() { "--server" => &mut options.server, "--token-file" => &mut options.token_file, _ => &mut options.report };
                if slot.replace(value).is_some() { return Err("An option was provided more than once.".to_string()); }
                index += 1;
            }
            "--scan" => options.scan = true,
            "--download" => options.download = true,
            "--merge" => {}, // Explicit spelling of the safe default; no replacement mode.
            "--token" => return Err("Use --token-file PATH or CODEC_AUTH_TOKEN; do not put credentials in process arguments.".to_string()),
            value if value.starts_with("--") => return Err(usage()),
            _ => {
                if options.manifest.replace(args[index].clone()).is_some() { return Err(usage()); }
            }
        }
        index += 1;
    }
    if options.scan as u8 + options.download as u8 + options.manifest.is_some() as u8 != 1
        || (options.download && options.server.is_none())
        || (options.scan && options.server.is_some())
    {
        return Err(usage());
    }
    Ok(options)
}

fn usage() -> String {
    "usage: codec_import <music-root> <manifest.json> [--server URL] [--merge] [--token-file PATH] [--report PATH]\n       codec_import <music-root> --download --server URL [--token-file PATH] [--report PATH]\n       codec_import <music-root> --scan [--report PATH]".to_string()
}

fn auth_token(options: &Options) -> Result<String, String> {
    if let Some(path) = &options.token_file {
        return fs::read_to_string(path)
            .map(|value| value.trim().to_string())
            .map_err(|err| format!("Could not read token file: {err}"));
    }
    Ok(env::var("CODEC_AUTH_TOKEN")
        .or_else(|_| env::var("LOUD_AUTH_TOKEN"))
        .unwrap_or_default()
        .trim()
        .to_string())
}

fn run(options: &Options, output: &mut Value) -> Result<bool, String> {
    if options.scan {
        let library = codec_lib::scan_library_path(&options.root)?;
        println!(
            "library: {} tracks, {} playlists",
            library.tracks.len(),
            library.playlists.len()
        );
        output["mode"] = json!("scan");
        output["library"] = serde_json::to_value(library)
            .map_err(|err| format!("Could not encode scan report: {err}"))?;
        return Ok(true);
    }
    let token = auth_token(options)?;
    let mut successful = true;
    let mut expected_fingerprints = Vec::new();
    if let Some(manifest) = &options.manifest {
        output["mode"] = json!("import-merge");
        let report = codec_lib::import_library_manifest_path(&options.root, manifest)?;
        println!(
            "imported: {} new tracks, {} exact matches, {} playlist updates, {} likes",
            report.new_tracks,
            report.existing_tracks,
            report.playlist_updates,
            report.liked_updates
        );
        println!(
            "artwork: {} tracks, {} playlists, {} already present, {} missing, {} failed",
            report.track_artwork_imported,
            report.playlist_artwork_imported,
            report.artwork_already_present,
            report.artwork_missing,
            report.artwork_failed
        );
        successful &= report.failures.is_empty() && report.artwork_failures.is_empty();
        expected_fingerprints = report.track_fingerprints.clone();
        output["import"] = serde_json::to_value(report)
            .map_err(|err| format!("Could not encode import report: {err}"))?;
    } else {
        output["mode"] = json!("download");
    }
    if let Some(server) = &options.server {
        println!(
            "{}",
            if options.download {
                "Downloading missing media and artwork…"
            } else {
                "Merging into server; preserving existing metadata, playlists, likes, and covers…"
            }
        );
        let sync = if options.download {
            codec_lib::sync_library_from_server_headless(
                options.root.clone(),
                server.clone(),
                token,
            )?
        } else {
            codec_lib::sync_library_to_server_headless_checked(
                options.root.clone(),
                server.clone(),
                token,
                &expected_fingerprints,
            )?
        };
        println!("server: {} new tracks, {} matched, {} audio uploaded, {} downloaded, {} already present", sync.tracks_added, sync.tracks_matched, sync.tracks_uploaded, sync.tracks_downloaded, sync.tracks_skipped);
        println!(
            "playlists: {} added, {} updated, {} memberships appended, {} likes added",
            sync.playlists_added,
            sync.playlists_updated,
            sync.playlist_tracks_added,
            sync.liked_updates
        );
        println!(
            "artwork: {} uploaded, {} downloaded, {} already present, {} missing, {} failed",
            sync.artwork_uploaded,
            sync.artwork_downloaded,
            sync.artwork_already_present,
            sync.artwork_missing,
            sync.artwork_failed
        );
        successful &= sync.failures.is_empty();
        if !sync.failures.is_empty() {
            println!(
                "{} transfer failures; see the JSON report for details.",
                sync.failures.len()
            );
        }
        output["sync"] = serde_json::to_value(sync)
            .map_err(|err| format!("Could not encode sync report: {err}"))?;
    }
    Ok(successful)
}

fn write_report(path: &str, value: &Value) -> Result<(), String> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let path = Path::new(path);
    if let Some(parent) = path.parent().filter(|path| !path.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Could not create report directory: {err}"))?;
    }
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(&temporary)
        .map_err(|err| format!("Could not create report: {err}"))?;
    let result = (|| {
        let bytes = serde_json::to_vec_pretty(value)
            .map_err(|err| format!("Could not encode report: {err}"))?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|err| format!("Could not write report: {err}"))?;
        fs::rename(&temporary, path).map_err(|err| format!("Could not save report: {err}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

fn main() -> ExitCode {
    let options = match parse(&env::args().skip(1).collect::<Vec<_>>()) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    let mut output = json!({"schema":"codec.import-report.v1"});
    let successful = match run(&options, &mut output) {
        Ok(successful) => successful,
        Err(error) => {
            eprintln!("{error}");
            output["error"] = json!(error);
            false
        }
    };
    output["success"] = json!(successful);
    if let Some(path) = options.report {
        if let Err(error) = write_report(&path, &output) {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    }
    if successful {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }
    #[test]
    fn import_merge_scan_download_and_invalid_arguments() {
        assert!(parse(&args(&[
            "root",
            "manifest",
            "--server",
            "http://server",
            "--merge",
            "--report",
            "report.json"
        ]))
        .is_ok());
        assert!(parse(&args(&["root", "--scan"])).unwrap().scan);
        assert!(
            parse(&args(&["root", "--download", "--server", "http://server"]))
                .unwrap()
                .download
        );
        for invalid in [
            &["root", "manifest", "--server"][..],
            &["root", "--download"],
            &["root", "--scan", "manifest"],
            &["root", "manifest", "--token", "secret"],
            &["root", "manifest", "--wat"],
        ] {
            assert!(parse(&args(invalid)).is_err());
        }
    }
}
