`timescale 1ns / 1ps
`default_nettype none

import video_pkg::*;

// Camera Capture Module (OV7670 Compatible)
// Collects pixel data and generates RGB444 or RGB565 pixels.
//
// Features:
//   Handles VSYNC/HREF synchronization
//   Skips first frame after camera init for stabilization
//   Outputs valid pixel_t + write enable for FIFO/memory

module cam_capture_data
#(
    parameter int H_ACTIVE = 640,
    parameter int V_ACTIVE = 480
)
(
    input  wire logic                                   pclk,
    input  wire logic                                   rst_n,
    input  wire logic [7:0]                             i_cam_data,
    input  wire logic                                   i_vsync,
    input  wire logic                                   i_href,
    input  wire logic                                   i_init_done,

    output pixel_t                                      cam_packed
);
    
    localparam int RGB_W = $bits({cam_packed.r,cam_packed.g,cam_packed.b});
    
    logic sof_i;
    logic eof_i;
    
    logic [7:0]      cam_data;
    logic                   vsync, vsync_d, href, href_d;
    
    
    // 1 cycle delay
    always_ff @(posedge pclk) begin
        if (!rst_n) begin
            {vsync, vsync_d}        <= '0;
            {href,  href_d}         <= '0;
            cam_data                <= '0;
        end else begin
            {vsync_d, vsync}        <= {vsync, i_vsync};
            {href_d, href}          <= {href,  i_href };
            cam_data                <= i_cam_data;
        end
    end

    // 2 cycle delay
    assign sof_i  =  vsync_d & ~vsync; // VSYNC falling = start of frame
    assign eof_i  = ~vsync_d &  vsync; // VSYNC rising  = end of frame
  //  assign eol_i  =  href_d  & ~href;  // HREF falling  = end of line
    
    // Byte Phase Tracking
    logic [7:0] byte_1;
    logic byte_phase;

    always_ff @(posedge pclk)
        if (!rst_n || !href)
            byte_phase <= 1'b0;
        else
            byte_phase <= ~byte_phase;

    // Skip first frame after init (OV7670 warm-up)
    logic skip_frame;
    always_ff @(posedge pclk)
        if (!rst_n)
            skip_frame <= 1'b1;
        else if (eof_i && i_init_done)
            skip_frame <= 1'b0;



    // FSM: Capture and Pixel Packing
    typedef enum logic [1:0] {IDLE, CAPTURE, FRAME_DONE} state_t;
    state_t state, next;

    always_ff @(posedge pclk)
        if (!rst_n) state <= IDLE;
        else          state <= next;

    always_comb begin
        next = state;
        case (state)
            IDLE       : if (sof_i && i_init_done && !skip_frame) next = CAPTURE;
            CAPTURE    : if (eof_i)                               next = FRAME_DONE;
            FRAME_DONE : if (sof_i)                               next = CAPTURE;
            default    : next = IDLE;
        endcase
    end

    // Capture Logic
    always_ff @(posedge pclk) begin
        if (!rst_n) begin
            byte_1          <= '0;
            cam_packed      <= '0;
        end else begin
            // This absorbs OV7670 clock jitter perfectly.
            if (!href) begin
                cam_packed.x  <= '0;
            end
            
            cam_packed.de   <= 1'b0;
            cam_packed.sof  <= 1'b0;
            cam_packed.eol  <= 1'b0;
            
            if (sof_i) {cam_packed.x, cam_packed.y}     <= '0;
            
            if (state == CAPTURE) begin
                if(href) begin
                    if (!byte_phase) begin    
                        byte_1          <= cam_data;
                    end else begin
                        cam_packed.de   <= 1'b1;  
                        cam_packed.sof <= (cam_packed.x == 0 && cam_packed.y == 0);
                        cam_packed.eol <= (cam_packed.x == H_ACTIVE - 1);
                       // cam_packed.eof <= (cam_packed.x == T.H_ACTIVE - 1) && (cam_packed.y == T.V_ACTIVE - 1);
                        cam_packed.x    <= cam_packed.x + 1;
                        
                        if (cam_packed.x == H_ACTIVE-1) begin
                            if (cam_packed.y == V_ACTIVE-1) begin
                                cam_packed.y    <= '0;
                            end else begin
                                cam_packed.y    <= cam_packed.y + 1;
                            end
                        end
                        
                        if (RGB_W == 12) begin
                            // RGB444: {R[3:0], G[3:0], B[3:0]}
                            cam_packed.r    <= byte_1[3:0];
                            cam_packed.g    <= cam_data[7:4];
                            cam_packed.b    <= cam_data[3:0];
                        end else if (RGB_W == 16) begin
                            // RGB565
                            cam_packed.r    <= byte_1[7:3];
                            cam_packed.g    <= {byte_1[2:0], cam_data[7:5]};
                            cam_packed.b    <= cam_data[4:0];
                        end
                    end
                    
                end
            end
        end
    end

endmodule

`default_nettype wire
