#!/bin/zsh
# Verifies that docs/status.md still matches reality instead of drifting.
# It runs the offline suites and compares the recorded counts; it also reports
# whether HEAD has moved past the commit the status was verified at.
set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"

status_file=docs/status.md
[[ -f $status_file ]] || { print -r -- "missing $status_file"; exit 1; }

field() {
  grep -m1 "^| $1 |" "$status_file" | awk -F'|' '{gsub(/^ +| +$/, "", $3); print $3}'
}

recorded_commit=$(field "verified-at-commit")
recorded_debug=$(field "debug-tests")
recorded_release=$(field "release-tests")

print -r -- "running offline suites..."
cd Packages/MacEaseCore
debug_count=$(swift test 2>&1 | grep -oE 'Test run with [0-9]+ tests' | tail -1 |
  grep -oE '[0-9]+')
release_count=$(swift test -c release 2>&1 |
  grep -oE 'Test run with [0-9]+ tests' | tail -1 | grep -oE '[0-9]+')
cd "$repo_root"

typeset -i failures=0
compare() {
  if [[ $2 != $3 ]]; then
    print -r -- "$1: status says $2, measured $3"
    (( failures += 1 ))
  else
    print -r -- "$1: $3"
  fi
}
compare debug-tests "$recorded_debug" "$debug_count"
compare release-tests "$recorded_release" "$release_count"

head_commit=$(git rev-parse --short HEAD)
if [[ $recorded_commit != $head_commit ]]; then
  print -r -- "note: status verified at $recorded_commit, HEAD is $head_commit"
fi

(( failures == 0 )) || exit 1
print -r -- "status matches"
