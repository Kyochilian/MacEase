#!/bin/zsh
# Checks only the test counts recorded in docs/status.md. Other status fields
# require their own evidence.
#
# With no arguments it runs both offline suites itself. CI has already run
# them, so it passes the counts it measured instead of paying for a second
# full build.
set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"

debug_count=
release_count=

while (( $# > 0 )); do
  case "$1" in
    --debug-count)
      debug_count="$2"
      shift 2
      ;;
    --release-count)
      release_count="$2"
      shift 2
      ;;
    -h|--help)
      print -r -- "usage: $0 [--debug-count N --release-count N]"
      exit 0
      ;;
    *)
      print -u2 -r -- "unknown argument: $1"
      exit 2
      ;;
  esac
done

if [[ -n $debug_count || -n $release_count ]]; then
  # A half-supplied pair would silently measure one suite and trust the other.
  if [[ -z $debug_count || -z $release_count ]]; then
    print -u2 -r -- "--debug-count and --release-count must be given together"
    exit 2
  fi
  for supplied in "$debug_count" "$release_count"; do
    if [[ $supplied != <-> ]]; then
      print -u2 -r -- "not a test count: $supplied"
      exit 2
    fi
  done
fi

status_file=docs/status.md
[[ -f $status_file ]] || { print -r -- "missing $status_file"; exit 1; }

field() {
  grep -m1 "^| $1 |" "$status_file" | awk -F'|' '{gsub(/^ +| +$/, "", $3); print $3}'
}

recorded_commit=$(field "verified-at-commit")
recorded_debug=$(field "debug-tests")
recorded_release=$(field "release-tests")

if [[ -z $debug_count ]]; then
  print -r -- "running offline suites..."
  cd Packages/MacEaseCore
  debug_count=$(swift test 2>&1 | grep -oE 'Test run with [0-9]+ tests' | tail -1 |
    grep -oE '[0-9]+')
  release_count=$(swift test -c release 2>&1 |
    grep -oE 'Test run with [0-9]+ tests' | tail -1 | grep -oE '[0-9]+')
  cd "$repo_root"
fi

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
if [[ $recorded_commit != working-tree* && $recorded_commit != $head_commit ]]; then
  print -r -- "note: status verified at $recorded_commit, HEAD is $head_commit"
fi

(( failures == 0 )) || exit 1
print -r -- "recorded test counts match"
