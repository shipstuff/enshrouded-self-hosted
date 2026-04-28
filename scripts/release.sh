#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release.sh <version> [--push] [--skip-checks] [--allow-non-main]

Prepares a versioned Enshrouded release from this source repo.

The version must be X.Y.Z. The script:
  - updates helm/enshrouded/Chart.yaml version and appVersion to X.Y.Z
  - updates default server and stats API image tags to X.Y.Z
  - runs local release checks
  - commits the release metadata update when needed
  - creates an annotated vX.Y.Z git tag
  - optionally pushes the branch and tag

GitHub Actions publish:
  - ghcr.io/shipstuff/enshrouded-server:X.Y.Z
  - ghcr.io/shipstuff/enshrouded-live-stats-api:X.Y.Z
  - oci://ghcr.io/shipstuff/charts/enshrouded --version X.Y.Z
EOF
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

version="$1"
shift

allow_non_main=0
push=0
run_checks=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-non-main)
      allow_non_main=1
      ;;
    --push)
      push=1
      ;;
    --skip-checks)
      run_checks=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be X.Y.Z, got '${version}'" >&2
  exit 2
fi

tag="v${version}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

current_branch="$(git branch --show-current)"
if [ "${allow_non_main}" -eq 0 ] && [ "${current_branch}" != "main" ]; then
  echo "Releases should be cut from main; currently on '${current_branch}'." >&2
  echo "Use --allow-non-main only for deliberate dry runs or backports." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Tracked working tree changes must be clean before preparing a release." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "Tag already exists locally: ${tag}" >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
  echo "Tag already exists on origin: ${tag}" >&2
  exit 1
fi

sed -i -E \
  -e "s/^version:.*/version: ${version}/" \
  -e "s/^appVersion:.*/appVersion: \"${version}\"/" \
  helm/enshrouded/Chart.yaml

tmp_values="$(mktemp)"
awk -v tag="${version}" '
  /^image:/ {
    in_root_image = 1
    in_stats_api = 0
    in_stats_image = 0
    print
    next
  }
  /^statsApi:/ {
    in_root_image = 0
    in_stats_api = 1
    in_stats_image = 0
    print
    next
  }
  /^[^[:space:]]/ && $0 !~ /^image:/ && $0 !~ /^statsApi:/ {
    in_root_image = 0
    in_stats_api = 0
    in_stats_image = 0
  }
  in_stats_api && /^  image:/ {
    in_stats_image = 1
    print
    next
  }
  in_root_image && /^  tag:/ {
    print "  tag: " tag
    in_root_image = 0
    next
  }
  in_stats_image && /^    tag:/ {
    print "    tag: " tag
    in_stats_image = 0
    next
  }
  { print }
' helm/enshrouded/values.yaml > "${tmp_values}"
mv "${tmp_values}" helm/enshrouded/values.yaml

if [ "${run_checks}" -eq 1 ]; then
  bash -n image/entrypoint.sh
  bash -n bare-linux/install.sh
  helm lint ./helm/enshrouded
  helm template enshrouded ./helm/enshrouded >/dev/null
  git diff --check
fi

if ! git diff --quiet; then
  git add helm/enshrouded/Chart.yaml helm/enshrouded/values.yaml
  git commit -m "release: pin to v${version}"
fi

git tag -a "${tag}" -m "Release ${version}"

echo "Created ${tag} at $(git rev-parse --short HEAD)"
if [ "${push}" -eq 1 ]; then
  git push origin HEAD
  git push origin "${tag}"
else
  echo "Push with:"
  echo "  git push origin HEAD"
  echo "  git push origin ${tag}"
fi
