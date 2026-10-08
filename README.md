# Balloon Radio Astronomy Spectrometer — FPGA Firmware

A 4-channel real-time FFT spectrometer with auto- and cross-correlation, built in
Simulink with the CASPER toolflow for the **Red Pitaya STEMlab 125-14** (Zynq-7010,
125 MHz). It runs entirely in FPGA fabric, one ADC sample per clock, and outputs
16-bit power spectra.

*Last updated: 2026-10-08. Current design file: `Baloon_CrossCo.slx`.*

---

## Status at a glance

| Area | State |
|---|---|
| 4-channel FFT → power → accumulate chain | Working in simulation |
| Positive-frequency gating (data and `valid`) | Working in simulation |
| Auto-correlation output reduced 32 → 16 bits | Working in simulation (value correct; see Known issues #1 for port width) |
| Cross-correlation ch0 × ch1, 16-bit output | Working in simulation |
| Generated HDL (Verilog) | **Not yet produced** — first attempt failed on a path containing a space |
| Vivado synthesis / DSP48 and BRAM utilisation | **Never run** |
| Readout path from fabric to the ARM processor | **Not built** |
| Behaviour on real hardware | **Not tested** |
| `fft_biplex_real_4x` (shared-FFT version) | Abandoned for now; see "Biplex FFT" |

Everything marked "working" was verified in Simulink/System Generator simulation only.

---

## What it does

```
4 × ADC channel (14-bit)
      │
      ▼
  256-point FFT  ──►  power = re² + im²  ──►  accumulate 16 frames  ──►  keep top 16 bits
      │                                                                        │
      └─► ch0 × conj(ch1) cross-product ──► accumulate (signed) ──► top 16 ────┤
                                                                               ▼
                                              gate to positive half (bins 0–127) + `valid`
```

- **Frequency resolution:** 125 MHz / 256 = **488.28125 kHz** per bin.
- **Output band:** bins 0–127, i.e. 0 to ~62 MHz. Bins 128–255 mirror 0–127 for a real
  input and are blanked.
- **Timing:** one FFT frame = 256 clocks = 2.048 µs. One integration = 16 frames =
  4096 clocks = 32.768 µs.

---

## Hardware and toolchain

| | |
|---|---|
| Board | Red Pitaya STEMlab 125-14, Zynq `xc7z010clg400-1` (80 DSP48, 60 BRAM36) |
| Clock | 125 MHz (`sysclk_period` = 8 ns, `sample_period` = 1) |
| Tools | MATLAB R2022a, Vitis Model Composer / System Generator 2023.1, Vivado 2023.1 |
| Flow | CASPER `mlib_devel` (platform block `RED_PITAYA_14:xc7z010`) |
| Host OS | Pop!_OS 22.04 LTS |

Simulink convention used throughout: **1 simulation time unit = 1 clock cycle**, so a
Sine Wave block's `Frequency` is in radians per clock.

---

## Files

| File | Purpose |
|---|---|
| `Baloon_CrossCo.slx` | **Current design**: 4 auto channels, 16-bit slices, gating, ch0×ch1 cross-correlation |
| `Baloon_4Channel.slx` | 4-channel auto-correlation only (32-bit outputs) |
| `Baloon_testSpace.slx` | Single-channel reference design, simulation-verified |
| `Baloon_2.slx` | Original CASPER 2-channel tutorial design (used to learn the structure) |
| `Baloon_real.slx` | Abandoned `fft_biplex_real_4x` attempt |
| `final_code.m` | MATLAB plotting and report script for `Baloon_CrossCo.slx` |
| `test_matrix.md` | Test cases with expected values |
| `spectrometer_complete_walkthrough.md` | Every parameter and design decision |
| `spectrometer_design_report.md` | Block-by-block design report |
| `fpga_from_scratch.md` | FPGA/DSP background for newcomers |
| `four_channel_build_guide.md`, `the_ladder.md` | Build guides |

---

## Architecture

### Per-channel auto-correlation chain (×4, identical)

| # | Block | Setting | Value / role |
|---|---|---|---|
| 1 | Gateway In | Signed 14-bit, `bin_pt` 0, Round, Saturate | ADC boundary |
| 2 | `hdlBasic/FFT` | 256-pt, unscaled, `bit_reversed_order` = on | Xilinx FFT; imaginary input tied to a 14-bit zero constant |
| 3 | Convert ×2 (re, im) | Signed 14-bit, `bin_pt` 0, **Truncate, Wrap** | Re-quantises FFT output so the multiplies fit one DSP48 each |
| 4 | `ri_to_c` | 14 + 14 | Packs re and im onto one 28-bit bus (wiring only) |
| 5 | `power_calc` | `c_to_ri` → 2 × Mult (Full, DSP48) → AddSub (Full) | re² + im²; products 28 bits, sum 29 bits |
| 6 | pipeline ×2 | latency 2 | Aligns data with the `new_acc` control pulse |
| 7 | `simple_bram_vacc` | `vec_len` 256, Unsigned 32-bit, `bin_pt` 0 | Sums 16 frames per bin; one adder + one BRAM serves all 256 bins |
| 8 | Slice | 16 bits, MSB-anchored | Keeps accumulator bits 31–16 (÷65,536) |
| 9 | Mux | `sel` = MSB of `bin_cntr` | Passes bins 0–127, outputs 0 for bins 128–255 |
| 10 | Gateway Out | | 16-bit output |

### Cross-correlation branch (ch0 × conj(ch1))

Taps the channel 0 and channel 1 Convert outputs (a + jb and c + jd):

| Block | Computes | Setting |
|---|---|---|
| `Mult_ac`, `Mult_bd`, `Mult_bc`, `Mult_ad` | the four products | Full precision, latency 3, embedded DSP48, pipelined |
| `AddSub` | real = ac + bd | Addition |
| `AddSub1` | imag = bc − ad | **Subtraction**, `bc` on input 1 |
| `vacc0_xre`, `vacc0_xim` | accumulate 16 frames | **Signed 34-bit**, `vec_len` 256 |
| `Slice0_xre`, `Slice0_xim` | top 16 of 34 bits (÷2¹⁸) | MSB-anchored |
| `Mux8`, `Mux9` | positive-half gate | zero constants are Signed 16-bit |

The 34-bit width gives headroom because a cross product is signed and can swing both
ways. Because the slice drops 18 bits instead of 16, the cross output is scaled 4×
finer than the auto output for the same accumulator value. That is a scale difference,
not a signal difference.

### Shared control (one copy serves all channels)

| Block | Setting | Role |
|---|---|---|
| `frame_cntr` + `Constant1` + `Relational1` | 8-bit counter, compare to 2⁸−1, `a=b` | Fires the FFT `start` every 256 clocks |
| `acc_cntrl` | `chan_bits` = 8, `acc_len` = 16 (`Constant16`), `sync` ← **`FFT3.start_frame_out`** | Emits `new_acc` every 4096 clocks, aligned to FFT output |
| `bin_cntr` | 8-bit, free-running, **`start_count` = 144** | MSB marks "positive half"; drives all Mux selects |

`sync` must come from the FFT's `start_frame_out`, not from the input-side `sync_fft`:
`acc_cntrl` arms on its first pulse and never re-arms, so a wrong source offsets every
integration permanently.

`start_count = 144` was **measured**, not derived: it places the surviving block so it
starts at true bin 0 on the auto path. It must be re-measured if any latency in the
data path changes.

### Valid signal

`valid` comes from the accumulator and is gated by the same positive-half select as the
data. The result is high for exactly 128 clocks (bins 0–127) at the start of each
4096-clock integration and low otherwise. Between integrations the data output keeps
repeating the previous completed spectrum (the accumulator is double-buffered), so
**only the window where `valid` is high is a fresh spectrum.**

---

## Bit widths: where precision goes

Worked example: amplitude-60 tone at bin 32 (15.625 MHz).

| Stage | Value | Bits used / allocated |
|---|---|---|
| Sine (rounded) | 0, 42, 60, 42, 0, −42, −60, −42 | 7 / 14 |
| FFT imaginary at bin 32 | −7641.4 | — |
| Convert (truncate toward −∞) | −7642 (93% of the ±8191 limit) | 14 / 14 |
| re² + im² | 58,400,164 | 26 / 29 |
| × 16 frames | 934,402,624 | 30 / 32 |
| Slice, top 16 bits | **14,257** (remainder 55,872 discarded) | 14 / 16 |

- **Only the final Slice loses information.** Everything before it keeps every bit.
- **Dynamic range:** a 32-bit word spans 96.3 dB, a 16-bit word 48.2 dB. A coherent
  tone is a worst case; noise-like sky signal spreads across all bins and fits comfortably.
- **Two headroom bits are unused** at this test level (accumulator bits 31 and 30 are
  always zero). A left shift of 2 before the Slice would recover them (peak 57,031,
  still fits in 16 bits); a shift of 3 overflows. Any such shift is tuned to this
  amplitude and `acc_len`, so for flight it should be a software-writable register.
- **Why amplitude 60:** the unscaled FFT multiplies a tone by N/2 = 128, so the
  limit is `amplitude × 128 ≤ 8191` (the 14-bit Convert ceiling), i.e. amplitude ≤ 63.
  At 1,048,469 an earlier test wrapped to −107 and destroyed the signal.
- **Why the Convert uses Wrap:** it is only safe because the input is kept inside the
  limit above. There is no overflow flag on the Xilinx FFT, so nothing in this design
  detects it.

---

## Running the simulation

1. Open `Baloon_CrossCo.slx` in MATLAB. Stop Time is 20000.
2. Run the simulation so the logged variables land in `out`.
3. Run `final_code.m`. It plots, per channel, the power spectrum (vs bin and vs MHz)
   and the final spectrum, then the valid flags and the cross-correlation.

### Test tones

| Channel | Bin | Frequency | Sine `Frequency` (rad/clock) | Phase |
|---|---|---|---|---|
| 0 | 32 | 15.625 MHz | 0.785398 | 0 |
| 1 | 32 | 15.625 MHz | 0.785398 | 0 |
| 2 | 32 | 15.625 MHz | 0.785398 | π/2 |
| 3 | 90 | 43.945 MHz | 2.208932 | 0 |

`Frequency = 2π·k/256` for bin k. If you change a tone, update `channels` in the script.

### Logged variables (note the rotated numbering)

| Channel | Power spectrum | Final spectrum | Valid (pre-gate, post-gate) |
|---|---|---|---|
| 0 | `PowerSpectrum1` | `FinalSpectrum1` | `val_test3`, `val2` |
| 1 | `PowerSpectrum2` | `FinalSpectrum2` | `val_test2`, `val1` |
| 2 | `PowerSpectrum3` | `FinalSpectrum3` | `val_test1`, `val` |
| 3 | `PowerSpectrum` | `FinalSpectrum` | `val_test`, `val03` |
| cross 0×1 | — | `CrossRe0`, `CrossIm0` | — |

Variable suffixes do **not** follow channel numbers, and the valid numbering runs the
opposite way. Check this table before reading a plot.

### Results observed in simulation

| Check | Expected | Observed |
|---|---|---|
| FFT imaginary peak | ±7,641.6 | ±7,642 |
| Power at bin 32 | 7642² = 58,400,164 | 58,400,164 |
| Final ÷ Power | 16 (= `acc_len`) | 16 on all four channels |
| `valid` width | 256 → 128 clocks after gating | 128, zero steady-state offset over 5 integrations |
| 16-bit auto peaks (ch0–3) | ≈ 14,257 / 14,257 / 14,257 / ≈ 14,325 | 14,426 / 14,404 / 14,421 / 14,396 |
| Cross real, ch0×ch1 | ≈ +3,564 | +3,606 |
| Cross imaginary (in-phase tones) | exactly 0 | exactly 0 on all 256 bins |

The 16-bit peaks and the cross-real peak sit 0.5–1.2% above the hand calculation.
The cause has not been identified (see Known issues #5). It does not affect any
conclusion about bit widths.

For the phase test, ch2 has a π/2 phase offset: a ch0×ch2 baseline should show real ≈ 0
and imaginary ≈ ±3,600 (phase ±90°). That baseline has not been built.

---

## Generating HDL

The System Generator token is set for Zynq `xc7z010`, Vivado project type, 8 ns system
clock.

**HDL only (Verilog):**
1. Double-click the System Generator token.
2. Compilation → **HDL Netlist**, Hardware description language → **Verilog**.
3. Set **Target directory** to a path **with no spaces**, e.g. `~/verilog_out`.
4. Click **Generate**.

**Full CASPER flow** (HDL → Vivado → `.fpg`): run `jasper` at the MATLAB prompt with
the model open. It creates `sysgen/`, `myproj/` and `outputs/` next to the `.slx`.

**Known failure:** with the output folder `/home/bahnimanghosh/Simulink Project/verilog`,
generation failed with `error copying "{…/Simulink Project/verilog/sysgen/…clock.xdc}":
no such file or directory`. Vivado's Tcl wraps a path containing a space in braces and
then cannot find the file. Use a space-free path. The retry has not yet been confirmed.

Only logic between Gateway blocks is exported. Sine Waves, Scopes and To Workspace
blocks are simulation-only.

---

## Changing the FFT size

These must change together; a mismatch caused the worst crash in this project
(FFT at 1024, everything else at 256):

| Item | 256 points (now) | 1024 points |
|---|---|---|
| FFT `transform_length` | 256 | 1024 |
| `frame_cntr` width | 8 | 10 |
| `Constant1` | 2⁸−1, 8-bit | 2¹⁰−1, 10-bit |
| `acc_cntrl` `chan_bits` | 8 | 10 |
| every `vacc` `vec_len` | 256 | 1024 |
| `bin_cntr` width | 8 | 10 (and **re-measure `start_count`**) |

---

## Known issues and open items

1. **Three channels have 32-bit output ports, not 16.** In the audited file,
   `Constant0`, `Constant6` and `Constant7` (the zero inputs to the channel 1–3 gating
   Muxes) are 32-bit while the data input is 16-bit. With Mux precision = Full the
   output port widens to 32 bits. Values are correct (they fit 16 bits), but only
   channel 0 (`Constant8` = 16) truly has a 16-bit port. Fix: set the three to
   Unsigned, 16 bits, `bin_pt` 0.
2. **Cross path timing is probably off by 4 clocks.** Multiply (3) + add (1) = 4 clocks
   of arithmetic that the auto path does not have, but both use the same compensating
   delays. `new_acc` and the `bin_cntr` gate (measured on the auto path) therefore reach
   the cross accumulator 4 clocks early relative to its data. Testing did not expose it
   because bin 32 is well inside the surviving block. Proposed fix: add 4 clocks of
   delay to `pipeline15`/`pipeline16` and the select lines into `Mux8`/`Mux9`, then
   re-run the alignment check (expected: surviving block starts at true bin 0).
3. **No readout path.** `P_acc0–3` and `val_acc0–3` are Goto tags with no consumer.
   Nothing yet moves the data to the ARM (BRAM/AXI4-Stream/DMA).
4. **Input is simulated.** The Gateway Ins are fed by Sine Wave blocks; the
   `red_pitaya_adc` block is placed in the model but not connected.
5. **16-bit peaks are 0.5–1.2% above hand calculation, unexplained.** Channels 0 and 1
   are configured identically yet differ by 22 counts, so some of it is not a fixed
   quantisation effect. Next step: read the FFT imaginary peak and the power value
   directly for each channel in the same run.
6. **Output ordering on hardware is unverified.** `bit_reversed_order` is `on`, but
   System Generator simulation emits **natural** order (proved by testing both
   hypotheses against measured peak positions). The generated HDL and real hardware
   may differ; confirm against a known tone before trusting bin numbers.
7. **`acc_len` = 16 is a simulation convenience.** It averages only 4× (√16) and
   produces 768 numbers per 32.8 µs, about 47 MB/s — more than the ARM can drain.
   For flight use a much larger value (e.g. 65,536: 134 ms integration, ~11 kB/s,
   64× more noise reduction), but then the accumulator grows by 16 bits instead of 4
   and a full-scale tone no longer fits in 32 bits. Re-do the bit budget when changing it.
8. **Resource use unknown.** Four FFTs plus the cross-correlator have never been
   synthesised. Check DSP48 (80 available) and BRAM (60) before scaling to 1024 points
   or adding baselines.
9. **Only one baseline exists** (ch0 × ch1). Six pairs are possible with four channels.

---

## Biplex FFT (`fft_biplex_real_4x`)

The CASPER biplex FFT transforms four real streams in one core, roughly 4× fewer FFT
resources than four separate FFTs, and is the intended end state. It was abandoned in
this toolchain because `mlib_devel` and Model Composer 2023.1 disagree:

- Stale `xbsIndex_r4/*` references in `bi_real_unscr_4x_init.m`, `bi_real_unscr_2x_init.m`
  and `reorder_init.m` must become `hdlBasic/*`.
- `explicit_period` is `'Explicit'` on Counter but `'on'` on Constant.
- Unresolved: `hdlBasic/Constant` with `arith_type='Boolean'` produces `Fix_1_0`, which
  `reorder_even/Counter`'s `en` port rejects.

Untried lead: the `Slice` block's Boolean output works correctly in this design, so a
`Relational` block might replace the failing `en_even`/`en_odd` constants.

The current design keeps the biplex-compatible architecture (shared control, replicated
data path), so only the FFT block would change.

---

## Glossary

- **Bin k** — the FFT output for frequency k × 488.28125 kHz.
- **Auto-correlation** — a channel multiplied by itself (power, re² + im²). Real,
  non-negative, no phase.
- **Cross-correlation** — channel A times the conjugate of channel B. Complex and
  signed; its phase is the phase difference between the two inputs.
- **Integration** — the 16 frames summed into one output spectrum.
- **Hermitian symmetry** — for real input, bin N−k mirrors bin k, so only bins 0–N/2 carry
  unique information.
