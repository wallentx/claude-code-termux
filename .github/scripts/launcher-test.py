#!/usr/bin/env python3
"""Exercise both launch paths with native executable fixtures; no Claude/network needed."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENV_KEYS = (
    "LD_PRELOAD", "LD_LIBRARY_PATH", "SSL_CERT_FILE", "TMPDIR", "BUN_TMPDIR",
    "BROWSER", "HTTPS_PROXY", "CLAUDE_CODE_PROXY_RESOLVES_HOSTS",
)


class LauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="claude-launcher-", dir=os.getenv("TMPDIR"))
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.compiler = os.environ.get("CC") or shutil.which("clang") or shutil.which("cc")
        if not cls.compiler:
            raise RuntimeError("A native C compiler is required")
        cls.launcher = cls.root / "launcher"
        subprocess.run([
            cls.compiler, "-D_GNU_SOURCE", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-o", str(cls.launcher), str(ROOT / "lib/claude_helper.c"),
        ], check=True)
        recorder = cls.root / "recorder.c"
        recorder.write_text('''
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    const char *names[] = {KEYS};
    printf("%d%c", argc, 0);
    for (int i = 0; i < argc; i++) printf("%s%c", argv[i], 0);
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        const char *value = getenv(names[i]);
        printf("%s%c", value ? value : "<unset>", 0);
    }
    const char *status = getenv("FIXTURE_EXIT");
    return status ? atoi(status) : 0;
}
'''.replace("KEYS", ", ".join('"' + key + '"' for key in ENV_KEYS)))
        cls.recorder = cls.root / "recorder"
        subprocess.run([cls.compiler, "-o", str(cls.recorder), str(recorder)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="case with spaces ", dir=self.root)
        self.addCleanup(self.temp.cleanup)
        self.case = Path(self.temp.name)
        self.prefix = self.case / "prefix"
        self.bin = self.prefix / "bin"
        self.bin.mkdir(parents=True)
        self.loader = self.prefix / "glibc/lib/ld-linux-aarch64.so.1"
        self.aether = self.bin / "aether-run"
        self.payload = self.bin / "claude.glibc"
        self.payload.write_text("fixture payload")
        self.payload.chmod(0o755)
        self.cert = self.prefix / "etc/tls/cert.pem"
        self.cert.parent.mkdir(parents=True)
        self.cert.write_text("fixture CA")
        self.command = self.bin / "claude"
        shutil.copy2(self.launcher, self.command)
        self.env = os.environ.copy()
        for name in list(self.env):
            if name.startswith("CLAUDE_TERMUX_") or name.lower().endswith("_proxy"):
                self.env.pop(name)
        self.env.update(
            PREFIX=str(self.prefix), TERMUX_VERSION="fixture",
            CLAUDE_TERMUX_NO_DNS_PROXY="1", HTTPS_PROXY="http://fixture.invalid:8080",
            CLAUDE_CODE_PROXY_RESOLVES_HOSTS="true",
            TMPDIR=str(self.case), BUN_TMPDIR=str(self.case),
            BROWSER="fixture-browser", LD_LIBRARY_PATH=str(self.case),
        )
        self.env.pop("FIXTURE_EXIT", None)

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.recorder, path)

    def invoke(self, *args, status=0):
        result = subprocess.run([str(self.command), *args], env=self.env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, status, result.stderr.decode())
        fields = result.stdout.decode().split("\0")
        argc = int(fields[0])
        return fields[1:argc + 1], dict(zip(ENV_KEYS, fields[argc + 1:-1]))

    def assert_legacy(self):
        args, env = self.invoke("--version")
        self.assertEqual(args, [str(self.loader), "--library-path", str(self.loader.parent),
                                str(self.payload), "--version"])
        self.assertEqual(env["LD_PRELOAD"], "<unset>")
        self.assertEqual(env["LD_LIBRARY_PATH"], "<unset>")

    def test_ordinary_termux_keeps_legacy_loader_and_cleanup(self):
        self.executable(self.loader)
        self.assert_legacy()

    def test_aether_without_package_loader_preserves_args_and_environment(self):
        self.executable(self.aether)
        forwarded = ["--version", "two words", "", "quote'\"", "line\nbreak"]
        args, env = self.invoke(*forwarded)
        self.assertEqual(args, [str(self.aether), "--", str(self.payload), *forwarded])
        self.assertEqual(env["LD_PRELOAD"], self.env.get("LD_PRELOAD", "<unset>"))
        self.assertEqual(env["LD_LIBRARY_PATH"], self.env["LD_LIBRARY_PATH"])
        self.assertEqual(env["SSL_CERT_FILE"], str(self.cert))
        for name in ENV_KEYS[3:]:
            self.assertEqual(env[name], self.env[name])

    def test_aether_is_preferred_when_both_runtimes_exist(self):
        self.executable(self.aether)
        self.executable(self.loader)
        self.assertEqual(self.invoke()[0], [str(self.aether), "--", str(self.payload)])

    def test_opt_out_keeps_legacy_path(self):
        self.executable(self.aether)
        self.executable(self.loader)
        for value in ("1", "true", "yes", "on"):
            with self.subTest(value=value):
                self.env["CLAUDE_TERMUX_NO_AETHER"] = value
                self.assert_legacy()

    def test_false_opt_out_still_uses_aether(self):
        self.executable(self.aether)
        for value in ("", "0", "false"):
            with self.subTest(value=value):
                self.env["CLAUDE_TERMUX_NO_AETHER"] = value
                self.assertEqual(self.invoke()[0][0], str(self.aether))

    def test_nonexecutable_aether_keeps_legacy_path(self):
        self.executable(self.loader)
        self.executable(self.aether)
        self.aether.chmod(0o644)
        self.assert_legacy()

    def test_path_lookup_does_not_select_unrelated_aether(self):
        self.executable(self.loader)
        fake_bin = self.case / "unrelated"
        self.executable(fake_bin / "aether-run")
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]
        self.assert_legacy()

    def test_aether_failure_is_not_retried_with_legacy_loader(self):
        self.executable(self.aether)
        self.executable(self.loader)
        self.env["FIXTURE_EXIT"] = "37"
        self.assertEqual(self.invoke("--version", status=37)[0][0], str(self.aether))

    def test_updates_still_intercept_before_runtime_and_certificate_checks(self):
        updater = self.bin / "claude-termux-update"
        self.executable(updater)
        self.cert.unlink()
        for aether in (False, True):
            if aether:
                self.executable(self.aether)
            for command in ("update", "upgrade", "install"):
                with self.subTest(aether=aether, command=command):
                    self.assertEqual(self.invoke(command, "--dry-run")[0],
                                     [str(updater), command, "--dry-run"])

    def test_aether_still_requires_payload_and_certificates(self):
        self.executable(self.aether)
        for path, message in ((self.payload, "Claude glibc payload"), (self.cert, "CA bundle")):
            content = path.read_bytes()
            path.unlink()
            result = subprocess.run([str(self.command)], env=self.env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn(message, result.stderr.decode())
            path.write_bytes(content)

    def test_installer_prerequisites_agree_with_launcher(self):
        # Dry-run only: simulate the architecture gate on portable CI hosts.
        uname = self.bin / "uname"
        uname.write_text(f"#!{shutil.which('bash')}\nprintf 'aarch64\\n'\n")
        uname.chmod(0o755)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        for aether, legacy, disabled, expected in (
            (False, False, "0", 1), (False, True, "0", 0),
            (True, False, "0", 0), (True, False, "1", 1),
            (True, False, "true", 1), (True, True, "yes", 0),
        ):
            with self.subTest(aether=aether, legacy=legacy, disabled=disabled):
                for enabled, path in ((aether, self.aether), (legacy, self.loader)):
                    if enabled:
                        self.executable(path)
                    else:
                        path.unlink(missing_ok=True)
                self.env["CLAUDE_TERMUX_NO_AETHER"] = disabled
                result = subprocess.run(["bash", str(ROOT / "install.sh"), "--dry-run"],
                                        env=self.env, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stdout.decode() + result.stderr.decode())


if __name__ == "__main__":
    unittest.main(verbosity=2)
