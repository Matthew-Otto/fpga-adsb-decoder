# FPGA-based ADS-B signal decoder

Real-time 1090MHz Mode-S demodulation and decoding on hardware.

This repo contains gateware used to receive and decode ADS-B messages on a Gowin Tang Nano 20K FPGA.

This project is documented in more detail on [my website](https://matthew-otto.github.io/projects/fpga-adsb/).

## Demo

![demo](figures/demo.gif)

Decoded aircraft telemetry being streamed in real-time.

## Tools / Dependencies:

This project is built entirely using open-source FPGA dev tools.

* [Python](https://www.python.org/) - Various scripts and tooling
* [Numpy](https://numpy.org/install/) - To process the samples used for simulation.
* [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) - Complete FPGA build flow
* [cocotb](https://www.cocotb.org/) - Testbench generator
* [Verilator](https://www.verilator.org/) - Simulation (driven by cocotb)
* [Surfer](https://github.com/surfer-project/surfer) - Waveform viewer
