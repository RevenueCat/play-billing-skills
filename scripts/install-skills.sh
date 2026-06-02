#!/usr/bin/env bash
# install-skills.sh — symlink every Play Billing skill into a target skills
# directory so flat-layout skill loaders (Claude Code, Android Studio Agent
# mode, Gemini) discover them.
#
# Background. Claude Code expects ~/.claude/skills/<slug>/SKILL.md.
# This repo organizes 45 skills under two top-level collections:
#   google-play/<slug>/SKILL.md   (raw Play Billing Library workflows)
#   revenuecat/<slug>/SKILL.md    (RevenueCat Android SDK workflows)
# Several slugs intentionally collide between the two collections (setup,
# error-handling, purchase-flow, plan-changes, ...). To install both side
# by side, this script prefixes each symlink with gp- or rc- so the two
# collections coexist in a single flat target directory.
#
# Usage:
#   ./scripts/install-skills.sh                       # install both collections to ~/.claude/skills
#   ./scripts/install-skills.sh /custom/path          # install to a custom dir
#   ./scripts/install-skills.sh --only google-play    # install only one collection
#   ./scripts/install-skills.sh --only revenuecat /p  # one collection, custom dir
#   ./scripts/install-skills.sh --uninstall           # remove links from default target
#   ./scripts/install-skills.sh --uninstall /p        # remove links from a custom dir

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="install"
only=""
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)
      mode="uninstall"
      shift
      ;;
    --only)
      only="${2:-}"
      if [[ "$only" != "google-play" && "$only" != "revenuecat" ]]; then
        echo "Error: --only must be 'google-play' or 'revenuecat'" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

TARGET="${positional[0]:-$HOME/.claude/skills}"

prefix_for() {
  case "$1" in
    google-play) echo "gp" ;;
    revenuecat)  echo "rc" ;;
    *) echo "Error: unknown collection $1" >&2; exit 1 ;;
  esac
}

if [[ "$mode" == "uninstall" ]]; then
  if [[ ! -d "$TARGET" ]]; then
    echo "Target directory does not exist: $TARGET"
    exit 0
  fi
  echo "Uninstalling Play Billing skill links from $TARGET"
  removed=0
  for link in "$TARGET"/*; do
    [[ -L "$link" ]] || continue
    target_path="$(readlink "$link")"
    if [[ "$target_path" == "$REPO_ROOT"/google-play/* || "$target_path" == "$REPO_ROOT"/revenuecat/* ]]; then
      rm "$link"
      echo "  removed: $(basename "$link")"
      removed=$((removed + 1))
    fi
  done
  echo ""
  echo "Removed $removed symlinks."
  exit 0
fi

mkdir -p "$TARGET"
echo "Installing Play Billing skills"
echo "  source: $REPO_ROOT"
echo "  target: $TARGET"
if [[ -n "$only" ]]; then
  echo "  collection: $only only"
else
  echo "  collections: google-play, revenuecat"
fi
echo ""

linked=0
skipped=0
collections=("google-play" "revenuecat")
if [[ -n "$only" ]]; then
  collections=("$only")
fi

for collection in "${collections[@]}"; do
  prefix="$(prefix_for "$collection")"
  collection_dir="$REPO_ROOT/$collection"
  [[ -d "$collection_dir" ]] || continue

  while IFS= read -r skill_md; do
    skill_dir="$(dirname "$skill_md")"
    slug="$(basename "$skill_dir")"
    link_name="${prefix}-${slug}"
    link="$TARGET/$link_name"

    if [[ -L "$link" ]]; then
      skipped=$((skipped + 1))
      continue
    elif [[ -e "$link" ]]; then
      echo "  WARN: $link_name already exists at $link and is not a symlink; skipping"
      skipped=$((skipped + 1))
      continue
    fi

    ln -s "$skill_dir" "$link"
    echo "  link: $link_name -> $collection/$slug"
    linked=$((linked + 1))
  done < <(find "$collection_dir" -name "SKILL.md" -type f)
done

echo ""
echo "Linked $linked skills, skipped $skipped."
echo "Restart Claude Code (or your agent) to pick them up."
