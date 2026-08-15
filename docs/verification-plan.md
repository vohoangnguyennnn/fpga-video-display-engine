# Verification Plan

## 1. Verification objective

Verification must establish both image correctness and streaming-protocol
correctness. A Sobel image that looks plausible is insufficient evidence: the
testbench must detect a single duplicated pixel, misplaced `TLAST`, stale
configuration value, signed overflow, or unstable output under backpressure.

## 2. Tool strategy

The intended open-source regression stack is:

- Verilator for lint and fast regression;
- Icarus Verilog as a second simulator;
- cocotb and pytest for stimulus, scoreboarding, and test selection;
- NumPy for the bit-accurate image model;
- Pillow only for loading/saving demonstration images.

Vivado xsim is used for Xilinx primitive and board-top simulation. Vivado
synthesis and implementation are the source of final FPGA metrics.

Tool versions will be pinned in CI. A single `make test` entry point must run
the portable regression from a clean clone.

## 3. Reference model

The golden model operates on integer arrays only. It implements exactly:

1. RGB coefficient multiplication;
2. `+128` rounding before division by 256;
3. signed Sobel `Gx` and `Gy`;
4. `abs(Gx) + abs(Gy)`;
5. 8-bit saturation;
6. strict 11-bit-domain threshold comparison against
   `cfg_threshold × 6`;
7. constant-zero Sobel borders;
8. RGB replication for scalar modes.

Floating-point OpenCV output may be used for visualization, but it is not the
pass/fail oracle because library rounding and border policies differ.

The model consumes a frame and configuration object and produces:

- expected output pixels;
- expected SOF/EOL positions;
- expected frame dimensions;
- expected status flags for malformed input tests.

The independent framebuffer model operates at transaction level. It covers:

- fixed XRGB8888 layout, framebuffer bases, and pixel addresses;
- 128-bit AXI lane packing and 4-KiB-safe burst planning;
- sparse memory behavior with byte-write strobes; and
- response-qualified writes, slot ownership, startup black, vblank promotion,
  repeat-frame behavior, DMA failure, and read-deadline recovery.

It intentionally does not model MIG latency or duplicate the DMA ready/valid
state machines. Those behaviors remain in the RTL simulation environments.

## 4. Verification layers

### 4.1 Unit tests

| DUT | Mandatory cases |
| --- | --- |
| `axis_elastic_buffer` | fall-through/full behavior, prolonged stall, simultaneous push/pop, reset while full |
| `rgb_to_gray` | black/white, primary colors, random RGB, rounding boundaries, backpressure |
| `window_3x3` | 3×3 minimum, line-bank rotation, first/last row and column, bubbles, BRAM collision semantics |
| `sobel_gx_gy` | flat field, horizontal/vertical edges, both polarities, maximum positive/negative gradient |
| `sobel_magnitude` | absolute-value corner cases, reachable maximum 1530, saturation, 6× threshold below/equal/above |
| `stream_align_delay` | payload/metadata alignment, fork/join accounting, and randomized independent branch stalls |
| `video_mode_mux` | each mode, mid-frame config changes, next-frame atomic commit |

### 4.2 Core integration tests

- Tiny exhaustive images: 3×3, 4×4, and 5×5.
- Non-power-of-two dimensions: 13×7 and 53×17.
- Standard dimensions: 640×480 and 1280×720.
- Constant black, constant white, impulse, ramp, checkerboard, vertical edge,
  horizontal edge, diagonal edge, and seeded random images.
- Every mode and threshold corner value: 0, 1, 127, 254, and 255.
- Input valid probability sweeps: 100%, 75%, 25%, and bursty gaps.
- Output ready probability sweeps: 100%, 75%, 25%, and long deterministic
  stalls at SOF/EOL.
- Simultaneous input gaps and output stalls.
- Back-to-back frames with identical and different configurations.
- Next-frame SOF presented while the previous frame drains: the source holds
  the transfer while not ready, no false protocol error is raised, and the SOF
  is accepted only after drain.
- Width/height configuration at minimum, odd, even, and standard dimensions.
- Reset before a frame, at every early pipeline stage, mid-line, at EOL, and
  while the output is stalled.

### 4.3 Malformed-stream tests

- An unexpected SOF accepted before the configured final input pixel.
- Missing SOF at power-up.
- EOL earlier or later than the first-line width.
- Configured width or height equal to zero.
- Width greater than `MAX_WIDTH`.
- Height greater than `MAX_HEIGHT`.
- A source that illegally changes SOF/data while stalled, checked as a
  testbench protocol violation rather than a required DUT telemetry event.

Each DUT-malformed test checks the documented sticky error and successful
resynchronization at the next legal SOF. The source-side stall violation is
expected to be caught by the driver assertion; the DUT is not required to
diagnose a transfer it did not accept.

### 4.4 Board-level tests

- XDC audit: `clk_50m` is J19/LVCMOS33/20.000 ns; no Digilent Arty constraint
  is present; HDMI and user-I/O pins match the reviewed MicroPhase schematic.
- MMCM frequency/5:1-ratio checks, lock acquisition, synchronization of the
  asynchronous lock request, at least four further pixel-clock cycles of reset
  qualification, forced lock loss, and clean frame-boundary reacquisition.
- `pix_reset` assertion and release are both edge-aligned to `pix_clk`; the
  asynchronously controlled request synchronizer never directly drives BRAM
  address/control logic or the reusable processing core.
- No active-video/TMDS-valid state is enabled before its local reset release.
- 720p timing totals (1650×750), positive sync polarity, and 1280×720 active
  region.
- Raster line-bank reservation, frame-boundary SOF lock, fill/drain, underflow,
  overflow, uninterrupted active pixels, expected pre-lock startup black,
  post-lock black-frame fallback, and next-SOF resynchronization.
- Bounded AXI stalls and forced missing-line injection prove that the raster
  never stretches timing or switches banks mid-line; a normal release run
  records zero post-lock fallback/error events.
- TMDS control symbols during blanking.
- Known color-bar encoded symbols.
- Mode/threshold button synchronization and debounce.
- HDMI smoke test on at least one monitor and one capture device, if available.
- ILA evidence for input/output handshakes, SOF, EOL, mode, threshold, and
  error status when available; otherwise preserve equivalent simulation
  waveform evidence and documented board-level diagnostic status.

### 4.5 Implementation-structure checks

- Directed same-address line-RAM collisions return the old-line pixel in RTL;
  the Vivado inference report and a post-synthesis check confirm the same
  implementation semantics.
- Yosys/elaboration and Vivado post-synthesis queries independently confirm no
  combinational top-level `m_axis_tready` to `s_axis_tready` path.
- End-of-frame tests count exactly `width × height` outputs with one SOF and
  `height` EOL markers; internal border/drain cycles never appear as dummy AXI
  transfers.
- `report_clocks`, `report_clock_networks`, `report_clock_interaction`,
  `report_cdc`, `check_timing`, and `report_timing_summary` are archived.
  Unconstrained clocks/endpoints and unjustified CDC exceptions are release
  failures.

## 5. Assertions

Assertions are bound to module interfaces where supported. Required properties
include:

```systemverilog
// Output payload cannot change while the receiver is stalling.
m_axis_tvalid && !m_axis_tready |=>
    $stable({m_axis_tdata, m_axis_tuser, m_axis_tlast});
```

Additional properties:

- valid is cleared after reset;
- a registered stage never overwrites an unaccepted payload;
- fork and join branch transaction counts remain one-to-one;
- a line-buffer write occurs only on accepted input;
- horizontal and vertical counters advance only on accepted input;
- SOF appears only on output pixel `(0,0)`;
- EOL appears exactly once per output line;
- no output is emitted from invalid line-buffer state;
- configuration remains constant throughout an active output frame;
- input and output frame/pixel accounting balances after drain;
- signed gradients remain inside the mathematically legal range;
- L1 magnitude never exceeds the reachable Sobel bound of 1530.

Properties are written to avoid relying on simulator scheduling accidents.

## 6. Scoreboard model

The cocotb driver converts each source frame into AXI transfers. The monitor
reconstructs frames only from accepted output transfers. The scoreboard checks:

- exact pixel value at every coordinate;
- exact SOF/EOL placement;
- total line and frame size;
- output stability during each stall cycle;
- input/output transaction accounting;
- expected configuration version per frame.

Tests use deterministic random seeds printed in failure logs. A failing run must
be reproducible with one command and seed.

## 7. Coverage closure

Functional coverage is tracked in Python until SystemVerilog coverage tooling
is justified.

| Cross | Required bins |
| --- | --- |
| mode × pattern | all four modes with all directed patterns |
| mode × backpressure | no stall, random stall, long stall |
| threshold relation | magnitude below, equal, and above threshold |
| gradient sign | `Gx` ±/0 crossed with `Gy` ±/0 |
| border location | top, bottom, left, right, and four corners |
| reset location | idle, fill, active line, EOL, output stall |
| frame size | below 3, minimum 3, odd, even, standard |
| configuration update | idle, first pixel, mid-line, final pixel |

Coverage gaps must be resolved by adding tests or documenting unreachable bins.

## 8. Regression tiers

| Tier | Trigger | Contents | Target runtime |
| --- | --- | --- | --- |
| Smoke | every local edit | lint + unit directed tests | under 1 minute |
| Pull request | every PR | all unit tests + randomized tiny/medium frames | under 10 minutes |
| Nightly/release | scheduled/tag | long random runs + 640×480 + 720p + Vivado build | runtime reported, not artificially capped |

Large generated images and waveforms are CI artifacts, not committed files.

## 9. Failure triage artifacts

On failure, the test framework preserves:

- simulator and seed;
- input frame/configuration;
- expected and actual output images;
- absolute-difference image;
- first mismatching coordinate and neighboring 3×3 values;
- the shortest useful waveform around the mismatch;
- protocol-event log around SOF/EOL/reset.

## 10. Verification sign-off

The verification sign-off checklist is:

- all acceptance criteria mapped to tests;
- zero unexplained lint warnings;
- zero failing tests in both portable simulators;
- all mandatory coverage bins hit;
- board primitive simulation passes in xsim;
- post-route timing is clean;
- hardware capture matches the tagged RTL;
- known limitations are listed in the release notes.
