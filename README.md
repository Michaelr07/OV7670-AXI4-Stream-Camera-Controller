## OV7670 AXI4-Stream Camera Controller

### **Overview**
This repository contains a synthesis-ready SystemVerilog IP that interfaces with an OV7670 CMOS sensor and converts the raw data into a standard AXI4-Stream. It handles the low-level timing and protocol conversion, allowing for easy integration into Xilinx Vivado Video pipelines.

### **Specifications**
* **Input Interface:** Parallel 8-bit Data, VSYNC, HREF, PCLK.
* **Default Resolution:** VGA (640x480) @ 60Hz.
* **Color Format:** RGB444 (12-bit color).
* **Output Interface:** AXI4-Stream (Master).
* **Protocol Support:** AXI4-Stream Video Feature Adoption.
  * `TUSER[0]`: Start of Frame (SOF)
  * `TLAST`: End of Line (EOL).
* **Resolution:** 640x480 (VGA).
* **Clock Domains:** 24 MHz Input (XCLK), 100 MHz AXI Clock (`aclk`).

## Key Features
### Architectural Robustness
The IP utilizes a centralized `video_pkg` to manage timing and pixel structures. One of the standout features is the `pixel_t` struct, which uses 11-bit logic for X/Y coordinates. This is intentionally hardcoded to **bypass common Vivado IP Packager math bugs** that often occur when calculating widths dynamically in complex hierarchies.

### Auto-Initialization
No MicroBlaze or Zynq code is required to start the feed. The IP includes a:
* **10ms Boot Delay:** Ensures the camera's internal power rails are stable before configuration begins.
* **I2C Sequencer:** Automatically blasts 77 configuration commands to the sensor over I2C to set the gain, white balance, and RGB444 formatting.
* **Status LEDs:** Physical outputs for `LED_I2C_DONE` and `LED_I2C_ERROR` provide instant hardware feedback.

### Future-Proofed Design
While currently optimized for VGA, the `video_pkg` includes pre-defined structs for **720p60** and **1080p30**. The architecture is designed for easy resolution switching in future iterations by simply modifying the `TIMING` localparam.

### **Quick Setup Steps**
1. **Import Source:** Add the `.sv` files in `/src` to your Vivado project.
2. **I2C Initialization:** Use the provided I2C master to write the camera registers.
3. **Package IP** Go to Tools and Create and Package new IP
4. **Connect to Pipeline:** Wire the `m_axis` port directly to a VDMA or Subset Converter.
5. **Clocking:** Ensure the `aclk` is at least 50 MHz to avoid back-pressure issues.
This repository hosts a high-performance **OV7670 Camera Controller IP** designed for Xilinx FPGAs. It simplifies the often-frustrating process of interfacing with CMOS sensors by combining an auto-initializing I2C sequencer with a robust AXI4-Stream master interface.
