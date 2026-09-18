# APISIX diagnostics validation

Status: local source and image integration verified; **production suitability unverified**.
The machine-readable matrix starts empty. No production sample, configuration change,
deployment, or load test is authorized by this file.

## Tested environment

- Developer Linux Docker host: `6.6.80-29.tl4.x86_64`, x86_64.
- TencentOS 4 runtime Python: 3.11.6.
- Pinned package: `perf-6.6.119-52.7.tl4.x86_64`, RPM installed size 10,617,560 bytes
  (this excludes dependencies and is not the image size increase).
- `cpu-clock:u`, `-F 19`, single PID, `--no-inherit`, `-m 64K`,
  `--no-buildid`, `--no-buildid-cache` arguments accepted; the unprivileged
  disposable container refused `perf_event_open` with EPERM. No permission
  escalation was attempted. This does not validate the recorder on a production kernel.
- External debug packages were not supplied. The build inventory records embedded
  `.debug_info` for each actual ELF; the optional symbol target exports those exact files.

## Required before enabling expensive collection

Use a non-production image/kernel/security-policy combination and an internal harness
that injects a candidate support entry. There is no production CLI override.
Record target Build ID, collector digest, architecture, exact kernel, perf version,
budget_version, exact security fields (Seccomp, CapEff, perf_event_paranoid),
`perf_ip_validated`, `smaps_rollup_validated`, and report reference.
Validate each feature independently; changing code/budget invalidates prior results.

For normal proxying, near-quota CPU, JSON/regex work, shared-dictionary contention,
anonymous-memory growth and file-cache/I/O pressure, run at least five paired
baseline/collection windows per mode with a separate load generator. Stabilize the
normal baseline for two minutes and observe each run plus 60 seconds. Record RPS,
errors, P50/P99/P999, sample counts, image digest, quotas and memory limits.

Initial gates: no tool-induced worker exit/restart/new errors; normal throughput
loss <=1%, P99 increase <=2%, P999 <=5% and within the existing absolute SLO;
collector+children peak RSS target <=64 MiB; no remaining recorder/events;
bounded files/deadline/cooldown. High-load runs must meet the existing absolute SLO.
Noise exceeding a threshold is inconclusive. Validate actual perf ring-buffer count,
parseable nonzero samples, lost-sample reporting, symbol identity, and smaps overhead.

Also exercise denial, readonly/non-root operation, low disk/memory, OOM deltas,
PID reuse/target exit, interrupt, caller SIGKILL and timeout on disposable targets.
No representative traffic/SLO or production matching environment has been supplied;
these measurements remain pending. Do not add a matrix entry from unit tests alone.

## Local verification results (2026-09-18)

- Standard-library suite: 47 tests passed on Python 3.9 (official slim image)
  and on runtime Python 3.11.6 (TencentOS image), plus the developer Python runtime.
  Tests cover CPU units/reset, cgroup v1/v2/hybrid/namespace paths and ancestor
  headroom, worker roles/parent/cgroup/PID reuse, CLI, lock/cooldown, byte caps,
  resource limits, timeout, interrupt, parent SIGKILL, denied perf/no retry,
  ELF corruption, matrix mismatch, bundle tampering/traversal/symlinks, and
  independent count/period denominators. Fixtures are synthetic, constructed in tests.
- Root Dockerfile built successfully with the current local plugin tree; the source
  revision is explicitly `unknown-local-working-tree` because unrelated local
  changes are present. No commit revision is falsely claimed for this image.
- A paired build using the original Dockerfile and the same plugin inputs has no
  removed/replaced RPMs; 51 RPMs were added for perf and its dependencies.
  Docker cumulative image size increased by approximately 70.8 MiB. binutils is
  installed and removed within the manifest-generation layer; package caches are
  cleaned in their installation layers. Final RPM inventory equals diag-build.json.
- Disposable Nginx from the same image, one same-UID worker: `--all` completed the
  base/CPU/memory/I/O windows in about 12 seconds, returned 10, skipped native and
  smaps collection, and produced a checksum-verifiable package. This is a CLI
  integration smoke test, not a representative APISIX traffic/load test.
- A worker running under a different UID with inaccessible `/proc/PID/exe` was
  correctly excluded. Unknown executable identity is not guessed or bypassed.
- Arbitrary working directory, cross-output-directory cooldown, readonly/non-root
  refusal, and offline JSON analysis were exercised. `--help` works without writes.
- A user perf config requesting DWARF was ignored with the selected perf binary
  under the runner's PERF_CONFIG/NOSYSTEM/NOGLOBAL settings.
- Python compilation and workflow YAML parsing passed. actionlint was unavailable;
  Actions semantics were inspected locally. CI itself was not remotely triggered.
- Signals/subprocesses/read paths/write paths were reviewed in the current agent;
  no independent subagent review was performed, per the handoff's delegation boundary.
- No Lua lint/test suite was run: no request-path code was changed.

Still unverified: a successful real native recording and matching offline parse,
actual ring-buffer count, smaps load overhead, all paired workload/SLO gates,
and any production matching platform. The empty matrix prevents these unverified
features from running through the production CLI. Unit tests and the smoke run
are not evidence of production-safe latency or zero business impact.

Four standalone mode smoke runs on the developer kernel also passed: CPU about
2.02 s / exit 10, memory about 10.02 s / exit 10, I/O about 10.02 s / exit 0,
all about 12.03 s / exit 10. Bundles were approximately 331–402 kB and verified.
CPU was idle in this smoke fixture; no native samples were inferred. The symbol
export contained 101 matching ELF files and 1,465 Lua files with verified SHA256.
These counts describe the current local image inputs, not a stable product contract.
