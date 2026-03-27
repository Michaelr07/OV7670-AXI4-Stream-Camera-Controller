`timescale 1ns/1ps
`default_nettype none

module i2c_slave_ack_bfm #(
  parameter logic [6:0] SLAVE_ADDR7 = 7'h21,
  parameter int REGISTER_WIDTH = 256   // -1 = never; else NACK that (0-based) data byte
)(
  input  wire logic clk,
  input  wire logic rst_n,

  inout  tri  sda,
  inout  tri  scl
);
  
  parameter [6:0] GENERAL_CALL_ADDR = 7'h00;

  // internal registerrs and address pointer
  logic [7:0] registers [0:REGISTER_WIDTH-1];
  logic [7:0] reg_addr;
  
  // Initalize registers with default data
  initial begin
    foreach(registers[i])
        registers[i] = i;
  end
  
  // open-drain drive (pull low when sda_drv_low=1, else release)
  logic sda_drv_low;
  assign sda = sda_drv_low ? 1'b0 : 1'bz;

  // 2FF sync of pins into clk domain
  logic sda_q, scl_q, sda_qq, scl_qq;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      sda_q     <= 1'b1; 
      sda_qq    <= 1'b1;
      scl_q     <= 1'b1; 
      scl_qq    <= 1'b1;
    end else begin
      sda_q     <= sda;   
      sda_qq    <= sda_q;
      scl_q     <= scl;   
      scl_qq    <= scl_q;
    end
  end

  int  rd_idx;
  
  logic scl_rise, scl_fall, start_cond, stop_cond;
  // edges and bus conditions
  assign scl_rise   = (scl_q==1'b1 && scl_qq==1'b0);
  assign scl_fall   = (scl_q==1'b0 && scl_qq==1'b1);
  assign start_cond = (scl_q==1'b1 && sda_q==1'b0 && sda_qq==1'b1);
  assign stop_cond  = (scl_q==1'b1 && sda_q==1'b1 && sda_qq==1'b0);

  typedef enum logic [2:0] {IDLE, START_WAIT, ADDR, DATA, READ, READ_ACK, ACK} st_t;
  st_t          st;

  logic  [7:0]  shreg, tx_reg;
  logic  [3:0]  bit_idx;        // counts 8..0
  logic         addr_byte;      // true during address/RW reception
  logic         mode_read;      // 0=write, 1=read
  logic         write_reg_byte;

  // ACK
  logic         ack_active;     // we are in the ACK bit (drive low while true)
  logic         ack_drive_low;  // latched decision for this ACK bit

  // Sequential FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st                <= IDLE;
      bit_idx           <= '0;
      shreg             <= '0;
      tx_reg            <= '0;
      reg_addr          <= '0;
      sda_drv_low       <= 0;
      ack_active        <= 0;
      ack_drive_low     <= 0;
      addr_byte         <= 0;
      mode_read         <= 0;
      write_reg_byte    <= 0;

    end else begin
      // default: only drive during an ACK bit; keep level stable across SCL high
      sda_drv_low <= (ack_active && ack_drive_low);

      if (start_cond) begin
        st              <= START_WAIT;
        bit_idx         <= 4'd8;      // expect to shift 8 bits
        addr_byte       <= 1;
        ack_active      <= 0;
        ack_drive_low   <= 0;
        shreg           <= '0;
        tx_reg          <= '0;
        //rd_idx          <= '0;    do not reset addr on start
        
      end else if (stop_cond) begin
        st              <= IDLE;
        ack_active      <= 0;
        ack_drive_low   <= 0;
        addr_byte       <= 0;
      end else begin
        unique case (st)

          // Wait for SCL to go low after START
          START_WAIT: begin
            if (scl_fall) st    <= ADDR;
          end

          // ------------------------------------------------------------------
          // Address: shift LSB on each SCL rising edge (R/W is bit0)
          // After last bit sampled (bit_idx==0 at rising edge), wait for
          // SCL falling edge to arm ACK and decide address ACK/NACK.
          // ------------------------------------------------------------------
          ADDR: begin
            if (scl_rise) begin
              shreg <= {shreg[6:0], sda_qq};
              if (bit_idx != 0) bit_idx <= bit_idx - 1;
            end
            // after the last data bit's HIGH period ends, prepare ACK on next LOW
            if (bit_idx == 0 && scl_fall) begin
              mode_read         <= sda_qq;              // R/W bit we just sampled
              ack_active        <= 1;                // enter ACK bit
              ack_drive_low     <= (shreg[7:1] == SLAVE_ADDR7) || (shreg[7:1] == GENERAL_CALL_ADDR && sda_qq == 1'b0);
              st                <= ACK;
            end
          end

          // ------------------------------------------------------------------
          // DATA (write to slave): shift data in on SCL rising edges
          // When the 8th bit completes (falling edge after last rising), arm ACK
          // ------------------------------------------------------------------
          DATA: begin
            if (scl_rise) begin 
                if(bit_idx != 0) begin
                    shreg       <= {shreg[6:0], sda_qq};
                    bit_idx     <= bit_idx - 1;
                end
              //  else if (bit_idx==0 && write_reg_byte) begin
              //      reg_addr    <= shreg;
              //  end 
            end

            if (bit_idx == 0 && scl_fall) begin
                if(write_reg_byte)
                    ack_drive_low   <= (shreg >= 0 && shreg <= REGISTER_WIDTH-1);
                else
                    ack_drive_low   <= 1;
                    
                ack_active          <= 1;
              //ack_drive_low     <= (should_nack_this_data(data_byte_count)) ? 1'b0 : 1'b1;
                st                  <= ACK;
            end
          end
          
          READ: begin
            sda_drv_low     <= ~tx_reg[7];
            if (scl_fall) begin   
                if (bit_idx != 0) begin
                    tx_reg <= {tx_reg [6:0], 1'b0};
                end 
                else begin      
                  	sda_drv_low <= 1'b0;
                    st      <= READ_ACK;  
                end
            end
            else if (scl_rise) begin
              	if (bit_idx != 0)
                  bit_idx     <= bit_idx - 1;
            end
          end

          READ_ACK: begin
             sda_drv_low <= 1'b0;        // release for master response
            if(scl_rise) begin
                if (sda_qq == 1'b0) begin
                    reg_addr    <= reg_addr + 1;
                    //tx_reg      <= registers[reg_addr+1];          might need to uncomment
                    bit_idx     <= 4'd8;
                end else 
                    st          <= IDLE;
             end
             else if(scl_fall) begin
                tx_reg      <= registers[reg_addr];
                st          <= READ;
             end
          end

          // ------------------------------------------------------------------
          // ACK bit handling:
          // - We entered ACK with ack_active=1 and ack_drive_low=decision
          // - Hold SDA low across SCL high if ack_drive_low==1
          // - On the falling edge after SCL high, release SDA, clear ack_active,
          //   and branch to next state.
          // ------------------------------------------------------------------
          ACK: begin
            if (scl_fall) begin
              // End of the ACK clock -> release SDA and move on
              ack_active        <= 1'b0;
              sda_drv_low       <= 1'b0;

              if (addr_byte) begin
                addr_byte   <= 1'b0;
                bit_idx     <= 4'd8;
                if (ack_drive_low) begin                
                  	if (mode_read==0) begin                       // WRITE
                    	write_reg_byte  <= 1;
                    	shreg           <= '0;
                    	st              <= DATA;     
                  	end else begin                                // READ
                    	tx_reg  <= registers[reg_addr];             // load shift reg with register data
                    	st      <= READ;    
                  	end
                  end else begin
                  // Address NACKed: ignore until next START/STOP
                  	st    <= IDLE;
                  end
                
              end else begin
                bit_idx                 <= 4'd8;
                // Data ACK just finished
                if (ack_drive_low==1'b0) begin
                    // We intentionally NACKed
                    st <= IDLE;
                end else if(write_reg_byte) begin
                    reg_addr                <= shreg;
                    write_reg_byte          <= 0;
                    shreg                   <= '0;
                    st                      <= DATA;
                end else begin
                    registers[reg_addr]     <= shreg;
                    reg_addr                <= reg_addr + 1;
                    shreg                   <= '0;
                    st                      <= DATA;
                end
              end
              
            end
            
          end

          default:  ;
        endcase
      end
    end
  end
endmodule

`default_nettype wire