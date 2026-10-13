#!/usr/bin/env bash
# ./test/run.sh [contract|unit|integration]...   (default: all three)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
suites=("$@")
(( ${#suites[@]} )) || suites=(contract unit integration)
rc=0
for suite in "${suites[@]}"; do
  printf '\n\033[1;4m%s\033[0m\n' "$suite"
  bash "./$suite.sh" || rc=1
done
printf '\n'
(( rc == 0 )) && printf '\033[32mall suites passed\033[0m\n' || printf '\033[31msome suites failed\033[0m\n'
exit $rc
