#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# program_fpgas_ofl.sh
#
# Same job as program_fpgas.sh, but downloads with openFPGALoader instead of
# Vivado. No license, no Tcl, much faster start-up.
#
# For every slot that has a bitstream defined this script:
#   1. selects that slot's JTAG channel on the MCH (NAT-JSM override),
#   2. detects the chain and maps each role to a device index,
#   3. programs the RTM FPGA first, then the AMC FPGA,
#   4. reports warnings and errors - cable not found, chain empty, unknown
#      IDCODE, programming failure, or no DONE after programming,
#   5. reports the time taken per device and per slot.
#
# Bitstream paths come from bit_files.env, keyed by the symbols in the map file.
# A '-' in the map means "no load" and the slot is skipped. Relative paths in
# bit_files.env are resolved against the directory that file lives in.
#
# NOTE ON THE CLOCK: measured on this bench (Digilent pod via NAT-JSM), 10 MHz
# returns a corrupt IDCODE unless the read edge is inverted; plain sampling even
# fails at 8 MHz. --invert-read-edge therefore defaults to ON, which makes 10 MHz
# (the NAT-JSM maximum) reliable: ~30.5 s for a 36 MB bitstream.
#
# Without --invert-read-edge the useful ceiling is ~6-7 MHz:
#   plain      10 MHz -> corrupt IDCODE      8 MHz -> corrupt      7 MHz -> ok
#   inverted   10 MHz -> ok
#
# Options:
#   --map FILE        slot map to use (default: the only slot_map*.md beside this script)
#   --env FILE        bitstream path table (default: bit_files.env beside this script)
#   --slot N          only handle slot N (repeatable)
#   --dry-run         show the plan and exit
#   --no-mch          do not touch the MCH; assume the channel is already selected
#   --mch ADDR        MCH address (default: 10.19.198.31)
#   --user USER       MCH web user (default: root)
#   --password PASS   MCH web password (default: nat)
#   --channel-wait S  max wait for the MCH channel switch (default: 20)
#   --settle S        pause after switching channel (default: 0.5)
#   --timeout S       openFPGALoader timeout per device (default: 600)
#   --freq HZ         JTAG clock (default: 10000000, the NAT-JSM maximum)
#   --invert-read-edge    sample JTAG reads on the falling edge (default: on)
#   --no-invert-read-edge disable the above
#   --cable NAME      JTAG cable (default: digilent_hs3)
#   --vid ID          cable USB vendor id (default: 0x0403)
#   --pid ID          cable USB product id (default: 0x6010)
#   --ofl PATH        openFPGALoader binary (default: $OPENFPGALOADER or PATH)
#   -h, --help        show this help
#
# Examples:
#   ./program_fpgas_ofl.sh --dry-run
#   ./program_fpgas_ofl.sh --map slot_map_ddr4.md --slot 1
#   ./program_fpgas_ofl.sh --map slot_map_waveform.md --freq 3000000
#   ./program_fpgas_ofl.sh --ofl /opt/ofl/openFPGALoader
#-------------------------------------------------------------------------------
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slot_map=""
env_file="$here/bit_files.env"

jsm_max_jtag_hz=10000000

# --- defaults -----------------------------------------------------------------
slot_filter=()
dry_run=0
no_mch=0
mch="10.19.198.31"
mch_user="root"
mch_pass="nat"
channel_wait=20
settle=0.5
ofl_timeout=600
jtag_freq=$jsm_max_jtag_hz
cable="digilent_hs3"
vid="0x0403"
invert_read_edge=1
pid="0x6010"
ofl="${OPENFPGALOADER:-openFPGALoader}"

warnings=()
errors=()
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT

info() { printf '[INFO ] %s\n' "$*"; }
ok()   { printf '[ OK  ] %s\n' "$*"; }
warn() { printf '[WARN ] %s\n' "$*"; warnings+=("$*"); }
err()  { printf '[ERROR] %s\n' "$*"; errors+=("$*"); }

fmt_ms() { printf '%d.%03ds' "$(($1 / 1000))" "$(($1 % 1000))"; }

# print the header comment block: between the opening and closing rule
usage() { awk 'NR==1{next} /^#----/{if(seen)exit; seen=1; next} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

# --- arguments ----------------------------------------------------------------
while (($#)); do
  case "$1" in
    --map)          slot_map="$2"; shift 2 ;;
    --env)          env_file="$2"; shift 2 ;;
    --slot)         slot_filter+=("$2"); shift 2 ;;
    --dry-run)      dry_run=1; shift ;;
    --no-mch)       no_mch=1; shift ;;
    --mch)          mch="$2"; shift 2 ;;
    --user)         mch_user="$2"; shift 2 ;;
    --password)     mch_pass="$2"; shift 2 ;;
    --channel-wait) channel_wait="$2"; shift 2 ;;
    --settle)       settle="$2"; shift 2 ;;
    --timeout)      ofl_timeout="$2"; shift 2 ;;
    --freq)         jtag_freq="$2"; shift 2 ;;
    --cable)        cable="$2"; shift 2 ;;
    --vid)          vid="$2"; shift 2 ;;
    --invert-read-edge)    invert_read_edge=1; shift ;;
    --no-invert-read-edge) invert_read_edge=0; shift ;;
    --pid)          pid="$2"; shift 2 ;;
    --ofl)          ofl="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --- preflight ----------------------------------------------------------------
if [[ -z $slot_map ]]; then
  mapfile -t _maps < <(compgen -G "$here/slot_map*.md")
  if (( ${#_maps[@]} == 1 )); then
    slot_map="${_maps[0]}"
  elif (( ${#_maps[@]} == 0 )); then
    err "no slot map found - pass --map FILE (looked for $here/slot_map*.md)"
  else
    err "several slot maps found - choose one with --map:"
    for m in "${_maps[@]}"; do printf '           %s\n' "$m"; done
  fi
fi
(( ${#errors[@]} == 0 )) || exit 1

for f in "$slot_map" "$env_file"; do
  [[ -n $f && -f $f ]] || err "missing file: ${f:-<unset>}"
done
(( ${#errors[@]} == 0 )) || exit 1

if (( jtag_freq > jsm_max_jtag_hz )); then
  warn "--freq $jtag_freq Hz exceeds the NAT-JSM maximum ($jsm_max_jtag_hz Hz); clamping"
  jtag_freq=$jsm_max_jtag_hz
fi
if (( jtag_freq > 6000000 )) && (( ! invert_read_edge )); then
  warn "--freq $jtag_freq Hz without --invert-read-edge is unreliable on this bench (corrupt IDCODE above ~7 MHz)"
fi

# shared cable/frequency arguments
ofl_common=(-c "$cable" --vid "$vid" --pid "$pid" --freq "$jtag_freq")
(( invert_read_edge )) && ofl_common+=(--invert-read-edge)

# --- env / map ----------------------------------------------------------------
declare -A bitpath=()
while IFS='=' read -r key value; do
  [[ -z ${key//[[:space:]]/} || $key == \#* ]] && continue
  key="${key//[[:space:]]/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  [[ -n $key ]] && bitpath["$key"]="$value"
done < "$env_file"

env_dir="$(cd "$(dirname "$env_file")" && pwd)"
for key in "${!bitpath[@]}"; do
  value="${bitpath[$key]}"
  [[ $value == /* ]] || bitpath[$key]="$(realpath -m -- "$env_dir/$value")"
done

declare -A sym_of=()
while IFS= read -r line; do
  [[ $line =~ ^\|([A-Za-z]+)[[:space:]]*\| ]] || continue
  role="${BASH_REMATCH[1]^^}"
  [[ $role == AMC || $role == RTM ]] || continue
  row="${line#|}"
  row="${row%|}"
  IFS='|' read -r -a cells <<< "$row"
  slot=1
  for cell in "${cells[@]:1}"; do
    (( slot > 12 )) && break
    sym_of["$slot:$role"]="${cell//[[:space:]]/}"
    ((slot++))
  done
done < "$slot_map"

# --- plan ---------------------------------------------------------------------
plan_slots=()
declare -A role_path=() role_sym=()
for slot in $(seq 1 12); do
  if (( ${#slot_filter[@]} )); then
    keep=0
    for want in "${slot_filter[@]}"; do (( want == slot )) && keep=1; done
    (( keep )) || continue
  fi
  entries=0
  for role in RTM AMC; do
    sym="${sym_of["$slot:$role"]:-}"
    [[ -z $sym || $sym == "-" ]] && continue
    if [[ -z ${bitpath[$sym]:-} ]]; then
      err "slot $slot $role: symbol '$sym' is not defined in $(basename "$env_file")"
      continue
    fi
    role_path["$slot:$role"]="${bitpath[$sym]}"
    role_sym["$slot:$role"]="$sym"
    entries=$((entries + 1))
  done
  (( entries )) && plan_slots+=("$slot")
done
(( ${#errors[@]} == 0 )) || exit 1

if (( ${#plan_slots[@]} == 0 )); then
  err "no slot in $(basename "$slot_map") has a bitstream to load ('-' = no load)"
  exit 1
fi

printf 'Plan from %s + %s:\n' "$slot_map" "$env_file"
for slot in "${plan_slots[@]}"; do
  line=""
  for role in RTM AMC; do
    p="${role_path["$slot:$role"]:-}"
    [[ -n $p ]] && line+="${role}=${role_sym["$slot:$role"]}[$(basename "$p")] "
  done
  printf '  slot %s: %s\n' "$slot" "${line% }"
done

for slot in "${plan_slots[@]}"; do
  for role in RTM AMC; do
    p="${role_path["$slot:$role"]:-}"
    [[ -n $p && ! -f $p ]] && err "slot $slot $role: bitstream not found: $p"
  done
done
(( ${#errors[@]} == 0 )) || exit 1

if (( dry_run )); then
  printf '\nDry run - nothing programmed.\n'
  exit 0
fi

if [[ $ofl == */* ]]; then
  [[ -x $ofl ]] || err "openFPGALoader not executable: $ofl"
else
  command -v "$ofl" >/dev/null || err "openFPGALoader not in PATH: $ofl (use --ofl PATH)"
fi
(( ${#errors[@]} == 0 )) || exit 1

# Warn early when the installed build predates xcku15p support (0.13.1 is the
# current distro package and cannot identify the u4FCP FPGA).
ofl_ver=$("$ofl" --Version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9.]+' | tr -d v)
if [[ -n $ofl_ver ]] && (( ${ofl_ver%%.*} == 0 )); then
  warn "openFPGALoader $ofl_ver does not know the u4FCP xcku15p - it will fail at chain detection; 1.1.x or newer is required (see docs/openfpgaloader_install.md)"
fi


# --- MCH channel --------------------------------------------------------------
mch_state() {
  local html compact sel
  html=$(curl -s --max-time 8 -u "$mch_user:$mch_pass" \
              "http://$mch/goform/view_jtag_jsm_par") || { mch_dev="?"; mch_status="unreachable"; return 1; }
  compact=$(printf '%s' "$html" | tr '\n' ' ')
  if [[ $compact == *"Waiting for Xilinx Virtual Cable completion"* ]]; then
    mch_dev="?"; mch_status="Waiting for Xilinx Virtual Cable completion."
    return 0
  fi
  if [[ $compact == *">Ready<"* ]]; then
    sel=$(printf '%s' "$compact" | awk -v RS='</select>' '/FrontActiveDev/ {print; exit}')
    mch_dev=$(printf '%s' "$sel" | grep -o "selected value='[0-9]*'>[^<]*" | sed 's/.*>//' | tail -1)
    mch_status="Ready"
    return 0
  fi
  mch_dev="?"; mch_status="unknown"
}

select_channel() {
  local slot=$1 deadline
  if ! curl -s --max-time 10 -u "$mch_user:$mch_pass" \
        -d "FrontActiveDev=$((slot - 1))&front_jtag_dev=override_front" \
        "http://$mch/goform/ctrl_jtag_jsm_override" -o /dev/null; then
    err "slot $slot: cannot select MCH channel (is $mch reachable?)"
    return 1
  fi
  deadline=$(( $(date +%s) + ${channel_wait%%.*} ))
  while :; do
    mch_state || { err "slot $slot: cannot read MCH state"; return 1; }
    [[ $mch_status == Ready* ]] && break
    (( $(date +%s) < deadline )) || break
    sleep 0.5
  done
  if [[ $mch_status != Ready* ]]; then
    err "slot $slot: MCH channel switch blocked (status: $mch_status). A JTAG tool session may still be attached; close it and retry."
    return 1
  fi
  if [[ -n $mch_dev && $mch_dev != "?" && $mch_dev != "AMC$slot" ]]; then
    warn "slot $slot: MCH reports active channel $mch_dev, expected AMC$slot"
  else
    info "slot $slot: MCH channel selected (AMC$slot)"
  fi
  return 0
}

# --- chain detection ----------------------------------------------------------
declare -A dev_family=() dev_model=()
detect_chain() {
  # The first scan straight after an MCH channel switch can come back empty even
  # though the chain is healthy (same stale-scan effect seen with Vivado), so
  # retry a few times before declaring the channel dead.
  local attempt out rc cur="" i
  for attempt in 1 2 3 4; do
    dev_family=(); dev_model=()
    timeout "$ofl_timeout" "$ofl" "${ofl_common[@]}" --detect > "$out_file" 2>&1
    rc=$?
    out=$(tr -d '\000' < "$out_file")
    if [[ $out == *"Unknown device with IDCODE"* ]]; then
      local idcode
      idcode=$(printf '%s' "$out" | grep -o 'IDCODE: 0x[0-9a-fA-F]*' | head -1)
      err "unrecognised device on the chain (${idcode:-no idcode})"
      # A correct IDCODE that is still 'unknown' means this build simply lacks the
      # part. 0.13.1 (the current distro package) reports exactly this for xcku15p.
      case "${idcode:-}" in
        *14a56093*|*4a56093*)
          printf '         hint: that is the u4FCP xcku15p; openFPGALoader 0.13.1 does not know this part.\n'
          printf '               use 1.1.x from the release tarball - see docs/openfpgaloader_install.md\n' ;;
        *)
          printf '         hint: likely a bad scan - try a lower --freq and --invert-read-edge\n' ;;
      esac
      return 1
    fi
    if [[ $out == *"JTAG init failed"* || $out == *"unable to open ftdi"* ]]; then
      err "no JTAG target: $(printf '%s' "$out" | grep -E 'JTAG init failed|unable to open' | head -1)"
      return 1
    fi
    if (( rc != 0 )); then
      err "openFPGALoader --detect failed (exit $rc)"
      return 1
    fi
    cur=""
    while IFS= read -r line; do
      if [[ $line =~ ^index\ ([0-9]+): ]]; then
        cur="${BASH_REMATCH[1]}"
      elif [[ -n $cur && $line =~ ^[[:space:]]+family[[:space:]]+(.+)$ ]]; then
        dev_family[$cur]="${BASH_REMATCH[1]}"
      elif [[ -n $cur && $line =~ ^[[:space:]]+model[[:space:]]+(.+)$ ]]; then
        dev_model[$cur]="${BASH_REMATCH[1]}"
      fi
    done <<< "$out"

    if (( ${#dev_model[@]} > 0 )); then
      (( attempt > 1 )) && info "chain detected on attempt $attempt"
      for i in "${!dev_model[@]}"; do
        info "chain device $i: ${dev_model[$i]} (${dev_family[$i]:-?})"
      done
      return 0
    fi
    sleep 0.7
  done

  err "chain is empty after 4 scans - no device found on the selected channel"
  printf '%s\n' "         --- last openFPGALoader --detect output: ---"
  printf '%s\n' "$out" | sed 's/^/         /'
  return 1
}

# AMC is the UltraScale/UltraScale+ part; RTM is the 7-series part.
role_index() {
  local role=$1 i
  for i in "${!dev_model[@]}"; do
    case "$role:${dev_family[$i]:-}" in
      AMC:*usp*|AMC:*ultra*) echo "$i"; return 0 ;;
      RTM:*7*|RTM:zynq7000)  echo "$i"; return 0 ;;
    esac
  done
  return 1
}

# --- program one device -------------------------------------------------------
program_device() {
  local slot=$1 role=$2 idx=$3 bit=$4
  local out rc t0 t1
  info "slot $slot $role: downloading $(basename "$bit") (index $idx, $jtag_freq Hz)"
  t0=$(date +%s%N)
  timeout "$ofl_timeout" "$ofl" "${ofl_common[@]}" --index-chain "$idx" "$bit" > "$out_file" 2>&1
  rc=$?
  out=$(tr -d '\000' < "$out_file")
  t1=$(date +%s%N)
  local took=$(( (t1 - t0) / 1000000 ))

  if (( rc == 124 )); then
    err "slot $slot $role: openFPGALoader timed out after ${ofl_timeout}s"
    return 1
  fi
  if [[ $out == *"Unknown device with IDCODE"* ]]; then
    err "slot $slot $role: unknown IDCODE - bad scan; try a lower --freq"
    return 1
  fi
  if (( rc != 0 )) || [[ $out == *"fail"* && $out != *"Done"* ]]; then
    err "slot $slot $role: programming failed (exit $rc): $(printf '%s' "$out" | grep -iE 'fail|error' | head -1)"
    return 1
  fi

  # openFPGALoader prints the status register after loading:
  #   ir: 1 isc_done 1 isc_ena 0 init 1 done 1
  local done_bit="?"
  if [[ $out =~ done\ ([01]) ]]; then
    done_bit="${BASH_REMATCH[1]}"
  fi
  case "$done_bit" in
    0) err "slot $slot $role: no DONE - status register reads done 0"; return 1 ;;
    1) ok "slot $slot $role: programmed, DONE=1 in $(fmt_ms "$took")"; return 0 ;;
    *) warn "slot $slot $role: programmed in $(fmt_ms "$took") but DONE could not be confirmed"; return 0 ;;
  esac
}

# --- main loop ----------------------------------------------------------------
for slot in "${plan_slots[@]}"; do
  printf '\n=== slot %s %s\n' "$slot" "=============================================="
  slot_start=$(date +%s%N)

  if (( ! no_mch )); then
    select_channel "$slot" || continue
    sleep "$settle"
  fi

  detect_chain || continue

  for role in RTM AMC; do
    bit="${role_path["$slot:$role"]:-}"
    [[ -z $bit ]] && continue
    if ! idx=$(role_index "$role"); then
      if [[ $role == RTM ]]; then
        warn "slot $slot: RTM bitstream defined but no 7-series device found in the chain"
      else
        err "slot $slot: AMC bitstream defined but no UltraScale device found in the chain"
      fi
      continue
    fi
    program_device "$slot" "$role" "$idx" "$bit" || true
  done

  slot_ms=$(( ($(date +%s%N) - slot_start) / 1000000 ))
  info "slot $slot: total $(fmt_ms "$slot_ms") (MCH select + detect + program)"
done

# --- summary ------------------------------------------------------------------
printf '\n%s\n' "--------------------------------------------------------------"
if (( ${#errors[@]} )); then
  printf 'RESULT: FAILED - %d error(s), %d warning(s)\n' "${#errors[@]}" "${#warnings[@]}"
  for e in "${errors[@]}";   do printf '   error: %s\n' "$e"; done
  for w in "${warnings[@]}"; do printf '   warn : %s\n' "$w"; done
  exit 1
fi
if (( ${#warnings[@]} )); then
  printf 'RESULT: PASSED WITH WARNINGS - %d warning(s)\n' "${#warnings[@]}"
  for w in "${warnings[@]}"; do printf '   warn : %s\n' "$w"; done
  exit 0
fi
printf 'RESULT: PASSED\n'
exit 0
