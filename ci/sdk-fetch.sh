#!/usr/bin/env bash
# CI: download release sdk-<SDK_ID> into <dir>, verify it and install it to
# sdk/. If this commit's sdk run is still building it, wait for that run.
# (Kept out of ci/sdk.sh, which is in sdk.yml's trigger paths.)
#   ci/sdk-fetch.sh <dir>
# Needs gh with GH_TOKEN (contents: read, actions: read) and GITHUB_SHA.
set -euo pipefail
S=$(dirname "$0")/sdk.sh
id=$("$S" id)
D=${1:?usage: $0 <dir>}
if ! gh release view "sdk-$id" >/dev/null 2>&1; then
	run=$(gh run list -w sdk.yml -c "${GITHUB_SHA:?}" --json databaseId,status \
		-q '[.[] | select(.status != "completed")][0].databaseId // empty')
	[ -n "$run" ] || { echo "sdk-fetch: no release sdk-$id and no sdk run building it" >&2; exit 1; }
	echo "sdk-fetch: sdk-$id not published yet; waiting for sdk run $run"
	gh run watch "$run" --exit-status --interval 60 > /dev/null
fi
gh release download "sdk-$id" -p "sdk-$id.tar.gz*" -D "$D"
# the .sha256 also lists sdk-<id>-legal-info.tar, which builds don't need
(cd "$D" && sha256sum -c --ignore-missing "sdk-$id.tar.gz.sha256")
"$S" install "$D/sdk-$id.tar.gz"
