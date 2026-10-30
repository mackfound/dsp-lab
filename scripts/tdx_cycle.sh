#!/usr/bin/env bash
# One timed launch -> collect -> delete cycle for a GCP TDX Confidential VM. Run from WSL.
#   PROJECT=... ZONE=... MTYPE=... ./tdx_cycle.sh
set -euo pipefail
 
PROJECT="${PROJECT:-cvm-tdx-quote-collection}"   # assumption: project from first session
ZONE="${ZONE:-us-central1-a}"
MTYPE="${MTYPE:-c3-standard-4}"                  # slot: confirm smallest TDX-supported type
TIMEOUT_S="${TIMEOUT_S:-600}"
 
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="tdx-cycle-$(date -u +%Y%m%d-%H%M%S)"
OUT="$HERE/runs/$NAME"; mkdir -p "$OUT"
G=(gcloud --project="$PROJECT" --quiet)
ts(){ local t; t=$(date -u +%s.%N); [[ $t == *N ]] && t=$(perl -MTime::HiRes=time -e 'printf "%.5f", time'); echo "$t"; }
el(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
serial(){ "${G[@]}" compute instances get-serial-port-output "$NAME" --zone="$ZONE" --port="$1" \
            > "$OUT/serial$1.log" 2>"$OUT/serial$1.err" || true; }
 
CREATED=0
trap '[[ $CREATED == 1 ]] && "${G[@]}" compute instances delete "$NAME" --zone="$ZONE" >/dev/null 2>&1' EXIT
 
T0=$(ts)
"${G[@]}" compute instances create "$NAME" --zone="$ZONE" --machine-type="$MTYPE" \
  --confidential-compute-type=TDX --maintenance-policy=TERMINATE \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --boot-disk-auto-delete --labels=purpose=tdx-cycle \
  --metadata-from-file=startup-script="$HERE/startup.sh" > "$OUT/create.log" 2>&1 \
  || { cat "$OUT/create.log" >&2; exit 1; }
CREATED=1
T_CREATED=$(ts); echo "created     +$(el "$T0" "$T_CREATED")s"
 
# value() is tab-separated; split on tabs only, since cpuPlatform contains spaces.
IFS=$'\t' read -r IID CPU < <("${G[@]}" compute instances describe "$NAME" --zone="$ZONE" \
  --format='value(id,cpuPlatform)')
 
# Poll port 2 (quote channel). On timeout, also save port 1 to see how far the guest got.
SECONDS=0
until grep -q 'TDXCYCLE-QUOTE-END' "$OUT/serial2.log" 2>/dev/null; do
  if (( SECONDS >= TIMEOUT_S )); then
    serial 1; echo "timed out; see $OUT/serial2.err and serial1.log" >&2; cat "$OUT/serial2.err" >&2; exit 1
  fi
  grep -q 'STAGE quote_failed' "$OUT/serial2.log" 2>/dev/null && { serial 1; echo "guest quote_failed" >&2; exit 1; }
  sleep 5; serial 2
done
T_QUOTE=$(ts); echo "quote seen  +$(el "$T0" "$T_QUOTE")s"
 
"${G[@]}" compute instances delete "$NAME" --zone="$ZONE" > "$OUT/delete.log" 2>&1
CREATED=0
T_DELETED=$(ts); echo "deleted     +$(el "$T0" "$T_DELETED")s"
[[ -z $("${G[@]}" compute disks list --verbosity=error --filter="name=$NAME" --format='value(name)') ]] \
  && CLEAN=yes || CLEAN=NO
 
# From here on nothing may abort: every outcome becomes a column, then the row is written.
set +e +o pipefail
C="$OUT/serial2.clean"; tr -d '\r' < "$OUT/serial2.log" > "$C"
awk '/TDXCYCLE-QUOTE-BEGIN/{f=1;next} /TDXCYCLE-QUOTE-END/{exit} f' "$C" | base64 -d > "$OUT/quote.bin" 2>/dev/null
grep -o 'TDXCYCLE-NONCE [A-Za-z0-9+/=]*' "$C" | head -1 | cut -d' ' -f2 | base64 -d > "$OUT/nonce.bin" 2>/dev/null
WANT=$(grep -o 'TDXCYCLE-SHA256 [0-9a-f]*' "$C" | head -1 | cut -d' ' -f2)
GOT=$(sha256sum "$OUT/quote.bin" | cut -d' ' -f1)
if [[ -z $WANT ]]; then INTEG=missing; elif [[ $WANT == "$GOT" ]]; then INTEG=ok; else INTEG=BAD; fi
grep -o 'TDXCYCLE STAGE .*' "$C" > "$OUT/guest_stages.txt"
 
VER=-; TEE=-; RD=-; TRIM=0
if [[ $INTEG == ok ]]; then
  VER=$(od -An -tu2 -j0 -N2 "$OUT/quote.bin" | tr -d ' ')
  TEE=$(od -An -tx4 -j4 -N4 "$OUT/quote.bin" | tr -d ' ')
  SIGLEN=$(od -An -tu4 -j632 -N4 "$OUT/quote.bin" | tr -d ' ')
  head -c $((636 + SIGLEN)) "$OUT/quote.bin" > "$OUT/quote-trimmed.bin"
  TRIM=$(wc -c < "$OUT/quote-trimmed.bin" | tr -d ' ')
  if [[ ! -s $OUT/nonce.bin ]]; then RD=missing
  elif cmp -s <(head -c 632 "$OUT/quote.bin" | tail -c 64) "$OUT/nonce.bin"; then RD=yes
  else RD=no; fi
fi
grep -q apt_start "$OUT/guest_stages.txt" && APT=yes || APT=no
 
CSV="$HERE/runs/cycles.csv"
[[ -f $CSV ]] || echo "name,zone,mtype,instance_id,cpu_platform,t0,t_created,t_quote,t_deleted,integrity,trimmed_bytes,version,tee_type,rd_match,apt,clean" > "$CSV"
echo "$NAME,$ZONE,$MTYPE,$IID,\"$CPU\",$T0,$T_CREATED,$T_QUOTE,$T_DELETED,$INTEG,$TRIM,$VER,$TEE,$RD,$APT,$CLEAN" >> "$CSV"
tail -1 "$CSV"
[[ $INTEG == ok && $RD == yes ]] || { echo "check failed: integrity=$INTEG rd_match=$RD; see $OUT" >&2; exit 1; }
