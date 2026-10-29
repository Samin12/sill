# Updates for Samin's fork

Sill's menu has **Check for Updates…** (or **Update Sill…** when a newer original
commit is known). In Settings → General, **Update & Restart** fetches
`Saffsanity/sill/main`, merges it into this checkout's `main`, builds and signs
the app, pushes the merged history to `Samin12/sill/main`, then installs and
restarts `/Applications/Sill.app`. It preserves this fork's updater and other
commits. It never force pushes or discards local edits. It also works when the
release number has not changed. Automatic checks run on launch and once a day;
installing an update requires the button.

The original release-page checker stays in builds without
`Packaging/SourceUpdates.plist`. This fork opts into source updates with that
file. `Scripts/make-app.sh` records the checkout path, fork, original repository,
source commit and latest merged original commit in the signed app bundle, and
includes `Scripts/update-from-upstream.sh` as a signed resource.

Keep the checkout at the path recorded by the installed build. Updating needs
Xcode, a signed-in GitHub CLI with write access to the fork, and the same Apple
Development signing identity used to install Sill. Changing that identity stops
the update before installation so the current permissions remain valid. The
checkout must be clean, on `main`, with `origin` pointing to `Samin12/sill` and
`upstream` pointing to `Saffsanity/sill`.

Merge conflicts are aborted. Dirty checkouts, divergent fork history, build
errors, changed signatures and push failures stop before replacing the app.
The updater never resets or cleans the checkout: a successful source merge can
remain locally after a later failure, ready to retry or inspect. Details are
in `~/Library/Logs/Sill/SourceUpdate.log`, opened by **Open Update Log**.
The existing installer quits the host only after its build and signing succeed.
Settings, pairing and launch-at-login registration keep the same bundle ID.

Validation: `Tests/checks/source-updates/run.sh` exercises real Git operations
with isolated local repositories, including preserving fork commits, conflicts,
uncommitted work, divergent history, wrong remotes and concurrent updates.
Its `--prepare-only` helper mode never builds, pushes or installs anything.
