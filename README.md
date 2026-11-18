# MicroTCA JTAG helper

Program FPGAs on a MicroTCA shelf through an **NAT-MCH + NAT-JSM** JTAG switch: the MCH selects the
JTAG channel for a slot, and a Digilent pod on the JSM front connector performs the download.

Two interchangeable back-ends are provided — Xilinx **Vivado** and **openFPGALoader** — driving the same
slot map, so you can pick per machine.

## Why this exists

On a MicroTCA shelf the FPGAs of all AMC/RTM slots sit behind a JTAG switch module. Only one slot's chain
is routed to the front-panel connector at a time, selected either by the JSM rotary switch or by a web
override on the MCH. These scripts automate that selection per slot and then program the devices in a
defined order, reporting failures instead of leaving you to interpret tool output.

XVC is deliberately not used: it tunnels every JTAG transaction over TCP and is far slower than a local
pod.

## Contents

| Path | Purpose |
|---|---|
| `program_fpgas.sh` | Driver using **Vivado** (`program_chain.tcl`) |
| `program_fpgas_ofl.sh` | Driver using **openFPGALoader** (faster start-up) |
| `program_chain.tcl` | Vivado batch payload: connect, detect, program RTM then AMC, check DONE |
| `slot_map_ddr4.md`, `slot_map_waveform.md` | Example slot maps (which bitstream per slot) |
| `bit_files.env` | Bitstream paths, keyed by the letters used in the maps |
| `docs/mch_jtag_selection.md` | How the MCH/JSM channel selection works, with measurements |
| `docs/openfpgaloader_install.md` | Installing openFPGALoader (including its pitfalls) |

## Requirements

- NAT-MCH with NAT-JSM, reachable over HTTP (defaults: `192.168.1.41`, `root`/`nat`)
- Digilent JTAG pod (tested with a JTAG-SMT3 / HS3, USB `0403:6010`)
- Vivado for `program_fpgas.sh` - **any version** with the `hw_manager` Tcl API (tested with 2022.2).
  Found in this order: `--vivado PATH`, `$VIVADO`, a `VIVADO=` entry in the env file, `PATH`, then the
  newest install under `/opt/Xilinx/Vivado/*` (also `/tools` and `$HOME`). The chosen binary is printed
  at start-up.
- **or** openFPGALoader **>= 1.1** for `program_fpgas_ofl.sh`
- Bitstreams, supplied locally under `./firmwares/` (not part of this repository)

## Quick start

```bash
# see what would be programmed, touching nothing
./program_fpgas.sh --map slot_map_ddr4.md --dry-run

# program everything the map lists, with Vivado
./program_fpgas.sh --map slot_map_ddr4.md

# same, with openFPGALoader
./program_fpgas_ofl.sh --map slot_map_ddr4.md
```

The **map file is the whole job description**: it lists a bitstream per slot and the scripts program
exactly that set. To program a subset, give a map that lists only those slots (`-` means no load).

With no `--map`, the script uses the only `slot_map*.md` beside it, and **refuses to guess** when several
are present.

Common options: `--map FILE`, `--dry-run`, `--no-mch` (channel already set by hand),
`--mch ADDR`,
`--jtag-freq HZ`, `--hw-server URL` and `--vivado PATH` (Vivado) or `--ofl PATH` (openFPGALoader). Both
scripts accept `--help`.

## Configure your bench (first run)

The repository ships **examples**, not live configuration: `bit_files.env.example` and
`slot_map_*.md.example`. Copy the ones you need and edit the copies - your files stay untracked, so pulling
updates never touches them:

```bash
cp bit_files.env.example          bit_files.env
cp slot_map_ddr4.md.example       slot_map_ddr4.md
cp slot_map_waveform.md.example   slot_map_waveform.md
```

`.gitignore` already excludes `bit_files.env` and `slot_map_*.md` (but not the `.example` files).

`slot_map_*.md` decides which bitstream each slot gets; `-` means "no load" and the slot is skipped:

```
|Slot| 1 | 2 | ... | 12 |
|AMC | B | D | ... | D  |
|RTM | - | E | ... | E  |
```

`bit_files.env` maps those letters to files. Relative paths are resolved against the env file's own
directory, so the scripts work from any working directory:

```
A=./firmwares/ddr4_selftest/top.bit
B=./firmwares/WR/top.bit
```

Because relative paths resolve against this file's own directory, keep it next to `firmwares/` (or use
absolute paths) - a copy placed elsewhere will look for bitstreams relative to the copy.

The same file can carry two optional settings:

| Key | Effect | Precedence |
|---|---|---|
| `MCH=` | MCH address used for channel selection | `--mch` > this entry > `192.168.1.41` |
| `VIVADO=` | Vivado binary for `program_fpgas.sh` | `--vivado` > `$VIVADO` > this entry > `PATH` > newest install |

## Selecting the channel

Selection is done through the **MCH website** - the drivers POST to `/goform/ctrl_jtag_jsm_override` before
each slot. Two things are required for the switch to actually move, both established by experiment:

1. **Nothing may hold the JTAG cable.** Vivado leaves `hw_server` running after a batch run, and while it
   holds the cable the MCH accepts the override but the switch never moves. The drivers stop it first.
2. **Send the override at least twice.** A single POST is never enough; two switch reliably and the
   drivers default to `--override-repeats 3`. The cable needs only ~50 ms after `hw_server` is killed.

With both, the switch follows every request. Verified by reading the device DNA per channel - each board
returns a different value.

If you prefer to pick the channel by hand in the browser, run with `--no-mch`.

## How it works

1. Select the slot's channel on the MCH (`FrontActiveDev` override over HTTP).
2. Wait for the JSM to report `Ready` — a deferred switch is reported rather than silently ignored.
3. Detect the chain and map roles to devices: UltraScale/UltraScale+ is the **AMC**, 7-series is the
   **RTM**.
4. Program the RTM first, then the AMC, and verify DONE from the configuration status register.
5. Report warnings and errors — no cable, empty chain, unknown IDCODE, missing device, programming
   failure, no DONE — plus the time taken per device and per slot.

If two different slots report an **identical chain**, the tools respond differently because they can see
different things:

- **Vivado** compares device **DNA**, which is unique per die, so an identical chain means the same FPGA
  answered twice. It refuses, because that would program one board while reporting success for two.
- **openFPGALoader** can only compare part and IDCODE (UltraScale+ DNA is not readable), so a crate full of
  identical boards produces identical chains legitimately. It **warns and continues**; use
  `--strict-chain` to refuse anyway, or `--allow-same-chain` to silence the warning.

## Measured limits

On a bench with a 36 MB bitstream (see `docs/mch_jtag_selection.md` for the full data):

| Item | Result |
|---|---|
| Maximum usable JTAG clock | **10 MHz** (JSM rating; 15 MHz corrupts on both tools) |
| Transfer at 10 MHz | 30.3-30.6 s, ~95 % of the theoretical 29.07 s |
| Vivado, end to end | ~47.6 s per slot |
| openFPGALoader, end to end | ~31.4 s per slot |
| openFPGALoader at 10 MHz | requires `--invert-read-edge` |

`--invert-read-edge` is enabled by default in `program_fpgas_ofl.sh`; without it the ceiling drops to
7 MHz.

Any slot can be marginal at 10 MHz - AMC12 is just the case observed so far. When a slot fails, both
drivers retry it once at `--fallback-freq` (default **7.5 MHz**) and continue at that clock if the retry
works. This covers both scan and programming failures, but not the chain-identity guard. Set
`--fallback-freq` equal to `--freq` to disable the fallback.

## Notes

- openFPGALoader **0.13.1** (current distro package) cannot identify some newer parts; the scripts warn
  when the installed version is 0.x. Use 1.1.x.
- The scripts never touch configuration flash; programming is volatile.
- Default MCH credentials are the vendor defaults (`root`/`nat`) — change them for any shared network.

## License

MIT, see [LICENSE](LICENSE).
