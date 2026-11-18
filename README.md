# MicroTCA JTAG helper

Program FPGAs on a MicroTCA shelf through an **NAT-MCH + NAT-JSM** JTAG switch: the MCH selects the JTAG
channel for a slot, and a local pod on the JSM front connector performs the download.

Two interchangeable back-ends drive the same slot map - Xilinx **Vivado** and **openFPGALoader** - so you
can pick per machine.

## Why this exists

On a MicroTCA shelf the FPGAs of all AMC/RTM slots sit behind a JTAG switch module, and only one slot's
chain is routed to the front connector at a time. These scripts automate the per-slot selection, program
the devices in a defined order (RTM before AMC), verify the result, and report what failed instead of
leaving you to interpret tool output.

XVC is deliberately not used: it tunnels every JTAG transaction over TCP and is far slower than a local pod.

## Contents

| Path | Purpose |
|---|---|
| `program_fpgas.sh` | driver using **Vivado** (`program_chain.tcl`) |
| `program_fpgas_ofl.sh` | driver using **openFPGALoader** (faster start-up) |
| `program_chain.tcl` | Vivado batch payload: connect, detect, program RTM then AMC, check DONE |
| `bit_files.env.example` | template: bitstream paths, keyed by the letters used in a map |
| `slot_map_ddr4.md.example`, `slot_map_waveform.md.example` | template slot maps |
| `docs/mch_jtag_selection.md` | how MCH/JSM channel selection works, with measurements |
| `docs/openfpgaloader_install.md` | installing openFPGALoader and its pitfalls |

## Requirements

- NAT-MCH with NAT-JSM, reachable over HTTP (default `192.168.1.41`, `root` / `nat`)
- A Digilent JTAG pod on the JSM front connector (tested: JTAG-SMT3 / HS3, USB `0403:6010`)
- `program_fpgas.sh`: Vivado, **any version** with the `hw_manager` Tcl API (tested with 2022.2).
  Looked up in this order: `--vivado PATH`, `$VIVADO`, `VIVADO=` in the env file, `PATH`, then the newest
  install under `/opt/Xilinx/Vivado/*` (also `/tools` and `$HOME`). The chosen binary is printed at start-up.
- `program_fpgas_ofl.sh`: **openFPGALoader >= 1.1** - the distro's 0.13.1 does not know newer parts
- Bitstreams under `./firmwares/`, supplied locally (not part of this repository)

## Configure your bench (first run)

The repository ships **templates**, not live configuration. Copy the ones you need and edit the copies;
they are gitignored, so pulls never overwrite them:

```bash
git clone <this repo> && cd MicroTCA_JTAG_helper
cp bit_files.env.example        bit_files.env
cp slot_map_ddr4.md.example     slot_map_ddr4.md
cp slot_map_waveform.md.example slot_map_waveform.md
```

`slot_map_*.md` says which bitstream each slot gets; `-` means "no load":

```
|Slot| 1 | 2 | ... | 12 |
|AMC | B | D | ... | D  |
|RTM | - | E | ... | E  |
```

`bit_files.env` maps those letters to files. Relative paths resolve against that file's own directory:

```
A=./firmwares/ddr4_selftest/top.bit
B=./firmwares/WR/top.bit
```

Keep it beside `firmwares/` (or use absolute paths) - a copy elsewhere resolves relative to the copy.

It can also carry two optional settings:

| Key | Effect | Precedence |
|---|---|---|
| `MCH=` | MCH address for channel selection | `--mch` > this entry > `192.168.1.41` |
| `VIVADO=` | Vivado binary for `program_fpgas.sh` | `--vivado` > `$VIVADO` > this entry > `PATH` > newest install |

## Quick start

```bash
# what would be programmed? touches nothing
./program_fpgas.sh --map slot_map_ddr4.md --dry-run

# what does each channel actually expose?
./program_fpgas_ofl.sh --map slot_map_ddr4.md --scan

# program everything the map lists
./program_fpgas.sh     --map slot_map_ddr4.md
./program_fpgas_ofl.sh --map slot_map_ddr4.md
```

The **map is the whole job description** - there is no slot filter. To program a subset, use a map that
lists only those slots. With no `--map`, a single `slot_map*.md` beside the script is used, and several
are refused rather than guessed.

## Options

| Option | Driver | Meaning |
|---|---|---|
| `--map FILE` | both | slot map to use (default: the only `slot_map*.md`) |
| `--env FILE` | both | bitstream path table (default `bit_files.env`) |
| `--dry-run` | both | print the plan and exit |
| `--scan` | openFPGALoader | report the chain of every slot, program nothing |
| `--no-mch` | both | do not touch the MCH (channel already selected) |
| `--mch ADDR` | both | MCH address (default `192.168.1.41`) |
| `--user`, `--password` | both | MCH web credentials (default `root` / `nat`) |
| `--channel-wait S` | both | max wait for the JSM to report `Ready` (default 20) |
| `--settle S` | both | pause after switching channel (default 0.3) |
| `--override-repeats N` | both | how often to send the override (default 3; 2 is the minimum) |
| `--timeout S` | both | per-slot timeout (default 900 Vivado, 600 openFPGALoader) |
| `--jtag-freq HZ` | both | JTAG clock (default 10000000, the JSM maximum; `--freq` also accepted) |
| `--fallback-freq HZ` | both | retry clock for a failing slot (default 7500000) |
| `--allow-same-chain` | both | accept an identical chain (Vivado refuses by default) |
| `--strict-chain` | openFPGALoader | refuse an identical chain (it warns by default) |
| `--hw-server URL` | Vivado | hw_server (default `localhost:3121`) |
| `--vivado PATH` | Vivado | Vivado binary |
| `--rtm-dev`, `--amc-dev` | Vivado | force the hw_device name instead of matching by part |
| `--ofl PATH` | openFPGALoader | openFPGALoader binary |
| `--cable`, `--vid`, `--pid` | openFPGALoader | cable profile and USB IDs (default `digilent_hs3`, `0x0403`, `0x6010`) |
| `--invert-read-edge`, `--no-invert-read-edge` | openFPGALoader | sample reads on the falling edge (default on, required at 10 MHz) |
| `-h`, `--help` | both | usage |

## How it works

1. Select the slot's channel on the MCH (`FrontActiveDev` override over HTTP).
2. Wait for the JSM to report `Ready`.
3. Detect the chain and map roles by part family: UltraScale/UltraScale+ is the **AMC**, 7-series is the
   **RTM**.
4. Program the RTM first, then the AMC, and verify DONE from the configuration status register.
5. Report warnings and errors - no cable, empty chain, unknown IDCODE, missing device, programming
   failure, no DONE - plus per-device and per-slot timing.

## Selecting the channel

Two conditions are required for the switch to actually move, both established by experiment:

1. **Nothing may hold the JTAG cable.** Vivado leaves `hw_server` running after every batch run, and while
   it holds the cable the MCH accepts the override but the switch never moves. The drivers stop it first.
2. **The override must be sent at least twice.** A single POST is never enough, and waiting does not help.
   The drivers default to three.

The cable is free ~50 ms after `hw_server` is killed and the new chain is scannable ~45 ms after the last
POST, so the waits are short by design. Verified by reading device DNA per channel: each board returns a
different value.

If you prefer to select by hand in the browser, run with `--no-mch`.

## When two slots look identical

The tools see different things, so they behave differently:

- **Vivado** compares device **DNA**, unique per die. An identical chain means the same FPGA answered
  twice, which is always a fault - it refuses.
- **openFPGALoader** can only compare part and IDCODE (UltraScale+ DNA is not readable), so a crate full of
  identical boards produces identical chains legitimately. It **warns and continues**;
  `--strict-chain` restores the refusal, `--allow-same-chain` silences the warning.

To tell "same board" from "switch did not move", scan a slot you know is **empty**: `chain is empty` means
the switch works, a full chain means it does not.

## Measured limits

From a 36 MB bitstream on the reference bench (full data in `docs/mch_jtag_selection.md`):

| Item | Result |
|---|---|
| Maximum usable JTAG clock | **10 MHz** (15 MHz corrupts on both tools) |
| Transfer at 10 MHz | 30.3-30.6 s, ~95 % of the theoretical 29.07 s |
| Vivado, end to end | ~47.6 s per slot |
| openFPGALoader, end to end | ~31.4 s per slot |
| openFPGALoader at 10 MHz | requires `--invert-read-edge` (on by default) |

Any slot can be marginal at 10 MHz - AMC12 is just the case observed. When a slot fails, both drivers
retry it once at `--fallback-freq` (default **7.5 MHz**) and continue at that clock if the retry works.
This covers scan and programming failures, but not the chain-identity guard. Set `--fallback-freq` equal
to `--jtag-freq` to disable it.

## Notes

- Programming is volatile: configuration flash is never touched.
- Slots are not equivalent. A slot may expose only the AMC, or the AMC plus an RTM; an `RTM` row in a map
  only does anything where a 7-series device is actually in the chain (`--scan` warns when it is not).
- `--mch` / `MCH=` default to the NAT factory address. Change the credentials for any shared network.
- Some failures are transient after a switch (`TDO is stuck at 0`, `JTAG init failed`); the drivers retry
  before reporting, so a single error line means repeated attempts already failed.

## License

MIT, see [LICENSE](LICENSE).
