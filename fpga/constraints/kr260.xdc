# =============================================================================
# kr260.xdc
# Timing and configuration constraints for Kria KR260 / K26 SOM.
#
# NOTE: Unlike the SP701, the KR260's PS-PL clocks and most I/O pins are
# managed by the Zynq PS block in the block design — NOT by XDC pin
# assignments. The board preset (applied in the TCL script) configures
# all the MIO pins, DDR4, and Ethernet automatically.
#
# This XDC only needs to contain:
#   1. Timing constraint for the generated PL clock (for clarity)
#   2. Bitstream configuration settings
#   3. Any custom PMOD or FMC pins IF you add them later
# =============================================================================

# -----------------------------------------------------------------------------
# PL clock: 200 MHz from PS pl_clk0
# Vivado auto-derives this from the block design — this constraint is
# informational (documents the intent) but not strictly necessary.
# Uncomment if Vivado doesn't auto-derive it:
# -----------------------------------------------------------------------------
# create_generated_clock -name pl_clk0_200 \
#     -source [get_pins */zynq_ultra_ps_e_0/inst/PS8_i/PLCLK[0]] \
#     -divide_by 1 \
#     [get_nets */zynq_ultra_ps_e_0/inst/PS8_i/PLCLK[0]]

# -----------------------------------------------------------------------------
# Bitstream settings
# -----------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# -----------------------------------------------------------------------------
# False paths across the async reset synchroniser
# (The synchroniser input comes from pl_resetn0 which is asynchronous to pl_clk)
# -----------------------------------------------------------------------------
set_false_path -to [get_cells -hierarchical -filter {NAME =~ */dp_rst_n_s1*}]

# =============================================================================
# OPTIONAL: PMOD connectors on KR260 (add if you wire up LEDs or debug signals)
# =============================================================================
# The KR260 carrier board has two PMOD connectors (J2 and J3).
# Pin assignments depend on which pins you connect to in the block design.
# Example (uncomment and adjust if you add pl_led to the block design I/O):
#
set_property -dict {PACKAGE_PIN xxx IOSTANDARD LVCMOS33} [get_ports {pl_led_0}]
set_property -dict {PACKAGE_PIN xxx IOSTANDARD LVCMOS33} [get_ports {pl_led_1}]
set_property -dict {PACKAGE_PIN xxx IOSTANDARD LVCMOS33} [get_ports {pl_led_2}]
set_property -dict {PACKAGE_PIN xxx IOSTANDARD LVCMOS33} [get_ports {pl_led_3}]
#
# Refer to: KR260 Carrier Card User Guide (UG1494) Table 2-14 for PMOD pin map
