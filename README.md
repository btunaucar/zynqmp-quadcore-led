# ZynqMP Quad-Core Synchronized LED Blinker

> Developed during an internship at InfoDif (Summer 2026) as a foundational
> project on the ALINX AXU2CGB board — building the multi-core, heterogeneous-
> processor (Cortex-A53 + Cortex-R5), and standalone-boot intuition needed for
> larger Zynq UltraScale+ work ahead.

A bare-metal, 4-core demonstration on the **ALINX AXU2CGB** development board
(Zynq UltraScale+ MPSoC ZU2CG), where every processor core available on the PS —
both A53 application cores and both R5 real-time cores — runs independent
bare-metal code simultaneously, with no RTOS and no shared BSP between them.

## Overview

Each of the 4 cores owns one LED on the board's J15 header and blinks it at its
own fixed frequency (1 Hz, 2 Hz, 4 Hz, 8 Hz). The interesting part isn't the
blinking itself — it's getting 4 independently-linked bare-metal programs,
running on two different processor architectures (ARMv8-A and ARMv7-R), to
start blinking in lockstep every single time the board powers on or resets,
without any of them being "primary" or coordinating through software running
on another core.

That's done with a small shared-memory barrier in DDR: every core increments
a shared generation counter, publishes its own arrival in a per-core slot, then
spins until it sees all 4 slots agree — only then does it start toggling its
LED. Because A53 and R5 both cache DDR locally, every read/write to the barrier
is wrapped in explicit cache maintenance so the cores actually see each other's
writes instead of stale cached values.

The other half of the project was making the whole thing boot completely on
its own — no JTAG cable plugged in, no debugger attached, no host PC. See
[Key Technical Notes](#key-technical-notes) for the FSBL bug that was blocking
exactly that.

## Hardware

- **Board:** ALINX AXU2CGB
- **SoC:** Zynq UltraScale+ MPSoC ZU2CG (`xczu2cg-sfvc784-1-e`)
- **Cores used:** all 4 — 2× Cortex-A53 (APU, `psu_cortexa53_0` / `_1`) + 2× Cortex-R5 (RPU, split mode, `psu_cortexr5_0` / `_1`)
- **LEDs:** 4× LED on the J15 header, driven from PS GPIO through EMIO (no PL logic besides the EMIO passthrough — the block design is a single Zynq UltraScale+ PS IP with a 4-bit `GPIO_0_0` EMIO interface)
- **Boot mode:** QSPI, fully standalone (no SD card, no JTAG required after flashing)

| Core | Domain | GPIO pin (EMIO) | `GPIO_0_0_tri_io` bit | Package pin | Blink rate |
|------|--------|:---:|:---:|:---:|:---:|
| A53-0 | `standalone_psu_cortexa53_0` | 78 | `[0]` | AG11 | 1 Hz |
| A53-1 | `standalone_psu_cortexa53_1` | 79 | `[1]` | AB14 | 2 Hz |
| R5-0  | `standalone_psu_cortexr5_0`  | 80 | `[2]` | W13  | 4 Hz |
| R5-1  | `standalone_psu_cortexr5_1`  | 81 | `[3]` | W11  | 8 Hz |

All 4 pins are `LVCMOS33`. PS GPIO pin numbers 78-81 are EMIO bits 0-3 — ZynqMP PS GPIO has 78 MIO-routed pins (0-77), so pin 78 is the first EMIO bit.

## How It Works

### Boot chain

`BOOT.bin` (built via `bootgen` from `scripts/boot.bif`) contains, in order:
FSBL (runs on A53-0) → PMU firmware → PL bitstream → one ELF per core. FSBL
brings up DDR and the PS, configures the PL, then releases all 4 cores out of
reset with their respective ELF already loaded — each core starts executing
its own `main()` independently, with no core waiting on another to hand off
control.

### Startup barrier (generation-counter sync)

A 5-word `uint32_t` region at a fixed DDR address (`0x10000000`) is used purely
as a rendezvous point:

```c
sync[0..3]  // one slot per core — "I have reached the barrier for generation N"
sync[4]     // the current generation counter
```

Each core reads the current generation, computes `gen = sync[4] + 1`, writes
`gen` into its own slot, then busy-waits until all 4 slots read back `gen`.
The core that observes the last slot flip writes `gen` into `sync[4]`, which
lets every core proceed. Because this is a race-free monotonically increasing
counter rather than a boolean flag, the barrier also works correctly across
repeated power cycles — there's no stale "already triggered" state to reset.

Every access to the barrier region is bracketed with `Xil_DCacheFlushRange` /
`Xil_DCacheInvalidateRange`, since both the A53 and R5 domains run with their
D-caches enabled and DDR is not otherwise coherent between the APU and RPU.

### After the barrier

Once released, each core just does its own thing — there is no further
inter-core communication, no round-robin, no shared state. Each core writes
its GPIO pin high, sleeps half its blink period, writes it low, sleeps again,
forever.

### Memory Map

| Address | Region | Purpose |
|---|---|---|
| `0x10000000` | DDR (shared) | Sync barrier — 5× `uint32_t`: `[0..3]` = per-core generation slots, `[4]` = global generation counter |
| `0x00000000` – `0x7FF00000` | DDR | A53-0 code/data/stack (`psu_ddr_0_memory_0`, `led1.c`'s linker script) |
| `0x20000000` – `0x3FF00000` | DDR | A53-1 code/data/stack (`psu_ddr_0_memory_0`, offset in `led2.c`'s linker script to stay clear of A53-0) |
| `0x00000000` – `0x0003FFFF` | R5 TCM (ATCM/BTCM) | R5 code/data/stack (`psu_r5_tcm_ram_0_MEM_0`, 256 KB per core, private per-core TCM instance) — R5 apps run entirely out of TCM, not DDR |
| `0xFFFC0000` – `0xFFFFFFFF` | OCM | Reserved by the platform, unused by the application |
| PS GPIO pin 78-81 (EMIO) | J15 header | LED0-LED3 output pins, see [Hardware](#hardware) table |

The R5 barrier code dereferences `0x10000000` directly — DDR is a single
physical resource shared by every master in the system (APU and RPU alike),
so the same address is valid from all 4 cores despite R5's own code and stack
living in TCM rather than DDR. Both R5 domains' linker scripts also declare an
identical `psu_r5_ddr_0_memory_0` DDR window (`ORIGIN = 0x100000`), but neither
app places any section there — TCM holds everything.

## Tools

- Vivado 2025.2.1
- Vitis Unified IDE 2025.2.1
- CMake + Ninja (Vitis 2025's default embeddedsw build system)
- `bootgen` (QSPI `BOOT.bin` assembly)

## Project Structure

```
zynqmp-quadcore-led/
├── vivado/
│   ├── export_project.tcl   # Recreate the Vivado project from scratch
│   ├── system.bd            # Block design (Zynq UltraScale+ PS, EMIO GPIO x4)
│   └── led_pins.xdc         # J15 LED pin constraints
├── vitis/
│   ├── fsbl_bsp.yaml        # FSBL BSP config, stdout/stdin already set to None (see Build & Run)
│   ├── core0_a53_1hz/       # A53-0 — psu_cortexa53_0, 1 Hz
│   │   ├── led1.c
│   │   └── lscript.ld
│   ├── core1_a53_2hz/       # A53-1 — psu_cortexa53_1, 2 Hz
│   │   ├── led2.c
│   │   └── lscript.ld
│   ├── core2_r5_4hz/        # R5-0  — psu_cortexr5_0, 4 Hz
│   │   ├── led3.c
│   │   └── lscript.ld
│   └── core3_r5_8hz/        # R5-1  — psu_cortexr5_1, 8 Hz
│       ├── led4.c
│       └── lscript.ld
└── scripts/
    └── boot.bif             # bootgen partition layout for standalone QSPI boot
```

## Build & Run

### 1. Recreate the Vivado Project

```tcl
# In Vivado Tcl Console:
source vivado/export_project.tcl
```

Then run Synthesis → Implementation → Generate Bitstream, and export hardware
**with the bitstream included** as `zynq_led_qspi.xsa`.

### 2. Create the Vitis Platform

Create a new Platform Component from `zynq_led_qspi.xsa` in Vitis 2025 with
4 `standalone` domains, one per processor:

- `standalone_psu_cortexa53_0`
- `standalone_psu_cortexa53_1`
- `standalone_psu_cortexr5_0`
- `standalone_psu_cortexr5_1`

Creating the platform also auto-adds a `zynqmp_fsbl` boot domain — this is
Xilinx's own stock FSBL template, nobody writes source for it, you just build it.
**Before** you build that domain, apply the fix below, or the board will only
boot with a JTAG debugger attached.

#### Required: disable the FSBL's DCC stdout

By default, Xilinx's stock FSBL template sends its console output over
CoreSight DCC — a channel that only drains when a JTAG debugger is attached.
Build it with the defaults and the board hangs on the FSBL startup banner the
moment no debugger is connected.

This repo already includes the fix: `vitis/fsbl_bsp.yaml` has `stdout` and
`stdin` set to `None` instead of the CoreSight default. Before building the
`zynqmp_fsbl` domain, copy this file over the auto-generated `bsp.yaml` in
that domain's folder, then regenerate the BSP and build — no manual clicking
through BSP Settings required.

Optional sanity check after building: `objdump -d fsbl.elf | grep dbgdtrtx`
should print nothing — no DCC calls left in the binary.

Then build the rest of the platform.

### 3. Create the PMU Firmware Application

The PMU firmware is also a stock Xilinx template, not custom code: **File →
New → Application Component**, target processor `psu_pmu_0`, template
`pmu_firmware`. Build it as-is — this produces `pmufw.elf`. (The platform's
own default/QEMU-targeted PMU firmware is not sufficient for real hardware,
which is why this needs to be a proper application component of its own.)

### 4. Create the 4 Application Components

For each of `core0_a53_1hz`, `core1_a53_2hz`, `core2_r5_4hz`, `core3_r5_8hz`,
create an Application Component targeting the matching domain above, then copy
in that folder's `.c` file and `lscript.ld` — these are the only files in this
repo you actually need to bring in; everything else above is stock Xilinx
tooling. Build all four; ELFs land at `<component>/build/<component>.elf`.

### 5. Assemble and Flash BOOT.bin

Update the paths in `scripts/boot.bif` to point at your actual build outputs
(`fsbl.elf` from step 2, `pmufw.elf` from step 3, the bitstream from step 1,
and the 4 application ELFs from step 4), then:

```
bootgen -image scripts/boot.bif -arch zynqmp -o BOOT.bin -w
```

Program `BOOT.bin` to QSPI (Vitis' `program_flash` or Vivado Hardware Manager),
set the board's boot-mode switch to QSPI, and power-cycle. All 4 LEDs should
start blinking together, at 1/2/4/8 Hz, with no host connection required.

None of the 5 steps above require writing any new code — steps 1-3 are
stock Vivado/Vitis tooling and templates, and steps 4-5 only need the files
already sitting in this repo.

## Key Technical Notes

### The generation-counter barrier, not a boolean flag

An earlier version of this synchronization used a plain "everyone set, go"
boolean flag. That breaks on the second and later power cycles: a flag that's
already `1` from a previous run gives every core a false "go" signal before
its peers have even reached the barrier. Using a strictly-increasing
generation counter instead means each boot/reset cycle has its own unique
target value, so there is no stale state to accidentally satisfy the barrier.

### Offset DDR regions for the two A53 cores

A53-0 and A53-1 both run out of DDR, and — unlike the two R5 cores, which each
get a physically separate TCM — DDR is one shared resource. A53-1's linker
script moves its whole `psu_ddr_0_memory_0` region to `ORIGIN = 0x20000000`
instead of the default `0x0`, so its code, data, and stack can't land on top
of A53-0's.

### Root cause of the JTAG dependency (and the fix)

The project would only boot when a JTAG cable was attached — powering the
board with JTAG disconnected hung during FSBL, before any core ever reached
main(). The cause: the FSBL BSP's `standalone_stdout` (and `stdin`) defaulted
to `psu_coresight_0` — CoreSight DCC, a channel that only drains when a
JTAG-attached debugger is actively reading it. `XCoresightPs_DccSendByte()`
polls the DCC TX-empty bit with no timeout, so the very first FSBL banner
character sent without a debugger attached spun forever, and the board never
got past FSBL.

**Fix:** the FSBL BSP needs `standalone_stdout:None` and `standalone_stdin:None`
instead of the coresight default. That's a config value, not source code — it
lives in the domain's `bsp.yaml`, so it doesn't have to be a manual, repeated
step. `vitis/fsbl_bsp.yaml` in this repo already has it applied; drop it in
before generating the BSP (see [Build & Run](#build--run)) and every rebuild
of `fsbl.elf` comes out fixed automatically. Verified with
`objdump -d fsbl.elf | grep dbgdtrtx` returning empty — no DCC instructions
left in the binary. With JTAG never in the loop, standalone QSPI boot works
identically whether or not a debugger is physically connected.

### Real hardware PMU firmware

The final `BOOT.bin` uses a PMU firmware build validated against real
hardware, rather than the QEMU-target PMUFW image Vitis produces by default
during platform bring-up — the two are not interchangeable for actual board
boot.

### Split-mode R5 with TCM-resident code

Both R5 cores run in split mode (independent, not lockstep), and each app's
linker script places all sections in that core's own TCM
(`psu_r5_tcm_ram_0_MEM_0`, `ORIGIN = 0x0`, `LENGTH = 0x40000`) rather than
DDR. The R5 domains also see a DDR window in their linker script
(`psu_r5_ddr_0_memory_0`, `ORIGIN = 0x100000`) that this application doesn't
use for code, but the barrier's raw pointer dereference at `0x10000000` still
resolves to the same physical DDR that the A53 cores use, since DDR sits on
a shared physical address map visible to every bus master in the system.

## License

MIT
