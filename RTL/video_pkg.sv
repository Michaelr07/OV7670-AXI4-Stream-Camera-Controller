package video_pkg;


  typedef struct packed {
  int R, G , B; //bits per channel
  } rgb_size_s;
  
  localparam rgb_size_s RGB444 = '{
    R:4, G:4, B:4
  };
  
// add other RGB widths
  
  typedef struct packed {
    int H_ACTIVE, H_FP, H_SYNC, H_BP;
    int V_ACTIVE, V_FP, V_SYNC, V_BP;
    bit HS_NEG; // 1 = active low
    bit VS_NEG;
  } vid_timing_t;

  // 640x480@60 (25.175 MHz nominal)
  localparam vid_timing_t TIMING_VGA_640x480 = '{
    H_ACTIVE:640, H_FP:16,  H_SYNC:96,  H_BP:48,
    V_ACTIVE:480, V_FP:10,  V_SYNC:2,   V_BP:33,
    HS_NEG:1, VS_NEG:1
  };

  // 720p60 (74.25 MHz)
  localparam vid_timing_t TIMING_720P_60 = '{
    H_ACTIVE:1280, H_FP:110, H_SYNC:40,  H_BP:220,
    V_ACTIVE:720,  V_FP:5,   V_SYNC:5,   V_BP:20,
    HS_NEG:1, VS_NEG:1
  };

  // 1080p30 (74.25 MHz)
  localparam vid_timing_t TIMING_1080P_30 = '{
    H_ACTIVE:1920, H_FP:88,  H_SYNC:44,  H_BP:148,
    V_ACTIVE:1080, V_FP:4,   V_SYNC:5,   V_BP:36,
    HS_NEG:1, VS_NEG:1
  };
  
// HARDCODED STRUCT (Bypasses Vivado IP Packager Math Bug)
    typedef struct packed {
        logic        de;     // 1 bit
        logic        sof;    // 1 bit
        logic        eol;    // 1 bit
        logic [10:0] x;      // 11 bits (Hardcoded: Easily holds 640, and even 1920 for 1080p!)
        logic [10:0] y;      // 11 bits (Hardcoded: Easily holds 480, and even 1080 for 1080p!)
        
        logic [3:0]  r;      // 4 bits
        logic [3:0]  g;      // 4 bits
        logic [3:0]  b;      // 4 bits
    } pixel_t;
endpackage
