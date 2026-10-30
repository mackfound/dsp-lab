#!/bin/bash
# Runs as root at first boot (startup-script metadata). Generates one TDX quote via
# configfs-tsm. The quote goes to serial port 2 (ttyS1), which nothing else writes to;
# STAGE lines go to ports 1 and 2 so port 1 still shows progress if port 2 fails.
set -u
P1=/dev/ttyS0; P2=/dev/ttyS1
stty -F "$P2" 115200 -onlcr 2>/dev/null || true
log(){ local l="TDXCYCLE STAGE $1 $(date -u +%s.%N) ${2:-}"; echo "$l" > "$P1"; echo "$l" > "$P2"; }
 
log guest_start "kernel=$(uname -r)"
 
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
if [ ! -d /sys/kernel/config/tsm/report ] && ! modprobe tdx_guest 2>/dev/null; then
  log apt_start
  apt-get -qq -o DPkg::Lock::Timeout=120 update
  DEBIAN_FRONTEND=noninteractive apt-get -qq -o DPkg::Lock::Timeout=120 install -y "linux-modules-extra-$(uname -r)"
  modprobe tdx_guest
  log apt_done
fi
 
R=/sys/kernel/config/tsm/report/cycle0
mkdir "$R" 2>/dev/null || { log quote_failed no_tsm_report; exit 1; }
 
# Fresh 64-byte report_data. Write inblob first, then read outblob.
dd if=/dev/urandom of=/tmp/nonce.bin bs=64 count=1 status=none
cat /tmp/nonce.bin > "$R/inblob"
cat "$R/outblob" > /tmp/quote.bin
log quote_done "provider=$(cat "$R/provider")"
rmdir "$R"
 
{
  echo "TDXCYCLE-NONCE $(base64 -w0 /tmp/nonce.bin)"
  echo "TDXCYCLE-SHA256 $(sha256sum /tmp/quote.bin | cut -d' ' -f1)"
  echo "TDXCYCLE-QUOTE-BEGIN"
  base64 -w 76 /tmp/quote.bin
  echo "TDXCYCLE-QUOTE-END"
} > "$P2"
