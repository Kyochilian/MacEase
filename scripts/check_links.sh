#!/bin/zsh
# Fails when a relative link or script path referenced by README.md or docs/
# does not exist in the working tree. It exists so the public repository
# cannot drift back into documenting files it does not ship.
set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"

typeset -i failures=0

# A clean clone only has tracked files, so existence on this machine is not
# enough: the target must actually be committed.
# NB: not named `path`, which zsh ties to $PATH.
typeset -A tracked
while read -r tracked_file; do
  tracked[$tracked_file]=1
done < <(git ls-files)

check() {
  local source_file=$1 target=$2
  local normalised=${target#./}
  if [[ -z ${tracked[$normalised]:-} ]]; then
    print -r -- "not tracked: $normalised (referenced by $source_file)"
    (( failures += 1 ))
  fi
}

# Only tracked markdown is scanned: untracked maintainer notes are not part
# of what a clean clone promises.
for source_file in ${(f)"$(git ls-files '*.md')"}; do
  [[ -f $source_file ]] || continue
  local base=${source_file:h}
  # Markdown links of the form [text](path) with no scheme and no anchor.
  grep -oE '\]\([^):#]+\)' "$source_file" 2>/dev/null | sed -E 's/^\]\(|\)$//g' |
    while read -r target; do
      [[ $target == http* || $target == mailto:* ]] && continue
      check "$source_file" "$base/$target"
    done
  # Shell invocations of repository scripts.
  grep -oE '(\./)?scripts/[A-Za-z0-9_./-]+\.sh' "$source_file" 2>/dev/null |
    sed -E 's|^\./||' | sort -u |
    while read -r target; do
      check "$source_file" "$target"
    done
done

if (( failures > 0 )); then
  print -r -- "$failures broken reference(s)"
  exit 1
fi
print -r -- "all documented paths exist"
