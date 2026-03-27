`timescale 1ns/1ps

import video_pkg::*;
import cam_i2c_pkg::*;

module ov7670_axis_cam 
#(
    parameter int H_ACTIVE = 640,
    parameter int V_ACTIVE = 480
)
(
    input  logic        clk,
    input  logic        sys_clk_rstn,
    input  logic        pclk_rstn,
    
    // Physical Camera Pins
    // Physical Camera Pins
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CAM_PCLK CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, FREQ_HZ 24000000" *)
    input  logic        CAM_PCLK,               
    input  logic        CAM_VSYNC, 
    input  logic        CAM_HREF,
    input  logic [7:0]  CAM_D,                  
    output logic        CAM_RSTN, 
    output logic        CAM_PWDN,
    
    input  wire sda_i,
    output wire sda_o,
    output wire sda_t,
    
    input  wire scl_i,
    output wire scl_o,
    output wire scl_t,
    
    output logic LED_I2C_DONE,
    output logic LED_I2C_ERROR,

    // AXI4-Stream Master Output
    output logic [15:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready, // Ignored by camera, but required by standard
    output logic        m_axis_tuser,
    output logic        m_axis_tlast
);
    
    assign CAM_PWDN = 1'b0;
    assign CAM_RSTN = 1'b1;
    
    localparam vid_timing_t T = TIMING_VGA_640x480;
    
    localparam int N_CMDS = 77; 
    cam_i2c_pkg::cmd_t init_cmds [N_CMDS];
    
    ov7670_rom_rgb444_vga_cmds #(.DLY_MS(1), .N(N_CMDS)) u_rom (.cmds(init_cmds)); // currently only compatible with RGB444
    
// 10 Millisecond Boot Delay (1,000,000 clock cycles at 100 MHz)
    logic [19:0] boot_timer;
    logic cfg_start_reg;

    always_ff @(posedge clk or negedge sys_clk_rstn) begin
        if (!sys_clk_rstn) begin
            boot_timer <= 0;
            cfg_start_reg <= 0;
        end else begin
            if (boot_timer < 20'd1_000_000) begin
                boot_timer <= boot_timer + 1;
                cfg_start_reg <= 0;
            end else if (boot_timer == 20'd1_000_000) begin
                boot_timer <= boot_timer + 1;
                cfg_start_reg <= 1'b1; // Send exactly one pulse to start I2C
            end else begin
                cfg_start_reg <= 0;
            end
        end
    end
    
    assign cfg_start = cfg_start_reg;
    
    logic wr_start, wr_done, wr_busy, wr_ackerr;
    logic [6:0] wr_dev_addr7;
    logic [7:0] wr_reg, wr_val;
    logic seq_busy, seq_done, seq_err;
    
    cam_i2c_sequencer #(
        .CLK_HZ(100_000_000), .USE_TICK(0), .DEV_ADDR7(7'h21), .N_CMDS(N_CMDS), .MAX_RETRIES(3)
    ) u_seq (
        .clk(clk), .rst_n(sys_clk_rstn), .start(cfg_start), .busy(seq_busy), .done(seq_done),
        .error(seq_err), .tick_1ms(1'b0), .cmds(init_cmds), .wr_start(wr_start),
        .wr_dev_addr7(wr_dev_addr7), .wr_reg(wr_reg), .wr_val(wr_val),
        .wr_busy(wr_busy), .wr_done(wr_done), .wr_ackerr(wr_ackerr)
    );
    
    i2c_controller #(
        .SYS_CLK(100_000_000), .I2C_SPEED(100_000), .STRETCH_EN(1)
    ) u_i2c (
        .clk(clk), .rst_n(sys_clk_rstn), .wr_start(wr_start), .wr_dev_addr7(wr_dev_addr7),
        .wr_reg(wr_reg), .wr_val(wr_val), .wr_busy(wr_busy), .wr_done(wr_done),
        .wr_ackerr(wr_ackerr), .sda_i(sda_i),.sda_o(sda_o),.sda_t(sda_t),.scl_i(scl_i),.scl_o(scl_o),.scl_t(scl_t)
    );

    (* ASYNC_REG = "TRUE" *) logic [1:0] seq_done_sync;
    always_ff @(posedge CAM_PCLK or negedge pclk_rstn) begin
        if (!pclk_rstn) seq_done_sync <= 2'b00;
        else            seq_done_sync <= {seq_done_sync[0], seq_done};
    end
        
    pixel_t pixel_cam;
    
    cam_capture_data #( .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE)) camera_data (
        .pclk(CAM_PCLK), 
        .rst_n(pclk_rstn),
        .i_cam_data(CAM_D),
        .i_vsync(CAM_VSYNC),
        .i_href(CAM_HREF),
        .i_init_done(seq_done_sync[1]),
        .cam_packed(pixel_cam)
    );
        

    always_ff @(posedge CAM_PCLK or negedge pclk_rstn) begin
        if (!pclk_rstn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tdata  <= '0;
        end else begin
            if (m_axis_tready || !m_axis_tvalid) begin
                m_axis_tvalid <= pixel_cam.de;
                m_axis_tdata  <= {4'b0000, pixel_cam.r, pixel_cam.g, pixel_cam.b};
                m_axis_tuser  <= pixel_cam.sof;
                m_axis_tlast  <= pixel_cam.eol;
            end

        end
    end

    assign LED_I2C_DONE = seq_done;
    assign LED_I2C_ERROR = seq_err;

endmodule