// Description:
//   Parameterized I2C master controller supporting both write and read
//   transactions using the standard 7-bit addressing mode.
//   Generates start, stop, and optional repeated-start conditions,
//   supports clock stretching, and provides streaming-style interfaces
//   for data in/out.

`timescale 1ns / 1ps
`default_nettype none

  module i2c_master #(
    parameter int SYS_CLK       = 100_000_000,  //Hz
    parameter int I2C_SPEED     = 100_000,      //Hz
    parameter bit STRETCH_EN    = 1             //Clock stretching
) (
    input wire logic            clk,
    input wire logic            rst_n,
    
    // Command
    input  wire logic           start,          // pulse high to launch a transaction
    input  wire logic [6:0]     addr7,          // 7-bit slave address
    input  wire logic [7:0]     wr_len,         // number of bytes to write
    input  wire logic [7:0]     rd_len,         // number of bytes to read
                     
    output logic                busy,           // high during transaction
    output logic                done,           // 1-cycle pulse when complete
    output logic                nack_addr,      // address phase NACK
    output logic                nack_data,      // data phase NACK
    output logic                timeout,        // SCL held low too long (stretch fail)
                                       
    input wire logic [7:0]      wr_data,        // write data stream
    input wire logic            wr_valid,
    output logic                wr_ready,
    
    output logic [7:0]          rd_data,        // read data stream
    output logic                rd_valid,
    input wire logic            rd_ready,
    
    // I2C pins (open-drain)
    input  wire sda_i,
    output wire sda_o,
    output wire sda_t,
    
    input  wire scl_i,
    output wire scl_o,
    output wire scl_t
);

    logic sda_drv_low, scl_drv_low;
    logic sda_in;
    logic scl_in;
    
    // In Xilinx IOBUF: T=0 means drive the pin, T=1 means float/listen
    assign sda_o = 1'b0; // I2C only ever drives 0V
    assign sda_t = ~sda_drv_low; 
    
    assign scl_o = 1'b0;
    assign scl_t = ~scl_drv_low;

    // Make sure your sampling logic reads from the new input wires
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sda_in <= 1;
            scl_in <= 1;
        end
        else begin
            sda_in <= sda_i;
            scl_in <= scl_i;
        end
    end
    
    //assign sda_io = sda_drv_low ? 1'b0 : 1'bz;
    //assign scl_io = scl_drv_low ? 1'b0 : 1'bz;
    
//    always_ff @(posedge clk or negedge rst_n) begin
//        if (!rst_n)begin
//            sda_meta <= 1'b1;
//            scl_meta <= 1'b1;
//            sda_in   <= 1'b1;
//            scl_in   <= 1'b1;
//        end else begin
//            sda_meta <= sda_io;
//            sda_in   <= sda_meta;
//            scl_meta <= scl_io;
//            scl_in   <= scl_meta;
//        end
//    end
    
    //Divider for half period of scl
    localparam int unsigned DIV = (SYS_CLK + (2*I2C_SPEED - 1))/(2*I2C_SPEED);
    logic tick;
    
    n_counter #(.DIV(DIV)) clk_pulse (.clk(clk), .rst_n(rst_n), .en(1'b1), .done(tick));
    
    //START and STOP FSM
    logic [3:0] bit_counter;
    logic [7:0] shift_reg, rx_reg;
    
    //Control logic for write/read
    logic [7:0] tx_rem, rx_rem;   // remaining write bytes
    logic do_write, do_read, do_both, rw_bit;
    logic addr_byte, stop_bit;
    logic wr_accept;
    logic ack_on_read;
    
    typedef enum logic [4:0] {
        IDLE, 
        START_HI, START_FALL, START_HOLD,
        ADDR_LOAD,
        BYTE_LOAD, BIT_LOW, BIT_HIGH, 
        ACK_LOW, ACK_HIGH, ACK_CHECK,
        STALL, RESTART,
        STOP_PREP, STOP_RISE, DONE
    } 
        state_type;
        
    state_type next, state;
    
        //start edge detect (1 cycle pulse)
    logic start_q, start_qq, start_pulse, start_ok, repeated_start;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin 
            start_q     <= 1'b0; 
            start_qq    <= 1'b0;
        end else begin       
            start_q     <= start;
            start_qq    <= start_q;
        end
        
    assign ack_on_read  = (!addr_byte && do_read && (rx_rem > 8'd1));
        
    // stable, second-stage SCL edges inside clk domain
    logic scl_in_d;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) scl_in_d <= 1'b0;
        else        scl_in_d <= scl_in;
        
    logic phase_read, rd_handshake;                                       // 0=first phase, 1=after repeated START (read phase)
    logic scl_rise_sync, stall_read;
    
    assign scl_rise_sync =  scl_in & ~scl_in_d;             
    //assign scl_fall_sync = ~scl_in &  scl_in_d;
    assign stall_read = STRETCH_EN && do_read && !addr_byte && rd_valid && !rd_ready;
                 
    assign start_pulse      = ~start_qq & start_q;
    assign start_ok         = start_pulse && ((wr_len != 0) || (rd_len != 0)) && (state==IDLE);
    assign repeated_start   = (!addr_byte && do_both && do_write && (tx_rem == 0));
    assign stop_bit         = nack_addr || nack_data || ((!addr_byte && do_write && (tx_rem == 0))&& !do_both)
                                                 || (!addr_byte && do_read && (rx_rem == 0));
    
    //state register
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) state <= IDLE;
        else        state <= next;
    
    // state logic
    always_comb begin
        next = state;
        case (state)
            IDLE      : if (start_ok)           next = START_HI;
            
            START_HI  : if (scl_in && sda_in)   next = START_FALL;
            
            START_FALL:                         next = START_HOLD;
            
            START_HOLD: if (tick)               next = ADDR_LOAD;
            
            ADDR_LOAD :                         next = BIT_LOW;
            
            BYTE_LOAD : if (wr_accept)          next = BIT_LOW; 
            
            BIT_LOW:    if (tick)               next = BIT_HIGH;
            
            BIT_HIGH  : if (tick)               next = (bit_counter == 8)? ACK_LOW : BIT_LOW; // adjust for multi byte 
            
            ACK_LOW  :  if (tick)               next = ACK_HIGH;
            
            ACK_HIGH :  if (tick)               next = ACK_CHECK;
                 
            ACK_CHECK: begin
                        if (repeated_start)     next = RESTART;                       
                        else if (stop_bit)      next = STOP_PREP;
                        else if (do_write)      next = BYTE_LOAD;
                        else if (do_read)       next = (stall_read)? STALL : BIT_LOW;     
                        end
            
            STALL:                              next = (stall_read)? STALL : BIT_LOW;
            
            RESTART:    if (tick)               next = START_HI;
            STOP_PREP:  if (tick)               next = STOP_RISE;
            
            STOP_RISE:  if (tick && scl_in)     next = DONE;      
             
            DONE:                               next = IDLE;
            default:                            next = IDLE;
        endcase 
    end
 
    //OUTPUT REGISTER
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            nack_addr   <= 1'b0;
            nack_data   <= 1'b0;
            timeout     <= 1'b0; 
            rd_data     <= '0;
            sda_drv_low <= 1'b0;
            scl_drv_low <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            shift_reg   <= '0;
            rx_reg      <= '0;
            bit_counter <= '0;
            do_write    <= 1'b0;
            do_read     <= 1'b0;
            do_both     <= 1'b0;
            addr_byte   <= 1'b0;
            tx_rem      <= 1'b0;
            phase_read  <= 1'b0;
            rw_bit      <= 1'b0;
            wr_ready    <= 1'b0;
            wr_accept   <= 1'b0;
            rd_valid    <= 1'b0;
          	rd_handshake	<= 1'b0;
        end
        else begin
            // ---------------------------------------------------------
            // 1. STANDALONE READ HANDSHAKE (Evaluated every clock cycle)
            // ---------------------------------------------------------
            
            // Clear valid if upstream module accepted the data
            if (rd_valid && rd_ready) begin
                rd_valid <= 1'b0;
            end
            
            // ---------------------------------------------------------
            // 2. FSM OUTPUT LOGIC
            // ---------------------------------------------------------
            case (next)
                IDLE                    :   begin
                                                sda_drv_low <= 1'b0;
                                                scl_drv_low <= 1'b0;
                                                nack_addr   <= 1'b0;
                                                nack_data   <= 1'b0;
                                                timeout     <= 1'b0;
                                                // rd_data is intentionally NOT cleared here!
                                                done        <= 1'b0;
                                                busy        <= 1'b0;
                                                do_write    <= 1'b0;
                                                do_read     <= 1'b0;
                                                do_both     <= 1'b0;
                                                addr_byte   <= 1'b0;
                                                tx_rem      <= '0;
                                                rx_reg      <= '0;
                                                phase_read  <= 1'b0;
                                                rw_bit      <= 1'b0;
                                                wr_ready    <= 1'b0;
                                                wr_accept   <= 1'b0;
                  								rd_handshake <= 1'b0;
                                            end
                START_HI                :   begin
                                                sda_drv_low <= 1'b0;
                                                scl_drv_low <= 1'b0;
                                                busy        <= 1'b1;
                                                
                                                if (!phase_read) begin
                                                    do_both  <= (wr_len!=0) && (rd_len!=0);
                                                    do_write <= (wr_len!=0);
                                                    do_read  <= (rd_len!=0) && (wr_len==0);
                                                    tx_rem   <= wr_len;
                                                    rx_rem   <= rd_len;
                                                end                                                   
                                            end
                START_FALL, START_HOLD  :   begin
                                                sda_drv_low <= 1'b1;
                                                scl_drv_low <= 1'b0;
                                            end
                ADDR_LOAD               :   begin                                               
                                                sda_drv_low <= 1'b1;                          
                                                scl_drv_low <= 1'b1;
                                                addr_byte   <= 1'b1;
                                                if(tx_rem > 0)
                                                    shift_reg   <= {addr7,1'b0};
                                                else if (rx_rem > 0 && tx_rem == 0)
                                                    shift_reg   <= {addr7,1'b1};
                                            end    
                                            
                BYTE_LOAD               :   begin                                                                     
                                                scl_drv_low <= 1'b1;
                                                wr_ready    <= 1'b1;
                                                if (wr_valid && wr_ready) begin
                                                    wr_ready    <= 1'b0;
                                                    shift_reg   <= wr_data;
                                                    wr_accept   <= 1'b1;
                                                end   
                                                if (do_write)
                                                    sda_drv_low <= 1'b1;      
                                                else 
                                                    sda_drv_low <= 1'b0;                
                                            end
                BIT_LOW                 :   begin
                                                scl_drv_low <= 1'b1;
                                                wr_accept   <= 1'b0;
                                                if (do_write || addr_byte)
                                                    sda_drv_low <= (shift_reg[7])? 1'b0 : 1'b1;
                                                else if (do_read)
                                                    sda_drv_low <= 1'b0;
                                            end
                BIT_HIGH                :   begin
                                                scl_drv_low <= 1'b0;
                                                if (scl_rise_sync) begin
                                                    bit_counter <= bit_counter + 1;
                                                    if (do_write || addr_byte)
                                                        shift_reg   <= {shift_reg[6:0],1'b0};
                                                  else if (do_read) begin
                                                        rx_reg      	<= {rx_reg[6:0], sda_in};
                                                    	rd_handshake	<= 1;
                                                  end
                                               end
                                            end
                ACK_LOW                 :   begin
                                                scl_drv_low <= 1'b1;
                                                bit_counter <= '0;
                                                if (do_write)
                                                    sda_drv_low <= 1'b0;  
                                                else if (do_read) begin
                                                    sda_drv_low <= ack_on_read? 1'b1 : 1'b0; 
                                                  if (rd_handshake) begin
                                                    rd_data		<= rx_reg;
                                                    rd_valid	<= 1'b1;
                                                    rd_handshake<= 1'b0;
                                                  end
                                                end
                                            end
                ACK_HIGH                :   begin
                                                scl_drv_low <= 1'b0;
                                                if (scl_rise_sync) begin
                                                    if (addr_byte) begin
                                                       nack_addr <= sda_in;
                                                    end else if (do_write) begin
                                                       nack_data <= sda_in;
                                                    end  
                                                end
                                            end
                ACK_CHECK               :   begin
                                            if (!nack_data && do_write && !addr_byte && tx_rem != 0)
                                                tx_rem      <= tx_rem - 1;
                                            else if (do_read && !addr_byte && rx_rem != 0)
                                                rx_rem      <= rx_rem - 1;
                                            else
                                                addr_byte <= 1'b0;
                                            end     
                STALL                   :   begin
                                                scl_drv_low <= 1'b1;   // stretch   
                                            end    
                RESTART                 :   begin
                                              scl_drv_low <= 1'b1;     // pull SCL low
                                              sda_drv_low <= 1'b0;     // release SDA
                                              do_write    <= 1'b0;
                                              do_read     <= 1'b1;     // prepare read phase
                                              phase_read  <= 1'b1;
                                            end
                STOP_PREP               :   begin
                                                sda_drv_low <= 1'b1;
                                                scl_drv_low <= 1'b1;    // release SCL used to be 1
                                            end 
                STOP_RISE               :   begin
                                                sda_drv_low <= (scl_in)? 1'b0 : 1'b1;
                                                scl_drv_low <= 1'b0;
                                            end
                DONE                    :   begin
                                                done        <= 1'b1;
                                                phase_read  <= 1'b0;
                                                
                                            end
               default: ;    
            endcase
       end
    end

endmodule

`default_nettype wire