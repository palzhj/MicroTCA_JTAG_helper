#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# program_fpgas.sh
#
# Program the u4FCP FPGAs slot by slot, according to a slot map file.
#
# For every slot that has a bitstream defined this script:
#   1. selects that slot's JTAG channel on the MCH (NAT-JSM override),
#   2. programs the RTM FPGA first, then the AMC FPGA,
#   3. reports warnings and errors - missing cable/target, a device missing from
#      the chain, a programming failure, or no DONE/startup after programming.
#
# Bitstream paths come from bit_files.env, keyed by the symbols in the map file.
# A '-' in the map means "no load" and the slot is skipped. Relative paths in
# bit_files.env are resolved against the directory that file lives in.
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
#   --timeout S       Vivado timeout per slot (default: 900)
#   --jtag-freq HZ    JTAG clock, capped at the NAT-JSM maximum (default: 10000000)
#   --hw-server URL   hw_server URL (default: localhost:3121)
#   --rtm-dev NAME    force the RTM hw_device name (default: auto by part)
#   --amc-dev NAME    force the AMC hw_device name (default: auto by part)
#   --allow-same-chain    allow two slots to report an identical chain (default: refuse)
#   --vivado PATH     Vivado executable (default: $VIVADO, VIVADO= in the env file, PATH, newest install)
#   -h, --help        show this help
#
# Examples:
#   ./program_fpgas.sh --dry-run          # show what would be programmed
#   ./program_fpgas.sh                    # program every loaded slot
#   ./program_fpgas.sh --no-mch           # channel already selected by hand
#   ./program_fpgas.sh --jtag-freq 5000000 --hw-server 192.168.10.50:3121
#   ./program_fpgas.sh --map slot_map_waveform.md   # choose the slot map
#   ./program_fpgas.sh --map ../other/slot_map_x.md --env ../other/bits.env
#-------------------------------------------------------------------------------
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slot_map=""                                   # resolved after option parsing
env_file="$here/bit_files.env"
tcl_file="$here/program_chain.tcl"

# The NAT-JSM cannot clock JTAG faster than this, whatever the cable supports.
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
vivado_timeout=900
jtag_freq=$jsm_max_jtag_hz
hw_server="localhost:3121"
rtm_dev=""
amc_dev=""
allow_same_chain=0
prev_chain_sig=""
vivado_opt=""
vivado=""           # resolved after parsing: --vivado, $VIVADO, PATH, newest install

warnings=()
errors=()

info() { printf '[INFO ] %s\n' "$*"; }
ok()   { printf '[ OK  ] %s\n' "$*"; }
warn() { printf '[WARN ] %s\n' "$*"; warnings+=("$*"); }
err()  { printf '[ERROR] %s\n' "$*"; errors+=("$*"); }

# print the header comment block: between the opening and closing rule
usage() { awk 'NR==1{next} /^#----/{if(seen)exit; seen=1; next} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

# --- arguments ----------------------------------------------------------------
while (($#)); do
  case "$1" in
    --map)         slot_map="$2"; shift 2 ;;
    --env)         env_file="$2"; shift 2 ;;
    --dry-run)     dry_run=1; shift ;;
    --no-mch)      no_mch=1; shift ;;
    --override-repeats) override_repeats="$2"; shift 2 ;;
    --mch)         mch_opt="$2"; shift 2 ;;
    --user)        mch_user="$2"; shift 2 ;;
    --password)    mch_pass="$2"; shift 2 ;;
    --channel-wait) channel_wait="$2"; shift 2 ;;
    --settle)      settle="$2"; shift 2 ;;
    --timeout)     vivado_timeout="$2"; shift 2 ;;
    --jtag-freq)   jtag_freq="$2"; shift 2 ;;
    --hw-server)   hw_server="$2"; shift 2 ;;
    --rtm-dev)     rtm_dev="$2"; shift 2 ;;
    --amc-dev)     amc_dev="$2"; shift 2 ;;
    --allow-same-chain) allow_same_chain=1; shift ;;
    --vivado)      vivado_opt="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done


# --- preflight ----------------------------------------------------------------
# With no --map, accept a single slot_map*.md next to this script. More than one
# is an error rather than a guess, so the wrong bitstreams are never programmed.
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
  warn "--jtag-freq $jtag_freq Hz exceeds the NAT-JSM maximum ($jsm_max_jtag_hz Hz); clamping to the maximum"
  jtag_freq=$jsm_max_jtag_hz
fi

declare -A bitpath=()
env_mch=""
env_vivado=""
while IFS='=' read -r key value; do
  [[ -z ${key//[[:space:]]/} || $key == \#* ]] && continue
  key="${key//[[:space:]]/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  # VIVADO= pins the tool; every other key is a bitstream symbol
  if [[ ${key^^} == VIVADO ]]; then env_vivado="$value"; continue; fi
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

# --- Vivado discovery ---------------------------------------------------------
# Any installed version works: the Tcl payload only uses the hardware-manager API.
# Precedence: --vivado, $VIVADO, VIVADO= in the env file, PATH, then the newest
# install found on disk.
resolve_vivado() {
  local cand
  if [[ -n $vivado_opt ]]; then printf '%s' "$vivado_opt"; return 0; fi
  if [[ -n ${VIVADO:-} ]]; then printf '%s' "$VIVADO"; return 0; fi
  if [[ -n ${env_vivado:-} ]]; then printf '%s' "$env_vivado"; return 0; fi
  if cand=$(command -v vivado 2>/dev/null); then printf '%s' "$cand"; return 0; fi
  local -a found=()
  while IFS= read -r cand; do
    [[ -n $cand && -x $cand ]] && found+=("$cand")
  done < <(ls -1d /opt/Xilinx/Vivado/*/bin/vivado /tools/Xilinx/Vivado/*/bin/vivado \
                  /opt/xilinx/Vivado/*/bin/vivado "$HOME"/Xilinx/Vivado/*/bin/vivado 2>/dev/null)
  (( ${#found[@]} )) || return 1
  printf '%s\n' "${found[@]}" | sort -V | tail -1
}

if ! vivado="$(resolve_vivado)" || [[ -z $vivado ]]; then
  err "vivado not found - pass --vivado PATH, set VIVADO, or put it in PATH"
  err "searched: /opt/Xilinx/Vivado/*/bin/vivado, /tools/Xilinx/Vivado/*/bin/vivado, \$HOME/Xilinx/Vivado/*/bin/vivado"
  exit 1
fi
info "vivado  : $vivado"

# slot -> symbol, parsed from the |AMC ...| / |RTM ...| rows of the map
declare -A sym_of=()
while IFS= read -r line; do
  [[ $line =~ ^\|([A-Za-z]+)[[:space:]]*\| ]] || continue
  role="${BASH_REMATCH[1]^^}"
  [[ $role == AMC || $role == RTM ]] || continue
  row="${line#|}"                 # drop leading pipe
  row="${row%|}"                  # drop trailing pipe
  IFS='|' read -r -a cells <<< "$row"
  slot=1
  for cell in "${cells[@]:1}"; do
    (( slot > 12 )) && break
    value="${cell//[[:space:]]/}"
    sym_of["$slot:$role"]="$value"
    ((slot++))
  done
done < "$slot_map"

# --- build the plan -----------------------------------------------------------
plan_slots=()
declare -A role_path=()
declare -A role_sym=()
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

[[ -x $vivado ]] || err "vivado not executable: $vivado"
(( ${#errors[@]} == 0 )) || exit 1

if (( dry_run )); then
  printf '\nDry run - nothing programmed.\n'
  exit 0
fi

# --- MCH channel --------------------------------------------------------------
# sets globals mch_dev / mch_status
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
    info "slot $slot: MCH channel selected (${mch_dev/AMC/AMC})"
  fi
  return 0
}

# --- evaluate one Vivado transcript ------------------------------------------
evaluate_slot() {
  local slot=$1 out=$2
  shift 2
  local roles=("$@")
  local line cur="" fatal="" chain_count="" role
  local -A begun=() fail=() startup=() prog=() took=() done=() eos=() crc=()
  local -a chain=()
  chain_sig=""
  chain_similar=0
  local -a missing=()
  for role in "${roles[@]}"; do
    begun[$role]=0; fail[$role]=""; startup[$role]=""; prog[$role]=""; took[$role]=""
    done[$role]=""; eos[$role]=""; crc[$role]=""
  done

  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]+WARNING:[[:space:]]*(.*) ]]; then
      warn "slot $slot: ${BASH_REMATCH[1]}"
    fi
    if [[ $line =~ ^(FATAL|ERROR):\ ([^\[]*) ]] && [[ ${BASH_REMATCH[2]} != "" ]]; then
      fatal+="${BASH_REMATCH[2]}"$'\n'
    fi
    [[ $line =~ ^CHAIN_COUNT:\ ([0-9]+) ]] && chain_count="${BASH_REMATCH[1]}"
    [[ $line =~ ^CHAIN_SIG:\ (.*) ]] && chain_sig="${BASH_REMATCH[1]}"
    [[ $line =~ ^CHAIN_SIMILAR:\ (.*) ]] && chain_similar=1
    [[ $line =~ ^CHAIN\ dev=([^[:space:]]+)\ part=([^[:space:]]+) ]] && chain+=("${BASH_REMATCH[1]} (${BASH_REMATCH[2]})")
    [[ $line =~ ^MISSING\ role=([A-Za-z]+) ]] && missing+=("${BASH_REMATCH[1]}")
    if [[ $line =~ ^PROGRAM_BEGIN\ role=([A-Za-z]+) ]]; then
      cur="${BASH_REMATCH[1]}"; begun[$cur]=1
    elif [[ $line =~ ^PROGRAM_FAIL\ role=([A-Za-z]+)\ dev=[^[:space:]]+\ error=(.*) ]]; then
      fail[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    elif [[ $line =~ ^PROGRAM_STATUS\ role=([A-Za-z]+)\ dev=[^[:space:]]+\ done=([^[:space:]]+)\ eos=([^[:space:]]+)\ crc=([^[:space:]]+) ]]; then
      done[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
      eos[${BASH_REMATCH[1]}]="${BASH_REMATCH[3]}"
      crc[${BASH_REMATCH[1]}]="${BASH_REMATCH[4]}"
    elif [[ $line =~ ^PROGRAM_TIME\ role=([A-Za-z]+)\ dev=[^[:space:]]+\ ms=([0-9]+) ]]; then
      took[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    elif [[ $line =~ End\ of\ startup\ status:\ (HIGH|LOW) ]]; then
      [[ -n $cur ]] && startup[$cur]="${BASH_REMATCH[1]}"
    elif [[ $line =~ ^PROGRAM_END\ role=([A-Za-z]+)\ dev=[^[:space:]]+\ is_programmed=([^[:space:]]+) ]]; then
      prog[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    fi
  done < "$out"

  if [[ -n $fatal ]]; then
    while IFS= read -r f; do [[ -n $f ]] && err "slot $slot: $f"; done <<< "$fatal"
    return
  fi
  if [[ -z $chain_count ]]; then
    err "slot $slot: no JTAG chain information in the Vivado output"
    return
  fi
  if [[ $chain_count == 0 ]]; then
    err "slot $slot: JTAG chain is empty - no target found on the selected channel"
    return
  fi

  local dev
  for dev in "${chain[@]}"; do info "slot $slot: chain device $dev"; done

  for role in "${roles[@]}"; do
    (( begun[$role] )) || continue
    if [[ -n ${fail[$role]} ]]; then
      err "slot $slot $role: programming failed - ${fail[$role]}"; continue
    fi

    ms="${took[$role]:-}"
    if [[ -n $ms ]]; then
      secs="$((ms / 1000)).$(printf '%03d' $((ms % 1000)))s"
    else
      secs=""
    fi
    [[ -n $secs ]] && secs=" in $secs"

    # 1) hardware register read is authoritative
    case "${crc[$role]:-}" in
      1) err "slot $slot $role: CRC error after programming (CONFIG_STATUS.CRC_ERROR=1)"; continue ;;
    esac
    case "${done[$role]:-}" in
      0)
        err "slot $slot $role: no DONE - CONFIG_STATUS.DONE_PIN reads 0"; continue ;;
      1)
        ok "slot $slot $role: programmed, DONE=1 (EOS=${eos[$role]:-?})$secs"
        continue ;;
    esac

    # 2) fall back to the startup message if the register was not readable
    case "${startup[$role]}" in
      LOW)  err "slot $slot $role: no DONE - startup ended LOW after programming"; continue ;;
      HIGH) ok  "slot $slot $role: programmed, DONE asserted (startup HIGH)$secs"; continue ;;
    esac

    if [[ ${prog[$role]} == 0 ]]; then
      err "slot $slot $role: device reports is_programmed=0 after programming"; continue
    fi
    warn "slot $slot $role: programmed but DONE could not be confirmed (no register read, no startup status)"
  done

  if (( chain_similar )); then
    warn "slot $slot: chain matches the previous slot by part name only (DNA unavailable) - cannot tell boards apart"
  fi
  prev_chain_sig="$chain_sig"

  local m
  if (( ${#missing[@]} )); then
    for m in "${missing[@]}"; do
      case "$m" in
        RTM) warn "slot $slot: RTM bitstream defined but no 7-series device found in the chain" ;;
        AMC) err  "slot $slot: AMC bitstream defined but no UltraScale device found in the chain" ;;
      esac
    done
  fi
}

# --- program ------------------------------------------------------------------
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT

for slot in "${plan_slots[@]}"; do
  printf '\n=== slot %s %s\n' "$slot" "=============================================="
  slot_start=$(date +%s%N)
  rtm_bit="${role_path["$slot:RTM"]:-none}"
  amc_bit="${role_path["$slot:AMC"]:-none}"
  roles=()
  [[ $rtm_bit != none ]] && roles+=(RTM)
  [[ $amc_bit != none ]] && roles+=(AMC)

  if (( ! no_mch )); then
    select_channel "$slot" || continue
    sleep "$settle"
  fi

  timeout "$vivado_timeout" "$vivado" -mode batch -nojournal -nolog -notrace \
      -source "$tcl_file" \
      -tclargs "$rtm_bit" "$amc_bit" "$jtag_freq" "$hw_server" "$rtm_dev" "$amc_dev" \
               "$( (( allow_same_chain )) && echo '' || echo "$prev_chain_sig")" \
      > "$out_file" 2>&1
  rc=$?

  evaluate_slot "$slot" "$out_file" "${roles[@]}"

  if (( rc == 124 )); then
    err "slot $slot: vivado timed out after ${vivado_timeout}s"
  elif (( rc != 0 )) && ! grep -qE '^(FATAL|ERROR): ' "$out_file"; then
    err "slot $slot: vivado exited with code $rc"
  fi

  slot_ms=$(( ($(date +%s%N) - slot_start) / 1000000 ))
  info "slot $slot: total $((slot_ms / 1000)).$(printf '%03d' $((slot_ms % 1000)))s (MCH select + Vivado + program)"
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
