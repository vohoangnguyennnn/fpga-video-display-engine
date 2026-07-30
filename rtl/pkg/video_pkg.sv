// Shared payload type for the vendor-neutral video-processing pipeline.

package video_pkg;

    // One accepted video token and the metadata that must remain aligned with
    // it under stalls. eof is internal-only; AXI4-Stream Video exposes SOF on
    // TUSER[0] and EOL on TLAST.
    typedef struct packed {
        logic [23:0] rgb;
        logic [7:0]  gray;
        logic        sof;
        logic        eol;
        logic        eof;
        logic        border;
    } video_payload_t;

endpackage
