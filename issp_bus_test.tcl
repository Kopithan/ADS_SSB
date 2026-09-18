#!/usr/bin/env quartus_stp -t
# ===========================================================================
#  issp_bus_test.tcl
#
#  Hardware verification of Sytembus over JTAG, using the In-System Sources
#  and Probes instance in Sytembus_top.
#
#  Usage:   quartus_stp -t issp_bus_test.tcl
#           (NOT quartus_sh, and NOT the Quartus GUI Tcl console - the JTAG
#            and ISSP Tcl packages exist only in quartus_stp)
#
#  Requires: Sytembus_top programmed onto the DE0, USB-Blaster connected,
#            and the ISSP editor tab CLOSED in the GUI (it holds the session).
#
#  Exits 0 if every case passes, 1 otherwise.
#
#  ---------------------------------------------------------------------
#  SOURCE MAP (53 bits, laptop -> fabric)
#    [15:0]   d1_addr
#    [23:16]  d1_wdata
#    [24]     d1_valid
#    [25]     d1_mode      0 = read, 1 = write
#    [41:26]  d2_addr
#    [49:42]  d2_wdata
#    [50]     d2_valid
#    [51]     d2_mode
#    [52]     reserved     (was d1_remote)
#
#  PROBE MAP (19 bits, fabric -> laptop)
#    [7:0]    d1_rdata
#    [8]      d1_ready
#    [16:9]   d2_rdata
#    [17]     d2_ready
#    [18]     br_error     bridge: far board did not answer in time
#
#  ---------------------------------------------------------------------
#  ADDRESS MAP  (device id = addr[15:12])
#    id 0 -> Slave 1, 2K BRAM            0x0000 - 0x07FF
#    id 1 -> Slave 2, 4K BRAM            0x1000 - 0x1FFF
#    id 2 -> Slave 3, 4K BRAM            0x2000 - 0x2FFF
#             SPLIT capable: a read releases the bus, then reconnects.
#             It has no uart of its own, so it always completes.
#    id 3 -> unmapped, used for the decode-error case
#    id 8,9,10 -> the bridge: far board S1, S2, S3 over rm_tx/rm_rx
#
#  Either master goes remote by ADDRESS (0x8000 ORed in). The address is
#  interpreted on the FAR board's bus, not ours - the map above still applies
#  because both boards run the same design. Only addr[13:0] goes on the wire,
#  which is lossless here since addr[15:14] is always 00 on a legal access.
#
#  ---------------------------------------------------------------------
#  WHAT THIS SCRIPT CAN AND CANNOT CHECK
#
#  JTAG source/probe access takes milliseconds per round trip; a bus
#  transaction completes in tens of nanoseconds. Every transaction is
#  therefore already finished before the first probe read returns, so
#  d1_ready/d2_ready always read back as 1 (idle).
#
#  CAN verify:    data integrity through the serial bus, decoder slave
#                 select, address mapping across all three slaves,
#                 cross-master coherency, recovery after a decode error.
#  CANNOT verify: arbitration order, grant timing, split-transaction
#                 behaviour, or latency. Those are only observable in
#                 simulation - see final_tb.sv and its waveforms.
#
#  d1_valid / d2_valid are levels held by the source register, not pulses.
#  While a valid bit is set the master repeats the same transaction, so
#  read data sits stable on the probes and is safe to sample.
# ===========================================================================

set SRC     0        ;# shadow copy of the 53-bit source register
set REMOTE  0        ;# 1 = OR 0x8000 into addresses, i.e. aim at the far board
set ERRORS  0
set TESTS   0
set STEP_MS 400      ;# hold after each step so board LEDs are readable

# ------------------------------------------------------- environment checks
set IN_GUI 0
if {[info exists quartus(nameofexecutable)]} {
    set IN_GUI [expr {$quartus(nameofexecutable) eq "quartus"}]
}

proc script_exit {code} {
    global IN_GUI
    if {$IN_GUI} { return -code return } else { exit $code }
}

# --------------------------------------------------------------- utilities
# quartus_stp ships a 32-bit Tcl: bare [format %x] and any shift past bit 31
# truncate to 32 bits, which wipes every M2 field (source bits 26..51). Force
# wide() in the bit math and assemble the hex from the two 32-bit halves.
proc bits {v hi lo} {
    expr {(wide($v) >> $lo) & ((wide(1) << ($hi - $lo + 1)) - 1)}
}

proc src_field {lo width val} {
    global SRC
    set mask [expr {((wide(1) << $width) - 1) << $lo}]
    set SRC  [expr {(wide($SRC) & ~$mask) | ((wide($val) << $lo) & $mask)}]
}

proc src_hex {} {
    global SRC
    set lo [expr {wide($SRC) & 0xffffffff}]
    set hi [expr {(wide($SRC) >> 32) & 0xffffffff}]
    if {$hi == 0} { return [format %x $lo] }
    return [format {%x%08x} $hi $lo]
}

proc src_flush {} {
    global ISSP
    write_source_data -instance_index $ISSP -value [src_hex] -value_in_hex
}

proc probe {} {
    global ISSP
    return [expr 0x[read_probe_data -instance_index $ISSP -value_in_hex]]
}

proc pause {} { global STEP_MS; if {$STEP_MS > 0} { after $STEP_MS } }

proc pass {msg} { global TESTS; incr TESTS; puts "   PASS : $msg" }
proc fail {msg} { global TESTS ERRORS; incr TESTS; incr ERRORS; puts "   ERROR: $msg" }

proc check {label got want} {
    if {$got == $want} {
        pass [format "%s = 0x%02X" $label $got]
    } else {
        fail [format "%s expected 0x%02X, got 0x%02X" $label $want $got]
    }
}

# ------------------------------------------------------------ bus commands
# Master 0 = M1 (high priority), master 1 = M2 (low priority).
# Field bases differ per master, so look them up rather than hard-coding.
#   returns {addr_lo wdata_lo valid_bit mode_bit rdata_lo ready_bit}
proc mfields {m} {
    if {$m == 0} {
        return {0  16 24 25  0  8}
    } else {
        return {26 42 50 51  9 17}
    }
}

# Load one master's command fields without asserting valid.
proc arm {m mode addr wdata} {
    global REMOTE
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    # the link is a bus device now, so remote is just the top device id bit
    # and EITHER master can use it. idempotent on an address you already
    # wrote as 0x8xxx.
    if {$REMOTE} { set addr [expr {$addr | 0x8000}] }
    src_field $vbit 1  0
    src_field $alo  16 $addr
    src_field $dlo  8  $wdata
    src_field $mbit 1  $mode
}

# br_error is sticky per transaction, so sample it right after one completes
proc rem_error {} { return [bits [probe] 18 18] }

# Write: assert valid briefly, then release.
proc bus_write {m addr wdata} {
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    arm $m 1 $addr $wdata
    src_flush
    src_field $vbit 1 1
    src_flush
    after 20
    src_field $vbit 1 0
    src_flush
    after 10              ;# let the last repeated transaction drain to idle
}

# Read: assert valid, sample rdata while the master is looping, then release.
proc bus_read {m addr} {
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    arm $m 0 $addr 0
    src_flush
    src_field $vbit 1 1
    src_flush
    after 20
    set p  [probe]
    set rd [bits $p [expr {$rlo + 7}] $rlo]
    src_field $vbit 1 0
    src_flush
    after 10              ;# bus back to idle before the next master takes over
    return $rd
}

# Launch BOTH masters on the same clock edge. A single source write updates
# all 53 bits at once, so both valid bits rise together. Two separate writes
# would leave milliseconds between them and the first would always finish
# before the second started.
proc bus_write_pair {a0 d0 a1 d1} {
    arm 0 1 $a0 $d0
    arm 1 1 $a1 $d1
    src_flush
    src_field 24 1 1
    src_field 50 1 1
    src_flush                  ;# both masters launch on the same edge
    after 50
    src_field 24 1 0
    src_field 50 1 0
    src_flush
}

proc idle_all {} {
    src_field 24 1 0
    src_field 50 1 0
    src_flush
}

# ------------------------------------------------------------------ connect
puts "============================================================"
puts "   SYTEMBUS IN-SYSTEM VERIFICATION   (ISSP over JTAG)"
puts "============================================================"

if {[catch {load_package insystem_source_probe}] || [catch {load_package jtag}]} {
    puts "FATAL: the JTAG / In-System Sources and Probes Tcl packages are not"
    puts "       available in this interpreter."
    puts ""
    puts "       Run from a terminal with quartus_stp:"
    puts "           quartus_stp -t issp_bus_test.tcl"
    puts ""
    puts "       This cannot run in the Quartus GUI Tcl console, via"
    puts "       Tools > Tcl Scripts, or under quartus_sh."
    script_exit 1
}

if {[catch {set hwlist [get_hardware_names]} err]} {
    puts "FATAL: could not query programming hardware.\n       $err"
    script_exit 1
}
if {[llength $hwlist] == 0} {
    puts "FATAL: no programming hardware found. Is the USB-Blaster plugged in?"
    script_exit 1
}

set hw ""; set dev ""
foreach cand $hwlist {
    if {[catch {set devs [get_device_names -hardware_name $cand]}]} { continue }
    if {[llength $devs] > 0} { set hw $cand; set dev [lindex $devs 0]; break }
    puts "  (skipping \"$cand\" - no devices on the chain)"
}
if {$hw eq ""} {
    puts "FATAL: none of these cables had a device on the chain:"
    foreach cand $hwlist { puts "         $cand" }
    script_exit 1
}
puts "Hardware : $hw"
puts "Device   : $dev"

# Enumerate BEFORE opening a session - this query opens its own transient
# session and will fail if one is already active.
set ISSP -1
if {[catch {set insts [get_insystem_source_probe_instance_info \
                  -hardware_name $hw -device_name $dev]} err]} {
    puts "FATAL: could not enumerate ISSP instances.\n       $err"
    puts ""
    puts "       If that mentions an active session, the GUI's In-System"
    puts "       Sources and Probes Editor has this device open. Close that"
    puts "       tab (Quartus itself can stay open) and re-run."
    script_exit 1
}
foreach inst $insts {
    lassign $inst idx swidth pwidth name
    puts "Instance : index $idx  \"$name\"  source=$swidth probe=$pwidth"
    if {$swidth == 53 && $pwidth == 19} { set ISSP $idx }
}
if {$ISSP < 0} {
    puts "FATAL: no 53-bit source / 19-bit probe instance found."
    puts "       Either the current Sytembus_top is not programmed onto this"
    puts "       device, or Jtag.v still has the old widths. Regenerate the"
    puts "       IP, recompile fully, and reprogram."
    script_exit 1
}

if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} err]} {
    puts "FATAL: could not open an ISSP session.\n       $err"
    script_exit 1
}
puts ""

set SRC 0
src_flush
idle_all

# ===========================================================================
#  (a) RESET / IDLE STATE
# ===========================================================================
puts "\[a\] RESET STATE"
puts "    Press KEY\[0\] (rstn) now if the design has been running."
puts "    Async reset is a physical pin, so the script cannot assert it."
after 1500

set p [probe]
check "d1_ready (bus idle)" [bits $p 8 8]   1
check "d2_ready (bus idle)" [bits $p 17 17] 1
pause

# ===========================================================================
#  (b) ONE MASTER REQUEST
# ===========================================================================
puts "\n\[b\] SINGLE MASTER REQUEST"

puts "  M1 -> Slave 1 (2K) at 0x0155"
bus_write 0 0x0155 0x5A
check "M1 read back 0x0155" [bus_read 0 0x0155] 0x5A
pause

puts "  M1 -> Slave 2 (4K) at 0x1ABC"
bus_write 0 0x1ABC 0x3C
check "M1 read back 0x1ABC" [bus_read 0 0x1ABC] 0x3C
pause

puts "  M1 -> Slave 3 (4K, split capable) at 0x2A55"
bus_write 0 0x2A55 0x9D
check "M1 read back 0x2A55" [bus_read 0 0x2A55] 0x9D
pause

puts "  M2 alone (low priority master, uncontended) at 0x1FFF"
bus_write 1 0x1FFF 0xE7
check "M2 read back 0x1FFF" [bus_read 1 0x1FFF] 0xE7
pause

# ===========================================================================
#  (c) TWO MASTER REQUESTS
# ===========================================================================
puts "\n\[c\] TWO MASTER REQUESTS"
puts "  Both valid bits set in a single 53-bit source write, so both"
puts "  masters request the bus on the same clock edge."

bus_write_pair 0x0020 0x11  0x1020 0x22
check "M1 write landed at 0x0020" [bus_read 0 0x0020] 0x11
check "M2 write landed at 0x1020" [bus_read 1 0x1020] 0x22
puts "  NOTE: both completed, which proves the arbiter served each master"
puts "        in turn. Grant ORDER is not observable from JTAG - see the"
puts "        simulation waveform for M1's priority."
pause

puts "  Cross-master coherency: M2 writes, M1 reads the same cell"
bus_write 1 0x0100 0xC1
check "M1 sees M2's write at 0x0100" [bus_read 0 0x0100] 0xC1
pause

# ===========================================================================
#  ADDRESS DECODER / SLAVE SELECT
# ===========================================================================
puts "\n\[d\] ADDRESS DECODER - SLAVE SELECT"
puts "  Same offset 0x000 written to all three slaves. Distinct read-back"
puts "  values prove the decoder selects three independent memories."

bus_write 0 0x0000 0xA1     ;# slave 1
bus_write 0 0x1000 0xA2     ;# slave 2
bus_write 0 0x2000 0xA3     ;# slave 3, offset 0x000

check "offset 0x000 in Slave 1" [bus_read 0 0x0000] 0xA1
check "offset 0x000 in Slave 2" [bus_read 0 0x1000] 0xA2
check "offset 0x000 in Slave 3" [bus_read 0 0x2000] 0xA3
pause

puts "  Boundary addresses"
bus_write 0 0x07FF 0xB1     ;# top of slave 1
bus_write 0 0x1FFE 0xB2     ;# near top of slave 2
check "Slave 1 top 0x07FF" [bus_read 0 0x07FF] 0xB1
check "Slave 2 top 0x1FFE" [bus_read 0 0x1FFE] 0xB2
pause

# ===========================================================================
#  DECODE ERROR AND RECOVERY
# ===========================================================================
puts "\n\[e\] DECODE ERROR"
puts "  Device id 3 (0x3000) is unmapped. The decoder issues no ack and the"
puts "  master should time out and return to IDLE rather than wedging."

bus_write 0 0x3000 0xAA
after 200
set p [probe]
check "d1_ready after unmapped access" [bits $p 8 8] 1

puts "  Confirming the bus still works after the timeout"
check "S1 0x0155 still readable" [bus_read 0 0x0155] 0x5A
pause

# ===========================================================================
#  SPLIT TRANSACTION - NOT OBSERVABLE HERE
# ===========================================================================
puts "\n\[f\] SPLIT TRANSACTION"
puts "  Slave 3 splits on every read (slave_port SPLIT_EN = 1), so the reads"
puts "  above at 0x2A55 and 0x2000 DID exercise the split path and returned"
puts "  correct data - that is the functional evidence."
puts ""
puts "  The split HANDSHAKE (m1_split asserted, bus released, M2 granted"
puts "  meanwhile, M1 resumed) happens over a few clock cycles and cannot be"
puts "  sampled through JTAG. Use the simulation waveform from final_tb.sv"
puts "  for that timing diagram."

# ===========================================================================
#  REMOTE BUS ACCESS OVER UART
# ===========================================================================
puts "\n\[g\] REMOTE BUS ACCESS (either master, via 0x8000-0xAFFF)"
puts "  These need the second board powered, programmed and cabled:"
puts "     our rm_tx PIN_D3 -> their rm_rx,  their rm_tx -> our rm_rx PIN_C3,"
puts "     plus a common ground."
puts "  With no cable attached each command should take ~10ms and come back"
puts "  with br_error set and 0xFF, NOT wedge the bus."

set REMOTE 1

bus_write 0 0x1000 0x5A
set e [rem_error]
set rd [bus_read 0 0x1000]
set e2 [rem_error]

if {$e || $e2} {
    puts "   INFO : br_error set - no answer from the far board."
    puts "          That is the correct result with the cable unplugged."
    check "timeout returns 0xFF" $rd 0xFF
    puts "   INFO : skipping the rest of the remote checks."
} else {
    check "M1 remote read back of far 0x1000" $rd 0x5A
    bus_write 0 0x0155 0xC4
    check "M1 remote read back of far 0x0155" [bus_read 0 0x0155] 0xC4
    # the whole point of the bridge node: M2 gets there too
    bus_write 1 0x1234 0x3B
    check "M2 remote read back of far 0x1234" [bus_read 1 0x1234] 0x3B
    bus_write 1 0x2A55 0x7C
    check "M2 remote read back of far slave3" [bus_read 1 0x2A55] 0x7C
    check "no error flagged on a good link" [rem_error] 0
}

set REMOTE 0
pause

puts "\n\[h\] LOCAL AND REMOTE ARE SEPARATE MEMORIES"
puts "  Same address, once on our bus and once on theirs."
bus_write 0 0x1400 0x11
set local_val [bus_read 0 0x1400]
check "our own 0x1400" $local_val 0x11

set REMOTE 1
bus_write 0 0x1400 0x22
set remote_val [bus_read 0 0x1400]
set e [rem_error]
set REMOTE 0

if {$e} {
    puts "   INFO : link down, isolation check needs the far board. Skipped."
} else {
    check "far board 0x1400" $remote_val 0x22
    check "our 0x1400 untouched by the remote write" [bus_read 0 0x1400] 0x11
}
pause

# ------------------------------------------------------------------ summary
set REMOTE 0
idle_all
puts "\n============================================================"
if {$ERRORS == 0} {
    puts ">> HARDWARE TEST PASSED - $TESTS checks, 0 errors <<"
} else {
    puts ">> HARDWARE TEST FAILED - $ERRORS of $TESTS checks failed <<"
}
puts "============================================================"

end_insystem_source_probe
script_exit [expr {$ERRORS ? 1 : 0}]
