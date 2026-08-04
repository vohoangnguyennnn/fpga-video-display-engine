# Cocotb core regression

This directory verifies the vendor-neutral `video_stream_core` against the
NumPy golden model. It intentionally covers only behavior that benefits from
an image-level Python scoreboard:

- all four output modes on small directed frames;
- source gaps and deterministic output backpressure;
- exact RGB, SOF, and EOL comparison;
- configuration commit on the accepted SOF;
- sticky protocol-error reporting and legal-frame recovery.

Clock Wizard and TMDS primitive checks remain in the SystemVerilog/Xsim tests.

Run with Verilator:

```bash
make test-cocotb
```
