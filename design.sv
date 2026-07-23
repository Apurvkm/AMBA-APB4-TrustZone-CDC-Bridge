// ============================================================================
// 1. GRAY CODE CONVERTERS
// ============================================================================
module bin2gray #(parameter PTR_WIDTH = 4) (
    input  logic [PTR_WIDTH-1:0] bin,
    output logic [PTR_WIDTH-1:0] gray
);
    assign gray = bin ^ (bin >> 1);
endmodule

// ============================================================================
// 2. ASYNCHRONOUS FIFO (72-bit Payload)
// ============================================================================
module async_fifo #(
    parameter DATA_WIDTH = 72, // {PPROT[2:0], PSTRB[3:0], PWRITE, PADDR[31:0], PWDATA[31:0]}
    parameter ADDR_WIDTH = 4
)(
    input  logic                  wclk, wrst_n, winc,
    input  logic [DATA_WIDTH-1:0] wdata,
    output logic                  wfull,
    input  logic                  rclk, rrst_n, rinc,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic                  rempty
);
    logic [ADDR_WIDTH:0] wbin, wptr, wnext, wgnext;
    logic [ADDR_WIDTH:0] rbin, rptr, rnext, rgnext;
    logic [ADDR_WIDTH:0] wq1_rptr, wq2_rptr;
    logic [ADDR_WIDTH:0] rq1_wptr, rq2_wptr;
    logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    always_ff @(posedge wclk) begin
        if (winc && !wfull) mem[wbin[ADDR_WIDTH-1:0]] <= wdata;
    end
    assign rdata = mem[rbin[ADDR_WIDTH-1:0]];

    assign wnext  = wbin + (winc & ~wfull);
    assign wgnext = wnext ^ (wnext >> 1);
    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) {wbin, wptr} <= '0;
        else         {wbin, wptr} <= {wnext, wgnext};
    end

    assign rnext  = rbin + (rinc & ~rempty);
    assign rgnext = rnext ^ (rnext >> 1);
    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) {rbin, rptr} <= '0;
        else         {rbin, rptr} <= {rnext, rgnext};
    end

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) {wq2_rptr, wq1_rptr} <= '0;
        else         {wq2_rptr, wq1_rptr} <= {wq1_rptr, rptr};
    end

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) {rq2_wptr, rq1_wptr} <= '0;
        else         {rq2_wptr, rq1_wptr} <= {rq1_wptr, wptr};
    end

    assign rempty = (rptr == rq2_wptr);
    assign wfull  = (wgnext == {~wq2_rptr[ADDR_WIDTH:ADDR_WIDTH-1], wq2_rptr[ADDR_WIDTH-2:0]});
endmodule

// ============================================================================
// 3. APB4 MASTER FSM
// ============================================================================
module apb_master_fsm (
    input  logic        pclk, preset_n,
    input  logic        fifo_empty,
    input  logic [71:0] fifo_rdata,
    output logic        fifo_pop,
    
    // APB Bus Outputs
    output logic [31:0] paddr,
    output logic [31:0] pwdata,
    output logic        pwrite,
    output logic [2:0]  pprot,
    output logic [3:0]  pstrb,
    output logic        psel,
    output logic        penable,
    input  logic        pready,
    input  logic        pslverr
);
    typedef enum logic [1:0] {IDLE, SETUP, ACCESS} state_t;
    state_t state, next_state;

    logic [31:0] l_addr, l_wdata;
    logic        l_write;
    logic [2:0]  l_pprot;
    logic [3:0]  l_pstrb;

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) state <= IDLE;
        else           state <= next_state;
    end

    always_comb begin
        next_state = state;
        fifo_pop   = 1'b0;
        case (state)
            IDLE:  if (!fifo_empty) begin fifo_pop = 1'b1; next_state = SETUP; end
            SETUP: next_state = ACCESS;
            ACCESS: if (pready || pslverr) begin
                if (!fifo_empty) begin fifo_pop = 1'b1; next_state = SETUP; end
                else next_state = IDLE;
            end
        endcase
    end

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) {l_pprot, l_pstrb, l_write, l_addr, l_wdata} <= '0;
        else if (fifo_pop) {l_pprot, l_pstrb, l_write, l_addr, l_wdata} <= fifo_rdata;
    end

    assign psel    = (state == SETUP || state == ACCESS);
    assign penable = (state == ACCESS);
    assign paddr   = l_addr;
    assign pwdata  = l_wdata;
    assign pwrite  = l_write;
    assign pprot   = l_pprot;
    assign pstrb   = l_pstrb;
endmodule

// ============================================================================
// 4. APB4 TRUSTZONE FIREWALL (THE SLAVE)
// ============================================================================
module apb4_trustzone_firewall (
    input  logic        pclk, preset_n,
    input  logic [31:0] paddr,
    input  logic [2:0]  pprot,
    input  logic        psel, penable, pwrite,
    input  logic [31:0] pwdata,
    output logic        pready,
    output logic [31:0] prdata,
    output logic        pslverr
);
    logic [31:0] mem [0:255]; 
    logic is_secure_addr, access_violation;

    assign is_secure_addr = (paddr < 32'h0000_0080);
    assign access_violation = is_secure_addr && (pprot[1] == 1'b1); // Non-secure accessing secure!

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            prdata <= '0;
            pready <= 1'b0;
            pslverr <= 1'b0;
        end else begin
            pready <= 1'b0;
            pslverr <= 1'b0;
            if (psel && !penable) begin
                pready <= 1'b1; // Zero wait state response
                if (access_violation) begin
                    pslverr <= 1'b1;
                    prdata  <= 32'hDEADBEEF; // Blocked read
                end else if (pwrite) begin
                    mem[paddr[7:0]] <= pwdata;
                end else begin
                    prdata <= mem[paddr[7:0]];
                end
            end
        end
    end
endmodule

// ============================================================================
// 5. TOP LEVEL SOC SUBSYSTEM
// ============================================================================
module apb_cdc_soc_top (
    input  logic        sys_clk, sys_rst_n,
    input  logic        pclk, preset_n,
    
    // Fast CPU Interface
    input  logic        sys_req,
    input  logic [31:0] sys_addr,
    input  logic [31:0] sys_wdata,
    input  logic        sys_write,
    input  logic [2:0]  sys_pprot,
    input  logic [3:0]  sys_pstrb,
    output logic        sys_ready,
    
    // Expose APB pins for the Testbench Monitor
    output logic [31:0] mon_paddr, mon_pwdata, mon_prdata,
    output logic [2:0]  mon_pprot,
    output logic        mon_psel, mon_penable, mon_pwrite, mon_pready, mon_pslverr
);
    logic fifo_full, fifo_empty, fifo_pop;
    logic [71:0] fifo_rdata;

    assign sys_ready = !fifo_full;

    async_fifo u_fifo (
        .wclk(sys_clk), .wrst_n(sys_rst_n),
        .winc(sys_req && !fifo_full),
        .wdata({sys_pprot, sys_pstrb, sys_write, sys_addr, sys_wdata}),
        .wfull(fifo_full),
        
        .rclk(pclk), .rrst_n(preset_n),
        .rinc(fifo_pop), .rdata(fifo_rdata), .rempty(fifo_empty)
    );

    apb_master_fsm u_fsm (
        .pclk(pclk), .preset_n(preset_n),
        .fifo_empty(fifo_empty), .fifo_rdata(fifo_rdata), .fifo_pop(fifo_pop),
        
        .paddr(mon_paddr), .pwdata(mon_pwdata), .pwrite(mon_pwrite),
        .pprot(mon_pprot), .pstrb(), .psel(mon_psel), .penable(mon_penable),
        .pready(mon_pready), .pslverr(mon_pslverr)
    );

    apb4_trustzone_firewall u_slave (
        .pclk(pclk), .preset_n(preset_n),
        .paddr(mon_paddr), .pprot(mon_pprot), .psel(mon_psel), 
        .penable(mon_penable), .pwrite(mon_pwrite), .pwdata(mon_pwdata),
        .pready(mon_pready), .prdata(mon_prdata), .pslverr(mon_pslverr)
    );
endmodule
