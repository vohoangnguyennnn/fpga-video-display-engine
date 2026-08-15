# QuestaSim waveform workflow

This flow provides a deterministic, review-oriented GUI view of the reusable
`video_stream_core`. It is a debug and engineering-evidence aid; assertions,
scoreboards, and regressions remain the pass/fail authorities.

## Quick start

QuestaSim must be licensed and `vsim` must be on `PATH`.

```bash
# Headless compile/elaborate/run check
make test-questa-core

# Compile, run, and open the curated waveform GUI
make waves
```

The default Makefile flow writes the work library, transcript, and WLF database
under `/tmp/fpga-video-stream-processor/questa/core`. Override it when needed:

```bash
make QUESTA_BUILD=/tmp/my-questa-core waves
```

Generated libraries, logs, and waveform databases are not source-controlled.
The repository keeps only the compile order, Tcl automation, and curated signal
layout required to reproduce the view.

## Scenario navigation

The `wave_phase` signal divides the integration run into reviewable scenarios:

| Value | Scenario | Design intent |
| ---: | --- | --- |
| 0 | Reset/startup | No output before a new legal SOF |
| 1 | Legal 1×1 frame | Observable in-frame state and post-input drain |
| 2 | Configuration commit | Raw configuration changes do not affect the active frame |
| 3 | Grayscale | Pixel/metadata stability under bubbles and stalls |
| 4 | Sobel magnitude | Centered window, arithmetic, and zero border alignment |
| 5 | Binary threshold | Strict `magnitude > threshold × 6` behavior |
| 6 | Continuous throughput | One accepted input pixel per clock through final input |
| 7 | Recovery | Unexpected SOF flushes the malformed frame and resynchronizes |
| 8 | Done | All self-checking integration scenarios passed |

Use the phase transitions as navigation anchors, then zoom to the shortest
interval that demonstrates the property being reviewed.

## Wave groups and specification coverage

| Wave group | What to inspect | Relevant specification evidence |
| --- | --- | --- |
| AXIS input/output | `TVALID`, `TREADY`, payload and SOF/EOL stability during stalls | AC-04, AXI4-Stream contract |
| Configuration/status | SOF-time commit, `status_in_frame`, sticky protocol error | Sections 4.4 and 6.4 |
| Frame tracker | Accepted-transfer coordinates, border and internal EOF tags | Sections 4.4 and 5.3 |
| Pipeline handshakes | Transactional fork/join advances one-for-one | Section 6.2 |
| Window and drain | Centered look-ahead, bank state, exact end-of-frame drain | Sections 6.3 and 6.4 |
| Sobel arithmetic | 3×3 samples, signed gradients, magnitude and edge result | Section 5.2 |
| Alignment FIFO | Stall-aware RGB/gray/metadata occupancy and movement | Sections 6.1 and 6.2 |
| Recovery control | Preserve stalled output, flush safely, accept a new legal SOF | Section 4.4 and AC-05 |

## Portfolio capture checklist

Keep only a few annotated screenshots in GitHub or release artifacts:

1. An output stall spanning SOF or EOL, showing stable `TDATA/TUSER/TLAST`.
2. The continuous-throughput phase, showing one accepted pixel per clock.
3. Final-input drain, showing input blocked while delayed output tokens retire.
4. Unexpected-SOF recovery, showing flush/resynchronization and sticky error.

Each image should include the clock, reset, `wave_phase`, enough hierarchy to
identify the DUT, a readable time scale, and a caption naming the property. A
waveform is supporting evidence rather than standalone proof: link the image to
the self-checking test and its passing transcript.

## Maintainer notes

- `questa/core_files.f` is the canonical compile order for this view.
- `questa/compile_core.do` owns relocatable compilation and the generated work
  library location.
- `questa/core_batch.do` proves that the GUI design compiles and passes without
  manual interaction.
- `questa/core_gui.do` loads `questa/wave.do`, runs the deterministic test, and
  zooms to the complete execution.
- Keep `questa/wave.do` architectural. Avoid dumping every object recursively;
  large signal sets hide protocol intent and produce noisy portfolio evidence.
- Questa may report `vlog-13314` for packed-struct input-port defaults and
  `vopt-10908` because `+acc` intentionally preserves internal visibility.
  These are documented simulator diagnostics; Verilator lint and the
  self-checking regression remain the functional quality gates.
