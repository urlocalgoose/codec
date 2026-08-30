// Headless import: feed a loud.import.v1 manifest into a music library and
// optionally push the result to a sync server, without opening the app.
//
//   cargo run --bin codec_import -- <music-root> <manifest.json> \
//       [--server http://127.0.0.1:8787 --token-file <path>]

use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!(
            "usage: codec_import <music-root> <manifest.json> [--server URL --token-file PATH]"
        );
        return ExitCode::FAILURE;
    }

    let root = args[0].clone();
    let manifest = args[1].clone();
    let server = flag_value(&args, "--server");
    let token = match auth_token(&args) {
        Ok(token) => token,
        Err(err) => {
            eprintln!("{err}");
            return ExitCode::FAILURE;
        }
    };

    let report = match codec_lib::import_library_manifest_path(&root, &manifest) {
        Ok(report) => report,
        Err(err) => {
            eprintln!("import failed: {err}");
            return ExitCode::FAILURE;
        }
    };

    println!("imported:");
    println!("  new tracks:       {}", report.new_tracks);
    println!("  existing matched: {}", report.existing_tracks);
    println!("  playlist updates: {}", report.playlist_updates);
    println!("  liked updates:    {}", report.liked_updates);
    println!("  skipped:          {}", report.skipped_tracks);
    for failure in &report.failures {
        println!("  skipped: {} ({})", failure.file, failure.reason);
    }

    if let Some(server) = server {
        println!("uploading to {server}…");
        match codec_lib::sync_library_to_server_headless(
            root,
            server,
            "codec-import-cli".to_string(),
            token,
        ) {
            Ok(sync) => {
                println!("uploaded:");
                println!("  tracks uploaded:  {}", sync.tracks_uploaded);
                println!("  already remote:   {}", sync.tracks_skipped);
                println!("  artwork uploaded: {}", sync.artwork_uploaded);
                if !sync.failures.is_empty() {
                    println!("  failures:         {}", sync.failures.len());
                    for failure in sync.failures.iter().take(5) {
                        println!("    {} ({})", failure.track, failure.reason);
                    }
                }
            }
            Err(err) => {
                eprintln!("upload failed: {err}");
                return ExitCode::FAILURE;
            }
        }
    }

    ExitCode::SUCCESS
}

fn flag_value(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|arg| arg == name)
        .and_then(|index| args.get(index + 1))
        .cloned()
}

fn auth_token(args: &[String]) -> Result<String, String> {
    if let Some(token) = flag_value(args, "--token") {
        return Ok(token.trim().to_string());
    }
    if let Some(path) = flag_value(args, "--token-file") {
        return fs::read_to_string(&path)
            .map(|value| value.trim().to_string())
            .map_err(|err| format!("could not read token file {path}: {err}"));
    }
    if let Ok(token) = env::var("CODEC_AUTH_TOKEN") {
        return Ok(token.trim().to_string());
    }
    if let Ok(token) = env::var("LOUD_AUTH_TOKEN") {
        return Ok(token.trim().to_string());
    }
    Ok(String::new())
}
