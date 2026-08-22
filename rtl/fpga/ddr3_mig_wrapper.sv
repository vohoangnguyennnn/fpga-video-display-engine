// Board-specific boundary around the generated MIG 7 Series DDR3 controller.
//
// Fixed generated-IP contract (ip/ddr3_mig/mig_a.prj):
//   - MT41K256M16XX-107, x16, one rank, DDR3-800
//   - 50 MHz system clock and 200 MHz IODELAY reference clock
//   - 100 MHz AXI UI clock
//   - AXI4: 29-bit byte address, 128-bit data, 4-bit ID
//
// clk_50m is the already-buffered board clock from board_clock_buffer.  This
// module owns the auxiliary Clocking Wizard and the MIG instance, but no frame
// geometry, pixel packing, DMA, or framebuffer-ownership policy.

module ddr3_mig_wrapper (
    input logic clk_50m,
    input logic reset_async,

    // MT41K256M16 physical interface. Chip select is intentionally absent:
    // the reviewed board/MIG configuration disables the CS# FPGA port.
    output logic [14:0] ddr3_addr,
    output logic [2:0] ddr3_ba,
    output logic ddr3_ras_n,
    output logic ddr3_cas_n,
    output logic ddr3_we_n,
    output logic ddr3_reset_n,
    output logic [0:0] ddr3_ck_p,
    output logic [0:0] ddr3_ck_n,
    output logic [0:0] ddr3_cke,
    output logic [1:0] ddr3_dm,
    output logic [0:0] ddr3_odt,
    inout wire [15:0] ddr3_dq,
    inout wire [1:0] ddr3_dqs_p,
    inout wire [1:0] ddr3_dqs_n,

    // ui_reset is active high and changes only on ui_clk edges. It remains
    // asserted until the clock generators are locked and calibration passes.
    output logic ui_clk,
    output logic ui_reset,
    output logic init_calib_complete,

    // Bring-up/ILA status. device_temp uses the native MIG/XADC encoding.
    output logic ddr_clk_locked,
    output logic mig_mmcm_locked,
    output logic [11:0] device_temp,

    // AXI4 slave interface in the ui_clk domain.
    input logic [3:0] s_axi_awid,
    input logic [28:0] s_axi_awaddr,
    input logic [7:0] s_axi_awlen,
    input logic [2:0] s_axi_awsize,
    input logic [1:0] s_axi_awburst,
    input logic [0:0] s_axi_awlock,
    input logic [3:0] s_axi_awcache,
    input logic [2:0] s_axi_awprot,
    input logic [3:0] s_axi_awqos,
    input logic s_axi_awvalid,
    output logic s_axi_awready,

    input logic [127:0] s_axi_wdata,
    input logic [15:0] s_axi_wstrb,
    input logic s_axi_wlast,
    input logic s_axi_wvalid,
    output logic s_axi_wready,

    output logic [3:0] s_axi_bid,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input logic s_axi_bready,

    input logic [3:0] s_axi_arid,
    input logic [28:0] s_axi_araddr,
    input logic [7:0] s_axi_arlen,
    input logic [2:0] s_axi_arsize,
    input logic [1:0] s_axi_arburst,
    input logic [0:0] s_axi_arlock,
    input logic [3:0] s_axi_arcache,
    input logic [2:0] s_axi_arprot,
    input logic [3:0] s_axi_arqos,
    input logic s_axi_arvalid,
    output logic s_axi_arready,

    output logic [3:0] s_axi_rid,
    output logic [127:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rlast,
    output logic s_axi_rvalid,
    input logic s_axi_rready
);

    logic mig_sys_clk;
    logic mig_ref_clk;
    logic mig_sys_reset;
    logic mig_ui_sync_reset;
    logic mig_axi_aresetn;
    logic ui_reset_request;
    logic [2:0] _unused_app_status;

    // ddr3_clk_wiz is generated with No_buffer input because clk_50m has
    // already passed through the board's single IBUF/BUFG ownership point.
    ddr3_clk_wiz u_ddr3_clk_wiz (
        .clk_in1(clk_50m),
        .reset(reset_async),
        .locked(ddr_clk_locked),
        .clk_out1(mig_sys_clk),
        .clk_out2(mig_ref_clk)
    );

    // MIG sys_rst is active high. Holding it asserted while the auxiliary
    // MMCM is unlocked prevents either generated input clock being consumed
    // before both outputs are stable.
    assign mig_sys_reset = reset_async || !ddr_clk_locked;

    // Match the registered AXI-reset connection in the generated MIG example
    // design. MIG's ui_clk_sync_rst already has synchronous deassertion in the
    // UI domain; registering its inverse also avoids a combinational reset
    // release into the AXI shim.
    initial mig_axi_aresetn = 1'b0;

    always_ff @(posedge ui_clk) begin
        if (mig_ui_sync_reset) begin
            mig_axi_aresetn <= 1'b0;
        end else begin
            mig_axi_aresetn <= 1'b1;
        end
    end

    // Functional UI logic (DMA, interconnect-side state, and BIST) remains in
    // reset throughout PHY calibration. A calibration loss reasserts reset;
    // reset_sync ensures every observable ui_reset transition is edge-aligned
    // to ui_clk and that release receives four clean UI-clock cycles.
    assign ui_reset_request = mig_ui_sync_reset
        || !ddr_clk_locked
        || !mig_mmcm_locked
        || !init_calib_complete;

    reset_sync #(
        .RELEASE_STAGES(4)
    ) u_ui_reset_sync (
        .clk(ui_clk),
        .reset_async(ui_reset_request),
        .reset_out(ui_reset)
    );

    ddr3_mig u_ddr3_mig (
        .ddr3_addr(ddr3_addr),
        .ddr3_ba(ddr3_ba),
        .ddr3_cas_n(ddr3_cas_n),
        .ddr3_ck_n(ddr3_ck_n),
        .ddr3_ck_p(ddr3_ck_p),
        .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq),
        .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_dm(ddr3_dm),
        .ddr3_odt(ddr3_odt),

        .sys_clk_i(mig_sys_clk),
        .clk_ref_i(mig_ref_clk),
        .sys_rst(mig_sys_reset),

        .ui_clk(ui_clk),
        .ui_clk_sync_rst(mig_ui_sync_reset),
        .mmcm_locked(mig_mmcm_locked),
        .aresetn(mig_axi_aresetn),
        .init_calib_complete(init_calib_complete),
        .device_temp(device_temp),

        // Refresh and ZQ calibration remain under MIG's automatic policy.
        // These request ports are for optional application-forced events.
        .app_sr_req(1'b0),
        .app_ref_req(1'b0),
        .app_zq_req(1'b0),
        .app_sr_active(_unused_app_status[0]),
        .app_ref_ack(_unused_app_status[1]),
        .app_zq_ack(_unused_app_status[2]),

        .s_axi_awid(s_axi_awid),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),
        .s_axi_awlock(s_axi_awlock),
        .s_axi_awcache(s_axi_awcache),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awqos(s_axi_awqos),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),

        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),

        .s_axi_bid(s_axi_bid),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),

        .s_axi_arid(s_axi_arid),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),
        .s_axi_arlock(s_axi_arlock),
        .s_axi_arcache(s_axi_arcache),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arqos(s_axi_arqos),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),

        .s_axi_rid(s_axi_rid),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready)
    );

endmodule
