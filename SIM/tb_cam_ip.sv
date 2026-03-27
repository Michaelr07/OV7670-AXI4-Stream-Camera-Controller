`timescale 1ns / 1ps
`default_nettype none

import video_pkg::*;
import cam_i2c_pkg::*;

module tb_cam_ip();

    logic clk = 0;          // 100 MHz System Clock
    logic pclk = 0;         // 24 MHz Camera Pixel Clock
    logic sys_rst_n = 0;
    logic pclk_rst_n = 0;

    always #5 clk = ~clk;          
    always #20.83 pclk = ~pclk;    


    localparam int H_ACTIVE = 10;   
    localparam int V_ACTIVE = 10;
    
    logic       CAM_VSYNC = 0;
    logic       CAM_HREF = 0;
    logic [7:0] CAM_D = '0;
    logic       CAM_RSTN;
    logic       CAM_PWDN;
    
    logic sda_i, sda_o, sda_t;
    logic scl_i, scl_o, scl_t;
    

    logic LED_I2C_DONE;
    logic LED_I2C_ERROR;

    // AXI-Stream Output
    logic [15:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready = 1; // Fake VDMA is always ready
    logic        m_axis_tuser;
    logic        m_axis_tlast;


    wire sda;
    wire scl;
    
    pullup(sda);
    pullup(scl);

    assign sda = (sda_t == 1'b0) ? sda_o : 1'bz;
    assign sda_i = sda;

    assign scl = (scl_t == 1'b0) ? scl_o : 1'bz;
    assign scl_i = scl;

    ov7670_axis_cam #(
        .H_ACTIVE(H_ACTIVE),
        .V_ACTIVE(V_ACTIVE)
    ) DUT (
        .clk(clk),
        .sys_clk_rstn(sys_rst_n),
        .pclk_rstn(pclk_rst_n),
        
        .CAM_PCLK(pclk),
        .CAM_VSYNC(CAM_VSYNC),
        .CAM_HREF(CAM_HREF),
        .CAM_D(CAM_D),
        .CAM_RSTN(CAM_RSTN),
        .CAM_PWDN(CAM_PWDN),
        
        .sda_i(sda_i), .sda_o(sda_o), .sda_t(sda_t),
        .scl_i(scl_i), .scl_o(scl_o), .scl_t(scl_t),
        
        .LED_I2C_DONE(LED_I2C_DONE),
        .LED_I2C_ERROR(LED_I2C_ERROR),
        
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tuser(m_axis_tuser),
        .m_axis_tlast(m_axis_tlast)
    );


    i2c_slave_ack_bfm #(
        .SLAVE_ADDR7(7'h21),
        .REGISTER_WIDTH(256)
    ) FAKE_CAMERA_I2C (
        .clk(clk),              // BFM uses 100MHz to oversample
        .rst_n(sys_rst_n),
        .sda(sda),
        .scl(scl)
    );


    task send_fake_frame();
        $display("[%0t] Starting Fake Camera Frame...", $time);
        
        // VSYNC Pulse (Signals start of frame)
        CAM_VSYNC = 1'b1;
        repeat(50) @(posedge pclk);
        CAM_VSYNC = 1'b0;
        
        // Vertical Back Porch (Delay before rows start)
        repeat(50) @(posedge pclk);
        
        // Send Rows
        for (int y = 0; y < V_ACTIVE; y++) begin
            CAM_HREF = 1'b1; // Signals valid data on the line
            
            // Send Columns (Pixels)
            for (int x = 0; x < H_ACTIVE; x++) begin
                // The OV7670 sends 1 pixel over 2 clock cycles (Byte 1, then Byte 2)
                
                // Byte 1 (e.g., RRGGG)
                CAM_D = 8'hAA; 
                @(posedge pclk);
                
                // Byte 2 (e.g., GGBBB)
                CAM_D = 8'h55; 
                @(posedge pclk);
            end
            
            CAM_HREF = 1'b0; // End of row
            
            // Horizontal Blanking (Delay between rows)
            repeat(20) @(posedge pclk);
        end
        
        // Vertical Front Porch (Delay before next VSYNC)
        repeat(50) @(posedge pclk);
        $display("[%0t] Fake Camera Frame Complete.", $time);
    endtask


    initial begin
        $display("=== OV7670 Integration Testbench Started ===");
        
        sys_rst_n = 0;
        pclk_rst_n = 0;
        #100;

        sys_rst_n = 1;
        pclk_rst_n = 1;
        
        $display("[%0t] Waiting for I2C Sequencer...", $time);
        wait (LED_I2C_DONE == 1'b1 || LED_I2C_ERROR == 1'b1);
        
        if (LED_I2C_ERROR) begin
            $error("[%0t] I2C Sequencer FAILED! Check BFM connections.", $time);
            $finish;
        end else begin
            $display("[%0t] I2C Sequencer SUCCESS! Camera configured.", $time);
        end
        
        $display("[%0t] Sending Warmup Frame (Will be ignored by DUT)...", $time);
        send_fake_frame();
        
        $display("[%0t] Sending Active Frame (Monitor AXI Bus!)...", $time);
        send_fake_frame();


        #1000;
        $display("=== Testbench Complete ===");
        $finish;
    end

endmodule