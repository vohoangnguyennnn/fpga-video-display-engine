# Flagship pre-release implementation checklist

This checklist gates the final DDR-enabled Vivado implementation and A7-Lite
board smoke test. Reports from an earlier RTL snapshot are diagnostic evidence
only and must not be published as release results.

## 1. Source-of-truth gate

- Vivado must compile the files under this repository's `rtl/` tree, or copies
  proven byte-identical immediately before the run.
- The selected device is `xc7a35tfgg484-2`; the MIG and Clocking Wizard XCI
  files also record speed grade `-2`, matching the confirmed fitted marking.
- The active constraint set contains `constraints/main.xdc` plus only the
  mode-required DDR/CDC XDC files; no copied Arty constraint file is enabled.
- Synthesis and implementation are reset and rerun from the updated RTL. A
  release run does not reuse an incremental checkpoint from an older source
  snapshot.

## 2. Required reports and pass conditions

Archive these reports from the routed design:

```tcl
report_drc
report_methodology
report_timing_summary -delay_type min_max -report_unconstrained
check_timing -verbose
report_cdc -details
report_clock_interaction
report_clock_networks
report_route_status
report_utilization -hierarchical
report_power
report_ip_status
```

Release gates:

- zero errors and critical warnings;
- zero routing errors;
- `REQP-1839 = 0` and `REQP-1840 = 0`;
- setup, hold, and pulse-width slack are all non-negative, with zero failing
  endpoints;
- no unconstrained internal endpoint or clock;
- every CDC finding matches the reviewed inventory: button synchronizers,
  Gray-pointer asynchronous FIFOs, vblank toggle/acknowledge events, and
  synchronized status/reset levels;
- the line memories remain BRAM and RAM contents are not reset;
- the generated clocks remain near 74.21875 MHz and 371.09375 MHz with an
  exact 5:1 relationship.

## 3. Reviewed non-blocking warnings

The following may remain only if their descriptions and affected hierarchy are
unchanged from this review:

- `SYNTH-9` for fixed, small RGB-to-gray multipliers implemented in LUTs. Do
  not force DSP48 use while timing and resource budgets pass.
- unused canonical payload fields in stages that intentionally consume only a
  subset of the shared video payload.
- unused Sobel center pixel `p11`, whose coefficient is zero in both kernels.
- no external output delay on asynchronous status LEDs and internally
  serialized DVI-over-HDMI outputs. Do not invent an output-delay value merely
  to suppress `check_timing` output-port messages.
- Vivado 2024.1 virtual-grid initialization warnings, provided the design is
  fully routed with no route error and all timing gates pass.
- generated-MIG `BUFC-1` warnings for the two DQS `IBUFDS` input branches and
  `REQP-1709` for the internal `PLLE2_ADV` output, only while their count,
  description, and hierarchy remain unchanged and calibration/BIST pass on the
  fitted board.

Any new warning ID, changed hierarchy, inferred distributed RAM replacing a
line buffer, or truncated rule report requires review.

## 4. Board smoke-test order

1. Program the board with HDMI disconnected and confirm the fault LED remains
   inactive after startup.
2. Connect a known 720p-capable monitor and confirm stable frame lock.
3. Observe passthrough, grayscale, Sobel magnitude, and binary edge modes.
4. Press K2 through thresholds `0, 32, ..., 224, 0`; changes must become visible
   only at a frame boundary.
5. Exercise K1/K2 repeatedly and confirm no frame-lock loss or fault LED.
6. Reset or power-cycle at least ten times and check clean reacquisition without
   persistent blank frames, line displacement, or colored startup artifacts.
7. Record monitor mode, cable, board marking, Vivado version, bitstream hash,
   release commit, timing/utilization reports, and observed faults.

Passing the board smoke test proves the board wrapper. Publishing the reusable
IP additionally requires the core-only 100 MHz timing run, two-simulator
regression, randomized backpressure/image scoreboard, and structural ready-path
checks required by `docs/design-spec.md`.
