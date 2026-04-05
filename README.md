# throttle-bench

Benchmark comparing three GHC parallel build strategies:

| Strategy | How it works |
|----------|-------------|
| **ghc-throttle** | Limits concurrent GHC *processes* via `flock()`. Each process uses full `-j` internally. Zero overhead after `exec()`. |
| **-jsem** | GHC's built-in semaphore protocol. Cabal creates N tokens, GHC processes dynamically acquire/release them for per-module parallelism. |
| **baseline** | `cabal -jN, ghc -j1` — Well-Typed's best non-jsem configuration. |

## Quick Start

```bash
git clone https://github.com/stable-haskell/throttle-bench.git
cd throttle-bench

make setup                  # build ghc-throttle (one-time)
make bench-lens RUNS=1      # quick test with lens
make bench RUNS=3           # full benchmark (lens + pandoc)
make results                # view results
```

## Requirements

- [nix](https://nixos.org/download.html) with flakes enabled
- GHC and cabal are provided automatically via `nix develop`
- GNU time (`/usr/bin/time -v`) for peak RSS measurement
- ~10GB disk for build artifacts per package

Enable nix flakes if not already:
```bash
mkdir -p ~/.config/nix
echo "extra-experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

## Configuration

Override via `make` variables:

```bash
make bench CONCURRENCY=4,8,16 RUNS=3 APPROACHES=throttle,jsem COOLDOWN=30
```

| Variable | Default | Description |
|----------|---------|-------------|
| `CONCURRENCY` | `2,4` | Concurrency levels to sweep |
| `APPROACHES` | `baseline,unlimited,throttle,jsem` | Strategies to test |
| `RUNS` | `1` | Repetitions per configuration |
| `COOLDOWN` | `15` | Seconds between runs |
| `RESULTS_DIR` | `results` | Output directory |

### Choosing concurrency levels

Match to your CPU count. Interesting values are typically `ncpus/4`, `ncpus/2`, `ncpus`:

| CPUs | Recommended `CONCURRENCY` |
|------|--------------------------|
| 4 | `2,4` |
| 8 | `2,4,8` |
| 16 | `4,8,16` |
| 32 | `4,8,16,32` |
| 64 | `8,16,32,64` |

## What It Measures

Each configuration does a **fully cold build**: the cabal store and all
build artifacts are deleted before every run. This measures end-to-end
compilation time including all transitive dependencies.

Packages are pinned via `index-state` for reproducibility across time.

### Metrics

| Metric | Source | Notes |
|--------|--------|-------|
| `wall_sec` | GNU time | Wall-clock time (primary metric) |
| `user_sec` | GNU time | Total user CPU time |
| `sys_sec` | GNU time | Total system CPU time |
| `peak_rss_kb` | GNU time | Peak RSS of the `cabal` process (not the full process tree) |
| `max_ghc` | 1-second polling | Peak observed concurrent `ghc-9.8.4` processes |
| `exit_code` | build exit status | 0 = success, non-zero = failure |

### Known limitations

- `peak_rss_kb` measures only the cabal process, not aggregate memory of all
  GHC subprocesses. For total system memory pressure, use external monitoring.
- `max_ghc` samples at 1-second intervals, so short-lived GHC processes
  (sub-second packages) may be missed.

## Running Unattended

```bash
# Option A: tmux (preferred)
tmux new -s bench
make bench CONCURRENCY=4,8,16 RUNS=3
# Ctrl-b d to detach, tmux attach -t bench to reattach

# Option B: nohup
nohup make bench CONCURRENCY=4,8,16 RUNS=3 < /dev/null > bench.log 2>&1 &
tail -f bench.log
```

## Targets

```
make help           Show all targets with descriptions
make setup          Build ghc-throttle (one-time)
make check          Verify prerequisites
make bench          Run all benchmarks (lens + pandoc)
make bench-lens     Benchmark lens only
make bench-pandoc   Benchmark pandoc only
make dry-run        Print commands without executing
make results        Print formatted results table
make results-csv    Print raw CSV
make clean          Remove results (keep setup)
make distclean      Remove everything
```
