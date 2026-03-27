## OV7670 AXI4-Stream Camera Controller

### **Overview**
This repository contains a synthesis-ready SystemVerilog IP that interfaces with an OV7670 CMOS sensor and converts the raw data into a standard AXI4-Stream. It handles the low-level timing and protocol conversion, allowing for easy integration into Xilinx Vivado Video pipelines.

### **Specifications**
* **Input Interface:** Parallel 8-bit Data, VSYNC, HREF, PCLK.
* **Output Interface:** AXI4-Stream (Master).
* **Protocol Support:** AXI4-Stream Video Feature Adoption.
  * `TUSER[0]`: Start of Frame (SOF)
  * `TLAST`: End of Line (EOL).
* **Resolution:** 640x480 (VGA).
* *Clock Domains:** 24 MHz Input (XCLK), 100 MHz AXI Clock (`aclk`).

### **Quick Setup Steps**
1. **Import Source:** Add the `.sv` files in `/src` to your Vivado project.
2. **I2C Initialization:** Use the provided I2C master to write the camera registers (included in `/src/config`).
3. **Connect to Pipeline:** Wire the `m_axis` port directly to a VDMA or Subset Converter.
4. **Clocking:** Ensure the `aclk` is at least 50 MHz to avoid back-pressure issues.
