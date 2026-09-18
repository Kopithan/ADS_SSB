#!/usr/bin/env quartus_stp -t
# ===========================================================================
#  issp_console.tcl -- interactive memory console for Sytembus over JTAG.
#
#  Type an address and a byte; the console writes it, reads it back and says
#  whether the memory returned what you put in. Also dumps, fills, patterns,
#  and file load/save across the three on-chip memories.
#
#  Usage:   quartus_stp -t issp_console.tcl
#           (NOT quartus_sh, and NOT the Quartus GUI Tcl console - the JTAG
#            and ISSP Tcl packages exist only in quartus_stp)
#
#  Requires: Sytembus_top programmed onto the DE0, USB-Blaster connected,
#            and the ISSP editor tab CLOSED in the GUI (it holds the session).
#
#  Bus primitives below are the ones proven in issp_bus_test.tcl - same
#  source/probe maps, same settle delays - with a wedge check added.
#
#  ---------------------------------------------------------------------
#  SOURCE MAP (53 bits, laptop -> fabric)        PROBE MAP (19 bits, back)
#    [15:0]   d1_addr                              [7:0]    d1_rdata
#    [23:16]  d1_wdata                             [8]      d1_ready
#    [24]     d1_valid                             [16:9]   d2_rdata
#    [25]     d1_mode   0 = read, 1 = write        [17]     d2_ready
#    [41:26]  d2_addr                              [18]     br_error
#    [49:42]  d2_wdata
#    [50]     d2_valid
#    [51]     d2_mode
#    [52]     DIAG switch: 1 = probe bytes [7:0]/[16:9] carry the bus status
#             word instead of d1/d2 rdata. Driven by the 'diag' command.
#
#  The far board is reached by ADDRESS now, not by a mode bit: the uart link
#  is a device on the bus (ids 8/9/10), so BOTH masters can use it and the
#  far board can reach all three of our slaves. 'rem 1' is just a shortcut
#  that ORs 0x8000 into whatever address you type.
# ===========================================================================

set SRC     0        ;# shadow copy of the 53-bit source register
set MASTER  0        ;# 0 = M1 (high priority), 1 = M2 (low priority)
set REMOTE  0        ;# 1 = OR 0x8000 into addresses, i.e. aim at the far board
set SETTLE  20       ;# ms held with valid asserted before sampling
set DRAIN   10       ;# ms after releasing valid, so the bus reaches idle

# ---------------------------------------------------------------- memory map
# name lo hi kind note
#   kind: mem     - read and write freely
#         bridge  - unused now, slave 3 has no uart of its own any more
#         unmap   - no ack; master times out and recovers by itself
set REGIONS {
    {"S1 BRAM"        0x0000 0x07FF mem    "2K, slave 1"}
    {"S1 alias hole"  0x0800 0x0FFF nobits "slave 1 only shifts 11 addr bits"}
    {"S2 BRAM"        0x1000 0x1FFF mem    "4K, slave 2"}
    {"S3 BRAM"        0x2000 0x2FFF mem    "4K, slave 3, SPLIT capable, splits on read"}
    {"unmapped"       0x3000 0x7FFF unmap  "device id 3-7, decode error"}
    {"FAR S1 BRAM"    0x8000 0x87FF mem    "2K, far board slave 1, over the link"}
    {"FAR S1 hole"    0x8800 0x8FFF nobits "far slave 1 only shifts 11 addr bits"}
    {"FAR S2 BRAM"    0x9000 0x9FFF mem    "4K, far board slave 2, over the link"}
    {"FAR S3 BRAM"    0xA000 0xAFFF mem    "4K, far board slave 3, over the link"}
    {"unmapped"       0xB000 0xFFFF unmap  "device id 11-15, decode error"}
}

proc show_map {} {
    global REGIONS MASTER REMOTE
    puts ""
    puts "  Range            Name             Access  Notes"
    puts "  ---------------  ---------------  ------  --------------------------------"
    foreach r $REGIONS {
        lassign $r nm lo hi kind note
        switch -- $kind {
            mem    { set acc "rw" }
            bridge { set acc "w-only" }
            nobits { set acc "-" }
            unmap  { set acc "-" }
        }
        puts [format "  0x%04X-0x%04X    %-15s  %-6s  %s" $lo $hi $nm $acc $note]
    }
    puts ""
    puts "  Slave 3 is the SPLIT capable slave: a read there releases the bus"
    puts "  so the other master can use it, then reconnects. It always"
    puts "  completes - there is no uart behind slave 3 any more."
    puts ""
    puts "  0x8000-0xAFFF is the far board, over the rm_tx/rm_rx link. Both"
    puts "  boards run this design so the ranges mirror each other, and EITHER"
    puts "  master can use them. 'rem 1' just ORs 0x8000 into what you type."
    puts "  A dead link returns 0xFF with br_error set, it never wedges."
    puts "  Current master: M[expr {$MASTER + 1}][expr {$REMOTE ? { (REMOTE)} : {}}]"
    puts ""
}

proc region {addr} {
    global REGIONS
    foreach r $REGIONS {
        lassign $r nm lo hi kind note
        if {$addr >= $lo && $addr <= $hi} { return $r }
    }
    return {"?" 0 0 unmap "outside the 16-bit space"}
}

# Is this address safe for the requested operation? Returns "" if fine,
# otherwise the reason it was refused.
proc why_not {addr mode} {
    lassign [region $addr] nm lo hi kind note
    switch -- $kind {
        mem    { return "" }
        bridge {
            # kept so an old map entry cannot crash the checker; unused now
            return ""
        }
        nobits {
            return "0x[format %04X $addr] is in the slave 1 alias hole - the\
                    slave shifts only 11 address bits, so the transfer\
                    desyncs. Use 0x0000-0x07FF. Use -f to force."
        }
        unmap {
            return "0x[format %04X $addr] is unmapped ($note) - the decoder\
                    never acks and the master times out. Use -f to force."
        }
    }
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

# Master 0 = M1 (high priority), master 1 = M2 (low priority).
#   returns {addr_lo wdata_lo valid_bit mode_bit rdata_lo ready_bit}
proc mfields {m} {
    if {$m == 0} { return {0 16 24 25 0 8} } else { return {26 42 50 51 9 17} }
}

proc ready {m} {
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    return [bits [probe] $rbit $rbit]
}

# A wedged master never returns to IDLE, so dready stays low.
# With no argument, checks whichever master is currently selected.
proc check_wedge {{m ""}} {
    global MASTER
    if {$m eq ""} { set m $MASTER }
    # a remote timeout completes the transaction and releases dready, so it
    # is never a wedge - check_link reports that case instead. br_error is
    # sticky, so only believe it if the last access really went far.
    global LAST_FAR
    if {$LAST_FAR && [rem_error]} { return 0 }
    if {[ready $m] == 0} {
        puts "  !! M[expr {$m + 1}] is WEDGED - dready still low."
        puts "     Press KEY\[0\] (rstn) on the board, then carry on."
        return 1
    }
    return 0
}

# ------------------------------------------------------------ bus commands
proc arm {m mode addr wdata} {
    global REMOTE LAST_FAR
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    # 'rem 1' aims at the far board, which is just the top bit of the device
    # id. works for either master - the link is a bus device, not a master
    # feature - and is idempotent if you already typed a 0x8xxx address.
    if {$REMOTE} { set addr [expr {$addr | 0x8000}] }
    # remember where this access went: br_error only means something for
    # an access that actually crossed the link (device ids 8, 9, 10)
    set LAST_FAR [expr {(($addr >> 12) & 0xF) >= 8 && (($addr >> 12) & 0xF) <= 10}]
    src_field $vbit 1  0
    src_field $alo  16 $addr
    src_field $dlo  8  $wdata
    src_field $mbit 1  $mode
}

# br_error is sticky from the bridge, cleared when the next far access starts,
# so read it straight after an access completes. It belongs to the bridge, not
# to a master, so it reports for whichever master went across the link.
proc rem_error {} { return [bits [probe] 18 18] }

# DC continuity test of the receive pin. No uart, no timing, no protocol:
# just reads the live level of rm_rx. Ground the pin with a wire and it must
# read 0. If it stays 1 with the wire fitted, the wire is not on JP1 pin 4.
proc pintest {} {
    src_field 52 1 1
    src_flush
    after 20
    set w [expr {([bits [probe] 16 9] << 8) | [bits [probe] 7 0]}]
    src_field 52 1 0
    src_flush
    after 20
    set lvl [expr {($w >> 7) & 1}]
    puts ""
    puts "  rm_rx (PIN_C3, JP1 pin 4) reads : $lvl"
    puts ""
    if {$lvl} {
        puts "  HIGH. That is the idle state, and it is also what an"
        puts "  unconnected pin reads, because rm_rx has a weak pull up."
        puts "  To prove the pin works, run a wire from JP1 pin 4 to a"
        puts "  GROUND pin - JP1 pin 12 or pin 30 - and type pintest again."
        puts "  It MUST read 0. If it still reads 1 the wire is not on pin 4."
    } else {
        puts "  LOW. The receive pin and its input path work, and you have"
        puts "  found the right physical pin. Remove the ground wire and put"
        puts "  the real link back."
    }
    puts ""
}

# INTERNAL LOOPBACK SELF TEST.
#
# Source bit 52 ties the bridge's receiver to its own transmitter inside the
# fpga, so a far access never reaches PIN_D3, PIN_C3 or any wire. Far S1
# 0x8001 then IS local S1 0x0001. If this passes, the uart, the framing, the
# client, the server and both bus faces are all proven on real silicon and
# every remaining fault is the pins or the cable. If it fails, the fault is
# inside the design and no amount of rewiring will help.
proc selftest {} {
    global REMOTE
    puts ""
    puts "  INTERNAL LOOPBACK SELF TEST"
    puts "  receiver tied to our own transmitter INSIDE the fpga -"
    puts "  no pins, no jumper, no cable involved. Far 0x8001 = local 0x0001."
    puts ""
    # 'rem 1' ORs 0x8000 into every address inside arm, which would silently
    # turn the local verification read below into another FAR read. This test
    # must not depend on console state, so force it off and put it back.
    set save_remote $REMOTE
    set REMOTE 0

    src_field 52 1 1
    src_flush
    after 20
    bus_write 0 0x8001 0x5C          ;# far write == our own local 0x0001
    bus_read  0 0x8001               ;# far read of the same cell
    after 5
    set p [probe]
    set w [expr {([bits $p 16 9] << 8) | [bits $p 7 0]}]

    src_field 52 1 0                 ;# loopback open again, probe shows rdata
    src_flush
    after 20
    # master_port latches rdata until the NEXT read, so the probe still holds
    # the answer the far read brought back. Sample it before reading anything.
    set far [bits [probe] 7 0]

    set sent [expr {($w >> 13) & 1}]
    set rsp  [expr {($w >> 11) & 1}]
    set back [bus_read 0 0x0001]
    set REMOTE $save_remote

    puts [format "    request fully sent   : %d  (want 1)" $sent]
    puts [format "    0x5A response back   : %d  (want 1)" $rsp]
    puts [format "    far read returned    : 0x%02X  (want 0x5C)" $far]
    puts [format "    local 0x0001 read    : 0x%02X  (want 0x5C)" $back]
    puts ""
    if {$rsp && $far == 0x5C && $back == 0x5C} {
        puts "    PASS - the whole link stack works inside the fpga."
        puts "           Every remaining fault is the PINS or the WIRE."
    } else {
        puts "    FAIL"
        if {!$sent} {
            puts "           our transmitter never finished the request frame."
        }
        puts "           BEFORE believing this, check you REPROGRAMMED the board"
        puts "           after the internal loopback was added to Sytembus_top."
        puts "           On an older bitstream source bit 52 only swaps the probe"
        puts "           bytes and does NOT close the loopback, so this test is"
        puts "           guaranteed to fail and the result means nothing."
        puts "           On a current bitstream, FAIL means the fault is INSIDE"
        puts "           the design and rewiring will not help."
    }
    puts ""
}

# One snapshot of the bus AND link state. A wedge is STATIC, so this says
# exactly which machine is stuck where - no SignalTap needed. Source bit 52
# swaps the two rdata bytes on the probe for the 16 bit status word, and it
# also closes the internal loopback used by selftest.
proc show_diag {} {
    src_field 52 1 1
    src_flush
    after 5
    set p [probe]
    src_field 52 1 0
    src_flush
    set w   [expr {([bits $p 16 9] << 8) | [bits $p 7 0]}]
    set arb {IDLE M1 M2 M3 ? ? ? ?}
    set own {none M1 M2 M3}
    puts [format "  status word    : 0x%04X" $w]
    puts [format "  arbiter state  : %s     split owner: %s   split_busy=%d"               [lindex $arb [expr {($w >> 8) & 7}]]               [lindex $own [expr {($w >> 3) & 3}]] [expr {($w >> 2) & 1}]]
    set rx_low  [expr {($w >> 15) & 1}]
    set tx_ran  [expr {($w >> 14) & 1}]
    set req_snt [expr {($w >> 13) & 1}]
    set rx_any  [expr {($w >> 12) & 1}]
    set rx_rsp  [expr {($w >> 11) & 1}]
    puts "  link, since our last far request:"
    puts [format "    tx: transmitter ran=%d   request frame fully sent=%d" $tx_ran $req_snt]
    puts [format "    rx: pin seen LOW=%d   complete byte=%d   0x5A response=%d" \
              $rx_low $rx_any $rx_rsp]
    if {!$tx_ran} {
        puts "    -> our own transmitter never ran. The request never left the"
        puts "       fpga. This is OUR fault, not the cable and not them."
    } elseif {!$req_snt} {
        puts "    -> the transmitter started but never finished the 4 byte"
        puts "       frame. OUR fault."
    } elseif {!$rx_low} {
        puts "    -> we sent the whole frame and rm_rx PIN_C3 NEVER WENT LOW."
        puts "       No electrical activity reached the pin at all. With a"
        puts "       loopback jumper D3->C3 fitted this must not happen, so"
        puts "       the jumper is not making contact, or it is on the wrong"
        puts "       pins. With a real cable: their tx is not on our rx, or"
        puts "       there is no common ground, or they are not powered."
    } elseif {!$rx_any} {
        puts "    -> the pin moved but no COMPLETE byte was ever framed."
        puts "       Electrically connected but the bit timing is wrong:"
        puts "       different baud rate, or a bad ground giving a noisy edge."
    } elseif {!$rx_rsp} {
        puts "    -> whole bytes arrived but never a 0x5A RESPONSE frame."
        puts "       The link works. The far side answers in a different"
        puts "       format, or does not answer reads at all."
    } else {
        puts "    -> a 0x5A response did arrive. The link is healthy."
    }
    puts [format "  ssplit=%d  sb_split=%d  s3_ready=%d  sb_ready=%d"               [expr {$w & 1}] [expr {($w >> 1) & 1}] [expr {($w >> 5) & 1}]               [expr {($w >> 6) & 1}]]
    puts [format "  rm_rx pin level RIGHT NOW : %d" [expr {($w >> 7) & 1}]]
    puts [format "  d1_ready=%d  d2_ready=%d  br_error=%d"               [bits $p 8 8] [bits $p 17 17] [bits $p 18 18]]
    puts "  (only meaningful on a bitstream whose startup fingerprint said CURRENT)"
}

# Report a remote failure. Returns 1 if the last access timed out.
# br_error is STICKY in the bridge: it stays set from an earlier far read
# (the startup fingerprint, for one) until the next far request starts. A
# local access never touches it, so it is only consulted for a far access -
# otherwise every local command after a dead-link read would be blamed on
# the cable and its read value would never be printed.
# One line physical verdict from the sticky link flags, so a failed far
# access explains ITSELF instead of printing the same generic cable notice
# every time and leaving you to remember to type 'diag'.
proc link_hint {} {
    src_field 52 1 1
    src_flush
    after 5
    set p [probe]
    src_field 52 1 0
    src_flush
    after 5
    set w [expr {([bits $p 16 9] << 8) | [bits $p 7 0]}]
    set rx_low  [expr {($w >> 15) & 1}]
    set tx_ran  [expr {($w >> 14) & 1}]
    set req_snt [expr {($w >> 13) & 1}]
    set rx_any  [expr {($w >> 12) & 1}]
    set rx_rsp  [expr {($w >> 11) & 1}]
    if {!$tx_ran || !$req_snt} {
        return "our own transmitter never got the frame out. Internal fault -\
                run 'selftest'."
    } elseif {!$rx_low} {
        return "we sent the whole frame and PIN_C3 never went low. NOTHING is\
                reaching our rx pin. rm_tx is JP1 pin 2 (GPIO_00) and rm_rx is\
                JP1 pin 4 (GPIO_01), both in the EVEN column - JP1 pins 1 and 3\
                are GPIO_0_IN0/IN1 and are not this design. Check the pins, the\
                contact, the common ground, and that the far board is powered."
    } elseif {!$rx_any} {
        return "the pin moved but no complete byte was framed. Connected, but\
                the bit timing is wrong - baud rate mismatch or a bad ground."
    } elseif {!$rx_rsp} {
        return "whole bytes arrived but never a 0x5A response. The wire is\
                fine; the far side answers in a different format."
    }
    return "a 0x5A response did arrive - the link itself looks healthy."
}

proc check_link {} {
    global LAST_FAR
    if {$LAST_FAR && [rem_error]} {
        puts "  !! br_error - the far board did not answer (0xFF returned)."
        puts "     [link_hint]"
        return 1
    }
    return 0
}

# Write: assert valid briefly, then release.
proc bus_write {m addr wdata} {
    global SETTLE DRAIN
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    arm $m 1 $addr $wdata
    src_flush
    src_field $vbit 1 1
    src_flush
    after $SETTLE
    src_field $vbit 1 0
    src_flush
    after $DRAIN
}

# Read: assert valid, sample rdata while the master is looping, then release.
# d1_valid / d2_valid are levels, not pulses - while a valid bit is set the
# master repeats the transaction, so read data sits stable on the probes.
proc bus_read {m addr} {
    global SETTLE DRAIN
    lassign [mfields $m] alo dlo vbit mbit rlo rbit
    arm $m 0 $addr 0
    src_flush
    src_field $vbit 1 1
    src_flush
    after $SETTLE
    set p  [probe]
    set rd [bits $p [expr {$rlo + 7}] $rlo]
    src_field $vbit 1 0
    src_flush
    after $DRAIN
    return $rd
}

# Launch BOTH masters on the same clock edge. One source write updates all 53
# bits at once, so both valid bits rise together. Two separate writes would
# leave milliseconds between them and M1 would always finish before M2 began.
# Returns the probe word sampled while both were still looping.
proc bus_pair {mode a1 d1 a2 d2} {
    global SETTLE DRAIN
    arm 0 $mode $a1 $d1
    arm 1 $mode $a2 $d2
    src_flush
    src_field 24 1 1
    src_field 50 1 1
    src_flush                  ;# both masters launch on the same edge
    # one master waits out the other's turn, so allow at least the 50ms the
    # scripted test uses before sampling
    after [expr {$SETTLE < 50 ? 50 : $SETTLE}]
    set p [probe]
    src_field 24 1 0
    src_field 50 1 0
    src_flush
    after $DRAIN
    return $p
}

proc idle_all {} {
    src_field 24 1 0
    src_field 50 1 0
    src_flush
}

# ------------------------------------------------------------ input helpers
proc parse_hex {s} {
    set s [string trim $s]
    if {$s eq ""} { return -1 }
    regsub -nocase {^0x} $s "" s
    if {![regexp {^[0-9a-fA-F]+$} $s]} { return -1 }
    return [expr 0x$s]
}

proc ask {prompt} {
    puts -nonewline $prompt
    flush stdout
    if {[gets stdin line] < 0} { return "" }
    return [string trim $line]
}

# Split a typed line into tokens and pull out any -f. Split on whitespace with
# regexp rather than treating the line as a Tcl list, so a Windows path like
# d:\mem\dump.txt keeps its backslashes instead of being unescaped.
proc take_force {line} {
    set force 0
    set out {}
    # a "quoted token" (so paths may contain spaces), else a run of non-space
    foreach a [regexp -all -inline {"[^"]*"|\S+} $line] {
        if {[string match {"*"} $a]} { set a [string range $a 1 end-1] }
        if {$a eq "-f" || $a eq "--force"} { set force 1 } else { lappend out $a }
    }
    return [list $force $out]
}

proc printable {b} {
    if {$b >= 0x20 && $b < 0x7F} { return [format %c $b] }
    return "."
}

# ------------------------------------------------------------- operations
# 'w' is a PURE WRITE - one bus transaction, nothing else. Use 'wv' if you
# want the old write-then-read-back behaviour. Keeping them separate matters
# on slave 3: the read back is a SPLIT transaction, so a plain 'w' no longer
# drags the split path into every write you type.
proc do_write {addr data force {verify 0}} {
    global MASTER REMOTE
    if {!$force} {
        set no [why_not $addr 1]
        if {$no ne ""} { puts "  ! $no"; return }
    }
    lassign [region $addr] nm lo hi kind note

    bus_write $MASTER $addr $data
    puts [format "  M%d %swrite 0x%02X -> 0x%04X   (%s)" \
              [expr {$MASTER + 1}] [expr {$REMOTE ? "REMOTE " : ""}] \
              $data $addr $nm]
    if {[check_link]}  { return }
    if {[check_wedge]} { return }

    if {!$verify} { return }

    if {$kind ne "mem"} {
        puts "  -> $nm is not a plain memory; nothing to read back"
        return
    }
    set rd [bus_read $MASTER $addr]
    if {[check_link]}  { return }
    if {[check_wedge]} { return }
    if {$rd == $data} {
        puts [format "  -> read back 0x%02X   PASS" $rd]
    } else {
        puts [format "  -> read back 0x%02X   MISMATCH, expected 0x%02X" $rd $data]
    }
}

proc do_read {addr force} {
    global MASTER REMOTE
    if {!$force} {
        set no [why_not $addr 0]
        if {$no ne ""} { puts "  ! $no"; return }
    }
    lassign [region $addr] nm lo hi kind note
    set rd [bus_read $MASTER $addr]
    if {[check_link]}  { return }
    if {[check_wedge]} { return }
    puts [format "  M%d %sread 0x%04X = 0x%02X  '%s'   (%s)" \
              [expr {$MASTER + 1}] [expr {$REMOTE ? "REMOTE " : ""}] \
              $addr $rd [printable $rd] $nm]
}

# Classic hex dump, 16 bytes per row, aligned to a 16-byte boundary.
proc do_dump {addr n force} {
    global MASTER
    if {!$force} {
        set no [why_not $addr 0]
        if {$no ne ""} { puts "  ! $no"; return }
        set no [why_not [expr {$addr + $n - 1}] 0]
        if {$no ne ""} { puts "  ! end of range: $no"; return }
    }
    if {$n > 256} {
        puts "  (that is $n JTAG round trips - roughly [expr {$n / 20}] s)"
    }
    set end   [expr {$addr + $n - 1}]
    set start [expr {$addr & ~0xF}]
    puts ""
    for {set row $start} {$row <= $end} {incr row 16} {
        set hexpart ""
        set ascii   ""
        for {set c 0} {$c < 16} {incr c} {
            set a [expr {$row + $c}]
            if {$a < $addr || $a > $end} {
                append hexpart "   "
                append ascii   " "
            } else {
                set b [bus_read $MASTER $a]
                append hexpart [format "%02X " $b]
                append ascii   [printable $b]
            }
            if {$c == 7} { append hexpart " " }
        }
        puts [format "  %04X  %-49s |%s|" $row $hexpart $ascii]
        flush stdout
        if {[check_wedge]} { return }
    }
    puts ""
}

proc do_fill {addr n val force} {
    global MASTER
    if {!$force} {
        set no [why_not $addr 1]
        if {$no ne ""} { puts "  ! $no"; return }
    }
    puts [format "  filling 0x%04X-0x%04X with 0x%02X ..." \
              $addr [expr {$addr + $n - 1}] $val]
    for {set i 0} {$i < $n} {incr i} {
        bus_write $MASTER [expr {$addr + $i}] $val
        if {[check_wedge]} { return }
    }
    puts "  -> $n bytes written"
}

# Write a distinct value to every byte in the range, then read them all back.
# This is the "is this memory actually good" pass.
proc do_test {addr n force} {
    global MASTER
    if {!$force} {
        set no [why_not $addr 0]
        if {$no ne ""} { puts "  ! $no"; return }
        set no [why_not [expr {$addr + $n - 1}] 0]
        if {$no ne ""} { puts "  ! end of range: $no"; return }
    }
    lassign [region $addr] nm lo hi kind note
    puts [format "  testing %s, 0x%04X-0x%04X (%d bytes)" \
              $nm $addr [expr {$addr + $n - 1}] $n]

    # The value is keyed to the whole address, high byte folded in, so two
    # cells that alias onto the same word disagree and show as a mismatch.
    for {set i 0} {$i < $n} {incr i} {
        set a [expr {$addr + $i}]
        bus_write $MASTER $a [expr {(($a >> 8) ^ $a ^ 0x5A) & 0xFF}]
        if {[check_wedge]} { return }
    }
    set bad 0
    for {set i 0} {$i < $n} {incr i} {
        set a    [expr {$addr + $i}]
        set want [expr {(($a >> 8) ^ $a ^ 0x5A) & 0xFF}]
        set got  [bus_read $MASTER $a]
        if {[check_wedge]} { return }
        if {$got != $want} {
            incr bad
            if {$bad <= 8} {
                puts [format "    0x%04X  wrote 0x%02X  read 0x%02X  BAD" $a $want $got]
            } elseif {$bad == 9} {
                puts "    ... further mismatches not listed"
            }
        }
    }
    if {$bad == 0} {
        puts "  -> PASS: $n/$n bytes verified"
    } else {
        puts "  -> FAIL: $bad of $n bytes wrong"
    }
}

proc do_save {fname addr n force} {
    global MASTER
    if {!$force} {
        set no [why_not $addr 0]
        if {$no ne ""} { puts "  ! $no"; return }
    }
    if {[catch {set fh [open $fname w]} err]} { puts "  ! $err"; return }
    puts $fh "# Sytembus memory dump, base 0x[format %04X $addr], $n bytes"
    set line ""
    for {set i 0} {$i < $n} {incr i} {
        append line [format "%02X " [bus_read $MASTER [expr {$addr + $i}]]]
        if {[check_wedge]} { close $fh; return }
        if {($i % 16) == 15} { puts $fh [string trim $line]; set line "" }
    }
    if {$line ne ""} { puts $fh [string trim $line] }
    close $fh
    puts "  -> wrote $n bytes to $fname"
}

proc do_load {fname addr force} {
    global MASTER
    if {!$force} {
        set no [why_not $addr 1]
        if {$no ne ""} { puts "  ! $no"; return }
    }
    if {[catch {set fh [open $fname r]} err]} { puts "  ! $err"; return }
    set bytes {}
    while {[gets $fh line] >= 0} {
        regsub {#.*$} $line "" line
        foreach tok $line {
            set b [parse_hex $tok]
            if {$b >= 0 && $b <= 0xFF} { lappend bytes $b }
        }
    }
    close $fh
    set n [llength $bytes]
    if {$n == 0} { puts "  ! no hex bytes found in $fname"; return }
    puts [format "  loading %d bytes from %s to 0x%04X ..." $n $fname $addr]
    set i 0
    foreach b $bytes {
        bus_write $MASTER [expr {$addr + $i}] $b
        if {[check_wedge]} { return }
        incr i
    }
    puts "  -> $n bytes written"
}

# Both masters write on the same clock edge, then each reads its own cell back.
# Aim them at DIFFERENT slaves to exercise the decoder, or the SAME cell to see
# which master won the arbitration.
proc do_pair_write {a1 d1 a2 d2 force} {
    if {!$force} {
        foreach a [list $a1 $a2] {
            set no [why_not $a 1]
            if {$no ne ""} { puts "  ! $no"; return }
        }
    }
    lassign [region $a1] nm1
    lassign [region $a2] nm2
    puts [format "  M1 write 0x%02X -> 0x%04X  (%s)" $d1 $a1 $nm1]
    puts [format "  M2 write 0x%02X -> 0x%04X  (%s)" $d2 $a2 $nm2]
    puts "  both valid bits set in one 52-bit source write - same clock edge"

    bus_pair 1 $a1 $d1 $a2 $d2
    if {[check_wedge 0]} { return }
    if {[check_wedge 1]} { return }

    set ok 1
    foreach m {0 1} a [list $a1 $a2] d [list $d1 $d2] {
        lassign [region $a] nm lo hi kind note
        if {$kind ne "mem"} {
            puts "  -> M[expr {$m+1}]: $nm is not a plain memory, not verified"
            continue
        }
        set rd [bus_read $m $a]
        if {[check_wedge $m]} { return }
        if {$rd == $d} {
            puts [format "  -> M%d read back 0x%02X from 0x%04X   PASS" \
                      [expr {$m+1}] $rd $a]
        } else {
            puts [format "  -> M%d read back 0x%02X from 0x%04X   MISMATCH, expected 0x%02X" \
                      [expr {$m+1}] $rd $a $d]
            set ok 0
        }
    }
    if {$a1 == $a2} {
        puts "  NOTE: same address - the surviving byte is whichever master"
        puts "        the arbiter granted LAST."
    } elseif {$ok} {
        puts "  NOTE: both landed, so the arbiter served each master in turn."
        puts "        Grant ORDER is not observable from JTAG (a transaction"
        puts "        finishes in ns, a probe read takes ms) - see final_tb.sv."
    }
}

# Both masters read on the same clock edge; one probe word carries both bytes.
proc do_pair_read {a1 a2 force} {
    if {!$force} {
        foreach a [list $a1 $a2] {
            set no [why_not $a 0]
            if {$no ne ""} { puts "  ! $no"; return }
        }
    }
    set p [bus_pair 0 $a1 0 $a2 0]
    set r1 [bits $p 7 0]
    set r2 [bits $p 16 9]
    if {[check_wedge 0]} { return }
    if {[check_wedge 1]} { return }
    lassign [region $a1] nm1
    lassign [region $a2] nm2
    puts [format "  M1 read 0x%04X = 0x%02X  '%s'   (%s)" $a1 $r1 [printable $r1] $nm1]
    puts [format "  M2 read 0x%04X = 0x%02X  '%s'   (%s)" $a2 $r2 [printable $r2] $nm2]
}

proc show_help {} {
    puts ""
    puts "  r <addr>                read one byte          e.g.  r 1ABC"
    puts "  w <addr> <byte>         WRITE ONLY, one bus transaction"
    puts "                                                 e.g.  w 1ABC 5A"
    puts "  wv <addr> <byte>        write, then read back and check"
    puts "                          (the read back is a second transaction,"
    puts "                           and on slave 3 it is a SPLIT read)"
    puts "  d <addr> \[n\]            hex dump, n hex, default 40  e.g.  d 1000 40"
    puts "  fill <addr> <n> <byte>  fill a range"
    puts "  test <addr> <n>         address-keyed write+verify sweep"
    puts "  save <file> <addr> <n>  dump a range to a hex file"
    puts "  load <file> <addr>      write a hex file into memory"
    puts ""
    puts "  pair w <a1> <d1> <a2> <d2>   BOTH masters write on the same edge"
    puts "  pair r <a1> <a2>             BOTH masters read on the same edge"
    puts ""
    puts "  m <1|2>                 which master issues commands"
    puts "  rem <0|1>               0 = our bus, 1 = the far board. ORs 0x8000"
    puts "                          into the address; works for BOTH masters."
    puts "                          Same as typing 0x8xxx/9xxx/Axxx directly."
    puts "  map                     memory map and current master"
    puts "  ready                   show dready bits and br_error"
    puts "  diag                    snapshot of bus AND link state - type this"
    puts "                          when something is WEDGED or a far access"
    puts "                          fails. Names the faulty stage in words."
    puts "  pintest                 DC level of the rx pin - ground JP1 pin 4"
    puts "                          and it must read 0. Proves the pin itself."
    puts "  selftest                loops the link back INSIDE the fpga, so no"
    puts "                          pin, jumper or cable takes part. PASS means"
    puts "                          the design is sound and the fault is the"
    puts "                          wiring. Run this first when far access fails."
    puts "  delay \[settle drain\]    JTAG timing in ms (default 20 10)"
    puts "  h                       this help"
    puts "  q                       quit"
    puts ""
    puts "  All values are hex. Addresses are absolute 16-bit bus addresses."
    puts "  Add -f to force an access the map says is unsafe."
    puts ""
}

# ------------------------------------------------------------------ connect
puts "============================================================"
puts "   SYTEMBUS INTERACTIVE MEMORY CONSOLE   (ISSP over JTAG)"
puts "============================================================"

set IN_GUI 0
if {[info exists quartus(nameofexecutable)]} {
    set IN_GUI [expr {$quartus(nameofexecutable) eq "quartus"}]
}
proc script_exit {code} {
    global IN_GUI
    if {$IN_GUI} { return -code return } else { exit $code }
}

if {[catch {load_package insystem_source_probe}] || [catch {load_package jtag}]} {
    puts "FATAL: the JTAG / In-System Sources and Probes Tcl packages are not"
    puts "       available in this interpreter."
    puts ""
    puts "       Run from a terminal with quartus_stp:"
    puts "           quartus_stp -t issp_console.tcl"
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

set SRC 0
set LAST_FAR 0
src_flush
idle_all

set p [probe]
puts [format "Masters  : M1 dready=%d   M2 dready=%d   br_error=%d" \
          [bits $p 8 8] [bits $p 17 17] [bits $p 18 18]]
if {[bits $p 8 8] == 0 || [bits $p 17 17] == 0} {
    puts "           (a low dready means that master is mid-transaction or"
    puts "            wedged - press KEY\[0\] before starting)"
} else {
    # Bitstream fingerprint. Old copies of this project keep ending up on the
    # board while the console (this file) is current, which looks like RTL
    # bugs. One far read settles it: the current design has a bridge at
    # 0x8000, and with no far board answering it times out and sets br_error.
    # An old bitstream has nothing at 0x8000 - no ack, no error, stale data.
    bus_read 0 0x8100
    if {[rem_error]} {
        puts "Bitstream: CURRENT - bridge present at 0x8000 (no far board"
        puts "           answering, so br_error is set; that is expected)"
    } else {
        puts "Bitstream: !! NO TIMEOUT on a far read. If no cable is attached"
        puts "           this is an OLD BITSTREAM with no bridge - program"
        puts "           output_files/Sytembus.sof and restart this console."
        puts "           (with a live far board answering, ignore this line)"
    }
}

show_map
show_help

# --------------------------------------------------------------------- main
while {1} {
    puts -nonewline "M[expr {$MASTER + 1}][expr {$REMOTE ? {*} : {}}]> "
    flush stdout
    if {[gets stdin line] < 0} break
    set line [string trim $line]
    if {$line eq ""} { continue }
    lassign [take_force $line] force argv
    set cmd [string tolower [lindex $argv 0]]

    switch -- $cmd {
        q - quit - exit { break }
        h - help - "?"  { show_help }
        map             { show_map }

        ready {
            set p [probe]
            puts [format "  M1 dready=%d   M2 dready=%d   br_error=%d" \
                      [bits $p 8 8] [bits $p 17 17] [bits $p 18 18]]
            if {[bits $p 18 18]} {
                puts "  (br_error is sticky: set by the last far READ that got"
                puts "   no answer, cleared by the next far access. It says"
                puts "   nothing about local slaves.)"
            }
        }

        delay {
            if {[llength $argv] >= 3} {
                set SETTLE [lindex $argv 1]
                set DRAIN  [lindex $argv 2]
            }
            puts "  settle=${SETTLE}ms  drain=${DRAIN}ms  (~[expr {$SETTLE + $DRAIN}]ms per access)"
        }

        m {
            set v [lindex $argv 1]
            if {$v eq "1" || $v eq "2"} {
                set MASTER [expr {$v - 1}]
                puts "  master = M$v"
            } else {
                puts "  ! usage: m 1   or   m 2"
            }
        }

        rem - remote {
            set v [lindex $argv 1]
            if {$v eq "0" || $v eq "1"} {
                set REMOTE $v
                if {$REMOTE} {
                    puts "  addresses now get 0x8000 ORed in: the FAR board."
                    puts "  (applies to BOTH masters - the link is a bus device.)"
                } else {
                    puts "  addresses now run on our own bus."
                }
            } else {
                puts "  ! usage: rem 0   (local)   or   rem 1   (far board)"
                puts "    currently: [expr {$REMOTE ? {far board} : {local}}]"
            }
        }

        diag     { show_diag }
        selftest { selftest }
        pintest  { pintest }

        r {
            if {[llength $argv] >= 2} {
                set a [parse_hex [lindex $argv 1]]
            } else {
                set a [parse_hex [ask "  Address (hex): "]]
            }
            if {$a < 0 || $a > 0xFFFF} { puts "  ! need a 16-bit hex address" } \
            else { do_read $a $force }
        }

        w - wv {
            if {[llength $argv] >= 3} {
                set a [parse_hex [lindex $argv 1]]
                set d [parse_hex [lindex $argv 2]]
            } else {
                set a [parse_hex [ask "  Address (hex): "]]
                set d [parse_hex [ask "  Data (hex):    "]]
            }
            if {$a < 0 || $a > 0xFFFF} {
                puts "  ! need a 16-bit hex address"
            } elseif {$d < 0 || $d > 0xFF} {
                puts "  ! data is one byte (0x00-0xFF)"
            } else {
                # w = write only, wv = write then read back and check
                do_write $a $d $force [expr {$cmd eq "wv"}]
            }
        }

        d - dump {
            if {[llength $argv] >= 2} {
                set a [parse_hex [lindex $argv 1]]
                set n [expr {[llength $argv] >= 3 ? [parse_hex [lindex $argv 2]] : 64}]
            } else {
                set a [parse_hex [ask "  Address (hex): "]]
                set n [parse_hex [ask "  Count (hex, blank = 40): "]]
                if {$n < 0} { set n 64 }
            }
            if {$a < 0 || $a > 0xFFFF || $n <= 0} {
                puts "  ! need a hex address and a positive count"
            } else {
                do_dump $a $n $force
            }
        }

        fill {
            if {[llength $argv] >= 4} {
                set a [parse_hex [lindex $argv 1]]
                set n [parse_hex [lindex $argv 2]]
                set v [parse_hex [lindex $argv 3]]
            } else {
                set a [parse_hex [ask "  Address (hex): "]]
                set n [parse_hex [ask "  Count (hex):   "]]
                set v [parse_hex [ask "  Byte (hex):    "]]
            }
            if {$a < 0 || $n <= 0 || $v < 0 || $v > 0xFF} {
                puts "  ! usage: fill <addr> <count> <byte>, all hex"
            } else {
                do_fill $a $n $v $force
            }
        }

        test {
            if {[llength $argv] >= 3} {
                set a [parse_hex [lindex $argv 1]]
                set n [parse_hex [lindex $argv 2]]
            } else {
                set a [parse_hex [ask "  Address (hex): "]]
                set n [parse_hex [ask "  Count (hex):   "]]
            }
            if {$a < 0 || $n <= 0} {
                puts "  ! usage: test <addr> <count>, both hex"
            } else {
                do_test $a $n $force
            }
        }

        pair {
            set sub [string tolower [lindex $argv 1]]
            if {$sub eq "w"} {
                if {[llength $argv] >= 6} {
                    set a1 [parse_hex [lindex $argv 2]]
                    set d1 [parse_hex [lindex $argv 3]]
                    set a2 [parse_hex [lindex $argv 4]]
                    set d2 [parse_hex [lindex $argv 5]]
                } else {
                    set a1 [parse_hex [ask "  M1 address (hex): "]]
                    set d1 [parse_hex [ask "  M1 data (hex):    "]]
                    set a2 [parse_hex [ask "  M2 address (hex): "]]
                    set d2 [parse_hex [ask "  M2 data (hex):    "]]
                }
                if {$a1 < 0 || $a2 < 0 || $a1 > 0xFFFF || $a2 > 0xFFFF} {
                    puts "  ! need two 16-bit hex addresses"
                } elseif {$d1 < 0 || $d1 > 0xFF || $d2 < 0 || $d2 > 0xFF} {
                    puts "  ! each data value is one byte (0x00-0xFF)"
                } else {
                    do_pair_write $a1 $d1 $a2 $d2 $force
                }
            } elseif {$sub eq "r"} {
                if {[llength $argv] >= 4} {
                    set a1 [parse_hex [lindex $argv 2]]
                    set a2 [parse_hex [lindex $argv 3]]
                } else {
                    set a1 [parse_hex [ask "  M1 address (hex): "]]
                    set a2 [parse_hex [ask "  M2 address (hex): "]]
                }
                if {$a1 < 0 || $a2 < 0 || $a1 > 0xFFFF || $a2 > 0xFFFF} {
                    puts "  ! need two 16-bit hex addresses"
                } else {
                    do_pair_read $a1 $a2 $force
                }
            } else {
                puts "  ! usage: pair w <a1> <d1> <a2> <d2>   or   pair r <a1> <a2>"
            }
        }

        save {
            if {[llength $argv] >= 4} {
                set f [lindex $argv 1]
                set a [parse_hex [lindex $argv 2]]
                set n [parse_hex [lindex $argv 3]]
            } else {
                set f [ask "  File:          "]
                set a [parse_hex [ask "  Address (hex): "]]
                set n [parse_hex [ask "  Count (hex):   "]]
            }
            if {$f eq "" || $a < 0 || $n <= 0} {
                puts "  ! usage: save <file> <addr> <count>"
            } else {
                do_save $f $a $n $force
            }
        }

        load {
            if {[llength $argv] >= 3} {
                set f [lindex $argv 1]
                set a [parse_hex [lindex $argv 2]]
            } else {
                set f [ask "  File:          "]
                set a [parse_hex [ask "  Address (hex): "]]
            }
            if {$f eq "" || $a < 0} {
                puts "  ! usage: load <file> <addr>"
            } else {
                do_load $f $a $force
            }
        }

        default { puts "  ! unknown command \"$cmd\" - type h for help" }
    }
}

puts "\nclosing session."
idle_all
end_insystem_source_probe
script_exit 0
