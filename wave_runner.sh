#!/usr/bin/env bash
# wave_runner.sh — block schedule: WAVES waves of WIDTH concurrent tdx_cycle.sh runs.
#   PROJECT=... RUN_ID=r01 WIDTH=2 WAVES=2 ./wave_runner.sh      # pilot (handoff step 12)
#
# Must run under macOS /bin/bash 3.2 as well as bash 5:
#   no `wait -n`, no associative arrays, no `mapfile`,
#   and "${arr[@]}" on an EMPTY array errors under `set -u` before bash 4.4.
#
# CONTRACT with tdx_cycle.sh — NOT implemented there yet (needs your local copy):
#   reads   NAME, RUN_ID, WAVE, SLOT, OUT, ROW_FILE from the environment
#   writes  exactly one CSV row, no header, to ROW_FILE, on success AND on failure
#   labels  purpose=tdx-cycle,run=$RUN_ID,wave=wNN (lowercase only)
#   exits   0 iff integrity=ok and rd_match=yes
#
# Lines marked TODO(you) are deliberately left empty.

set -uo pipefail            # no -e: one failed slot must not stop the runner

PROJECT="${PROJECT:?set PROJECT}"
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"         # us-central1-a -> us-central1
MTYPE="${MTYPE:-c3-standard-4}"
VCPUS="${VCPUS:-4}"         # vCPUs per MTYPE
QUOTA="${QUOTA:-24}"        # C3 vCPUs per region (gcloud, 10-28, your project)
WIDTH="${WIDTH:-6}"
WAVES="${WAVES:-1}"
RUN_ID="${RUN_ID:?set RUN_ID}"
STAGGER_MAX="${STAGGER_MAX:-3}"   # seconds

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$HERE/runs/$RUN_ID"; mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/waves.log"
CSV="$RUN_DIR/cycles.csv"
G=(gcloud --project="$PROJECT" --quiet)

ts(){ :; }   # TODO(you): copy the %N / Perl Time::HiRes fallback from your local tdx_cycle.sh
log(){ echo "$(ts) $*" | tee -a "$LOG" >&2; }

# ---------- validation ----------
# TODO(you): refuse if WIDTH*VCPUS > QUOTA.
# TODO(you): refuse unless RUN_ID matches ^[a-z][a-z0-9-]*$. It goes into the
#            instance names and the label values. Check GCE's length limits for both.

# ---------- interrupt handling ----------
PIDS=()          # PIDs of the current wave's slots; index = slot-1
CUR_WAVE=none

on_interrupt(){
  log "interrupt during $CUR_WAVE"
  # TODO(you): send TERM to each PID in PIDS. Background children ignore SIGINT
  #            when job control is off (bash manual, "Signals").
  # TODO(you): wait for them, so their EXIT traps can issue deletes.
  sweep "$CUR_WAVE"
  exit 130
}
trap on_interrupt INT TERM

# ---------- pre-wave quota check (handoff step 4) ----------
quota_ok(){
  # TODO(you): read the current usage of the C3 vCPU metric in $REGION.
  #   Start from: "${G[@]}" compute regions describe "$REGION" --flatten=quotas --format=...
  #   then grep. Take the metric name from your 10-28 output; don't guess it.
  # Log the usage either way; return 0 iff usage + WIDTH*VCPUS <= QUOTA.
  return 1
}

# ---------- post-wave sweep (handoff step 8) ----------
sweep(){   # $1 = wave tag, for the log
  # TODO(you): list instances with labels.run=$RUN_ID. Check the filter actually
  #            works, given the 10-28 server-side filter failure.
  #            Delete leftovers and log each one as "LEAK <name> $1".
  # TODO(you): list disks with the name prefix "tdx-$RUN_ID-", delete them, log them.
  :
}

# ---------- merge per-slot rows (handoff step 7) ----------
HEADER=""  # TODO(you): tdx_cycle.sh's column order plus project,run_id,wave,slot
merge_rows(){   # $1 = wave dir
  [[ -f $CSV ]] || echo "$HEADER" > "$CSV"
  # TODO(you): append each "$1"/*.row to $CSV. Decide the order (slot? t_deleted?)
  #            and whether that order matters once the t_* columns are present.
  # TODO(you): a missing .row file means the slot died without writing.
  #            Log it, and decide whether it still gets a row here.
  :
}

# ---------- main loop ----------
log "run $RUN_ID: project=$PROJECT zone=$ZONE width=$WIDTH waves=$WAVES bash=$BASH_VERSION"
for ((w=1; w<=WAVES; w++)); do
  WTAG=$(printf 'w%02d' "$w"); CUR_WAVE=$WTAG
  WDIR="$RUN_DIR/$WTAG"; mkdir -p "$WDIR"

  quota_ok || { log "$WTAG abort: quota"; break; }

  PIDS=()
  for ((s=1; s<=WIDTH; s++)); do
    NAME="tdx-$RUN_ID-$WTAG-s$s"
    # TODO(you): stagger — sleep a random 0..STAGGER_MAX s ($RANDOM works in 3.2)
    NAME="$NAME" RUN_ID="$RUN_ID" WAVE="$w" SLOT="$s" \
    OUT="$WDIR/$NAME" ROW_FILE="$WDIR/$NAME.row" \
    PROJECT="$PROJECT" ZONE="$ZONE" MTYPE="$MTYPE" \
      "$HERE/tdx_cycle.sh" > "$WDIR/$NAME.stdout" 2> "$WDIR/$NAME.stderr" &
    PIDS+=($!)
    log "$WTAG s$s launched $NAME pid $!"
  done

  # TODO(you): wait on each PID in PIDS and log "<wtag> s<N> exit <code>".
  #            `wait "$pid"` returns that child's status.
  PIDS=()

  sweep "$WTAG"
  merge_rows "$WDIR"
  # TODO(you): stopping-rule hook. Write the rule down before the run.
done
log "run dir: $RUN_DIR"
