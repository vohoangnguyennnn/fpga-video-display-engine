`timescale 1ns/1ps

module axis_elastic_buffer_tb;

    import video_pkg::video_payload_t;

    localparam time CLK_PERIOD = 10ns;

    logic aclk;
    logic aresetn;
    video_payload_t s_axis_payload;
    logic s_axis_tvalid;
    logic s_axis_tready;
    video_payload_t m_axis_payload;
    logic m_axis_tvalid;
    logic m_axis_tready;

    video_payload_t expected_queue[$];

    axis_elastic_buffer dut (
        .aclk,
        .aresetn,
        .s_axis_payload,
        .s_axis_tvalid,
        .s_axis_tready,
        .m_axis_payload,
        .m_axis_tvalid,
        .m_axis_tready
    );

    always #(CLK_PERIOD / 2) aclk = !aclk;

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    function automatic video_payload_t make_payload(
        input logic [23:0] rgb,
        input logic [7:0] gray,
        input logic sof = 1'b0,
        input logic eol = 1'b0,
        input logic eof = 1'b0,
        input logic border = 1'b0
    );
        video_payload_t payload;

        payload.rgb = rgb;
        payload.gray = gray;
        payload.sof = sof;
        payload.eol = eol;
        payload.eof = eof;
        payload.border = border;
        return payload;
    endfunction

    task automatic reset_dut;
        @(negedge aclk);
        aresetn = 1'b0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b0;
        repeat (2) @(posedge aclk);
        #1ps;

        check(!m_axis_tvalid, "output valid remained set after reset");
        expected_queue.delete();

        @(negedge aclk);
        aresetn = 1'b1;
        #1ps;
        check(s_axis_tready, "input was not ready after reset");
    endtask

    task automatic run_cycle(
        input logic source_valid,
        input video_payload_t payload,
        input logic sink_ready
    );
        logic push;
        logic pop;
        video_payload_t expected_payload;

        @(negedge aclk);
        s_axis_tvalid = source_valid;
        s_axis_payload = payload;
        m_axis_tready = sink_ready;
        #1ps;

        push = s_axis_tvalid && s_axis_tready;
        pop = m_axis_tvalid && m_axis_tready;

        if (pop) begin
            check(expected_queue.size() > 0, "unexpected output transfer");
            expected_payload = expected_queue.pop_front();
            check(m_axis_payload == expected_payload, "payload order or metadata mismatch");
        end

        if (push) begin
            expected_queue.push_back(payload);
        end

        @(posedge aclk);
        #1ps;

        check(expected_queue.size() <= 2, "buffer occupancy exceeded two");
        check(m_axis_tvalid == (expected_queue.size() != 0), "output valid disagrees with expected occupancy");
        check(s_axis_tready == (expected_queue.size() < 2),"input ready disagrees with expected capacity");

        if (expected_queue.size() != 0) begin
            check(
                m_axis_payload == expected_queue[0],
                "output payload changed or was reordered"
            );
        end
    endtask

    initial begin
        video_payload_t first;
        video_payload_t second;
        video_payload_t third;
        video_payload_t stream_payload;

        aclk = 1'b0;
        aresetn = 1'b0;
        s_axis_payload = '0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b0;

        check($bits(video_payload_t) == 36, "video_payload_t width changed");

        first = make_payload(24'h123456, 8'h78, 1'b1);
        second = make_payload(24'habcdef, 8'h34, 1'b0, 1'b1);
        third = make_payload(24'h102030, 8'h40, 1'b0, 1'b0, 1'b1, 1'b1);

        reset_dut();

        // Fill both entries and prove the oldest payload remains stable while
        // the downstream receiver is stalled.
        run_cycle(1'b1, first, 1'b0);
        run_cycle(1'b1, second, 1'b0);
        check(!s_axis_tready, "buffer did not report full");
        check(m_axis_payload.rgb == 24'h123456, "RGB field mapping mismatch");
        check(m_axis_payload.gray == 8'h78, "gray field mapping mismatch");
        check(m_axis_payload.sof, "SOF field mapping mismatch");
        check(!m_axis_payload.eol, "EOL field mapping mismatch");
        check(!m_axis_payload.eof, "EOF field mapping mismatch");
        check(!m_axis_payload.border, "border field mapping mismatch");

        repeat (8) begin
            run_cycle(1'b0, '0, 1'b0);
            check(m_axis_payload == first, "output changed during prolonged stall");
        end

        // Drain one entry, then exercise simultaneous input and output
        // transfers without changing transaction order.
        run_cycle(1'b0, '0, 1'b1);
        run_cycle(1'b1, third, 1'b1);
        run_cycle(1'b0, '0, 1'b1);
        check(expected_queue.size() == 0, "buffer did not drain");

        // A continuously-ready sink must sustain one transfer per clock.
        for (integer index = 0; index < 32; index++) begin
            stream_payload = make_payload(
                24'(index * 24'h010203),
                8'(index * 17),
                index == 0,
                index == 31,
                index == 31,
                (index % 7) == 0
            );
            run_cycle(1'b1, stream_payload, 1'b1);
            check(s_axis_tready, "input bubble with continuously-ready sink");
        end
        run_cycle(1'b0, '0, 1'b1);
        check(expected_queue.size() == 0, "continuous stream did not drain");

        // Reset discards both buffered transfers and restores input capacity.
        run_cycle(1'b1, first, 1'b0);
        run_cycle(1'b1, second, 1'b0);
        check(expected_queue.size() == 2, "reset test did not fill the buffer");
        reset_dut();
        check(expected_queue.size() == 0, "reset did not clear the scoreboard");

        $display("axis_elastic_buffer_tb: PASS");
        $finish;
    end

endmodule
