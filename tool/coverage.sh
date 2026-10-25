#!/usr/bin/env bash
#
# Runs the offline test suite with coverage and prints per-file line coverage
# for the library sources.
#
# Usage:
#   tool/coverage.sh
#
# Exits with the test runner's status, so a failing test fails this script
# instead of yielding a partial report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${ROOT_DIR}/coverage"
LCOV_FILE="${COVERAGE_DIR}/lcov.info"

cd "${ROOT_DIR}"

rm -rf "${COVERAGE_DIR}"

echo "Running tests with coverage..."
dart test --coverage="${COVERAGE_DIR}"

echo "Formatting coverage report..."
dart run coverage:format_coverage \
  --lcov \
  --in "${COVERAGE_DIR}" \
  --out "${LCOV_FILE}" \
  --report-on lib \
  --base-directory "${ROOT_DIR}" \
  --packages .dart_tool/package_config.json

echo "Line coverage for lib/:"
awk -F: '
  /^SF:/ { file = substr($0, 4); lf = 0; lh = 0 }
  /^LF:/ { lf = $2 }
  /^LH:/ { lh = $2 }
  /^end_of_record/ {
    if (lf > 0) {
      printf "%.1f\t%d\t%d\t%s\n", (lh / lf) * 100, lh, lf, file
    }
  }
' "${LCOV_FILE}" |
  sort -n -k1,1 |
  awk -F'\t' '
    {
      printf "%6.1f%%  %4d/%-4d  %s\n", $1, $2, $3, $4
    }
  '

awk -F: '
  /^LF:/ { lf += $2 }
  /^LH:/ { lh += $2 }
  END {
    if (lf > 0) {
      printf "\nTOTAL %.1f%%  %d/%d lines\n", (lh / lf) * 100, lh, lf
    }
  }
' "${LCOV_FILE}"

echo
echo "lcov report: ${LCOV_FILE#"${ROOT_DIR}/"}"
echo "Filter to one file with: awk -F: '\''/^SF:.*<name>/{p=1} p{print} /^end_of_record/{p=0}'\'' ${LCOV_FILE#"${ROOT_DIR}/"}"
