# FPGA-based ADS-B signal decoder

This repo contains gateware used to receive and decode ADS-B messages from a modified HackRF One software defined radio onto a Gowin Tang Nano 20K FPGA.


## Motivation

Like most things I do, I built this project because I thought it would be cool. And also to prove that I could.


## Overview

The SDR is tuned to 1090MHz and captures ADS-B messages from planes as they pass overhead. The IQ samples from the SDR are passed to the FPGA, where the contents of the messages are extracted. The FPGA then sends the extracted messages to my computer via UART.

![demo](figures/demo.gif)

The HackRF One sends a copy of every IQ sample to both my computer and the FPGA. I can control the frequency, bandwidth, and gain of the SDR with normal control software (I use [SDR++](https://github.com/AlexandreRouma/SDRPlusPlus)), but all the signal processing occurs on the FPGA.

When no processing is applied, the signal seen in the SDR++ waterfall is the same signal that enters the FPGA (minus some digital noise).



### DSP chain

[todo: diagram]


### SDR modifications:

There is a spare header (P30) on the HackRF One that is connected to the CPLD that sends the ADC data to the Microcontroller. This CPLD can be reprogrammed to send a copy of the ADC samples to header P30.

Necessary modifcations to `firmware/cpld/sgpio_if/top.vhd` are shown below:

```diff
@@ -18,5 +18,9 @@ use UNISIM.vcomponents.all;    
         DA              : in    std_logic_vector(7 downto 0);
         DD              : out   std_logic_vector(9 downto 0);
+        
+        IQ_CLK          : out   std_logic;
+        I_TAP           : out   std_logic_vector(7 downto 0);
+        Q_TAP           : out   std_logic_vector(7 downto 0);
 
         CODEC_CLK       : in    std_logic;
         CODEC_X2_CLK    : in    std_logic
@@ -76,17 +81,20 @@ begin
         I => CODEC_X2_CLK
     );
 
+    -- Map front-end sample clock to P30 header
+    IQ_CLK <= CODEC_CLK;
@@ -106,9 +114,11 @@ begin
                 if codec_clk_rx_i = '1' then
                     -- I: non-inverted between MAX2837 and MAX5864
                     data_to_host_o <= adc_data_i xor X"80";
+                    I_TAP <= adc_data_i xor X"80";
                 else
                     -- Q: inverted between MAX2837 and MAX5864
                     data_to_host_o <= adc_data_i xor rx_q_invert_mask;
+                    Q_TAP <= adc_data_i xor rx_q_invert_mask;
                 end if;
             end if;
         end if;
```

And to `firmware/cpld/sgpio_if/top.ucf`:

``` diff
@@ -65,6 +66,25 @@ NET "HOST_SYNC_EN" LOC = "P90" ;
 NET "HOST_SYNC"  LOC = "P55" | PULLUP ; 
 NET "HOST_SYNC_CMD"  LOC = "P56" ; 
 
+NET "IQ_CLK"    LOC = "P22"; # GCK0
+NET "I_TAP<0>"  LOC = "P92"; # B2AUX16
+NET "I_TAP<1>"  LOC = "P97"; # B2AUX14
+NET "I_TAP<2>"  LOC = "P1";  # B2AUX12
+NET "I_TAP<3>"  LOC = "P3";  # B2AUX10
+NET "I_TAP<4>"  LOC = "P6";  # B2AUX8
+NET "I_TAP<5>"  LOC = "P8";  # B2AUX6
+NET "I_TAP<6>"  LOC = "P10"; # B2AUX4
+NET "I_TAP<7>"  LOC = "P12"; # B2AUX2
+
+NET "Q_TAP<0>"  LOC = "P94"; # B2AUX15
+NET "Q_TAP<1>"  LOC = "P99"; # B2AUX13
+NET "Q_TAP<2>"  LOC = "P2";  # B2AUX11
+NET "Q_TAP<3>"  LOC = "P4";  # B2AUX9
+NET "Q_TAP<4>"  LOC = "P7";  # B2AUX7
+NET "Q_TAP<5>"  LOC = "P9";  # B2AUX5
+NET "Q_TAP<6>"  LOC = "P11"; # B2AUX3
+NET "Q_TAP<7>"  LOC = "P13"; # B2AUX1
+
 #PACE: Start of PACE Area Constraints
 
 #PACE: Start of PACE Prohibit Constraints
```

Below is an oscilloscope trace of some signals on P30 after the CPLD modifcation. The signals traced are the sample clock (yellow), a bit from the I channel (blue) and from the Q channel (green).

![picture](figures/P30_probe_after_CPLD_mod.png)


## Testing (simulation)

I can collect raw samples from the SDR using `hackrf_transfer`. I then load these samples into my RTL simulator to verify that the DSP logic functions correctly.

Capturing raw ads-b signals:
``` bash
hackrf_transfer -r adsb_8mhz.bin -f 1090000000 -b 1750000 -s 8000000 -n 8000000 -l 32 -g 34
```

The design can be simulated by running `./test_adsb.py` in the `sim` directory.

The following dependencies are required for simulation:
* Verilator
* Cocotb
* Numpy

## Difficulties and debugging process

Initially, signals would successfully decode in simulation, but not on the FPGA. I suspected the issue was the dodgy connection between the SDR and FPGA.

![picture of the hardware](figures/hardware.jpg)

I wrote a some RTL to capture the signals that came into the FPGA and send them to my computer over UART (`RTL/debug_top.sv`). Due to BRAM limits on the Tang Nano 20K, I could only capture about 40k samples. However, this is more than enough to see the issue:

![bad sample transmission](figures/FPGA_captured_plot.png)

For reference, here is a plot of the same signal with samples captured directly from the SDR:

![reference samples](figures/Reference_plot.png)

It appears that some bits of the I sample bus were not being latched correctly. I played around with adjusting the phase of the incoming sample clock, however eventually I realized the the open-source toolchain I was using wasn't respecting my constrains. Instead, I had to force the I/Q sample bus into the hard IO buffer by instantiating Gowin IDDR primitives:

```
generate
for (i = 0; i < 8; i = i + 1) begin : IO_buffer_gen
    IDDR iddr_inst_i (
        .Q0(i_buf[i]), // Data captured on rising edge
        .Q1(),         // Data captured on falling edge
        .D(sample_i_in[i]),
        .CLK(sample_clk)
    );
    IDDR iddr_inst_q (
        .Q0(),         // Data captured on rising edge
        .Q1(q_buf[i]), // Data captured on falling edge
        .D(sample_q_in[i]),
        .CLK(sample_clk)
    );
end
endgenerate
```

This greatly reduces the skew on the IQ bus and makes it possible to safely latch the data.
Here are the results:

![post iob sample transmission](figures/FPGA_captured_samples_forced_iob.png)


