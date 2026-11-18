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
#   --dry-run         show the plan and exit
#   --no-mch          do not touch the MCH; assume the channel is already selected
#   --mch ADDR        MCH address (default: MCH= in the env file, else 192.168.1.41)
#   --override-repeats N  send the channel override N times (default: 3). A single
#                     POST is ignored; 2 is the measured minimum.
#   --user USER       MCH web user (default: root)
#   --password PASS   MCH web password (default: nat)
#   --channel-wait S  max wait for the MCH channel switch (default: 20)
#   --settle S        pause after switching channel (default: 0.3; measured 45 ms)
#   --timeout S       openFPGALoader timeout per device (default: 600)
#   --freq HZ         JTAG clock (default: 10000000, the NAT-JSM maximum)
#                     (--jtag-freq is accepted as an alias, matching the Vivado driver)
#   --fallback-freq HZ  retry at this clock if the chain does not scan (default: 7500000);
#                     set it equal to --freq to disable the fallback
#   --invert-read-edge    sample JTAG reads on the falling edge (default: on)
#   --no-invert-read-edge disable the above
#   --cable NAME      JTAG cable (default: digilent_hs3)
#   --allow-same-chain    silence the identical-chain warning (default behaviour now warns)
#   --strict-chain        refuse to program a slot whose chain matches the previous one
#   --scan                only report the chain of every slot; program nothing
#   --vid ID          cable USB vendor id (default: 0x0403)
#   --pid ID          cable USB product id (default: 0x6010)
#   --ofl PATH        openFPGALoader binary (default: $OPENFPGALOADER or PATH)
#   -h, --help        show this help
#
# Examples:
#   ./program_fpgas_ofl.sh --dry-run
#   ./program_fpgas_ofl.sh --map slot_map_waveform.md --freq 3000000
#   ./program_fpgas_ofl.sh --ofl /opt/ofl/openFPGALoader
#-------------------------------------------------------------------------------
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slot_map=""
env_file="$here/bit_files.env"

jsm_max_jtag_hz=10000000

# --- defaults -----------------------------------------------------------------
dry_run=0
no_mch=0
override_repeats=3
mch_opt=""
mch_default="192.168.1.41"
mch_user="root"
mch_pass="nat"
channel_wait=20
settle=0.3
ofl_timeout=600
jtag_freq=$jsm_max_jtag_hz
fallback_freq=7500000
allow_same_chain=0
strict_chain=0
scan_only=0
cable="digilent_hs3"
vid="0x0403"
invert_read_edge=1
pid="0x6010"
ofl="${OPENFPGALOADER:-openFPGALoader}"

warnings=()
errors=()
scan_rows=()
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
    --dry-run)      dry_run=1; shift ;;
    --no-mch)       no_mch=1; shift ;;
    --override-repeats) override_repeats="$2"; shift 2 ;;
    --mch)          mch_opt="$2"; shift 2 ;;
    --user)         mch_user="$2"; shift 2 ;;
    --password)     mch_pass="$2"; shift 2 ;;
    --channel-wait) channel_wait="$2"; shift 2 ;;
    --settle)       settle="$2"; shift 2 ;;
    --timeout)      ofl_timeout="$2"; shift 2 ;;
    --freq|--jtag-freq) jtag_freq="$2"; shift 2 ;;
    --fallback-freq) fallback_freq="$2"; shift 2 ;;
    --cable)        cable="$2"; shift 2 ;;
    --allow-same-chain) allow_same_chain=1; shift ;;
    --strict-chain)     strict_chain=1; shift ;;
    --scan)             scan_only=1; shift ;;
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
    err "no slot map found - pass --map FILE"
    printf '         looked for %s/slot_map*.md; copy one of the slot_map*.md.example files and edit it\n' "$here"
  else
    err "several slot maps found - choose one with --map:"
    for m in "${_maps[@]}"; do printf '           %s\n' "$m"; done
  fi
fi
(( ${#errors[@]} == 0 )) || exit 1

for f in "$slot_map" "$env_file"; do
  if [[ -z $f || ! -f $f ]]; then
    err "missing file: ${f:-<unset>}"
    case "$(basename "${f:-}")" in
      bit_files.env) printf '         copy bit_files.env.example to bit_files.env and edit it for your bench\n' ;;
      *.md)          printf '         copy a slot_map*.md.example file to slot_map_<name>.md and edit it\n' ;;
    esac
  fi
done
(( ${#errors[@]} == 0 )) || exit 1

if (( jtag_freq > jsm_max_jtag_hz )); then
  warn "--freq $jtag_freq Hz exceeds the NAT-JSM maximum ($jsm_max_jtag_hz Hz); clamping"
  jtag_freq=$jsm_max_jtag_hz
fi
if (( jtag_freq > 6000000 )) && (( ! invert_read_edge )); then
  warn "--freq $jtag_freq Hz without --invert-read-edge is unreliable on this bench (corrupt IDCODE above ~7 MHz)"
fi

# shared cable/frequency arguments; rebuilt when falling back to a slower clock
set_freq() {
  jtag_freq="$1"
  ofl_common=(-c "$cable" --vid "$vid" --pid "$pid" --freq "$jtag_freq")
  (( invert_read_edge )) && ofl_common+=(--invert-read-edge)
}
set_freq "$jtag_freq"

# --- env / map ----------------------------------------------------------------
declare -A bitpath=()
env_mch=""
while IFS='=' read -r key value; do
  [[ -z ${key//[[:space:]]/} || $key == \#* ]] && continue
  key="${key//[[:space:]]/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  if [[ ${key^^} == MCH ]]; then env_mch="$value"; continue; fi
  [[ -n $key ]] && bitpath["$key"]="$value"
done < "$env_file"

# --mch wins, then MCH= in the env file, then the built-in default
mch="${mch_opt:-${env_mch:-$mch_default}}"
info "mch     : $mch"

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
  if [[ $compact == *"Overriding Enabled"* ]]; then mch_ovr="Enabled"; else mch_ovr="Disabled"; fi
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
  # Two conditions are required for the switch to move, both measured:
  #  1. nothing may be holding the JTAG cable - a running hw_server blocks it
  #  2. the override must be sent several times (a single POST is ignored)
  if pgrep -x hw_server >/dev/null 2>&1; then
    info "slot $slot: stopping hw_server so the switch can move"
    pkill -x hw_server 2>/dev/null
    sleep 0.2      # cable is free 45-55 ms after the kill
  fi
  local n
  for ((n = 1; n <= override_repeats; n++)); do
    if ! curl -s --max-time 10 -u "$mch_user:$mch_pass" \
          -d "FrontActiveDev=$((slot - 1))&front_jtag_dev=override_front" \
          "http://$mch/goform/ctrl_jtag_jsm_override" -o /dev/null; then
      err "slot $slot: cannot select MCH channel (is $mch reachable?)"
      return 1
    fi
    (( n < override_repeats )) && sleep 0.3
  done
  (( override_repeats > 1 )) && info "slot $slot: override sent $override_repeats times (the JSM ignores the first few)"
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
declare -A dev_family=() dev_model=() dev_idcode=()
detect_chain() {
  # The first scan straight after a channel switch reliably fails - with
  # "TDO is stuck at 0", "JTAG init failed" or an empty chain - and succeeds a
  # moment later. Every failure is therefore retried; only the last one is
  # reported if all attempts fail.
  local attempt out rc cur="" i last_err="" freq primary="$jtag_freq"
  local -a freqs=("$primary")
  # A slot with a marginal link can scan at 7.5 MHz when 10 MHz fails; retry the
  # whole scan at the fallback clock before giving up on the slot.
  (( fallback_freq > 0 && fallback_freq < primary )) && freqs+=("$fallback_freq")
  for freq in "${freqs[@]}"; do
  if (( freq != primary )); then
    warn "no chain at ${primary} Hz - retrying at ${freq} Hz"
    set_freq "$freq"
  fi
  for attempt in 1 2 3 4; do
    dev_family=(); dev_model=(); dev_idcode=()
    timeout "$ofl_timeout" "$ofl" "${ofl_common[@]}" --detect > "$out_file" 2>&1
    rc=$?
    out=$(tr -d '\000' < "$out_file")

    cur=""
    while IFS= read -r line; do
      if [[ $line =~ ^index\ ([0-9]+): ]]; then
        cur="${BASH_REMATCH[1]}"
      elif [[ -n $cur && $line =~ ^[[:space:]]+family[[:space:]]+(.+)$ ]]; then
        dev_family[$cur]="${BASH_REMATCH[1]}"
      elif [[ -n $cur && $line =~ ^[[:space:]]+model[[:space:]]+(.+)$ ]]; then
        dev_model[$cur]="${BASH_REMATCH[1]}"
      elif [[ -n $cur && $line =~ ^[[:space:]]+idcode[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
        dev_idcode[$cur]="${BASH_REMATCH[1]}"
      fi
    done <<< "$out"

    if (( ${#dev_model[@]} > 0 )); then
      (( attempt > 1 )) && info "chain detected on attempt $attempt"
      for i in "${!dev_model[@]}"; do
        info "chain device $i: ${dev_model[$i]} (${dev_family[$i]:-?})"
      done
      chain_sig=""
      for i in $(printf '%s\n' "${!dev_model[@]}" | sort -n); do
        chain_sig+="${dev_model[$i]}/${dev_idcode[$i]:-?};"
      done
      return 0
    fi

    if [[ $out == *"Unknown device with IDCODE"* ]]; then
      last_err=$(printf '%s' "$out" | grep -o 'Unknown device with IDCODE[^)]*' | head -1)
    elif [[ $out == *"JTAG init failed"* ]]; then
      last_err=$(printf '%s' "$out" | grep -o 'JTAG init failed.*' | head -1)
    elif [[ $out == *"unable to open ftdi"* ]]; then
      last_err="cable busy - unable to open ftdi device"
    elif (( rc != 0 )); then
      last_err="openFPGALoader --detect exited $rc"
    else
      last_err="chain is empty"
    fi
    (( attempt < 4 )) && sleep 0.7
  done
  done

  err "no devices after 4 scans at ${primary} Hz${freqs[1]:+ and 4 at ${freqs[1]} Hz}: $last_err"
  case "$last_err" in
    *14a56093*|*4a56093*)
      printf '         hint: that is the u4FCP xcku15p; openFPGALoader 0.13.1 does not know this part.\n'
      printf '               use 1.1.x from the release tarball - see docs/openfpgaloader_install.md\n' ;;
    *"stuck"*|*"init failed"*)
      printf '         hint: the target may be unpowered - check `show_fru` (state M4 = payload on).\n'
      printf '               else it is transient right after a switch; retry or raise --settle\n'
      printf '               a marginal slot may need a slower clock: try --freq %s\n' "${fallback_freq}" ;;
  esac
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
  local out rc t0 t1 took freq primary="$jtag_freq" done_bit last_err=""
  local -a freqs=("$primary")
  # Marginal links can fail during programming too, so apply the same fallback
  # as the scan: one retry at a slower clock, reporting only the final result.
  (( fallback_freq > 0 && fallback_freq < primary )) && freqs+=("$fallback_freq")

  for freq in "${freqs[@]}"; do
    if (( freq != primary )); then
      warn "slot $slot $role: failed at ${primary} Hz - retrying at ${freq} Hz"
      set_freq "$freq"
    fi
    info "slot $slot $role: downloading $(basename "$bit") (index $idx, ${jtag_freq} Hz)"
    t0=$(date +%s%N)
    timeout "$ofl_timeout" "$ofl" "${ofl_common[@]}" --index-chain "$idx" "$bit" > "$out_file" 2>&1
    rc=$?
    out=$(tr -d '\000' < "$out_file")
    t1=$(date +%s%N)
    took=$(( (t1 - t0) / 1000000 ))

    if (( rc == 124 )); then
      last_err="timed out after ${ofl_timeout}s"
      continue
    fi
    if [[ $out == *"Unknown device with IDCODE"* ]]; then
      last_err="unknown IDCODE - bad scan"
      continue
    fi
    if (( rc != 0 )) || [[ $out == *"fail"* && $out != *"Done"* ]]; then
      last_err="programming failed (exit $rc): $(printf '%s' "$out" | grep -iE 'fail|error' | head -1)"
      continue
    fi

    # openFPGALoader prints the status register after loading:
    #   ir: 1 isc_done 1 isc_ena 0 init 1 done 1
    done_bit="?"
    [[ $out =~ done\ ([01]) ]] && done_bit="${BASH_REMATCH[1]}"
    case "$done_bit" in
      0) last_err="no DONE - status register reads done 0"; continue ;;
      1) ok "slot $slot $role: programmed, DONE=1 in $(fmt_ms "$took")"; return 0 ;;
      *) warn "slot $slot $role: programmed in $(fmt_ms "$took") but DONE could not be confirmed"; return 0 ;;
    esac
  done

  err "slot $slot $role: $last_err"
  return 1
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

  if (( scan_only )); then
    info "slot $slot: ${chain_sig:-<empty>}"
    scan_rows+=("$(printf '%-4s %s' "$slot" "${chain_sig:-<empty>}")")
    # report roles that the map asks for but the chain cannot serve
    for role in RTM AMC; do
      [[ -z ${role_path["$slot:$role"]:-} ]] && continue
      if ! idx=$(role_index "$role"); then
        if [[ $role == RTM ]]; then
          warn "slot $slot: RTM bitstream in the map, but no 7-series device in the chain - would be skipped"
        else
          err "slot $slot: AMC bitstream in the map, but no UltraScale device in the chain"
        fi
      fi
    done
    continue
  fi

  # A JTAG switch that is not routing leaves every slot looking identical. That
  # would program the same FPGA over and over while reporting success, so stop.
  # openFPGALoader exposes no device DNA, so identical part names cannot be told
  # apart from a switch that is not routing. Warn only - the Vivado driver, which
  # can read DNA, is the one that refuses.
  # openFPGALoader cannot read UltraScale+ DNA, so an identical chain may be a
  # different board of the same type - normal in a homogeneous crate. Warn by
  # default; --strict-chain restores the refusal.
  if [[ -n ${prev_chain_sig:-} && $chain_sig == "$prev_chain_sig" && $slot != "${prev_chain_slot:-}" ]] \
     && (( ! allow_same_chain )); then
    if (( strict_chain )); then
      err "slot $slot: chain identical to slot ${prev_chain_slot} ($chain_sig) - refusing to program (--strict-chain)"
      continue
    fi
    warn "slot $slot: chain identical to slot ${prev_chain_slot} ($chain_sig) - continuing; OFL cannot tell same-type boards apart"
  fi
  prev_chain_sig="$chain_sig"; prev_chain_slot="$slot"

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
if (( scan_only )); then
  printf '\n%s\n' "slot chain"
  printf '%s\n' "${scan_rows[@]}"
  printf '\nScan only - nothing programmed.\n'
  printf 'Identical results only prove the channel moved if you also scan a slot that is EMPTY:\n'
  printf 'a populated and an empty slot returning the same device means the switch did not move.\n'
  exit 0
fi

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
