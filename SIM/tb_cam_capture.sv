`timescale 1ns / 1ps
import video_pkg::*; // Make sure your video_pkg is compiled in the sim sources!

module tb_cam_capture();

    // 1. Generate the 24MHz Camera Clock (approx 41.66ns period)
    logic pclk = 0;
    always #20.83 pclk = ~pclk;

    // 2. Declare Signals
    logic rst_n;
    logic [7:0] i_cam_data;
    logic i_vsync;
    logic i_href;
    logic i_init_done;
    
    pixel_t cam_packed;

    cam_capture_data #(
        .H_ACTIVE(640), 
        .V_ACTIVE(480)
    ) DUT (
        .pclk(pclk),
        .rst_n(rst_n),
        .i_cam_data(i_cam_data),
        .i_vsync(i_vsync),
        .i_href(i_href),
        .i_init_done(i_init_done),
        .cam_packed(cam_packed)
    );

    initial begin
        rst_n = 0;
        i_cam_data = 8'h00;
        i_vsync = 0;
        i_href = 0;
        i_init_done = 0;

        #100;
        rst_n = 1;
        #100;

        // Simulate I2C Finishing
        $display("--- I2C Configuration Done ---");
        i_init_done = 1;
        #200;

        $display("--- Starting Frame 1 (Ignored) ---");
        i_vsync = 1; #100; i_vsync = 0; // VSYNC Pulse (Start of Frame)
        #200; // Wait a bit
        i_vsync = 1; #100; i_vsync = 0; // VSYNC Pulse (End of Frame)
        #200;

        $display("--- Starting Frame 2 (Valid) ---");
        i_vsync = 1; #100; i_vsync = 0; // VSYNC Pulse (Start of Valid Frame)
        #200; // Wait for Vertical Back Porch
        @(posedge pclk)
        // Send 4 lines of 4 pixels
        for (int y = 0; y < 480; y++) begin
            
            i_href = 1; // Start of Line
            
            for (int x = 0; x < 640; x++) begin
                // Byte 1
                i_cam_data = 8'hAA; // Fake Data
                @(posedge pclk);
                //byte 2
                i_cam_data = 8'hBB; // Fake Data
                @(posedge pclk);
            end
            
            i_href = 0; // End of Line
            #100; // Wait for Horizontal Blanking
            @(posedge pclk);
        end

        i_vsync = 1; #100; i_vsync = 0; 
        
        #500;
        $display("--- Simulation Complete ---");
        $finish;
    end

endmodule