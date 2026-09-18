# 🚀 Sytembus FPGA Project

A Quartus-based SoC-style interconnect and bus validation project built around a custom multi-master, multi-slave memory fabric with a UART-based bridge link between two FPGA boards.

## ✨ What this project does

This design implements a compact bus architecture with:

- Two external master interfaces
- Multiple slave memory blocks
- Split-capable slave behavior for transactional fairness
- An arbitration layer between masters and slaves
- A remote bridge node that connects boards over a UART link
- JTAG-controlled source/probe access for debugging and validation

The top-level design is centered on the `Sytembus_top` wrapper, which integrates the bus core with the JTAG In-System Sources and Probes (ISSP) block.

## 🧩 Project structure

- `rtl/` — SystemVerilog RTL modules for the bus fabric, masters, slaves, bridge, and UART link
- `tb/` — testbenches for exercises and validation scenarios
- `Sytembus_top.sv` — top-level integration module for the FPGA system
- `Sytembus_Top.v` — alternate top-level wrapper variant
- `Sytembus.qpf` / `Sytembus.qsf` — Quartus project files
- `Jtag.qsys` / `final.qsys` — platform-generated Qsys configuration
- `scr.tcl`, `issp_bus_test.tcl`, `issp_console.tcl` — utility and debug scripts

## 🏗️ Key design highlights

- `Sytembus` is the main bus fabric
- `master_port` handles external master-device signaling
- `slave` modules model local memory-backed endpoints
- `bus_bridge_node` provides the remote board communication path
- `bus_m3_s4` coordinates the arbitration and routing logic
- `addr_decoder` / `addr_decoder4` implement address decoding and routing

## ⚙️ Build and run

1. Open the Quartus project file `Sytembus.qpf`.
2. Compile the design.
3. Load the generated FPGA image to the target board.
4. Use the JTAG/ISSP interface and scripts to drive bus transactions and monitor bus state.

## 🧪 Test and debugging

The repository includes several testbenches and helper scripts for exercising:

- address decoding
- arbitration behavior
- UART and remote communication
- stress and loopback validation
- frame and console-based traffic control

## 📝 Notes

- The appendix content is intentionally excluded from the repository to keep the public project clean and focused.
- This workspace contains generated Quartus artifacts, simulation logs, and board-specific files alongside the source RTL.

## 🧑‍💻 Repository status

This project is intended as a hardware design and verification workspace for FPGA-based bus architecture experimentation and demonstration.
