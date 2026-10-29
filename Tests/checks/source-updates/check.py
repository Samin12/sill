"""Exercise the real updater's Git operations against isolated local bare repositories."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1)) / "Scripts/update-from-upstream.sh"
FORK = "https://github.com/fixture-fork/sill.git"
UPSTREAM = "https://github.com/fixture-original/sill.git"


class SourceUpdates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sill source updates ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=str(self.root / "gitconfig"),
                        GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
        for key, value in [("user.name", "Updater Fixture"), ("user.email", "fixture@example.invalid"),
                           ("commit.gpgsign", "false"), ("init.defaultBranch", "main")]:
            self.git("config", "--global", key, value)
        self.seed = self.root / "original working tree"
        self.git("init", str(self.seed))
        self.commit(self.seed, "shared.txt", "base\n")
        self.fork = self.root / "fork.git"
        self.original = self.root / "original.git"
        self.git("clone", "--bare", str(self.seed), str(self.fork))
        self.git("clone", "--bare", str(self.seed), str(self.original))
        for url, path in [(FORK, self.fork), (UPSTREAM, self.original)]:
            self.git("config", "--global", f"url.{path.as_uri()}.insteadOf", url)
        self.checkout = self.root / "app checkout"
        self.git("clone", FORK, str(self.checkout))
        self.git("remote", "add", "upstream", UPSTREAM, cwd=self.checkout)
        self.commit(self.checkout, "custom.txt", "keep this updater\n")
        self.git("push", "origin", "main", cwd=self.checkout)
        self.before = self.head(self.checkout)
        self.app = self.root / "Sill.app"
        self.app.mkdir()
        (self.app / "keep.txt").write_text("installed app")

    def git(self, *args, cwd=None, check=True):
        return subprocess.run(["/usr/bin/git", *args], cwd=cwd or self.root, env=self.env,
                              text=True, capture_output=True, check=check).stdout.strip()

    def commit(self, repo, name, text):
        (repo / name).write_text(text)
        self.git("add", name, cwd=repo)
        self.git("commit", "-m", name, cwd=repo)

    def head(self, repo):
        return self.git("rev-parse", "HEAD", cwd=repo)

    def advance(self, name="upstream.txt", text="new upstream code\n"):
        self.commit(self.seed, name, text)
        self.git("push", str(self.original), "main", cwd=self.seed)
        return self.head(self.seed)

    def run_update(self, expected=0):
        result = subprocess.run(["/bin/bash", str(SCRIPT), "--prepare-only", str(self.checkout),
                                 "fixture-fork/sill", "fixture-original/sill", str(self.app)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual((self.app / "keep.txt").read_text(), "installed app")
        return result.stdout + result.stderr

    def test_merge_keeps_custom_commits_and_does_not_install_or_push(self):
        latest = self.advance()
        self.run_update()
        for ancestor in [latest, self.before]:
            self.git("merge-base", "--is-ancestor", ancestor, "HEAD", cwd=self.checkout)
        self.assertEqual((self.checkout / "custom.txt").read_text(), "keep this updater\n")
        self.assertEqual((self.checkout / "upstream.txt").read_text(), "new upstream code\n")
        self.assertEqual(self.head(self.fork), self.before)
        self.assertEqual(self.git("status", "--porcelain", cwd=self.checkout), "")

    def test_current_source_is_a_no_op(self):
        self.run_update()
        self.assertEqual(self.head(self.checkout), self.before)

    def test_tracked_edits_are_kept(self):
        (self.checkout / "custom.txt").write_text("unfinished work")
        self.assertIn("unsaved changes", self.run_update(expected=1))
        self.assertEqual((self.checkout / "custom.txt").read_text(), "unfinished work")
        self.assertEqual(self.head(self.checkout), self.before)

    def test_untracked_files_are_kept(self):
        (self.checkout / "notes.txt").write_text("do not delete")
        self.assertIn("unsaved changes", self.run_update(expected=1))
        self.assertEqual((self.checkout / "notes.txt").read_text(), "do not delete")

    def test_conflicting_merge_is_aborted(self):
        self.commit(self.checkout, "shared.txt", "fork change\n")
        self.git("push", "origin", "main", cwd=self.checkout)
        before = self.head(self.checkout)
        self.advance("shared.txt", "original change\n")
        self.assertIn("merge was cancelled", self.run_update(expected=1))
        self.assertEqual(self.head(self.checkout), before)
        self.assertFalse((self.checkout / ".git/MERGE_HEAD").exists())
        self.assertEqual((self.checkout / "shared.txt").read_text(), "fork change\n")
        self.assertEqual(self.git("status", "--porcelain", cwd=self.checkout), "")

    def test_diverged_fork_is_not_reset_or_force_pushed(self):
        self.commit(self.checkout, "local.txt", "local work")
        before = self.head(self.checkout)
        other = self.root / "other checkout"
        self.git("clone", FORK, str(other))
        self.commit(other, "remote.txt", "remote work")
        self.git("push", "origin", "main", cwd=other)
        self.assertIn("diverged", self.run_update(expected=1))
        self.assertEqual(self.head(self.checkout), before)
        self.assertEqual(self.head(self.fork), self.head(other))

    def test_wrong_branch_is_rejected(self):
        self.git("checkout", "-b", "work", cwd=self.checkout)
        self.assertIn("Switch the source checkout to main", self.run_update(expected=1))

    def test_wrong_push_destination_is_rejected(self):
        self.git("remote", "set-url", "--push", "origin", UPSTREAM, cwd=self.checkout)
        self.assertIn("pushes to a different repository", self.run_update(expected=1))

    def test_wrong_original_repository_is_rejected(self):
        self.git("remote", "set-url", "upstream", FORK, cwd=self.checkout)
        self.assertIn("original repository", self.run_update(expected=1))

    def test_parallel_update_is_rejected(self):
        lock = self.checkout / ".git/sill-source-update.lock"
        lock.mkdir()
        self.assertIn("already running", self.run_update(expected=1))
        self.assertTrue(lock.exists())


unittest.main(verbosity=2)
