# MCH JTAG Channel Selection — Notes

| Field | Value |
|---|---|
| Scope | How the JTAG channel is selected on the u4FCP bench MCH, and how it behaves |
| MCH | `192.168.1.41` |
| Equipment | NAT-MCH (M4) + NAT-JSM JTAG switch module, uTCA shelf |
| Verified on | 2026-11-17, MCH firmware **V2.23.6 Final (r21087)**, 13 Sep 2023 |
| Reference | `NAT-MCH_UsersManual.pdf`, V1.41 (28 Sep 2021), §7.3.3 / §7.3.4 |
| Status | Verified by direct test on the live unit |

Bench measurements in this document were taken against the unit while it was addressed as
`10.19.198.31`; the scripts now default to `192.168.1.41`.

> The PDF is V1.41 (2021) while the unit runs V2.23.6 (2023). Where they disagree, the live unit wins —
> see [§7 Discrepancies](#7-discrepancies-vs-the-manual).

---

## 1. Two selection mechanisms

The NAT-JSM routes the JTAG chain of **one** target at a time. Which target is chosen by:

1. **Front rotary switch** on the NAT-JSM — the default, persistent source of truth.
2. **Web override** on the MCH — overrules the rotary switch while active.

The override is the only *remote* way to select a channel. It is **not persistent**: it lives in RAM and
reverts to the rotary switch position on MCH reboot or power cycle.

**Current state:** `AMC1` selected, overriding enabled, JSM `Ready`.

---

## 2. Channel map

The JSM on this unit exposes **12 targets**, all AMCs:

| Selection index | Device | Selection index | Device |
|---|---|---|---|
| 0 | AMC1 | 6 | AMC7 |
| 1 | AMC2 | 7 | AMC8 |
| 2 | AMC3 | 8 | AMC9 |
| 3 | AMC4 | 9 | AMC10 |
| 4 | AMC5 | 10 | AMC11 |
| 5 | AMC6 | 11 | AMC12 |

**Only AMC1 is populated** (`u4FCP-v2`, FRU 5, state M4). Selecting an empty slot gives a dead scan chain —
the pod/tool will report no devices. Check `show_fru` before selecting.

---

## 3. Selecting a channel from the shell

```bash
# select a target: FrontActiveDev = 0..11  (0 = AMC1)
curl -u root:nat -d 'FrontActiveDev=0&front_jtag_dev=override_front' \
     http://192.168.1.41/goform/ctrl_jtag_jsm_override

# hand control back to the rotary switch
curl -u root:nat -d 'front_jtag_dev=reset_overriding' \
     http://192.168.1.41/goform/ctrl_jtag_jsm_override

# read current state
curl -u root:nat http://192.168.1.41/goform/view_jtag_jsm_par
```

Both buttons share one form; the `front_jtag_dev` value is the discriminator
(`override_front` / `reset_overriding`). Web UI path: **Interface → JTAG-JSM → JSM Front Configuration**.

---

## 4. Behaviour with an active tool session — CONFIRMED

**Claim:** when a JTAG tool is connected to a channel, the channel selection cannot take effect.
**Result: confirmed.** The MCH holds the switch and reports:

> `Status: Waiting for Xilinx Virtual Cable completion.`

Observed sequence (tool session held open, target moved AMC1 → AMC5):

| Moment | Dropdown shows | JSM Front Config status |
|---|---|---|
| Baseline, no tool | AMC1 | `Ready` |
| Tool connected | AMC1 | `Waiting for Xilinx Virtual Cable completion.` |
| Request AMC5 | AMC5 | `Waiting for Xilinx Virtual Cable completion.` |
| +2 s, still connected | AMC5 | `Waiting for Xilinx Virtual Cable completion.` |
| Tool disconnected | **AMC5** | `Ready` |

Notes:

- The request is **deferred, not rejected**. The new target is accepted and shown in the dropdown, then
  applied the moment the session ends — no re-post needed. A change that "doesn't work" is queued and will
  fire later, which can surprise you if you walk away and the tool disconnects.
- The lock is **global, not per-channel**: a session held on another channel's port (AMC2/2543) while AMC1
  was active still blocked the switch.
- `Reset overriding` is deferred in the same way while a session is active.
- `Program FPGA with SVF` shows the same status — the whole switch matrix is held, not just the front path.
- **Scope limit:** the MCH only sees sessions through its own XVC server (status `In Operation`). A USB pod
  on the JSM front connector produces **no status change** — the page keeps saying `Ready`, so this lock does
  not engage at the MCH level for a local pod. If the JSM itself refuses to switch during local activity,
  that is invisible from the MCH.

---

## 5. USB pod workflow (current bench method)

XVC is slow for firmware download — TCP round-trips bound the TCK throughput. The bench uses a local USB
pod on the JSM instead:

1. Select the channel with the MCH (`§3`) so the JSM routes the target to the front connector.
2. Confirm the target slot is populated (`show_fru`) and in state M4.
3. Program over USB from the host with Vivado / `program_hw_devices` at full cable speed.
4. When finished, `Reset` the override so the next user inherits the rotary switch position.

This is automated by [`program_fpgas.sh`](../program_fpgas.sh): it selects each slot's channel, then programs
RTM before AMC through [`program_chain.tcl`](../program_chain.tcl).

**Observed on the bench (2026-11-17):** Digilent pod `210357A7D00EA`; the AMC1 channel carries a single
`xcku15p` (IDCODE `00010100101001010110000010010011`). The RTM Kintex-7 is **not** on this chain, so the
slot-1 RTM bitstream (`B`) cannot be loaded through this path. The NAT-JSM caps the JTAG clock at
**10 MHz**. A freshly opened target can report `No devices detected` on the first scan and succeed after a
close/re-open - retrying at 1 MHz then restoring the clock clears it.

**Measured on hardware, slot 1 AMC (`top.bit`, 36 MB) at 10 MHz:** **30.3 s** to program, **46.4 s** total
(Vivado start + hw_server connect + chain scan + MCH channel select). DONE is confirmed by reading
`REGISTER.CONFIG_STATUS.BIT[14]_DONE_PIN` = 1 (EOS = 1, CRC_ERROR = 0);
`PROGRAM.IS_PROGRAMMED` does not exist on UltraScale+.

### Vivado vs openFPGALoader (same bitstream, same pod, slot 1)

Bitstream `top.bit` = 36,343,220 bytes = 290,745,760 bits. At 10 MHz the theoretical floor is **29.07 s**.

| Tool | Clock | Program time (mean of n) | Efficiency | Total | Wall |
|---|---|---|---|---|---|
| Vivado (`program_fpgas.sh`) | 10 MHz | 30.35 s (n=4) | 95.8 % | 47.1-48.0 s | ~47.6 s |
| openFPGALoader (`program_fpgas_ofl.sh`) | 10 MHz + `--invert-read-edge` | 30.58 s (n=3) | 95.1 % | 31.3-31.5 s | ~31.4 s |
| openFPGALoader, plain sampling | 6 MHz | 49.9 s | - | 50.7 s | 50.8 s |

Installation of openFPGALoader - including the `libhidapi` and udev steps this bench needs - is in
[`openfpgaloader_install.md`](openfpgaloader_install.md). **Version matters:** apt's 0.13.1 reads the
IDCODE correctly but has no `xcku15p` entry (`Unknown device with IDCODE: 0x14a56093`), so it cannot
program this board; 1.1.1 detects `model xcku15p` and works.

Both tools land within **0.8 s** of each other on the download itself, at ~95 % of the theoretical JTAG
bandwidth; neither can go faster without a faster clock. openFPGALoader's advantage is entirely start-up:
it saves ~16 s per slot (47.6 s -> 31.4 s). Projected for all 12 slots: **~9.5 min with Vivado vs ~6.3 min
with openFPGALoader**.

### Clock ceiling (measured, both tools agree)

| Requested | Cable actually uses | openFPGALoader | Vivado |
|---|---|---|---|
| 10 MHz | 10 MHz | OK | OK |
| 12 MHz | 10 MHz (clamped by cable divider) | OK | OK |
| 15 MHz | 15 MHz | corrupt IDCODE | no devices |
| 20 / 25 MHz | 15 MHz (cable maximum) | corrupt IDCODE | no devices |

**10 MHz is a signal-integrity wall on this path, not just a cable setting** - 15 MHz is achievable by the
cable but both tools fail there, which matches the NAT-JSM rating. Requesting more is harmless (it clamps)
but pointless. Without `--invert-read-edge` the ceiling drops further: 10 MHz and 8 MHz corrupt, 7 MHz is
the last good step, so the flag is what buys back the full 10 MHz.

No other MCH setting is involved. XVC stays off for this path.

---

## 6. CLI / telnet — what it can and cannot do

The CLI on V2.23.6 has **no** `jtag`, `jsm`, or `xvc` command. Full `help` listing checked; relevant facts:

| Capability | Interface |
|---|---|
| Select / override / reset JTAG channel | **Web only** — no CLI command |
| Read JSM status, channel map | Web only |
| Read XVC enable flag | CLI: `mch` → `xvc access:` |
| Enable / disable XVC server | CLI: `mchcfg` → `[3] modify MCH global configuration`, or web |

`mchcfg` exits with `[q] quit and save configuration` — it writes on exit, so avoid it casually.

---

## 7. Discrepancies vs the manual

| Manual (V1.41, 2021) | This unit (V2.23.6, 2023) |
|---|---|
| 16 targets: AMC1–12, PM_1, PM_2, MCH1, MCH2 | **12 targets, AMC1–AMC12 only** — no PM/MCH targets |
| Base TCP port example `2550` → AMC1 at 2550 | Base port **2542** → AMC1 at 2542, AMC12 at 2553 |
| Figure 14 shows the full JSM menu | Live page matches in layout, differs in target count and base port |
| No `xvc access` option documented in §5.4.1 | `mch` reports `xvc access:`, so the option exists in newer firmware |

---

## 8. Gotchas

- **Override is RAM-only.** A reboot silently puts you back on the rotary switch position — possibly an
  empty slot. For a fixed rig, set the rotary switch physically and press `Reset`.
- **Deferred changes fire late.** Do not assume a selection failed just because the chain did not move;
  check whether a tool session is open.
- **Empty slot looks like a broken chain.** Before debugging cables or drivers, confirm the selected slot
  has a card (`show_fru`).
- **Empty slots for other AMCs**: only AMC1 is populated; a channel change to any other index is a no-op
  for programming.

---

## 9. Useful CLI commands

```text
show_fru                      # which FRUs are present and their state
show_fruinfo <fru_id>         # FRU contents (AMC1 = 5)
show_sensorinfo <fru_id>      # sensors / power state for a FRU
mch                           # full MCH configuration, incl. xvc access flag
```

Telnet to `192.168.1.41` (no password prompt on this unit); web UI at `http://192.168.1.41/`
with Basic auth `root` / `nat`.

---

## 10. Bit files per slot

Full paths are defined once in [`bit_files.env`](../bit_files.env), keyed by a letter; the map file decides
which letter each slot gets (`-` = no load). Two maps exist, chosen with `--map`:

| Map | Slot 1 | Slots 2-12 |
|---|---|---|
| [`slot_map_ddr4.md`](../slot_map_ddr4.md) | AMC `A` | AMC `A` |
| [`slot_map_waveform.md`](../slot_map_waveform.md) | AMC `B` | RTM `E` + AMC `D` |

`A` and `B` are both `top.bit` (ddr4 selftest vs WR), which is why the script prints the symbol as well as
the file name. The `AMC` device is the KUP (UltraScale+); a `RTM` entry expects a 7-series device.

Consequence for channel selection: **select AMC1** (`FrontActiveDev=0`) — the only slot with a defined
bitstream. If the slot-1 chain exposes both TAPs, confirm the device index against the scan chain rather
than assuming which is which.

## 11. Test log

| # | Test | Result |
|---|---|---|
| 1 | Change channel with no tool connected (AMC6 → AMC1) | Applied immediately, `Ready` |
| 2 | Hold tool session, request change | Deferred, `Waiting for Xilinx Virtual Cable completion.` |
| 3 | Disconnect without re-posting | Deferred target applied (`AMC5`), `Ready` |
| 4 | Session on non-active channel's port, request change | Also deferred → lock is global |
| 5 | `Reset overriding` while session held | Deferred likewise |
| 6 | CLI `help` scan for jtag/jsm | No such command |
| 7 | Manual vs live target count / base port | 12 targets, base 2542 |
| 8 | Chain scan via Digilent pod, AMC1 channel | Single `xcku15p`, no 7-series RTM |
| 9 | Clock sweep 10/6/4/2/1 MHz after re-open | All scan; first scan after a stale open is empty |
| 10 | Program slot 1 AMC (`top.bit`) on hardware | PASS - `DONE=1`, `EOS=1`, `CRC_ERROR=0` |
| 11 | Timing, slot 1 AMC at 10 MHz | 30.3 s program, 46.4 s total |

Unit left in its original state after testing: **AMC1 selected, overriding enabled, `Ready`, XVC disabled.**
