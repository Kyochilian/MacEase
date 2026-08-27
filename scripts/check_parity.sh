#!/bin/zsh
# Checks docs/backend-parity.md against its own status vocabulary.
#
# A parity table is only useful if every cell means something. This fails when
# a capability row carries a status that is not one of the seven defined words
# — a typo, or a word someone invented mid-edit — and when the summary counts
# no longer match the rows they claim to summarise.
set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"

parity_file=docs/backend-parity.md
[[ -f $parity_file ]] || { print -r -- "missing $parity_file"; exit 1; }

awk '
BEGIN {
  split("historical-live-observed implemented-offline probe-only missing hold " \
        "experimental-nonshipping excluded", words, " ")
  for (i in words) known[words[i]] = 1
  failures = 0
}

# The capability tables are sections 1 to 6. The vocabulary table above them
# and the summary below are descriptions of the scheme, not uses of it, so
# they must not be counted as rows.
/^## 1\./ { counting = 1 }
/^## 7\./ { counting = 0 }
/^## 8\./ { in_summary = 1 }

/^\|/ {
  n = split($0, cells, "|")
  for (i = 1; i <= n; i++) {
    cell = cells[i]
    gsub(/^[ \t]+|[ \t]+$/, "", cell)
    # A status claim is a cell that is nothing but one backticked lowercase
    # token. Type names, endpoint paths and prose never take that shape.
    if (cell !~ /^`[a-z][a-z-]*`$/) continue
    token = substr(cell, 2, length(cell) - 2)

    if (!(token in known)) {
      printf "unknown status %s on line %d\n", token, NR
      failures++
      continue
    }
    if (counting) tally[token]++
    if (in_summary) {
      summary_token = token
      # The count sits in the next cell of the same row.
      next_cell = cells[i + 1]
      gsub(/^[ \t]+|[ \t]+$/, "", next_cell)
      claimed[summary_token] = next_cell
    }
  }
}

END {
  for (i in words) {
    word = words[i]
    actual = (word in tally) ? tally[word] : 0
    if (!(word in claimed)) {
      printf "summary is missing a row for %s (rows counted: %d)\n", word, actual
      failures++
      continue
    }
    if (claimed[word] + 0 != actual) {
      printf "%s: summary says %s, tables contain %d\n", word, claimed[word], actual
      failures++
    } else {
      printf "%s: %d\n", word, actual
    }
  }
  if (failures > 0) {
    printf "%d parity problem(s)\n", failures
    exit 1
  }
  print "parity statuses and counts agree"
}
' "$parity_file"
