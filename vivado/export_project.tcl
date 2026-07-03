#*****************************************************************************************
# Vivado (TM) v2025.2.1 (64-bit)
#
# export_project.tcl: Tcl script for re-creating the 'zynq_led_v2' project
#
# This project targets the ALINX AXU2CGB board (Zynq UltraScale+ MPSoC ZU2CG,
# xczu2cg-sfvc784-1-e). The design is a single Zynq UltraScale+ Processing System
# IP (zynq_ultra_ps_e_0) with a 4-bit GPIO_0_0 EMIO interface routed to the J15
# LED header via led_pins.xdc. No other PL logic is present — GPIO 78-81 on the
# PS side are EMIO pins driven straight out to the four LEDs.
#
# Unlike Vivado's auto-generated 800+ line write_project_tcl output, this is a
# concise, hand-written recreation script. The actual IP configuration (PS clocking,
# DDR controller, QSPI, GIC, EMIO widths, etc.) lives entirely inside system.bd,
# which is checked into this repo verbatim and re-imported below — nothing about
# the hardware is redefined or guessed here.
#
# Usage (Vivado Tcl Console):
#   source vivado/export_project.tcl
#*****************************************************************************************

set project_name  "zynq_led_v2"
set part_name     "xczu2cg-sfvc784-1-e"
set origin_dir     [file dirname [info script]]

create_project $project_name ./$project_name -part $part_name -force

# --- Import the block design ---------------------------------------------
file mkdir ./$project_name/$project_name.srcs/sources_1/bd/design_1
file copy -force "$origin_dir/system.bd" \
    ./$project_name/$project_name.srcs/sources_1/bd/design_1/design_1.bd
add_files -norecurse ./$project_name/$project_name.srcs/sources_1/bd/design_1/design_1.bd

# --- Import pin constraints (J15 LED header) -------------------------------
add_files -fileset constrs_1 -norecurse "$origin_dir/led_pins.xdc"

# --- Generate the HDL wrapper and set it as top -----------------------------
set bd_file [get_files design_1.bd]
generate_target all [get_files $bd_file]
make_wrapper -files $bd_file -top
add_files -norecurse ./$project_name/$project_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]

update_compile_order -fileset sources_1

puts "Project '$project_name' recreated for part $part_name."
puts "Next: run Synthesis -> Implementation -> Generate Bitstream, then export"
puts "hardware (include bitstream) to produce the .xsa consumed by the Vitis platform."
