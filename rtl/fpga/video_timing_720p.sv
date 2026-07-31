// Fixed 1280x720p raster timing generator.
//
// Coordinates cover the complete raster, including blanking:
//   horizontal: 0..1649
//   vertical:   0..749
//
// Active video occupies the origin-aligned rectangle 0..1279 by 0..719.
// HSYNC and VSYNC are active high as required by the v1.0 board contract.

module video_timing_720p (
    input logic pix_clk,
    input logic pix_reset,

    output logic [10:0] h_count,
    output logic [9:0] v_count,
    output logic active_video,
    output logic hsync,
    output logic vsync
);

    localparam logic [10:0] H_ACTIVE = 11'd1280;
    localparam logic [10:0] H_FRONT_PORCH = 11'd110;
    localparam logic [10:0] H_SYNC_WIDTH = 11'd40;
    localparam logic [10:0] H_BACK_PORCH = 11'd220;
    localparam logic [10:0] H_TOTAL = H_ACTIVE + H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH;

    localparam logic [9:0] V_ACTIVE = 10'd720;
    localparam logic [9:0] V_FRONT_PORCH = 10'd5;
    localparam logic [9:0] V_SYNC_WIDTH = 10'd5;
    localparam logic [9:0] V_BACK_PORCH = 10'd20;
    localparam logic [9:0] V_TOTAL = V_ACTIVE + V_FRONT_PORCH + V_SYNC_WIDTH + V_BACK_PORCH;

    localparam logic [10:0] H_SYNC_START = H_ACTIVE + H_FRONT_PORCH;
    localparam logic [10:0] H_SYNC_END = H_SYNC_START + H_SYNC_WIDTH;
    localparam logic [10:0] H_LAST = H_TOTAL - 1'b1;

    localparam logic [9:0] V_SYNC_START = V_ACTIVE + V_FRONT_PORCH;
    localparam logic [9:0] V_SYNC_END = V_SYNC_START + V_SYNC_WIDTH;
    localparam logic [9:0] V_LAST = V_TOTAL - 1'b1;

    assign active_video = !pix_reset && (h_count < H_ACTIVE) && (v_count < V_ACTIVE);

    assign hsync = !pix_reset && (h_count >= H_SYNC_START) && (h_count < H_SYNC_END);

    assign vsync = !pix_reset && (v_count >= V_SYNC_START) && (v_count < V_SYNC_END);

    always_ff @(posedge pix_clk) begin
        if (pix_reset) begin
            h_count <= '0;
            v_count <= '0;
        end else if (h_count == H_LAST) begin
            h_count <= '0;

            if (v_count == V_LAST) begin
                v_count <= '0;
            end else begin
                v_count <= v_count + 1'b1;
            end
        end else begin
            h_count <= h_count + 1'b1;
        end
    end

endmodule
