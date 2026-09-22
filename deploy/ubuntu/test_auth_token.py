"""Read-only authentication helper regressions using synthetic credentials only."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("codec_auth_token", Path(__file__).with_name("auth_token.py"))
auth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(auth)


class Terminal(io.StringIO):
    def isatty(self):
        return True


class AuthTokenTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.environment = self.root / "etc/codec/codec.env"
        self.environment.parent.mkdir(parents=True)

    def write_environment(self, content, mode=0o600):
        self.environment.write_text(content)
        self.environment.chmod(mode)

    def invoke(self, arguments, output=None, error=None):
        output = io.StringIO() if output is None else output
        error = io.StringIO() if error is None else error
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            status = auth.main(arguments)
        return status, output.getvalue(), error.getvalue()

    def test_installer_json_quoting_round_trips_every_printable_ascii_character(self):
        token = "synthetic-" + "".join(chr(code) for code in range(32, 127)) + "-fixture"
        self.assertEqual(auth.parse_environment("CODEC_AUTH_TOKEN=" + json.dumps(token) + "\n"), token)

    def test_systemd_quoting_preserves_interior_spaces_and_literal_characters(self):
        cases = [
            ("alpha   bravo", "alpha   bravo"),
            ('alpha"bravo"', 'alpha"bravo"'),
            (r'alpha\ bravo\\char', "alpha bravo\\char"),
            (r'"alpha\$bravo\`char"', "alpha$bravo`char"),
            (r'"alpha\tbravo"', r"alpha\tbravo"),
            (r'"alpha\\$bravo"', r"alpha\$bravo"),
            (r"'alpha\$bravo`char'", r"alpha\$bravo`char"),
            ('"alpha"  \'bravo\'', "alphabravo"),
            ("alpha # bravo", "alpha # bravo"),
            ('"  alpha   bravo  "', "alpha   bravo"),
            ("   '  alpha   bravo  '   ", "alpha   bravo"),
            (r'"alpha\"bravo"', 'alpha"bravo'),
            (r"alpha\$bravo", "alpha$bravo"),
        ]
        for assignment, expected in cases:
            with self.subTest(assignment=assignment):
                self.assertEqual(auth.parse_environment("CODEC_AUTH_TOKEN=" + assignment + "\n"), expected)

    def test_comments_whitespace_and_other_variables_do_not_change_the_token(self):
        text = '# note\n; note\nIGNORED="a b"\nNO_EQUALS\n  CODEC_AUTH_TOKEN = "fixture-token"\r\n'
        self.assertEqual(auth.parse_environment(text), "fixture-token")

    def test_ambiguous_malformed_multiline_empty_and_control_values_are_rejected(self):
        invalid = [
            "OTHER=value\n", 'CODEC_AUTH_TOKEN=""\n', 'CODEC_AUTH_TOKEN="   "\n',
            "CODEC_AUTH_TOKEN=first\n CODEC_AUTH_TOKEN=second\n",
            'CODEC_AUTH_TOKEN="unterminated\n', "CODEC_AUTH_TOKEN=trailing\\\n",
            'OTHER="nested\nCODEC_AUTH_TOKEN=not-an-assignment\n"\n',
            "export CODEC_AUTH_TOKEN=value\n", "CODEC_AUTH_TOKEN=a\x00b\n",
            "CODEC_AUTH_TOKEN=a\tb\n", "CODEC_AUTH_TOKEN=not-ascii-☀\n",
            "\ufeffCODEC_AUTH_TOKEN=value\n",
        ]
        for text in invalid:
            with self.subTest(text=text), self.assertRaises(auth.AuthTokenError):
                auth.parse_environment(text)

    def test_reading_preserves_bytes_mode_and_mtime(self):
        self.write_environment('CODEC_AUTH_TOKEN="  fixture   $`\\\\quote\\\"  "\n', 0o400)
        before, metadata = self.environment.read_bytes(), self.environment.stat()
        self.assertEqual(auth.read_token(self.environment, expected_uid=os.geteuid()), 'fixture   $`\\quote"')
        self.assertEqual(self.environment.read_bytes(), before)
        after = self.environment.stat()
        self.assertEqual((after.st_mode, after.st_mtime_ns, after.st_ino), (metadata.st_mode, metadata.st_mtime_ns, metadata.st_ino))

    def test_reader_rejects_nonprivate_wrong_owner_oversized_and_invalid_utf8(self):
        self.write_environment("CODEC_AUTH_TOKEN=synthetic\n", 0o644)
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment)
        self.environment.chmod(0o600)
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment, expected_uid=os.geteuid() + 1)
        self.write_environment("x" * (auth.MAX_ENV_BYTES + 1))
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment)
        self.environment.write_bytes(b"CODEC_AUTH_TOKEN=\xff\n")
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment)

    def test_reader_rejects_leaf_and_parent_symlink_escapes(self):
        outside = self.root / "other.env"
        outside.write_text("CODEC_AUTH_TOKEN=outside-fixture\n")
        outside.chmod(0o600)
        self.environment.symlink_to(outside)
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment)
        self.environment.unlink()
        self.environment.parent.rmdir()
        alternate = self.root / "alternate"
        alternate.mkdir()
        (alternate / "codec.env").write_text("CODEC_AUTH_TOKEN=outside-fixture\n")
        (alternate / "codec.env").chmod(0o600)
        self.environment.parent.symlink_to(alternate, target_is_directory=True)
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment)

    def test_reader_rejects_special_file_without_blocking(self):
        os.mkfifo(self.environment, 0o600)
        with self.assertRaises(auth.AuthTokenError):
            auth.read_token(self.environment)

    def test_default_refuses_before_reading_unless_both_outputs_are_terminals(self):
        for output, error in [(io.StringIO(), io.StringIO()), (Terminal(), io.StringIO()), (io.StringIO(), Terminal())]:
            with mock.patch.object(auth, "read_token") as read:
                status, text, errors = self.invoke([], output, error)
                self.assertEqual(status, 1)
                self.assertEqual(text, "")
                self.assertIn("requires a terminal", errors)
                read.assert_not_called()

    def test_production_requires_root_and_reads_only_the_unit_environment_file(self):
        with mock.patch.object(auth.os, "geteuid", return_value=501), mock.patch.object(auth, "read_token") as read:
            status, text, errors = self.invoke(["--raw"])
            self.assertEqual(status, 1)
            self.assertEqual(text, "")
            self.assertIn("requires root", errors)
            read.assert_not_called()
        with mock.patch.object(auth.os, "geteuid", return_value=0), mock.patch.object(auth, "read_token", return_value="synthetic") as read:
            status, text, errors = self.invoke(["--raw"])
            self.assertEqual((status, text, errors), (0, "synthetic\n", ""))
            read.assert_called_once_with(Path("/etc/codec/codec.env"), expected_uid=0)

    def test_interactive_output_is_labeled_and_contains_the_existing_token(self):
        self.write_environment('CODEC_AUTH_TOKEN="existing-fixture"\n')
        status, text, errors = self.invoke(["--root-dir", str(self.root)], Terminal(), Terminal())
        self.assertEqual((status, errors), (0, ""))
        self.assertEqual(text, "Codec auth token:\nexisting-fixture\n")

    def test_raw_cli_does_not_execute_expand_change_or_fall_back_to_caller_environment(self):
        marker = self.root / "must-not-exist"
        token = 'fixture  $HOME `id` $(touch ' + str(marker) + ') # " \\ tail'
        self.write_environment("CODEC_AUTH_TOKEN=" + json.dumps(token) + "\n")
        before = self.environment.read_bytes()
        command = [sys.executable, str(Path(auth.__file__)), "--raw", "--root-dir", str(self.root)]
        result = subprocess.run(command, capture_output=True, text=True, env=dict(os.environ, CODEC_AUTH_TOKEN="wrong-token", LOUD_AUTH_TOKEN="wrong-token"))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, token + "\n", ""))
        self.assertEqual(self.environment.read_bytes(), before)
        self.assertFalse(marker.exists())
        self.environment.unlink()
        result = subprocess.run(command, capture_output=True, text=True, env=dict(os.environ, CODEC_AUTH_TOKEN="wrong-token"))
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertNotIn("wrong-token", result.stderr)
        self.assertFalse(self.environment.exists())

    def test_staging_root_cannot_be_system_root_or_a_symlink(self):
        link = self.root / "linked-root"
        link.symlink_to(self.root, target_is_directory=True)
        for root in ["/", "/./", "/usr/..", str(link)]:
            with self.subTest(root=root), mock.patch.object(auth, "read_token") as read:
                status, text, _ = self.invoke(["--raw", "--root-dir", root])
                self.assertEqual((status, text), (1, ""))
                read.assert_not_called()

    def test_failures_and_bad_arguments_never_echo_secret_values(self):
        secret = "synthetic-secret-do-not-echo"
        self.write_environment('CODEC_AUTH_TOKEN="' + secret + '\n')
        status, text, errors = self.invoke(["--raw", "--root-dir", str(self.root)])
        self.assertEqual((status, text), (1, ""))
        self.assertNotIn(secret, errors)
        self.assertNotIn("Traceback", errors)
        result = subprocess.run([sys.executable, str(Path(auth.__file__)), "--bad=" + secret], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_staging_resolution_errors_do_not_print_tracebacks(self):
        with mock.patch.object(Path, "resolve", side_effect=RuntimeError("synthetic-private-detail")):
            status, text, errors = self.invoke(["--raw", "--root-dir", str(self.root)])
        self.assertEqual((status, text), (1, ""))
        self.assertNotIn("synthetic-private-detail", errors)
        self.assertNotIn("Traceback", errors)


if __name__ == "__main__":
    unittest.main()
