// -----------------------------------------------------------------------------
// 1. SYSTEMVERILOG INTERFACES
// -----------------------------------------------------------------------------
// Interface for the Fast CPU Domain (100 MHz)
interface sys_if(input logic clk, input logic rst_n);
    logic        req;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic        write;
    logic [2:0]  pprot;
    logic [3:0]  pstrb;
    logic        ready;
endinterface

// Interface for the Slow APB Peripheral Domain (40 MHz)
interface apb_if(input logic pclk, input logic preset_n);
    logic [31:0] paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic [2:0]  pprot;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic        pready;
    logic        pslverr;
endinterface

// -----------------------------------------------------------------------------
// 2. TRANSACTION & COVERAGE CLASSES
// -----------------------------------------------------------------------------
class apb_transaction;
    rand bit [31:0] paddr;
    rand bit [31:0] pwdata;
    rand bit        pwrite;
    rand bit [2:0]  pprot;
    rand bit [3:0]  pstrb;
    
    bit [31:0]      prdata;
    bit             pslverr;

    // Constrain addresses to the 256-word memory space
    constraint c_addr { paddr inside {[32'h0000_0000 : 32'h0000_00FF]}; }
    constraint c_strb { pstrb == 4'hF; }
endclass

class apb_coverage;
    apb_transaction tr;
    
    covergroup apb_cg;
        option.per_instance = 1;
        // Did we verify both Reads and Writes?
        cp_pwrite:  coverpoint tr.pwrite { bins write={1}; bins read={0}; }
        // Did we verify both Secure and Non-Secure accesses?
        cp_pprot:   coverpoint tr.pprot[1] { bins secure={0}; bins non_secure={1}; }
        // Did the Firewall successfully block unauthorized traffic?
        cp_pslverr: coverpoint tr.pslverr { bins granted={0}; bins blocked={1}; }
        
        // Cross Coverage Matrix
        cross_op_security: cross cp_pwrite, cp_pprot;
        cross_security_firewall: cross cp_pprot, cp_pslverr;
    endgroup

    function new(); apb_cg = new(); endfunction
    function void sample(apb_transaction t); this.tr = t; apb_cg.sample(); endfunction
endclass

// -----------------------------------------------------------------------------
// 3. GENERATOR & DRIVER (Operates on Fast Clock)
// -----------------------------------------------------------------------------
class apb_generator;
    apb_transaction tr;
    mailbox #(apb_transaction) gen2drv;
    
    function new(mailbox #(apb_transaction) mbox); this.gen2drv = mbox; endfunction

    task run(int num_tx);
        for (int i = 0; i < num_tx; i++) begin
            tr = new();
            if(!tr.randomize()) $fatal("Randomization failed!");
            gen2drv.put(tr);
        end
    endtask
endclass

class apb_driver;
    virtual sys_if vif;
    mailbox #(apb_transaction) gen2drv;

    function new(virtual sys_if vif, mailbox #(apb_transaction) mbox);
        this.vif = vif; this.gen2drv = mbox;
    endfunction

    task run();
        forever begin
            apb_transaction tr;
            gen2drv.get(tr);

            // Wait for the Fast Clock edge and check if the CDC FIFO is ready
            @(posedge vif.clk);
            wait(vif.ready == 1'b1);
            
            // Push data into the Asynchronous FIFO
            vif.req   <= 1'b1;
            vif.addr  <= tr.paddr;
            vif.wdata <= tr.pwdata;
            vif.write <= tr.pwrite;
            vif.pprot <= tr.pprot;
            vif.pstrb <= tr.pstrb;

            @(posedge vif.clk);
            vif.req <= 1'b0;
            
            // Wait to prevent overflowing the 16-deep FIFO during fast blasts
            repeat(5) @(posedge vif.clk);
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 4. MONITOR (Operates on Slow Clock)
// -----------------------------------------------------------------------------
class apb_monitor;
    virtual apb_if vif;
    apb_coverage cov;

    function new(virtual apb_if vif, apb_coverage cov);
        this.vif = vif; this.cov = cov;
    endfunction

    task run();
        forever begin
            @(posedge vif.pclk);
            // Sample data only when a transfer completes successfully on the slow bus
            if (vif.psel && vif.penable && vif.pready) begin
                apb_transaction tr = new();
                tr.paddr   = vif.paddr;
                tr.pwrite  = vif.pwrite;
                tr.pprot   = vif.pprot;
                tr.prdata  = vif.prdata;
                tr.pslverr = vif.pslverr;
                cov.sample(tr);
                
                $display("[%0t] MONITOR: APB Tx Captured - Addr: %h, Secure: %b, SlvErr: %b", 
                         $time, tr.paddr, ~tr.pprot[1], tr.pslverr);
            end
        end
    endtask
endclass

// -----------------------------------------------------------------------------
// 5. TOP LEVEL ENVIRONMENT & TB MODULE
// -----------------------------------------------------------------------------
module tb_top;
    logic sys_clk, sys_rst_n;
    logic pclk, preset_n;
    
    // Fast System Clock (100 MHz)
    initial begin sys_clk = 0; forever #5 sys_clk = ~sys_clk; end
    
    // Slow APB Clock (40 MHz)
    initial begin pclk = 0; forever #12.5 pclk = ~pclk; end

    // Instantiate Interfaces
    sys_if s_if(sys_clk, sys_rst_n);
    apb_if p_if(pclk, preset_n);
    
    // Instantiate the Full SoC Design (CDC Bridge + APB FSM + Firewall)
    apb_cdc_soc_top dut (
        .sys_clk   (s_if.clk), 
        .sys_rst_n (s_if.rst_n),
        .pclk      (p_if.pclk), 
        .preset_n  (p_if.preset_n),
        
        .sys_req   (s_if.req),
        .sys_addr  (s_if.addr),
        .sys_wdata (s_if.wdata),
        .sys_write (s_if.write),
        .sys_pprot (s_if.pprot),
        .sys_pstrb (s_if.pstrb),
        .sys_ready (s_if.ready),
        
        // Monitor connections directly to the slow bus pins
        .mon_paddr   (p_if.paddr), 
        .mon_pwdata  (p_if.pwdata), 
        .mon_prdata  (p_if.prdata),
        .mon_pprot   (p_if.pprot),
        .mon_psel    (p_if.psel), 
        .mon_penable (p_if.penable), 
        .mon_pwrite  (p_if.pwrite), 
        .mon_pready  (p_if.pready), 
        .mon_pslverr (p_if.pslverr)
    );

    // Environment Components
    mailbox #(apb_transaction) gen2drv;
    apb_generator gen;
    apb_driver    drv;
    apb_monitor   mon;
    apb_coverage  cov;

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_top);

        // Init Components
        gen2drv = new();
        cov = new();
        gen = new(gen2drv);
        drv = new(s_if, gen2drv);
        mon = new(p_if, cov);

        // Reset Sequence
        sys_rst_n = 0; preset_n = 0;
        s_if.req = 0;
        #50; 
        sys_rst_n = 1; preset_n = 1;

        $display("=================================================");
        $display("   STARTING CADENCE XCELIUM UVM-LITE TESTBENCH   ");
        $display("=================================================");

        // Start TB Agents
        fork
            drv.run();
            mon.run();
            gen.run(2000); // Increased from 200 to 2000 to guarantee 100% coverage
        join_any

        #1000; // Let final transactions drain out of the CDC FIFO
        
        $display("=================================================");
        $display("   DUAL-DOMAIN VERIFICATION COMPLETE             ");
        $display("   Functional Coverage Score: %0.2f%%            ", cov.apb_cg.get_inst_coverage());
        $display("=================================================");
        $finish;
    end
endmodule
