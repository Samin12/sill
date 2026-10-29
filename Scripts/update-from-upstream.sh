#!/bin/bash
# Used by the signed app's Update & Restart button. --prepare-only stops after merging, for
# diagnostics and the real-Git fixture checks; it never builds, pushes or touches an installed app.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
prepare_only=0
if [ "${1:-}" = --prepare-only ]; then prepare_only=1; shift; fi
[ "$#" = 4 ] || { echo 'Usage: update-from-upstream.sh [--prepare-only] CHECKOUT FORK UPSTREAM APP' >&2; exit 2; }
checkout=$1; fork=$2; upstream=$3; app=$4
fail() { echo "Update stopped: $*" >&2; exit 1; }
[[ "$fork" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid fork repository.'
[[ "$upstream" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid original repository.'
cd -P "$checkout"
[ "$(git rev-parse --show-toplevel)" = "$PWD" ] || fail 'The source folder is not the checkout root.'
[ "$(git symbolic-ref --quiet --short HEAD)" = main ] || fail 'Switch the source checkout to main first.'
[ -z "$(git status --porcelain --untracked-files=all)" ] || fail 'The source checkout has unsaved changes. Commit or stash them first.'
[ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ] || fail 'Finish the existing merge first.'
[ ! -d "$(git rev-parse --git-path rebase-merge)" ] || fail 'Finish the existing rebase first.'
[ ! -d "$(git rev-parse --git-path rebase-apply)" ] || fail 'Finish the existing rebase first.'
matches_repository() {
    case "$1" in
        "https://github.com/$2"|"https://github.com/$2.git"|"git@github.com:$2.git"|"ssh://git@github.com/$2.git") return 0 ;;
        *) return 1 ;;
    esac
}
origin_url="$(git config --get-all remote.origin.url)"
matches_repository "$origin_url" "$fork" || fail 'origin no longer points to the configured fork.'
matches_repository "$(git config --get-all remote.origin.pushurl || printf '%s' "$origin_url")" "$fork" \
    || fail 'origin pushes to a different repository.'
matches_repository "$(git config --get-all remote.upstream.url)" "$upstream" || fail 'upstream no longer points to the original repository.'
lock="$(git rev-parse --git-path sill-source-update.lock)"
mkdir "$lock" 2>/dev/null || fail 'Another source update is already running.'
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

echo 'Fetching your fork and the original Sill…'
git fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
git fetch --no-tags upstream refs/heads/main:refs/remotes/upstream/main
git merge --ff-only origin/main || fail 'The checkout and your fork diverged. Reconcile them before updating.'
if ! git merge --no-edit upstream/main; then
    if [ -e "$(git rev-parse --git-path MERGE_HEAD)" ]; then git merge --abort; fi
    fail 'The original has conflicting changes. The merge was cancelled; the installed app is unchanged.'
fi
revision="$(git rev-parse HEAD)"
if [ "$prepare_only" = 1 ]; then
    echo "Source prepared at $revision. Nothing was built, pushed or installed."
    exit 0
fi

gh="$(command -v gh || true)"
[ -n "$gh" ] || fail 'GitHub CLI is needed to sync your fork.'
"$gh" auth status --active >/dev/null 2>&1 || fail 'Sign in to GitHub CLI before updating.'
echo 'Building and signing the updated app…'
Scripts/make-app.sh
staged="$PWD/.build/Sill.app"
/usr/bin/codesign --verify --deep --strict "$staged"
[ -f "$staged/Contents/Resources/update-from-upstream.sh" ] || fail 'The build lost its source updater.'
staged_revision="$(/usr/libexec/PlistBuddy -c 'Print :SillSourceRevision' "$staged/Contents/Info.plist")"
[ "$staged_revision" = "$revision" ] || fail 'The built app does not match the prepared source.'
if [ -d "$app" ]; then
    before="$(/usr/bin/codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
    after="$(/usr/bin/codesign -d -r- "$staged" 2>&1 | sed -n 's/^designated => //p')"
    [ -n "$before" ] && [ "$before" = "$after" ] || fail 'The signing identity changed. The installed app was kept to preserve its permissions.'
fi
[ -z "$(git status --porcelain --untracked-files=all)" ] && [ "$(git rev-parse HEAD)" = "$revision" ] \
    || fail 'The checkout changed during the build. The installed app is unchanged.'
echo 'Syncing your fork…'
git -c credential.helper= -c "credential.helper=!\"$gh\" auth git-credential" push origin HEAD:refs/heads/main
echo 'Installing and restarting Sill…'
# The normal installer builds from the warm cache, verifies the signature, and only then quits
# the old host through HostShutdown. The helper's log is a file, so it survives the app exiting.
SILL_INSTALL_DIR="$(dirname "$app")" Scripts/make-app.sh --install --open
echo 'Sill was updated successfully.'
