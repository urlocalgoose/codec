#!/usr/bin/env python3
"""Validate import contracts without reading media or writing to a library.

Requires jsonschema 4.x (install in a disposable venv with pip install jsonschema).
Run: python scripts/test-import-schema.py [--bundle /path/to/s2y/bundle]
"""

import argparse
import copy
import json
from pathlib import Path
import unittest
from urllib.parse import urljoin

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


DOCS = Path(__file__).resolve().parents[1] / "docs"
SCHEMAS = {
    name: json.loads((DOCS / name).read_text())
    for name in (
        "codec-import.schema.json",
        "s2y-playlist-artwork.schema.json",
        "s2y-track-artwork.schema.json",
    )
}
REGISTRY = Registry()
for filename, schema in SCHEMAS.items():
    resource = Resource.from_contents(schema)
    for uri in (schema["$id"], urljoin(schema["$id"], filename)):
        REGISTRY = REGISTRY.with_resource(uri, resource)


def validator(filename):
    return Draft202012Validator(
        SCHEMAS[filename], registry=REGISTRY, format_checker=FormatChecker()
    )


def artwork():
    return {
        "file": "artwork/cover.jpg",
        "sha256": "a" * 64,
        "mime_type": "image/jpeg",
        "width": 640,
        "height": 636,
        "source_url": "https://fixture.invalid/cover",
        "spotify_url": "https://open.spotify.com/playlist/fixture",
        "license_url": "https://fixture.invalid/license",
        "attribution_url": "https://fixture.invalid/attribution",
        "provenance": {"source": "fixture", "revision": 1},
    }


class ImportSchemaTests(unittest.TestCase):
    def test_all_schema_documents_are_valid_and_sidecar_references_resolve(self):
        for filename, schema in SCHEMAS.items():
            with self.subTest(filename=filename):
                Draft202012Validator.check_schema(schema)
        validator("s2y-playlist-artwork.schema.json").validate(
            {"schema": "s2y.playlist-artwork.v1", "playlists": []}
        )
        validator("s2y-track-artwork.schema.json").validate(
            {"schema": "s2y.track-artwork.v1", "tracks": []}
        )

    def test_legacy_minimal_manifest_and_optional_artwork(self):
        schema = validator("codec-import.schema.json")
        schema.validate({"schema": "loud.import.v1", "tracks": [{"file": "old.mp3"}]})
        schema.validate({"schema": "loud.import.v1", "tracks": []})
        schema.validate({
            "schema": "loud.import.v1",
            "source": {"name": "s2y", "generated_at": "2026-09-21T19:26:10.533541+00:00", "base_path": "."},
            "tracks": [{"file": "audio/song.flac", "fingerprint": "spotify:track:exact", "artwork": artwork()}],
            "playlists": [{"name": "Source Playlist", "artwork": artwork()}],
        })

    def test_nullable_optional_metadata_matches_runtime_options(self):
        track = {"file": "audio/song.m4a", "artwork": None}
        for field in ("title", "artist", "album", "album_artist", "genre", "year", "track_number", "disc_number", "duration_seconds", "duration_ms", "explicit", "fingerprint"):
            track[field] = None
        track["identifiers"] = {"isrc": None, "spotify_track_id": None}
        schema = validator("codec-import.schema.json")
        schema.validate({"schema": "loud.import.v1", "tracks": [track], "source": None})
        schema.validate({"schema": "loud.import.v1", "tracks": [], "source": {"base_path": None}, "playlists": [{"name": "Mix", "artwork": None}]})
        cover = artwork()
        for field in ("source_url", "spotify_url", "license_url", "attribution_url", "provenance"):
            cover[field] = None
        schema.validate({"schema": "loud.import.v1", "tracks": [], "playlists": [{"name": "Mix", "artwork": cover}]})

    def test_s2y_origin_and_exact_fingerprint_sidecars(self):
        validator("s2y-playlist-artwork.schema.json").validate({
            "schema": "s2y.playlist-artwork.v1", "base_path": ".",
            "playlists": [{"origin": "avb727", "name": "midnight", "artwork": artwork()}],
        })
        validator("s2y-track-artwork.schema.json").validate({
            "schema": "s2y.track-artwork.v1", "base_path": "covers",
            "tracks": [{"fingerprint": "spotify:track:exact", "artwork": artwork()}],
        })

    def test_required_artwork_integrity_fields_and_supported_formats(self):
        schema = validator("codec-import.schema.json")
        changes = [
            ("file", None), ("sha256", "not-a-digest"), ("mime_type", "image/webp"),
            ("mime_type", "image/gif"), ("width", 0), ("height", 8193), ("width", 1.5),
        ]
        for field, value in changes:
            cover = artwork()
            cover[field] = value
            with self.subTest(field=field, value=value):
                self.assertFalse(schema.is_valid({"schema": "loud.import.v1", "tracks": [], "playlists": [{"name": "Mix", "artwork": cover}]}))
        for field in ("file", "sha256", "mime_type", "width", "height"):
            cover = artwork()
            del cover[field]
            with self.subTest(missing=field):
                self.assertFalse(schema.is_valid({"schema": "loud.import.v1", "tracks": [], "playlists": [{"name": "Mix", "artwork": cover}]}))

    def test_malformed_sidecar_types_are_not_silently_defaulted(self):
        schema = validator("s2y-playlist-artwork.schema.json")
        valid = {"schema": "s2y.playlist-artwork.v1", "playlists": [{"name": "Mix", "artwork": artwork()}]}
        for value in (None, 1, {}, []):
            invalid = copy.deepcopy(valid)
            invalid["base_path"] = value
            with self.subTest(base_path=value):
                self.assertFalse(schema.is_valid(invalid))
        for field, value in (("origin", 1), ("name", None), ("artwork", None)):
            invalid = copy.deepcopy(valid)
            invalid["playlists"][0][field] = value
            with self.subTest(field=field):
                self.assertFalse(schema.is_valid(invalid))


def validate_bundle(bundle):
    contracts = {
        "loud-import.json": "codec-import.schema.json",
        "codec-import.json": "codec-import.schema.json",
        "playlist-artwork.json": "s2y-playlist-artwork.schema.json",
        "track-artwork.json": "s2y-track-artwork.schema.json",
    }
    failures = 0
    for document, schema in contracts.items():
        path = bundle / document
        if not path.exists() and document != "loud-import.json":
            continue
        data = json.loads(path.read_text())
        errors = list(validator(schema).iter_errors(data))
        print(f"{document}: {len(errors)} schema errors")
        for error in errors[:10]:
            print(f"  {error.json_path}: {error.message}")
        failures += len(errors)
    return failures == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    success = unittest.main(argv=[__file__], exit=False).result.wasSuccessful()
    if args.bundle:
        success = validate_bundle(args.bundle) and success
    raise SystemExit(0 if success else 1)
