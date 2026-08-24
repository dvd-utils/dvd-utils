#!/usr/bin/env bash
# ============================================================================
#  resolve_bdsup2sub.sh — Locate a usable BDSUP2SUB subtitle converter
# ============================================================================
#  Ubuntu no longer provides ogmrip/subp2pgm/bdsup2sub++ in standard repos,
#  so we search multiple locations for a usable converter.
#
#  Resolution order:
#    1. bdsup2sub++ in system PATH
#    2. Local bdsup2sub++ development builds
#    3. bdsup2sub (original Java wrapper) in system PATH
#    4. Local bdsup2sub.jar via Java
#
#  Sets: BDSUP2SUB_CMD (array) — invoke with "${BDSUP2SUB_CMD[@]}" <args>
# ============================================================================
set -euo pipefail

resolve_bdsup2sub() {
  BDSUP2SUB_CMD=()

  # Prefer the native bdsup2sub++ executable from PATH.
  if command -v bdsup2sub++ >/dev/null 2>&1; then
    BDSUP2SUB_CMD=("$(command -v bdsup2sub++)")

  # Look for local development/build copies of bdsup2sub++.
  else
    for candidate in \
      "./VobSub-Utilities/bdsup2sub++" \
      "./VobSub-Utilities/build/bdsup2sub++" \
      "./sup2vobsub/bdsup2sub++" \
      "./sup2vobsub/build/bdsup2sub++"
    do
      if [ -x "$candidate" ]; then
        BDSUP2SUB_CMD=("$candidate")
        break
      fi
    done

    # Fall back to the original Java bdsup2sub wrapper in PATH.
    if [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] && command -v bdsup2sub >/dev/null 2>&1; then
      BDSUP2SUB_CMD=("$(command -v bdsup2sub)")

    # Fall back to a local bdsup2sub.jar.
    elif [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] && command -v java >/dev/null 2>&1 && [ -f "./bdsup2sub.jar" ]; then
      BDSUP2SUB_CMD=("java" "-jar" "./bdsup2sub.jar")
    fi
  fi

  # No supported subtitle conversion tool was found.
  if [ ${#BDSUP2SUB_CMD[@]} -eq 0 ]; then
    echo "ERROR: No supported BDSUP2SUB subtitle converter was found." >&2
    echo >&2
    echo "Searched for:" >&2
    echo "  - bdsup2sub++ in system PATH" >&2
    echo "  - ./VobSub-Utilities/bdsup2sub++" >&2
    echo "  - ./VobSub-Utilities/build/bdsup2sub++" >&2
    echo "  - ./sup2vobsub/bdsup2sub++" >&2
    echo "  - ./sup2vobsub/build/bdsup2sub++" >&2
    echo "  - bdsup2sub in system PATH" >&2
    echo "  - ./bdsup2sub.jar via Java" >&2
    echo >&2
    echo "Install or compile bdsup2sub++:" >&2
    echo "git clone https://github.com/prinsbert/VobSub-Utilities && cd ./BDSup2SubPlusPlus && mkdir -p build && cd build && qmake6 ../src/bdsup2sub++.pro" >&2
    echo "make" >&2
    echo "cd ../../" >&2
    echo >&2
    echo "Expected local build locations:" >&2
    echo "  ./sup2vobsub/" >&2
    echo "  ./VobSub-Utilities/" >&2
    exit 1
  fi

  echo "Using subtitle converter: ${BDSUP2SUB_CMD[*]}"
}