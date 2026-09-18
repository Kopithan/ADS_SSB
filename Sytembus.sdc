# 50 MHz board clock
create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty

# async reset - synchronised inside the design
set_false_path -from [get_ports rstn]

# board to board link. asynchronous to clk and oversampled by the receiver,
# so the rx path is a false path into the 2 flop synchroniser in uart_rx.
set_false_path -from [get_ports rm_rx]
set_false_path -to   [get_ports rm_tx]

# dedicated JTAG pins of the ISSP megafunction. driven by the USB-Blaster's
# tck, asynchronous to clk, and there is no real path to constrain. tck itself
# is deliberately not touched - it is a genuine derived clock.
set_false_path -from [get_ports {altera_reserved_tdi altera_reserved_tms}]
set_false_path -to   [get_ports altera_reserved_tdo]
