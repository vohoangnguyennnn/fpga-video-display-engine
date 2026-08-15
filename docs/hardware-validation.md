# Hardware Validation

## 1. Purpose

Hardware validation closes risks that RTL simulation and place-and-route cannot prove: fitted-device identity, board pinout, clock integrity, TMDS electrical behavior, MIG calibration, external DDR3 data integrity, sustained memory service, reset/power sequencing, and visible frame stability.

This document separates observed results from planned checks. A pending row is not evidence of failure; it means the result has not yet been captured against a release bitstream.

## 2. Platform

| Item | Value |
| --- | --- |
| Board | MicroPhase A7-Lite R1.1, 35T variant |
| FPGA | XC7A35T-2FGG484 |
| Board clock | 50 MHz |
| Video output | DVI-compatible video over HDMI connector |
| Target mode | 1280×720p60 |
| External memory | Board-fitted x16 DDR3 configured through MIG 7 Series |

The bitstream, commit, Vivado version, cable, and monitor should be recorded for every release run because a photograph alone cannot distinguish direct and DDR data paths.

## 3. Evidence available now

![Direct HDMI hardware demonstration](images/hardware-demo.jpg)

| Check | Current evidence | Status |
| --- | --- | --- |
| Board powers and programs | Board visible active in the hardware capture | Observed |
| Video clock/raster/TMDS/pins | Stable 720p test pattern visible on a monitor | Direct path observed |
| Processing-core arithmetic | RTL/model/cocotb scoreboards | Simulation verified |
| DDR WDMA/RDMA | Unit, full-frame, loopback, and cocotb memory tests | Simulation verified |
| FB0/FB1 swap policy | Framebuffer subsystem integration test | Simulation verified |
| Routed DDR-enabled design | Mode-1 utilization/device/timing captures | Implemented |
| MIG calibration on repeated cold boots | No release record yet | Pending |
| Full-aperture DDR BIST | No release record yet | Pending |
| End-to-end DDR video | No release record yet | Pending |
| Long-duration/no-tearing run | No release record yet | Pending |

The current photo is valid evidence for the direct board/output chain. It is not proof that pixels traversed DDR3.

## 4. Test sequence

### 4.1 Direct diagnostic image (`DEMO_MODE=0`)

1. Build and program the direct image.
2. Confirm the fault LED remains inactive.
3. Confirm stable monitor lock at 1280×720p60.
4. Cycle passthrough, grayscale, Sobel magnitude, and binary edge.
5. Step threshold through `0, 32, …, 224` and confirm changes occur at a frame boundary.
6. Reset repeatedly and check deterministic reacquisition.

This isolates the root clock, video clock generator, processing pipeline, AXI-to-raster bridge, timing generator, TMDS encoder/serializer, HDMI pins, and monitor compatibility.

### 4.2 Standalone DDR qualification (`DEMO_MODE=2`)

1. Build and program the BIST-only image.
2. Confirm MIG calibration completes.
3. Confirm destructive BIST reaches done/pass.
4. Confirm no fault result is latched.
5. Repeat from cold power-up at least ten times.

The BIST image owns the memory port without concurrent video traffic. This separates DDR electrical/configuration failures from framebuffer scheduling or bandwidth failures.

### 4.3 Full framebuffer video (`DEMO_MODE=1`)

1. Program the mode-1 bitstream built from the same release commit.
2. Wait for calibration and BIST qualification.
3. Confirm HDMI remains black during invalid startup and then locks to a complete frame.
4. Observe a moving test pattern so repeated frames and tearing are visible.
5. Exercise all processing modes and thresholds.
6. Reset and power-cycle repeatedly.
7. Run for 15–30 minutes initially, then a longer release soak if practical.
8. Record any black fallback, horizontal displacement, colored startup artifact, frame-lock loss, tearing, or sticky fault.

## 5. Validation without ILA

An Integrated Logic Analyzer improves internal observability but is not mandatory for publishing the project. Without ILA, use three complementary evidence sources:

1. **Simulation waveform:** show final WDMA response, slot transition to `READY`, vblank request/acknowledge, front-buffer promotion, and RDMA command.
2. **BIST/status LEDs:** expose calibration, BIST pass, display-valid, and sticky fault states.
3. **External behavior:** record moving-pattern video, resets, power cycles, mode changes, and the absence of visible tearing/fault indication.

Fast pulses such as `status_swap` should not be connected directly to an LED and described as observable. If LED visibility is needed, use a clearly documented sticky flag, toggle, or divided counter in a diagnostic build.

The limitation must be stated explicitly:

> Internal buffer-swap events were verified in simulation; the release hardware build was validated through BIST/status outputs and end-to-end video observation without an on-chip ILA capture.

## 6. Evidence to capture

### Minimum portfolio evidence

- One clean board + HDMI monitor photograph.
- Four captures of the same pattern in passthrough, grayscale, Sobel magnitude, and binary mode.
- One short moving-pattern video from the DDR-enabled build.
- A test record showing cold-boot calibration/BIST results.
- A simulation waveform for backpressure or framebuffer swapping.

### Capture metadata

Record the following next to every hardware asset:

```text
Date
Board revision and fitted FPGA marking
Vivado version
DEMO_MODE
Git commit
Bitstream SHA-256
Monitor/capture device and cable
Observed LED state
Duration and power-cycle count
```

## 7. Release result template

Fill this table only after testing the final bitstream:

| Test | Expected | Result |
| --- | --- | --- |
| Direct HDMI lock | Stable 1280×720p60 | Pass — preliminary direct-path photo available |
| Four processing modes | Correct visible mode and frame-atomic changes | Pending portfolio capture |
| Threshold stepping | `0,32,…,224,0`, no loss of lock | Pending |
| MIG calibration | Complete on every cold boot | Pending |
| DDR BIST | Full configured aperture passes | Pending |
| Mode-1 startup | Black until first complete promotion | Pending |
| DDR moving pattern | Stable output, no visible tearing | Pending |
| Fault LED | Inactive during normal run | Pending |
| Reset stress | Clean reacquisition | Pending |
| Cold power cycles | Target 10/10 | Pending |
| Soak | Target ≥30 minutes, no persistent fault | Pending |

## 8. Claim boundary

Before physical DDR closure, the accurate portfolio statement is:

> The direct 720p HDMI path is hardware-demonstrated. The DDR3 DMA, BIST, CDC, and double-buffer control are implemented, timing-closed, and verified in simulation; complete physical DDR display-path validation is in progress.

After mode-2 and mode-1 tests pass against a tagged bitstream, this can be upgraded to:

> Demonstrated a custom DDR3-backed, double-buffered 720p60 video-processing pipeline on a Xilinx Artix-7 FPGA, with repeated calibration/BIST success and tear-free moving-pattern output.

Do not use the stronger statement until the pending rows above have direct evidence.
