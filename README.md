# ZynqMP Dual-Core Ping-Pong

> Developed during an internship at InfoDif (Summer 2026) as a foundational project for getting acquainted with the ALINX AXU2CGB developer board — building the intuition needed for more advanced multi-core and FPGA-accelerated applications on the Zynq UltraScale+ platform.

A bare-metal dual-core demonstration on the **ALINX AXU2CGB** development board (Zynq UltraScale+ MPSoC ZU2CG), running two Cortex-A53 cores simultaneously with shared memory synchronization — without an RTOS or BSP.

## Overview

This project demonstrates multi-core bare-metal programming on the ZynqMP PS (Processing System). Two A53 cores exchange "Ping!" and "Pong!" messages over UART using a shared memory flag at a fixed DDR address, taking turns in strict sequence.

The goal was to build hands-on intuition for the Zynq UltraScale+ platform — understanding how the PS works, how cores communicate through shared DDR, and how to load and run bare-metal code alongside a running Linux system via JTAG. These concepts form the foundation for more advanced work such as FPGA-accelerated signal processing pipelines and heterogeneous multi-core applications.

```
Core 0 (A53 #0)          Shared Memory           Core 1 (A53 #1)
     │                   0x50000000                    │
     │── writes "Ping!" ──────────────────────────────>│
     │── sets flag = 1 ──────────────────────────────> │
     │                                                  │── writes "Pong!"
     │                                                  │── sets flag = 0
     │<─────────────────────────────────────────────────│
     └──────────────────── repeat ─────────────────────┘
```

**UART output (115200 baud):**
```
Ping!
Pong!
Ping!
Pong!
...
```
![Demo](demo.gif)

## Hardware

- **Board:** ALINX AXU2CGB-I
- **SoC:** Zynq UltraScale+ MPSoC ZU2CG (xczu2cg-sfvc784-1-i)
- **JTAG:** Digilent JTAG-HS1
- **Boot mode:** SD card (PetaLinux 2020.1)

## How It Works

The key insight of this project is using **Linux as a DDR initializer**. The board boots PetaLinux from SD card, which initializes DDR4 (2GB). After Linux is fully booted, XSCT loads bare-metal ELF files onto individual A53 cores via JTAG — bypassing FSBL entirely.

This avoids a known issue in Vitis 2025: FSBL compiled with GCC 13 + LTO produces DWARF debug info that XSDB cannot parse, causing `XFsbl_Exit` breakpoint failures and preventing ELF download.

### Memory Map

| Region | Address | Purpose |
|--------|---------|---------|
| Core 0 ELF | `0x10000000` | Core 0 code + data |
| Core 1 ELF | `0x20000000` | Core 1 code + data |
| Shared flag | `0x50000000` | Inter-core synchronization |
| UART0 TX | `0xFF000030` | Serial output |
| UART0 Status | `0xFF00002C` | TX FIFO status |

## Tools

- Vivado 2025.2.1
- Vitis Unified IDE 2025.2.1
- XSCT (Xilinx Software Command-line Tool)
- PuTTY (115200 baud, 8N1)

## Project Structure

```
zynqmp-dualcore-pingpong/
├── vivado/
│   ├── export_project.tcl   # Recreate Vivado project from scratch
│   ├── system.bd            # Block design (Zynq PS + AXI GPIO)
│   └── led_pins.xdc         # Pin constraints
├── vitis/
│   ├── core0_ping/
│   │   ├── core0_ping.c     # Core 0 source
│   │   └── lscript.ld       # Linker script (origin: 0x10000000)
│   └── core1_pong/
│       ├── core1_pong.c     # Core 1 source
│       └── lscript.ld       # Linker script (origin: 0x20000000)
└── scripts/
    └── run.tcl              # XSCT automation script
```

## Build & Run

### 1. Recreate Vivado Project

```tcl
# In Vivado Tcl Console:
source vivado/export_project.tcl
```

Then run Synthesis → Implementation → Generate Bitstream. Export hardware as `system_wrapper.xsa`.

### 2. Create Vitis Platform

Open Vitis 2025, create a new Platform Component from `system_wrapper.xsa`:
- OS: `standalone`
- Processor: `psu_cortexa53_0`

Build the platform.

### 3. Create Application Components

Create two Application Components in Vitis:
- `core0_ping` — copy `vitis/core0_ping/core0_ping.c` and `lscript.ld`
- `core1_pong` — copy `vitis/core1_pong/core1_pong.c` and `lscript.ld`

Build both. ELF files will be at:
- `core0_ping/build/core0_ping.elf`
- `core1_pong/build/core1_pong.elf`

### 4. Boot Linux on Board

Set boot mode to SD card, power on. Wait for PetaLinux to fully boot (login prompt in PuTTY).

### 5. Run via XSCT

```
xsct scripts/run.tcl
```

Update ELF paths in `run.tcl` to match your build output directory. Open PuTTY (COM port, 115200 baud) to see the output.

## Key Technical Notes

### Vitis 2025 Migration from 2020

Migrating from Vitis 2020.1 to 2025.2.1 required resolving a critical FSBL debugging issue. The new GCC 13 toolchain compiles FSBL with `-flto` (Link Time Optimization), which corrupts DWARF debug sections. XSDB cannot read the `XFsbl_Exit` symbol, causing a 60-second timeout and failed ELF download.

**Workaround:** Boot PetaLinux (which initializes DDR), then load bare-metal ELFs directly onto A53 cores via XSCT after Linux is up.

### Linker Script Separation

Both cores share the same physical DDR but must occupy different address ranges to avoid overwriting each other. Core 0 starts at `0x10000000`, Core 1 at `0x20000000`. The shared flag at `0x50000000` sits in a neutral region neither core owns.

### Shared Memory Synchronization

A single `volatile unsigned int` at `0x50000000` acts as a mutex-free turn indicator. `volatile` prevents the compiler from caching the flag in a register — without it, each core would loop forever on a stale cached value.

## License

MIT
