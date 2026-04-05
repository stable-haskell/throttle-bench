#!/usr/bin/env bash
# bench.sh — Benchmark: ghc-throttle vs -jsem vs baselines
#
# Builds Hackage packages (lens, pandoc) from scratch under different
# parallelism strategies and measures wall time, CPU time, and peak RSS.
#
# Each run is fully cold: both dist-newstyle and the isolated cabal store
# are deleted before every build.
#
# Approaches:
#   baseline-N  — cabal -jN, ghc -j1      (Well-Typed's non-jsem best)
#   unlimited   — cabal -j,  ghc -j        (full oversubscription)
#   throttle-N  — cabal -j,  ghc -j, N slots (process-level gating)
#   jsem-N      — cabal -jN --semaphore    (token-level gating)
#
# Copyright (c) 2026, Moritz Angermann <moritz.angermann@iohk.io>
# Licensed under Apache-2.0

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults                                                                      #
# --------------------------------------------------------------------------- #

PACKAGES="lens,pandoc"
CONCURRENCY_LEVELS="2,4"
APPROACHES="baseline,unlimited,throttle,jsem"
RUNS=1
COOLDOWN=15
OUTPUT_DIR="results"
DRY_RUN=0
NCPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
THROTTLE_BIN="${THROTTLE_BIN:-$(pwd)/_build/ghc-throttle}"
WORK_DIR="$(pwd)/_build/work"

# Pinned index state for reproducibility. All builds resolve dependencies
# against this exact snapshot of Hackage, so results are stable across time.
INDEX_STATE="2026-04-04T00:00:00Z"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# --------------------------------------------------------------------------- #
# Args                                                                          #
# --------------------------------------------------------------------------- #

while [[ $# -gt 0 ]]; do
    case "$1" in
        --packages)     PACKAGES="$2"; shift 2 ;;
        --concurrency)  CONCURRENCY_LEVELS="$2"; shift 2 ;;
        --approaches)   APPROACHES="$2"; shift 2 ;;
        --runs)         RUNS="$2"; shift 2 ;;
        --cooldown)     COOLDOWN="$2"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --help|-h)      head -20 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)              die "unknown option: $1" ;;
    esac
done

IFS=',' read -ra PKG_ARRAY <<< "$PACKAGES"
IFS=',' read -ra CONC_ARRAY <<< "$CONCURRENCY_LEVELS"
IFS=',' read -ra APPROACH_ARRAY <<< "$APPROACHES"

# --------------------------------------------------------------------------- #
# Validation                                                                    #
# --------------------------------------------------------------------------- #

GHC_BIN="$(command -v ghc-9.8.4 2>/dev/null)" || die "ghc-9.8.4 not in PATH"
command -v cabal >/dev/null || die "cabal not in PATH"

for a in "${APPROACH_ARRAY[@]}"; do
    case "$a" in
        baseline|unlimited|throttle|jsem) ;;
        *) die "unknown approach: $a" ;;
    esac
done

if printf '%s\n' "${APPROACH_ARRAY[@]}" | grep -q throttle; then
    [[ -x "$THROTTLE_BIN" ]] || die "ghc-throttle not at $THROTTLE_BIN (run: make setup)"
fi

# --------------------------------------------------------------------------- #
# GNU time detection (once, not per-run)                                        #
# --------------------------------------------------------------------------- #

TIME_CMD=""
for t in /usr/bin/time /run/current-system/sw/bin/time; do
    if [[ -x "$t" ]] && "$t" -v true >/dev/null 2>&1; then
        TIME_CMD="$t"; break
    fi
done
if [[ -z "$TIME_CMD" ]] && command -v gtime >/dev/null 2>&1; then
    if gtime -v true >/dev/null 2>&1; then
        TIME_CMD="gtime"
    fi
fi
[[ -z "$TIME_CMD" ]] && info "WARNING: no GNU time found — no peak RSS or CPU breakdown"

# --------------------------------------------------------------------------- #
# Cleanup trap — kill orphaned monitors on exit/interrupt                       #
# --------------------------------------------------------------------------- #

MONITOR_PIDS=()
cleanup() {
    for pid in "${MONITOR_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# Monitor: count concurrent GHC processes                                       #
# --------------------------------------------------------------------------- #

start_monitor() {
    local log="$1"
    (
        echo "ts,ghc_count" > "$log"
        while true; do
            # pgrep -f matches full command line (works on both Linux and macOS)
            # wc -l counts matches (pgrep -c is Linux-only)
            n=$(pgrep -f 'ghc-9.8.4' 2>/dev/null | wc -l | tr -d ' ')
            echo "$(date +%s),${n:-0}" >> "$log"
            sleep 1
        done
    ) >/dev/null 2>/dev/null &
    local pid=$!
    MONITOR_PIDS+=("$pid")
    echo "$pid"
}

stop_monitor() {
    kill "$1" 2>/dev/null; wait "$1" 2>/dev/null || true
}

max_ghc_from_log() {
    awk -F, 'NR>1 && $2+0>m{m=$2+0} END{print m+0}' "$1"
}

# --------------------------------------------------------------------------- #
# Clean — the critical piece for reproducibility                                #
# --------------------------------------------------------------------------- #

clean_build() {
    local work="$1"
    info "  Cleaning: removing dist-newstyle and store..."
    rm -rf "$work/dist-newstyle" "$work/store"
    # Best-effort page cache drop (Linux: drop_caches, macOS: purge)
    sync
    echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || \
        sudo -n purge 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# Project setup — create cabal.project with pinned index-state                  #
# --------------------------------------------------------------------------- #

setup_project() {
    local work="$1" pkg="$2"

    mkdir -p "$work"

    # Minimal .cabal file that depends on the target package
    cat > "$work/bench-target.cabal" <<CABAL
cabal-version: 3.0
name: bench-target
version: 0.1
build-type: Simple

library
    default-language: Haskell2010
    build-depends: base, $pkg
    exposed-modules: Lib
CABAL

    # Minimal Haskell source (cabal warns about empty libraries)
    echo "module Lib where" > "$work/Lib.hs"

    # cabal.project with pinned index-state for reproducibility
    cat > "$work/cabal.project" <<PROJ
packages: .
index-state: $INDEX_STATE
PROJ
}

# --------------------------------------------------------------------------- #
# System metadata                                                               #
# --------------------------------------------------------------------------- #

record_metadata() {
    local dir="$1"
    {
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "hostname: $(hostname)"
        echo "os: $(uname -s) $(uname -r) $(uname -m)"
        echo "cpus: $NCPUS"
        if [[ -f /proc/cpuinfo ]]; then
            echo "cpu_model: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
        elif command -v sysctl >/dev/null 2>&1; then
            echo "cpu_model: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
        fi
        echo "ram_kb: $(grep -m1 MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo unknown)"
        echo "ghc: $($GHC_BIN --numeric-version)"
        echo "cabal: $(cabal --numeric-version)"
        echo "index_state: $INDEX_STATE"
        echo "throttle_bin: $THROTTLE_BIN"
        echo "approaches: $APPROACHES"
        echo "concurrency: $CONCURRENCY_LEVELS"
        echo "runs: $RUNS"
    } > "$dir/metadata.txt"
}

# --------------------------------------------------------------------------- #
# Main loop                                                                     #
# --------------------------------------------------------------------------- #

mkdir -p "$OUTPUT_DIR"
CSV="$OUTPUT_DIR/results.csv"
echo "package,approach,concurrency,run,wall_sec,user_sec,sys_sec,peak_rss_kb,max_ghc,exit_code" > "$CSV"

info "Benchmark: ghc-throttle vs -jsem"
info "  packages=[${PACKAGES}]  ncpus=$NCPUS  runs=$RUNS"
info "  concurrency=[${CONCURRENCY_LEVELS}]"
info "  approaches=[${APPROACHES}]"
info "  index_state=$INDEX_STATE"
info "  work_dir=$WORK_DIR"
info ""

record_metadata "$OUTPUT_DIR"

# Update hackage index once (all runs use the pinned index-state)
info "Updating hackage index..."
cabal update 2>&1 | tail -2
info ""

for pkg in "${PKG_ARRAY[@]}"; do
    info "=== Package: $pkg ==="

    pkg_work="$WORK_DIR/$pkg"
    setup_project "$pkg_work" "$pkg"

    for approach in "${APPROACH_ARRAY[@]}"; do
        if [[ "$approach" == "unlimited" ]]; then
            conc_list=("$NCPUS")
        else
            conc_list=("${CONC_ARRAY[@]}")
        fi

        for conc in "${conc_list[@]}"; do
            label="$approach"
            [[ "$approach" != "unlimited" ]] && label="${approach}-${conc}"

            # Build the cabal command.
            # --store-dir and --project-dir are global options (before 'build').
            # Everything else is a build subcommand option (after 'build').
            global="--store-dir=$pkg_work/store --project-dir=$pkg_work"
            build="--builddir=$pkg_work/dist-newstyle"
            case "$approach" in
                baseline)
                    cmd="cabal $global build $build -j$conc -w $GHC_BIN --ghc-options=-j1 all" ;;
                unlimited)
                    cmd="cabal $global build $build -j -w $GHC_BIN --ghc-options=-j all" ;;
                throttle)
                    cmd="GHC_THROTTLE_GHC=$GHC_BIN GHC_THROTTLE_JOBS=$conc cabal $global build $build -j -w $THROTTLE_BIN --ghc-options=-j all" ;;
                jsem)
                    cmd="cabal $global build $build -j$conc --semaphore -w $GHC_BIN all" ;;
            esac

            if (( DRY_RUN )); then
                info "[DRY] $pkg / $label x${RUNS}: $cmd"
                continue
            fi

            for run_num in $(seq 1 "$RUNS"); do
                run_dir="$OUTPUT_DIR/$pkg/$label/run-$run_num"
                mkdir -p "$run_dir"

                info "--- $pkg / $label  run=$run_num/$RUNS ---"
                info "  cmd: $cmd"

                # Full clean between every run
                clean_build "$pkg_work"

                # Clean throttle lock directory
                rm -rf "/tmp/ghc-throttle-$(id -u)" 2>/dev/null || true

                # Start concurrency monitor
                mon_pid=$(start_monitor "$run_dir/monitor.csv")

                # Run the build under GNU time
                info "  Building..."
                local_exit=0
                if [[ -n "$TIME_CMD" ]]; then
                    # Use -o to write time output to a dedicated file,
                    # keeping build stderr separate in build.log.
                    "$TIME_CMD" -v -o "$run_dir/time.log" \
                        bash -c "$cmd" \
                        < /dev/null > "$run_dir/build.log" 2>&1 \
                        || local_exit=$?
                else
                    # Fallback: bash time (no peak RSS)
                    start_ts=$(date +%s)
                    bash -c "$cmd" \
                        < /dev/null > "$run_dir/build.log" 2>&1 \
                        || local_exit=$?
                    end_ts=$(date +%s)
                    echo "Elapsed (wall clock) time: 0:$((end_ts - start_ts)).00" > "$run_dir/time.log"
                fi

                stop_monitor "$mon_pid"

                # Parse timing
                wall_sec=0; user_sec=0; sys_sec=0; peak_kb=0
                if [[ -f "$run_dir/time.log" ]]; then
                    wall_sec=$(awk -F': ' '/wall clock/{print $2}' "$run_dir/time.log" | head -1)
                    wall_sec=$(echo "$wall_sec" | awk -F: '{
                        if (NF==3) printf "%.2f", $1*3600+$2*60+$3;
                        else if (NF==2) printf "%.2f", $1*60+$2;
                        else printf "%.2f", $1
                    }')
                    user_sec=$(awk -F': ' '/User time/{print $2}' "$run_dir/time.log" | head -1)
                    sys_sec=$(awk -F': ' '/System time/{print $2}' "$run_dir/time.log" | head -1)
                    peak_kb=$(awk -F': ' '/Maximum resident/{print $2}' "$run_dir/time.log" | head -1)
                fi

                max_ghc=$(max_ghc_from_log "$run_dir/monitor.csv")

                # Record to CSV (includes exit_code for filtering failed runs)
                echo "$pkg,$label,$conc,$run_num,${wall_sec:-0},${user_sec:-0},${sys_sec:-0},${peak_kb:-0},$max_ghc,$local_exit" >> "$CSV"

                info "  wall=${wall_sec}s  user=${user_sec}s  sys=${sys_sec}s  rss=${peak_kb:-?}KB  max_ghc=$max_ghc  exit=$local_exit"

                if (( local_exit != 0 )); then
                    info "  WARNING: build failed (exit $local_exit), check $run_dir/build.log"
                fi

                if (( COOLDOWN > 0 )); then
                    info "  cooldown ${COOLDOWN}s ..."
                    sleep "$COOLDOWN"
                fi
            done
        done
    done
    info ""
done

if (( DRY_RUN )); then exit 0; fi

# --------------------------------------------------------------------------- #
# Summary                                                                       #
# --------------------------------------------------------------------------- #

info "=== RESULTS ==="
printf '%-10s %-18s %5s %4s %10s %10s %10s %12s %8s %5s\n' \
    "PACKAGE" "APPROACH" "CONC" "RUN" "WALL(s)" "USER(s)" "SYS(s)" "PEAK_RSS(MB)" "MAX_GHC" "EXIT"
printf '%s\n' "$(printf '%.0s-' {1..100})"

tail -n +2 "$CSV" | while IFS=, read -r pkg label conc run wall user sys peak max_ghc exit_code; do
    peak_mb=$(( ${peak:-0} / 1024 ))
    printf '%-10s %-18s %5s %4s %10s %10s %10s %12s %8s %5s\n' \
        "$pkg" "$label" "$conc" "$run" "$wall" "$user" "$sys" "$peak_mb" "$max_ghc" "$exit_code"
done

info ""
info "=== AVERAGES BY PACKAGE ==="

for pkg in "${PKG_ARRAY[@]}"; do
    info "--- $pkg ---"
    printf '%-18s %10s %10s %12s %8s %5s\n' \
        "APPROACH" "AVG_WALL" "AVG_USER" "AVG_RSS(MB)" "MAX_GHC" "RUNS"
    printf '%s\n' "$(printf '%.0s-' {1..65})"

    grep "^$pkg," "$CSV" | awk -F, '$10 == 0' | \
        awk -F, '{
            k=$2; wall[k]+=$5; user[k]+=$6; rss[k]+=$8
            if($9+0>mg[k]+0) mg[k]=$9; c[k]++
        } END {
            for(k in c) printf "%-18s %10.1f %10.1f %12.0f %8d %5d\n",
                k, wall[k]/c[k], user[k]/c[k], rss[k]/c[k]/1024, mg[k], c[k]
        }' | sort -k2 -n
    info ""
done

info "Raw data: $CSV"
info "Metadata: $OUTPUT_DIR/metadata.txt"
info "Done."
