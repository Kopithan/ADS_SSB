#=============================================================================
# sim.tcl - Sytembus verification driver for ModelSim / Questa
#
# load it once:      source sim.tcl
# then call:         build          compile everything
#                    t_arb          arbiter unit test
#                    t_dec          address decoder unit test
#                    t_top          top level, all scenarios
#                    t_rem          two boards over the remote uart link
#                    t_all          all four in sequence
#                    figs           print the logged figure time windows
#                    zoom <n>       zoom the wave window to figure n
#
# edit SRC and TB below to match your folder layout
#=============================================================================

set SRC "./rtl"
set TB  "./tb"

#-----------------------------------------------------------------------------
proc build {} {
    global SRC TB

    if {[file exists work]} { vdel -all }
    vlib work

    # leaves first, then things that depend on them
    set rtl {
        muxes.sv
        fifo.sv
        uart.sv
        addr_convert.sv
        slave_memory_bram.sv
        master_memory_bram.sv
        slave_port.sv
        slave.sv
        arbiter.sv
        addr_decoder.sv
        master_port.sv
        uart_bus_master.sv
        bus_bridge_slave.sv
        bus_m2_s3.sv
        Sytembus.sv
    }

    foreach f $rtl {
        set path "$SRC/$f"
        if {![file exists $path]} {
            puts "MISSING: $path"
            continue
        }
        if {[catch {vlog -sv $path} msg]} {
            puts "COMPILE FAILED: $f"
            puts $msg
            return 0
        }
    }

    set tbs {arbiter_tb.sv addr_decoder_tb.sv remote_link_tb.sv final_tb.sv}
    foreach f $tbs {
        set path "$TB/$f"
        if {![file exists $path]} { set path "./$f" }
        if {![file exists $path]} {
            puts "MISSING: $f (looked in $TB and .)"
            continue
        }
        if {[catch {vlog -sv $path} msg]} {
            puts "COMPILE FAILED: $f"
            puts $msg
            return 0
        }
    }

    puts "\n--- build complete ---\n"
    return 1
}

#-----------------------------------------------------------------------------
proc t_arb {} {
    quit -sim
    vsim -voptargs=+acc work.arbiter_tb
    add wave -r /arbiter_tb/*
    run -all
}

proc t_dec {} {
    quit -sim
    vsim -voptargs=+acc work.addr_decoder_tb
    add wave -r /addr_decoder_tb/*
    run -all
}

proc t_top {} {
    quit -sim
    vsim -voptargs=+acc work.final_tb
    wave_top
    run -all
    wave zoom full
}

proc t_rem {} {
    quit -sim
    vsim -voptargs=+acc work.remote_link_tb
    wave_remote
    run -all
    wave zoom full
}

proc t_all {} {
    if {[build]} {
        t_arb
        t_dec
        t_top
        t_rem
    }
}

#-----------------------------------------------------------------------------
# grouped waveform for the top level, so report screenshots are readable
proc wave_top {} {
    set t /final_tb
    set d /final_tb/dut

    add wave -divider "clock / reset"
    add wave -radix binary $t/clk $t/rstn

    add wave -divider "M1 device side"
    add wave -radix hex    $t/d1_addr $t/d1_wdata $t/d1_rdata
    add wave -radix binary $t/d1_valid $t/d1_ready $t/d1_mode

    add wave -divider "M2 device side"
    add wave -radix hex    $t/d2_addr $t/d2_wdata $t/d2_rdata
    add wave -radix binary $t/d2_valid $t/d2_ready $t/d2_mode

    add wave -divider "arbiter"
    add wave -radix binary $d/m1_breq $d/m1_bgrant $d/m2_breq $d/m2_bgrant
    add wave $d/bus_inst/bus_arbiter/state
    add wave $d/bus_inst/bus_arbiter/split_owner
    add wave -radix binary $d/m1_split $d/m2_split $d/split_grant

    add wave -divider "decoder"
    add wave -radix binary $d/bus_inst/ssel $d/bus_inst/ack
    add wave -radix binary $d/s1_mvalid $d/s2_mvalid $d/s3_mvalid

    add wave -divider "serial bus"
    add wave -radix binary $d/bus_inst/m_wdata $d/bus_inst/m_mvalid
    add wave -radix binary $d/bus_inst/s_rdata $d/bus_inst/s_svalid

    add wave -divider "slave ready"
    add wave -radix binary $d/s1_ready $d/s2_ready $d/s3_ready $d/s3_split

    add wave -divider "master FSMs"
    add wave $d/master1_port/engine/state $d/master2_port/state

    add wave -divider "M1 remote link"
    add wave -radix binary $t/d1_remote $t/d1_error
    add wave $d/master1_port/c_state $d/master1_port/s_state

    configure wave -timelineunits ns
}

#-----------------------------------------------------------------------------
# two boards, links crossed. shows the wire and both ends of the protocol.
proc wave_remote {} {
    set t /remote_link_tb
    set a /remote_link_tb/boardA/master1_port
    set b /remote_link_tb/boardB/master1_port

    add wave -divider "clock / reset / cable"
    add wave -radix binary $t/clk $t/rstn $t/link_up

    add wave -divider "board A device side"
    add wave -radix hex    $t/a1_addr $t/a1_wdata $t/a1_rdata
    add wave -radix binary $t/a1_valid $t/a1_ready $t/a1_mode $t/a1_remote $t/a1_error

    add wave -divider "the wire"
    add wave -radix binary $t/a_rm_tx $t/b_rm_tx

    add wave -divider "board A client / server"
    add wave $a/c_state $a/s_state $a/tx_state $a/rx_state
    add wave -radix hex $a/req_cmd $a/resp_data
    add wave -radix binary $a/req_pend $a/resp_pend $a/srv_issue

    add wave -divider "board B client / server"
    add wave $b/c_state $b/s_state $b/tx_state $b/rx_state
    add wave -radix hex $b/rx_cmd $b/resp_data
    add wave -radix binary $b/req_pend $b/resp_pend $b/srv_issue

    add wave -divider "board B device side"
    add wave -radix hex    $t/b1_addr $t/b1_rdata
    add wave -radix binary $t/b1_valid $t/b1_ready $t/b1_remote $t/b1_error

    configure wave -timelineunits ns
}

#-----------------------------------------------------------------------------
# read back the figure windows the testbench logged
proc figs {} {
    set f "figures.txt"
    if {![file exists $f]} {
        puts "no $f yet - run t_top first"
        return
    }
    set fh [open $f r]
    puts "\n  #   start      end        description"
    puts "  --  ---------  ---------  ------------------------------------"
    while {[gets $fh line] >= 0} {
        set p [split $line "|"]
        puts [format "  %-2s  %-9s  %-9s  %s" \
              [lindex $p 0] [lindex $p 1] [lindex $p 2] [lindex $p 3]]
    }
    close $fh
    puts ""
}

# zoom the wave window onto one figure, with a little margin
proc zoom {n} {
    set f "figures.txt"
    if {![file exists $f]} { puts "no $f yet - run t_top first"; return }
    set fh [open $f r]
    while {[gets $fh line] >= 0} {
        set p [split $line "|"]
        if {[lindex $p 0] == $n} {
            close $fh
            set a [expr {[lindex $p 1] - 50}]
            set b [expr {[lindex $p 2] + 50}]
            if {$a < 0} { set a 0 }
            wave zoom range ${a}ns ${b}ns
            puts "figure $n: [lindex $p 3]"
            return
        }
    }
    close $fh
    puts "no figure $n"
}

puts "loaded. commands: build  t_arb  t_dec  t_top  t_rem  t_all  figs  zoom <n>"