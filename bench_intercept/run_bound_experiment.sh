#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 RESULT_DIRECTORY" >&2
  exit 2
fi

result_dir=$1
cpu=${TAPECHECK_BENCH_CPU:-31}
draws=10000000
blocks=60

if [[ -e "$result_dir" ]]; then
  echo "result directory already exists: $result_dir" >&2
  exit 2
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "refusing to benchmark with tracked worktree or index changes" >&2
  exit 2
fi

mkdir -p "$result_dir"
arm_tmp=$(mktemp /tmp/tapecheck-intercept-arm.XXXXXX)
perf_tmp=$(mktemp /tmp/tapecheck-intercept-perf.XXXXXX)

{
  printf 'source_commit='
  git rev-parse HEAD
  printf 'started_at='
  date --iso-8601=seconds
  echo "cpu=$cpu"
  echo "draws_per_arm=$draws"
  echo "paired_blocks=$blocks"
  echo
  echo "[git status --short]"
  git status --short
  echo
  echo "[uname -a]"
  uname -a
  echo
  echo "[taskset --cpu-list --pid $$]"
  taskset --cpu-list --pid $$
  echo
  echo "[lscpu --extended=CPU,CORE,SOCKET,MAXMHZ,MINMHZ,ONLINE]"
  lscpu --extended=CPU,CORE,SOCKET,MAXMHZ,MINMHZ,ONLINE
  echo
  echo "[ocamlopt -config]"
  opam exec --switch=5.3.0 -- ocamlopt -config
  echo
  echo "[perf --version]"
  perf --version
  echo
  echo "[uptime]"
  uptime
} >"$result_dir/environment.txt"

opam exec --switch=5.3.0 -- dune build bench_intercept/bench_intercept_arm.exe
runner=_build/default/bench_intercept/bench_intercept_arm.exe

printf 'block\tcontrast\tdraw\torder\tdraws\tseed\tdenominator_seconds\tnumerator_seconds\tdenominator_instructions\tnumerator_instructions\tdenominator_cycles\tnumerator_cycles\tdenominator_branches\tnumerator_branches\tdenominator_branch_misses\tnumerator_branch_misses\tdenominator_accumulator\tnumerator_accumulator\n' >"$result_dir/pairs.tsv"
printf 'block\tcontrast\tdraw\tposition\timplementation\tdraws\tseed\tseconds\tinstructions\tcycles\tbranches\tbranch_misses\taccumulator\n' >"$result_dir/arms.tsv"

run_arm () {
  local block=$1
  local contrast=$2
  local draw=$3
  local position=$4
  local implementation=$5
  local seed=$6

  taskset --cpu-list "$cpu" \
    perf stat \
    --event instructions:u,cycles:u,branches:u,branch-misses:u \
    --field-separator $'\t' \
    --output "$perf_tmp" \
    "$runner" \
    --implementation "$implementation" \
    --draw "$draw" \
    --draws "$draws" \
    --seed "$seed" \
    >"$arm_tmp"

  last_seconds=$(awk -F '\t' 'NR == 2 { print $5 }' "$arm_tmp")
  last_accumulator=$(awk -F '\t' 'NR == 2 { print $6 }' "$arm_tmp")
  last_instructions=$(awk -F '\t' '$3 ~ /instructions/ && $1 != "<not counted>" { print $1; exit }' "$perf_tmp")
  last_cycles=$(awk -F '\t' '$3 ~ /cycles/ && $1 != "<not counted>" { print $1; exit }' "$perf_tmp")
  last_branches=$(awk -F '\t' '$3 ~ /branches/ && $3 !~ /branch-misses/ && $1 != "<not counted>" { print $1; exit }' "$perf_tmp")
  last_branch_misses=$(awk -F '\t' '$3 ~ /branch-misses/ && $1 != "<not counted>" { print $1; exit }' "$perf_tmp")

  if [[ -z "$last_seconds" || -z "$last_instructions" || -z "$last_cycles" || -z "$last_branches" || -z "$last_branch_misses" ]]; then
    echo "missing measurement for block=$block contrast=$contrast draw=$draw implementation=$implementation" >&2
    exit 1
  fi

  printf '%d\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$block" "$contrast" "$draw" "$position" "$implementation" "$draws" "$seed" \
    "$last_seconds" "$last_instructions" "$last_cycles" "$last_branches" \
    "$last_branch_misses" "$last_accumulator" >>"$result_dir/arms.tsv"
}

contrasts=(isolated module active)
draw_kinds=(bool int_0_1000 float_0_1)

for ((block = 0; block < blocks; block++)); do
  for contrast_index in 0 1 2; do
    contrast=${contrasts[$contrast_index]}
    case "$contrast" in
      isolated) numerator=seam; denominator=direct ;;
      module) numerator=seam; denominator=nohook ;;
      active) numerator=active; denominator=seam ;;
      *) echo "unknown contrast: $contrast" >&2; exit 1 ;;
    esac
    for draw_index in 0 1 2; do
      draw=${draw_kinds[$draw_index]}
      seed=$((202608220 + block * 17 + contrast_index * 5 + draw_index))
      if (((block + contrast_index + draw_index) % 2 == 0)); then
        first=$numerator
        second=$denominator
        order=numerator_first
      else
        first=$denominator
        second=$numerator
        order=denominator_first
      fi

      run_arm "$block" "$contrast" "$draw" first "$first" "$seed"
      first_seconds=$last_seconds
      first_instructions=$last_instructions
      first_cycles=$last_cycles
      first_branches=$last_branches
      first_branch_misses=$last_branch_misses
      first_accumulator=$last_accumulator

      run_arm "$block" "$contrast" "$draw" second "$second" "$seed"
      second_seconds=$last_seconds
      second_instructions=$last_instructions
      second_cycles=$last_cycles
      second_branches=$last_branches
      second_branch_misses=$last_branch_misses
      second_accumulator=$last_accumulator

      if [[ "$first_accumulator" != "$second_accumulator" ]]; then
        echo "accumulator mismatch for block=$block contrast=$contrast draw=$draw" >&2
        exit 1
      fi

      if [[ "$order" == numerator_first ]]; then
        num_seconds=$first_seconds; den_seconds=$second_seconds
        num_instructions=$first_instructions; den_instructions=$second_instructions
        num_cycles=$first_cycles; den_cycles=$second_cycles
        num_branches=$first_branches; den_branches=$second_branches
        num_branch_misses=$first_branch_misses; den_branch_misses=$second_branch_misses
      else
        den_seconds=$first_seconds; num_seconds=$second_seconds
        den_instructions=$first_instructions; num_instructions=$second_instructions
        den_cycles=$first_cycles; num_cycles=$second_cycles
        den_branches=$first_branches; num_branches=$second_branches
        den_branch_misses=$first_branch_misses; num_branch_misses=$second_branch_misses
      fi

      printf '%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$block" "$contrast" "$draw" "$order" "$draws" "$seed" \
        "$den_seconds" "$num_seconds" "$den_instructions" "$num_instructions" \
        "$den_cycles" "$num_cycles" "$den_branches" "$num_branches" \
        "$den_branch_misses" "$num_branch_misses" "$first_accumulator" \
        "$second_accumulator" >>"$result_dir/pairs.tsv"
    done
  done
done

uv --cache-dir /tmp/tapecheck-benchmark-uv-cache run bench_intercept/analyse_bound.py "$result_dir"
