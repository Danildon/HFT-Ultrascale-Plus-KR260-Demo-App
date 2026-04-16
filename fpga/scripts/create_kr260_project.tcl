# =============================================================================
# create_kr260_project.tcl  —  Vivado 2025.1, Kria KR260, plain Verilog
# Includes AXI DMA (free IP) for streaming market data into the FPGA parser.
#
# HOW TO RUN:
#   cd C:/path/to/hft-kr260/fpga/scripts
#   source create_kr260_project.tcl
# =============================================================================

set project_name "hft_kr260"
set project_dir  "./vivado_project"
set part         "xck26-sfvc784-2LV-c"

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir    [file normalize [file join $script_dir ".." "rtl"]]
puts "INFO: Script dir : $script_dir"
puts "INFO: RTL dir    : $rtl_dir"

set rtl_files [list \
    [file join $rtl_dir "market_data_parser.v"] \
    [file join $rtl_dir "order_book_engine.v"]  \
    [file join $rtl_dir "tob_axi_lite.v"]       \
    [file join $rtl_dir "msg_framer.v"]         \
    [file join $rtl_dir "kr260_top.v"]          \
]

# -----------------------------------------------------------------------------
# Helper: find latest installed IP VLNV
# -----------------------------------------------------------------------------
proc get_ip_vlnv {lib name} {
    set candidates {}
    foreach vendor {xilinx.com amd.com} {
        set found [get_ipdefs \
            -filter "VLNV =~ ${vendor}:${lib}:${name}:*" -quiet]
        if {$found ne ""} { foreach i $found { lappend candidates $i } }
    }
    if {[llength $candidates] == 0} { error "IP not found: ${lib}:${name}" }
    set chosen [lindex [lsort -decreasing $candidates] 0]
    puts "  Resolved: $chosen"
    return $chosen
}

# -----------------------------------------------------------------------------
# Helper: range string to bytes
# -----------------------------------------------------------------------------
proc range_to_bytes {r} {
    if {[regexp {^([0-9]+)K$} $r -> n]} { return [expr {$n*1024}] }
    if {[regexp {^([0-9]+)M$} $r -> n]} { return [expr {$n*1048576}] }
    if {[regexp {^([0-9]+)G$} $r -> n]} { return [expr {$n*1073741824}] }
    if {[regexp {^([0-9]+)$}  $r -> n]} { return $n }
    return 4096
}

# =============================================================================
# 1. Create project
# =============================================================================
puts "\nINFO: Creating project $project_name ..."
create_project $project_name $project_dir -part $part -force

set board_set 0
foreach bpart {"amd.com:kr260_som:part0:1.1" "xilinx.com:kr260_som:part0:1.1"} {
    if {![catch {set_property BOARD_PART $bpart [current_project]}]} {
        puts "INFO: Board part set: $bpart"
        set board_set 1; break
    }
}
if {!$board_set} { puts "WARN: KR260 board files not found." }
set_property TARGET_LANGUAGE Verilog [current_project]

# =============================================================================
# 2. Add RTL source files
# =============================================================================
puts "\nINFO: Adding RTL files ..."
set n_added 0
foreach f $rtl_files {
    if {[file exists $f]} {
        add_files -norecurse $f
        set_property file_type Verilog [get_files [file tail $f]]
        puts "  Added: [file tail $f]"
        incr n_added
    } else {
        puts "  ERROR: NOT FOUND: $f"
    }
}
if {$n_added < 5} {
    error "Only $n_added/5 RTL files found. Check $rtl_dir"
}

update_compile_order -fileset sources_1

puts "\nINFO: Checking RTL syntax ..."
if {[catch {synth_design -rtl -top kr260_top -quiet} err]} {
    puts "WARN: $err"
} else {
    puts "INFO: RTL syntax OK."
}

# =============================================================================
# 3. Create block design
# =============================================================================
puts "\nINFO: Creating block design ..."
create_bd_design "kr260_system"

# ---- Zynq UltraScale+ PS --------------------------------------------------
puts "INFO: Adding Zynq MPSoC PS ..."
set zynq [create_bd_cell -type ip \
    -vlnv [get_ip_vlnv ip zynq_ultra_ps_e] zynq_ultra_ps_e_0]

set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0                 {1}   \
    CONFIG.PSU__USE__M_AXI_GP1                 {0}   \
    CONFIG.PSU__USE__M_AXI_GP2                 {0}   \
    CONFIG.PSU__USE__S_AXI_GP2                 {1}   \
    CONFIG.PSU__FPGA_PL0_ENABLE                {1}   \
    CONFIG.PSU__FPGA_PL1_ENABLE                {1}   \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} \
    CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {200} \
    CONFIG.PSU__USE__IRQ0                      {0}   \
] $zynq

# ---- AXI SmartConnect: GP0 path (1 slave in, 2 masters out) ---------------
puts "INFO: Adding AXI SmartConnect (GP0) ..."
set sc [create_bd_cell -type ip \
    -vlnv [get_ip_vlnv ip smartconnect] smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $sc

# ---- AXI SmartConnect: HP0 path (DMA → DDR4) ------------------------------
puts "INFO: Adding AXI SmartConnect (HP0/DMA) ..."
set sc_hp [create_bd_cell -type ip \
    -vlnv [get_ip_vlnv ip smartconnect] smartconnect_hp0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc_hp

# ---- Proc Sys Reset -------------------------------------------------------
puts "INFO: Adding Proc Sys Reset ..."
set psr [create_bd_cell -type ip \
    -vlnv [get_ip_vlnv ip proc_sys_reset] proc_sys_reset_0]

# ---- AXI DMA (MM2S only, no scatter-gather, free IP) ----------------------
puts "INFO: Adding AXI DMA ..."
set dma [create_bd_cell -type ip \
    -vlnv [get_ip_vlnv ip axi_dma] axi_dma_0]

set_property -dict [list \
    CONFIG.c_include_mm2s            {1}  \
    CONFIG.c_include_s2mm            {0}  \
    CONFIG.c_mm2s_burst_size         {16} \
    CONFIG.c_m_axi_mm2s_data_width   {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {8}  \
    CONFIG.c_include_sg              {0}  \
    CONFIG.c_sg_length_width         {26} \
    CONFIG.c_addr_width              {32} \
] $dma

# ---- kr260_top RTL module reference ---------------------------------------
puts "INFO: Adding kr260_top module reference ..."
if {[catch {
    set kr260 [create_bd_cell -type module -reference kr260_top kr260_top_0]
    puts "INFO: kr260_top added OK."
} err]} {
    puts "ERROR: $err"
    error "Failed to add kr260_top. Check all .v files exist in $rtl_dir"
}

# =============================================================================
# 4. Connect interfaces
# =============================================================================
puts "\nINFO: Wiring ..."

# GP0 master → SmartConnect_0 slave
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins smartconnect_0/S00_AXI]

# SmartConnect_0 M00 → kr260_top AXI4-Lite (TOB registers)
set kr260_slave [lindex [get_bd_intf_pins kr260_top_0/s_axi*] 0]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] $kr260_slave

# SmartConnect_0 M01 → AXI DMA control
connect_bd_intf_net \
    [get_bd_intf_pins smartconnect_0/M01_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# AXI DMA MM2S AXI4 → SmartConnect_hp0 → PS HP0 (DMA reads DDR4)
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins smartconnect_hp0/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins smartconnect_hp0/M00_AXI] \
    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# AXI DMA MM2S stream → kr260_top s_axis (goes through msg_framer internally)
set kr260_axis [lindex [get_bd_intf_pins kr260_top_0/s_axis*] 0]
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    $kr260_axis

# ---- Clocks ---------------------------------------------------------------
set clk [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
connect_bd_net $clk \
    [get_bd_pins kr260_top_0/pl_clk0]               \
    [get_bd_pins kr260_top_0/pl_clk1]               \
    [get_bd_pins kr260_top_0/s_axi_aclk]            \
    [get_bd_pins smartconnect_0/aclk]               \
    [get_bd_pins smartconnect_hp0/aclk]             \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]  \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk]         \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk]

# ---- Resets ---------------------------------------------------------------
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins kr260_top_0/pl_resetn0]            \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins kr260_top_0/s_axi_aresetn]         \
    [get_bd_pins smartconnect_0/aresetn]             \
    [get_bd_pins smartconnect_hp0/aresetn]           \
    [get_bd_pins axi_dma_0/axi_resetn]

# =============================================================================
# 5. Address assignment
# =============================================================================
puts "\nINFO: Assigning addresses ..."
assign_bd_address

# Read back what Vivado auto-assigned and print the map
set space_segs [get_bd_addr_segs \
    -of_objects [get_bd_addr_spaces /zynq_ultra_ps_e_0/Data] -quiet]

puts "INFO: Address map (GP0 → PL):"
puts "INFO:   +------------------------+------------+-------+------------+"
puts "INFO:   | segment                | base       | size  | end        |"
puts "INFO:   +------------------------+------------+-------+------------+"

set regions {}
set dma_ctrl_addr 0xA0000000
set tob_regs_addr 0xA0010000

foreach seg $space_segs {
    set nm  [get_property NAME   $seg]
    set off [get_property OFFSET $seg]
    set rng [get_property RANGE  $seg]
    set sz  [range_to_bytes $rng]
    set end [expr {$off + $sz - 1}]
    puts [format "INFO:   | %-22s | 0x%08X | %5s | 0x%08X |" \
          $nm $off $rng $end]
    lappend regions [list $nm $off $sz]
    if {[string match "*dma*" [string tolower $nm]]} { set dma_ctrl_addr $off }
    if {[string match "*reg0*" [string tolower $nm]]} { set tob_regs_addr $off }
}
puts "INFO:   +------------------------+------------+-------+------------+"

# Overlap check
set n_overlap 0
set n [llength $regions]
for {set i 0} {$i < $n} {incr i} {
    for {set j [expr {$i+1}]} {$j < $n} {incr j} {
        set a [lindex $regions $i]; set b [lindex $regions $j]
        set a0 [lindex $a 1]; set as [lindex $a 2]
        set b0 [lindex $b 1]; set bs [lindex $b 2]
        if {$a0 < ($b0+$bs) && $b0 < ($a0+$as)} {
            puts "ERROR: OVERLAP: [lindex $a 0] and [lindex $b 0]"
            incr n_overlap
        }
    }
}
if {$n_overlap > 0} { error "Address overlap — fix before synthesising." }
puts "INFO:   No overlaps. $n segment(s)."

puts ""
puts "INFO: ┌─────────────────────────────────────────────┐"
puts [format "INFO: │  DMA_BASE = 0x%08X  (AXI DMA ctrl)   │" $dma_ctrl_addr]
puts [format "INFO: │  TOB_BASE = 0x%08X  (TOB registers)  │" $tob_regs_addr]
puts "INFO: └─────────────────────────────────────────────┘"
puts ""

# =============================================================================
# 6. Validate, save, generate wrapper
# =============================================================================
puts "INFO: Validating ..."
catch {validate_bd_design} val_err
if {$val_err ne ""} {
    puts "WARN: validate_bd_design: $val_err"
}
save_bd_design

puts "INFO: Generating HDL wrapper ..."
if {[catch {make_wrapper -files [get_files kr260_system.bd] -top} wrap_err]} {
    puts "ERROR: make_wrapper failed: $wrap_err"
    puts "ERROR: Open the project in Vivado GUI, right-click kr260_system.bd"
    puts "ERROR: and choose 'Create HDL Wrapper' manually."
    error "Wrapper generation failed."
}

set wrapper ""
foreach d [list \
    "$project_dir/${project_name}.gen/sources_1/bd/kr260_system/hdl" \
    "$project_dir/${project_name}.srcs/sources_1/bd/kr260_system/hdl" \
] {
    set hits [glob -nocomplain "$d/*wrapper*"]
    if {[llength $hits] > 0} { set wrapper [lindex $hits 0]; break }
}
if {$wrapper ne ""} {
    add_files -norecurse $wrapper
    set_property top kr260_system_wrapper [get_filesets sources_1]
    puts "INFO: Top = kr260_system_wrapper"
} else {
    puts "WARN: Wrapper file not found automatically."
    puts "WARN: In Sources panel, right-click kr260_system.bd → Create HDL Wrapper"
}

puts ""
puts "========================================================"
puts " Project ready: $project_dir/${project_name}.xpr"
puts ""
puts " Next: Run Synthesis → Implementation → Generate Bitstream"
puts " Then copy .bit to board and run:"
puts "   chmod +x ~/hft-kr260/scripts/setup_dma.sh"
puts "   ~/hft-kr260/scripts/setup_dma.sh"
puts "   sudo python3 ~/hft-kr260/scripts/demo.py --single"
puts "========================================================"
