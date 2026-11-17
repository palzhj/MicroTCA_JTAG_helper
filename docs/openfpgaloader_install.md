# Installing openFPGALoader

| Field | Value |
|---|---|
| Purpose | Install openFPGALoader so the u4FCP bench can program FPGAs without Vivado |
| Tested on | Ubuntu 26.04 LTS, x86_64, non-root user `iheper` |
| Verified version | **v1.1.1** (release tarball) |
| Used by | [`program_fpgas_ofl.sh`](../program_fpgas_ofl.sh) |
| Hardware | Digilent pod `210357A7D00EA` — USB `0403:6010`, Digilent JTAG-SMT3 (HS3) |

> **Which version?** Do not assume the distro package is good enough. On this host `apt` installs
> **0.13.1**, which was tried and **fails** on the u4FCP board: it does not know `xcku15p` (see §1). The
> release tarball, **1.1.1**, is verified end-to-end here. Method A documents the apt route and its
> limitation; Method B is the working path; Method C is untested here.

---

## 0. Quick install for this bench (no root, verified)

```bash
mkdir -p ~/.local/opt/ofl && cd ~/.local/opt/ofl
curl -LO https://github.com/trabucayre/openFPGALoader/releases/download/v1.1.1/ubtuntu24.04-openFPGALoader.tgz
tar xzf ubtuntu24.04-openFPGALoader.tgz

# one shared library is missing from this distro
cd /tmp && apt-get download libhidapi-libusb0
dpkg-deb -x libhidapi-libusb0_*.deb ~/.local/opt/ofl/lib
cd ~/.local/opt/ofl && rm -f /tmp/libhidapi-libusb0_*.deb

# verify
export LD_LIBRARY_PATH="$HOME/.local/opt/ofl/lib/usr/lib/x86_64-linux-gnu"
~/.local/opt/ofl/usr/local/bin/openFPGALoader --Version
```

Then point the script at it:

```bash
LD_LIBRARY_PATH="$HOME/.local/opt/ofl/lib/usr/lib/x86_64-linux-gnu" \
  ./program_fpgas_ofl.sh --map slot_map_ddr4.md --slot 1 \
     --ofl "$HOME/.local/opt/ofl/usr/local/bin/openFPGALoader"
```

To avoid repeating `LD_LIBRARY_PATH`, add a wrapper (step 5).

---

## 1. Method A — distro package (needs root)

```bash
sudo apt update
sudo apt install openfpgaloader
openFPGALoader --Version
```

**Measured outcome on this host: apt's 0.13.1 cannot drive the u4FCP board.** It reads the IDCODE correctly
but has no entry for the part:

```
JTAG init failed with: Unknown device with IDCODE: 0x14a56093
  (manufacturer: 0x049 (Xilinx), part: 0x25 vers: 0x1)
```

`--invert-read-edge` *is* present in 0.13.1, and `--fpga-part xcku15p` does **not** work around it — the
device table simply predates this part. Use Method B (1.1.1), which reports `model xcku15p` /
`family kintexusp` and programs correctly.

Pros: one command, dependencies handled by the package manager.
Cons: on this distro the packaged build is too old for xcku15p.

---

## 2. Method B — release tarball (verified)

### 2.1 Download and unpack

```bash
mkdir -p ~/.local/opt/ofl && cd ~/.local/opt/ofl
curl -LO https://github.com/trabucayre/openFPGALoader/releases/download/v1.1.1/ubtuntu24.04-openFPGALoader.tgz
tar xzf ubtuntu24.04-openFPGALoader.tgz
```

The archive extracts to `usr/local/bin/openFPGALoader` relative to the current directory — it does **not**
install into `/usr/local`. Pick the asset closest to (and not newer than) your distro:

| Distro | Asset |
|---|---|
| Ubuntu 22.04 | `ubtuntu22.04-openFPGALoader.tgz` |
| Ubuntu 24.04 | `ubtuntu24.04-openFPGALoader.tgz` |
| newer than 24.04 | use the 24.04 asset — a newer glibc runs older builds |

The `ubtuntu` spelling in the asset names is upstream's, not a typo here.

### 2.2 Check for missing libraries

```bash
ldd usr/local/bin/openFPGALoader | grep "not found"
```

On this host that prints exactly one line:

```
libhidapi-libusb.so.0 => not found
```

Everything else (`libusb-1.0`, `libftdi1`, `libudev`, `libz`) was already present.

### 2.3 Provide the missing library without root

```bash
cd /tmp
apt-get download libhidapi-libusb0
dpkg-deb -x libhidapi-libusb0_*.deb ~/.local/opt/ofl/lib
rm -f /tmp/libhidapi-libusb0_*.deb
export LD_LIBRARY_PATH="$HOME/.local/opt/ofl/lib/usr/lib/x86_64-linux-gnu"
```

`apt-get download` needs no privileges; `dpkg-deb -x` unpacks the `.deb` into a private prefix.
If `ldd` shows more missing libraries, repeat for each package name.

### 2.4 Verify

```bash
ldd usr/local/bin/openFPGALoader | grep "not found" || echo "all deps satisfied"
usr/local/bin/openFPGALoader --Version      # -> openFPGALoader v1.1.1
```

---

## 3. Method C — build from source

Only needed for a distro newer than the newest asset, or to patch device support.

```bash
sudo apt install -y build-essential cmake pkg-config git \
                    libftdi1-dev libusb-1.0-0-dev libhidapi-dev libudev-dev zlib1g-dev

git clone https://github.com/trabucayre/openFPGALoader
cd openFPGALoader && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=$HOME/.local
make -j"$(nproc)"
make install
```

Build dependencies, from `CMakeLists.txt`: `pkg-config`, `libftdi1`, `libusb-1.0`, `hidapi`, `zlib`,
`libudev` (and optionally `libgpiod` for the GPIO bitbang cable).

---

## 4. USB access permissions

Without a udev rule, a non-root user gets `unable to open ftdi device`. The repo ships
`99-openfpgaloader.rules`, which covers this bench's `0403:6010`:

```bash
sudo cp 99-openfpgaloader.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

The rule body for our pod is:

```
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="664", GROUP="plugdev", TAG+="uaccess"
```

so the user must also be in `plugdev`:

```bash
sudo usermod -aG plugdev "$USER"     # log out/in for it to take effect
```

**On this host no action was needed** — Xilinx's rules from the Vivado install already cover it
(`/etc/udev/rules.d/52-xilinx-digilent-usb.rules`, `52-xilinx-ftdi-usb.rules`), and the device node is
`crw-rw-rw-`. A machine without Vivado installed *will* need one of the two rules.

---

## 5. Wrapper so `LD_LIBRARY_PATH` is not needed

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/openFPGALoader <<'EOF'
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$HOME/.local/opt/ofl/lib/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HOME/.local/opt/ofl/usr/local/bin/openFPGALoader" "$@"
EOF
chmod +x ~/.local/bin/openFPGALoader
```

With `~/.local/bin` on `PATH`, `program_fpgas_ofl.sh` finds it with no extra options.

---

## 6. Verifying against the bench hardware

The MCH must already have the right JTAG channel selected (`program_fpgas_ofl.sh` does this itself).

```bash
openFPGALoader -c digilent_hs3 --vid 0x0403 --pid 0x6010 \
               --freq 10000000 --invert-read-edge --detect
```

Expected:

```
Jtag frequency : requested 10.00MHz   -> real 10.00MHz
index 0:
	idcode 0x4a56093
	manufacturer xilinx
	family kintexusp
	model  xcku15p
	irlength 6
```

Note `--vid 0x0403 --pid 0x6010` are required here: the pod enumerates as a generic FT2232H (`6010`)
rather than the `6014` that the `digilent_hs3` cable profile expects by default.

---

## 7. Bench-specific settings

| Setting | Value | Why |
|---|---|---|
| Cable | `-c digilent_hs3` | Digilent JTAG-SMT3 |
| VID/PID | `--vid 0x0403 --pid 0x6010` | pod enumerates as generic FT2232H |
| Frequency | `--freq 10000000` | NAT-JSM maximum; 15 MHz corrupts |
| Sampling | `--invert-read-edge` | without it 8 and 10 MHz return a corrupt IDCODE |
| Device select | `--index-chain N` | chain currently holds one device (index 0) |

Measured on this bench with a 36 MB bitstream: **30.6 s** download at 10 MHz, ~95 % of the 29.07 s
theoretical floor.

---

## 8. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `libhidapi-libusb.so.0: cannot open shared object file` | library not installed | step 2.3, or set `LD_LIBRARY_PATH` |
| `unable to open ftdi device: -3 (device not found)` | VID/PID mismatch or udev | add `--vid/--pid`, install udev rule |
| `unable to open ftdi device` (permission) | user lacks USB access | udev rule + `plugdev` |
| `Unknown device with IDCODE: 0x284bc027` | corrupt scan | lower `--freq`, add `--invert-read-edge` |
| `Unknown device with IDCODE: 0x14a56093` | correct IDCODE but the build lacks `xcku15p` (apt 0.13.1) | install 1.1.x (Method B) - `--fpga-part` does not help |
| `JTAG init failed` | no target on the channel | check MCH channel, cable |
| Frequency reports lower than requested | cable clamps to its divider steps | expected; 12 -> 10, 20 -> 15 |
| `empty` then nothing | chain is dead on the selected channel | MCH channel / slot not populated |

`openFPGALoader` prints the configuration status after a download, which is the DONE evidence:

```
ir: 1 isc_done 1 isc_ena 0 init 1 done 1
```

`done 1` means the FPGA configured successfully.

---

## 9. Uninstall

```bash
rm -rf ~/.local/opt/ofl ~/.local/bin/openFPGALoader
# if installed via apt:
sudo apt remove openfpgaloader
```

Nothing outside the chosen prefix is modified by Method B.
