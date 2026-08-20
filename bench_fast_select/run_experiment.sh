#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 RESULT_DIRECTORY" >&2
  exit 2
fi

result_dir=$1
cpu=${TAPECHECK_BENCH_CPU:-31}
draws=3000000
blocks=10
processes=12

if [[ -e "$result_dir" ]]; then
  echo "result directory already exists: $result_dir" >&2
  exit 2
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "refusing to benchmark with tracked worktree or index changes" >&2
  exit 2
fi

mkdir -p "$result_dir"

{
  printf 'source_commit='
  git rev-parse HEAD
  printf 'started_at='
  date --iso-8601=seconds
  echo "cpu=$cpu"
  echo "draws_per_arm=$draws"
  echo "blocks_per_kind=$blocks"
  echo "processes=$processes"
  echo
  echo "[git status --short]"
  git status --short
  echo
  echo "[uname -a]"
  uname -a
  echo
  echo "[lscpu]"
  lscpu
  echo
  echo "[ocamlopt -config]"
  opam exec --switch=5.3.0 -- ocamlopt -config
  echo
  echo "[uptime]"
  uptime
} >"$result_dir/environment.txt"

opam exec --switch=5.3.0 -- \
  dune build --profile release bench_fast_select/bench_fast_select.exe

for ((process_id = 0; process_id < processes; process_id++)); do
  printf -v output '%s/process-%02d.tsv' "$result_dir" "$process_id"
  taskset --cpu-list "$cpu" \
    opam exec --switch=5.3.0 -- \
    dune exec --profile release bench_fast_select/bench_fast_select.exe -- \
    --draws "$draws" --blocks "$blocks" --process-id "$process_id" \
    >"$output"
done

uv --cache-dir /tmp/tapecheck-benchmark-uv-cache \
  run bench_intercept/analyse.py "$result_dir" \
  --title "Inactive whole-generator selection result" \
  --numerator-label selected \
  --denominator-label "direct C"
