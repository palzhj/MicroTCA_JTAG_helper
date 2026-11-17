#--------------------------------------------------------------------------------
# program_chain.tcl
#
# Program the FPGAs on the JTAG chain that the NAT-JSM currently routes to the
# front-panel connector: RTM first, then AMC.
#
# The caller must select the MCH channel for the slot before invoking this.
#
# Connection, target selection, JTAG clock and device matching follow
# ddr4_selftest/scripts/program_fpga.tcl so that behaviour is consistent with
# the standalone programmer used for the u4FCP v2 board.
#
# Batch usage:
#   vivado -mode batch -nojournal -nolog -source program_chain.tcl \
#          -tclargs <rtm_bit|none> <amc_bit|none> [jtag_freq_hz] [hw_server_url] \
#                   [rtm_dev] [amc_dev]
#
#     jtag_freq_hz    default: 10000000 (10 MHz)
#     hw_server_url   default: localhost:3121
#
# Markers parsed by program_fpgas.sh:
#   CHAIN_COUNT: <n>
#   CHAIN dev=<name> part=<part>
#   MISSING role=<RTM|AMC>
#   PROGRAM_BEGIN role=<role> dev=<name>
#   PROGRAM_FAIL  role=<role> dev=<name> error=<text>
#   PROGRAM_END   role=<role> dev=<name> is_programmed=<0|1|?>
#   ERROR: <reason>
#--------------------------------------------------------------------------------

proc die {msg} {
  # single line so the caller's log parser captures the whole reason
  puts ""
  puts "ERROR: [string map [list "\n" " " "\t" " "] $msg]"
  puts ""
  exit 1
}

proc msg {text} {
  puts "  $text"
}

# first device whose PART matches a glob, or ""
proc pick_part {devs pattern} {
  foreach d $devs {
    if {![catch {set p [get_property PART $d]}] && [string match -nocase $pattern $p]} {
      return $d
    }
  }
  return ""
}

proc do_program {role dev bit} {
  puts "PROGRAM_BEGIN role=$role dev=$dev"
  set t_start [clock milliseconds]

  set ltxfile "[file rootname $bit].ltx"
  if {[file exists $ltxfile]} {
    catch {set_property PROBES.FILE $ltxfile $dev}
    msg "probes      : $ltxfile"
  }

  if {[catch {
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
  } perr]} {
    puts "PROGRAM_FAIL role=$role dev=$dev error=[string map [list "\n" " "] $perr]"
    return 0
  }

  # PART is present on all supported parts; IS_PROGRAMMED is not, so keep it
  # optional and let the startup status be the authoritative DONE evidence.
  set prog "?"
  catch {set prog [get_property PROGRAM.IS_PROGRAMMED $dev]}

  # Authoritative DONE evidence: read the configuration status register. This is
  # far more reliable than scraping the startup message from the log, and
  # PROGRAM.IS_PROGRAMMED does not exist on UltraScale+.
  set done_pin "?"
  set eos "?"
  set crc "?"
  catch {set done_pin [get_property {REGISTER.CONFIG_STATUS.BIT[14]_DONE_PIN} $dev]}
  catch {set eos      [get_property {REGISTER.CONFIG_STATUS.BIT[04]_END_OF_STARTUP_(EOS)_STATUS} $dev]}
  catch {set crc      [get_property {REGISTER.CONFIG_STATUS.BIT[00]_CRC_ERROR} $dev]}
  puts "PROGRAM_STATUS role=$role dev=$dev done=$done_pin eos=$eos crc=$crc"

  puts "PROGRAM_TIME role=$role dev=$dev ms=[expr {[clock milliseconds] - $t_start}]"
  puts "PROGRAM_END role=$role dev=$dev is_programmed=$prog"
  return 1
}

# --- arguments ---------------------------------------------------------------
set rtm_bit     [lindex $argv 0]
set amc_bit     [lindex $argv 1]
set jtag_freq   [lindex $argv 2]
set hw_url      [lindex $argv 3]
set rtm_dev_req [lindex $argv 4]
set amc_dev_req [lindex $argv 5]
set prev_sig    [lindex $argv 6]

if {$jtag_freq eq ""} { set jtag_freq 10000000 }
if {$hw_url eq ""}    { set hw_url "localhost:3121" }

foreach {role bit} [list RTM $rtm_bit AMC $amc_bit] {
  if {$bit ne "none" && $bit ne ""} {
    if {![file exists $bit]} { die "$role bit file '$bit' not found" }
    if {$role eq "RTM"} { set rtm_bit [file normalize $bit] } else { set amc_bit [file normalize $bit] }
  }
}

if {![string is integer -strict $jtag_freq] || $jtag_freq <= 0} {
  die "invalid JTAG frequency '$jtag_freq' (expected an integer in Hz)"
}

puts ""
puts "============================================================"
puts " u4FCP JTAG chain programming"
puts "============================================================"
msg "RTM bit     : $rtm_bit"
msg "AMC bit     : $amc_bit"
msg "JTAG clock  : $jtag_freq Hz"
msg "hw_server   : $hw_url"
puts ""

# --- connect to the hardware server ------------------------------------------
open_hw_manager
if {[catch {connect_hw_server -url $hw_url} err]} {
  if {[string match "*localhost*" $hw_url] || [string match "*127.0.0.1*" $hw_url]} {
    msg "starting a local hw_server and retrying ..."
    catch {exec hw_server -d &}
    after 3000
    if {[catch {connect_hw_server -url $hw_url} err2]} {
      die "cannot connect to hw_server ($hw_url): $err2\n       is a JTAG cable connected and the driver installed?"
    }
  } else {
    die "cannot connect to hw_server ($hw_url): $err\n       start it on the remote machine with: hw_server -d"
  }
}

catch {refresh_hw_server}

# --- open the JTAG target ----------------------------------------------------
# get_hw_targets raises instead of returning an empty list when there is no
# target at all, so both cases are treated the same way here.
if {[catch {set targets [get_hw_targets]} err]} {
  set targets {}
}
if {[llength $targets] == 0} {
  die "no JTAG target found.\n       check the USB cable, the board power and (on Linux) the cable driver/udev rules"
}
set target [lindex $targets 0]
foreach t $targets {
  if {[string match -nocase "*localhost*" $t]} { set target $t; break }
}
current_hw_target $target
msg "JTAG target : $target"

# set the clock before opening the target; some cables only expose the property
# afterwards, so retry there
set freq_ok [expr {![catch {set_property PARAM.FREQUENCY $jtag_freq [current_hw_target]}]}]

if {[catch {open_hw_target} err]} {
  puts "  WARNING: open_hw_target failed ($err) - retrying at 1000000 Hz"
  catch {close_hw_target}
  catch {set_property PARAM.FREQUENCY 1000000 [current_hw_target]}
  if {[catch {open_hw_target} err2]} {
    die "cannot open the JTAG target: $err2"
  }
}

if {!$freq_ok} {
  set freq_ok [expr {![catch {set_property PARAM.FREQUENCY $jtag_freq [current_hw_target]}]}]
}
if {$freq_ok} {
  msg "JTAG clock set to [get_property PARAM.FREQUENCY [current_hw_target]] Hz"
} else {
  puts "  WARNING: this cable does not accept a JTAG frequency setting, the default frequency is used"
}

# --- find the FPGAs ----------------------------------------------------------
if {[catch {set devs [get_hw_devices]} err]} {
  set devs {}
}

# The first scan after a cable/hub state change can come back empty even with a
# healthy chain (observed on the bench pod). Retry once at 1 MHz, then restore
# the requested clock.
if {[llength $devs] == 0} {
  puts "  WARNING: no devices on first scan - retrying at 1000000 Hz"
  catch {close_hw_target}
  catch {set_property PARAM.FREQUENCY 1000000 [current_hw_target]}
  if {![catch {open_hw_target}]} {
    if {[catch {set devs [get_hw_devices]}]} { set devs {} }
    if {[llength $devs] > 0} {
      catch {set_property PARAM.FREQUENCY $jtag_freq [current_hw_target]}
      msg "JTAG clock restored to [get_property PARAM.FREQUENCY [current_hw_target]] Hz"
    }
  }
}

puts "CHAIN_COUNT: [llength $devs]"
foreach d $devs {
  catch {puts "CHAIN dev=$d part=[get_property PART $d]"}
}
if {[llength $devs] == 0} {
  die "no device found on the JTAG target - the chain is empty on this channel"
}

# AMC: u4FCP v2 carries an XCKU15P (fall back to any UltraScale/UltraScale+)
set amc_dev [pick_part $devs "xcku15p*"]
if {$amc_dev eq ""} { set amc_dev [pick_part $devs "xcku*"] }
if {$amc_dev eq ""} { set amc_dev [pick_part $devs "xcvu*"] }
if {$amc_dev eq ""} { set amc_dev [pick_part $devs "xczu*"] }

# RTM: Kintex-7
set rtm_dev [pick_part $devs "xc7k*"]
if {$rtm_dev eq ""} { set rtm_dev [pick_part $devs "xc7*"] }

if {$rtm_dev_req ne ""} { set rtm_dev $rtm_dev_req }
if {$amc_dev_req ne ""} { set amc_dev $amc_dev_req }

# A JTAG switch that is not routing leaves every slot looking identical. That
# would program the same FPGA over and over while reporting success, so stop
# before touching it.
# Identify the devices by DNA, not by part name: two slots holding the same
# board type legitimately have identical part names, but never identical DNA.
set sig ""
set sig_strong 1
foreach d $devs {
  set dna ""
  catch {set dna [get_property REGISTER.DNA $d]}
  if {$dna eq ""} {
    set sig_strong 0
    append sig "[get_property PART $d];"
  } else {
    append sig "$dna;"
  }
}
if {$prev_sig ne "" && $sig eq $prev_sig} {
  if {$sig_strong} {
    puts "CHAIN_UNCHANGED: $sig"
    die "same device DNA as the previous slot ($sig) - the channel did not reach a different device. Check that the JTAG pod is on the JSM front connector and not on the board's own programmer. Refusing to program the same FPGA twice"
  } else {
    puts "CHAIN_SIMILAR: $sig"
  }
}
puts "CHAIN_SIG: $sig"

# --- program: RTM first, then AMC -------------------------------------------
if {$rtm_bit ne "none" && $rtm_bit ne ""} {
  if {$rtm_dev eq ""} {
    puts "MISSING role=RTM"
  } else {
    do_program RTM $rtm_dev $rtm_bit
  }
}

if {$amc_bit ne "none" && $amc_bit ne ""} {
  if {$amc_dev eq ""} {
    puts "MISSING role=AMC"
  } else {
    do_program AMC $amc_dev $amc_bit
  }
}

# --- clean up ----------------------------------------------------------------
catch {close_hw_target}
catch {disconnect_hw_server}
catch {close_hw_manager}

exit 0
