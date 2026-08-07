# lm_i2c

[![ci](https://github.com/LogiMentor/lm_i2c/actions/workflows/ci.yml/badge.svg)](https://github.com/LogiMentor/lm_i2c/actions/workflows/ci.yml)

Dependency-free I2C master/controller and target cores written in portable
VHDL.

NXP UM10204 revision 7.0 uses the terms controller and target. This repository
uses that terminology in new interfaces and documentation. The existing public
controller entity remains named `lm_i2c_master` for interface compatibility;
the target entity is `lm_i2c_target`.

## Scope and reference

The synthesizable controller and target support I2C Standard-mode through
100 kHz and Fast-mode through 400 kHz. Fast-mode Plus and High-speed mode are
not supported.

Bus behavior and timing follow
[NXP UM10204, revision 7.0](https://www.nxp.com/docs/en/user-guide/UM10204.pdf).
This README defines the public interface and integration contract for the
repository.

## Highlights

- IEEE-library-only RTL that analyzes and synthesizes as VHDL-93
- reusable 7-bit controller and target cores without internal register maps
- one-byte commands plus an ownership-checked STOP-only command
- optional START or repeated START before the byte
- optional STOP after the byte
- ready/valid command and backpressured ready/valid response interfaces
- target RX and TX byte streams with application backpressure
- target-selected address and direction status without fixed memory behavior
- explicit local bus ownership and independent physical bus-busy detection
- indefinite clock stretching in every released-SCL phase
- multi-controller arbitration-loss detection without an automatic STOP
- conservative 300 ns SCL-fall-to-SDA-change hold
- active-high drive-low outputs for portable open-drain integration
- resolved-bus passive timing monitor and Bash/PowerShell regressions

The core has no clock-stretch timeout and does not implement automatic retry or
stuck-bus recovery.

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/lm_i2c_master.vhd` | Synthesizable controller RTL |
| `src/lm_i2c_target.vhd` | Synthesizable target RTL |
| `sim/tb_lm_i2c_master.vhd` | Resolved-bus functional and timing regression |
| `sim/tb_lm_i2c_master_reset.vhd` | Reset-abort phase regression |
| `sim/tb_lm_i2c_master_invalid.vhd` | Expected-failure generic checks |
| `sim/tb_lm_i2c_target.vhd` | Target functional, timing, and controller integration regression |
| `sim/tb_lm_i2c_target_reset.vhd` | Target reset-abort phase regression |
| `sim/tb_lm_i2c_target_invalid.vhd` | Target expected-failure generic checks |
| `sim/run_ghdl.sh` | Bash regression entry point |
| `sim/run_ghdl.ps1` | Native PowerShell regression entry point |
| `tools/check_repo_hygiene.sh` | Bash repository policy checker |
| `tools/check_repo_hygiene.ps1` | PowerShell repository policy checker |

## Generics

```vhdl
g_clk_freq_hz : positive;
g_i2c_freq_hz : positive := 100_000
```

`g_clk_freq_hz` is required and must be at least eight times
`g_i2c_freq_hz`. The frequency must not exceed 400 kHz. Unsupported
combinations fail an assertion.

For `lm_i2c_master`, `g_i2c_freq_hz` is the requested maximum generated SCL
frequency. For `lm_i2c_target`, it is the maximum expected external SCL
frequency; a slower external controller is supported without reconfiguration.
The target also asserts that the mode-specific minimum LOW time contains enough
system-clock cycles for its synchronized stretch-takeover strategy. This
derived check can reject a marginal intermediate-frequency combination even
when its integer frequency ratio is exactly 8:1; increasing
`g_clk_freq_hz` resolves it.

## Controller public interface

### Clock and command

| Port | Direction | Meaning |
| --- | --- | --- |
| `clk_i` | input | system clock |
| `rst_n_i` | input | active-low synchronous reset |
| `bus_assume_free_i` | input | Permit HIGH+tBUF bus-free qualification without an observed STOP. |
| `cmd_valid_i` | input | command fields are valid |
| `cmd_ready_o` | output | command can be accepted |
| `cmd_start_i` | input | prepend START or repeated START |
| `cmd_stop_i` | input | append STOP |
| `cmd_stop_only_i` | input | generate only STOP; ignore other command fields |
| `cmd_read_i` | input | zero writes; one reads |
| `cmd_data_i[7:0]` | input | byte transmitted by a write |
| `cmd_nack_i` | input | bit transmitted after a read |

`bus_assume_free_i` must be static or synchronous to `clk_i`. It is sampled
directly and is not synchronized inside the core.

A command is accepted on a rising `clk_i` edge when `cmd_valid_i` and
`cmd_ready_o` are both high. All command fields must remain stable for that
edge.

With `cmd_stop_only_i = '0'`, every command transfers exactly one byte:

- `cmd_read_i = '0'` writes `cmd_data_i`;
- `cmd_read_i = '1'` reads one byte;
- for a read, `cmd_nack_i = '0'` transmits ACK and
  `cmd_nack_i = '1'` transmits NACK;
- `cmd_nack_i` is ignored by writes.

With `cmd_stop_only_i = '1'`, the command generates only STOP and ignores
`cmd_start_i`, `cmd_stop_i`, `cmd_read_i`, `cmd_data_i`, and `cmd_nack_i`.
STOP-only is legal only while the core owns the bus. It produces a successful
response when owned and a command-error response without bus activity when
unowned. It is useful after an address or data NACK because it releases the
bus without transmitting another byte or nine additional clock slots.

Standalone START-only commands are not part of the interface. The caller
builds address, register, payload, and read sequences from byte commands.

### Response and status

| Port | Direction | Meaning |
| --- | --- | --- |
| `rsp_valid_o` | output | one response is pending |
| `rsp_ready_i` | input | caller accepts the response |
| `rsp_data_o[7:0]` | output | byte received by a completed read |
| `rsp_nack_o` | output | write acknowledge sample; one means NACK |
| `rsp_arb_lost_o` | output | command lost arbitration |
| `rsp_cmd_error_o` | output | command was illegal without ownership |
| `busy_o` | output | command is executing or waiting for the bus |
| `bus_busy_o` | output | physical bus is active or not yet qualified free |

Every accepted command produces exactly one response unless reset cancels it.
`rsp_valid_o` and every response field remain stable until a rising edge with
`rsp_ready_i = '1'`. A pending response is never overwritten, and
`cmd_ready_o` remains low while that response is pending. Consuming a response
and accepting a new command on the same edge is not supported; the next
command can be accepted on the following edge.

`busy_o` describes command execution and waiting only. It can be low while a
response is pending; `cmd_ready_o` is the authoritative indication that
another command can be accepted.

`rsp_data_o` is meaningful for a successful read. `rsp_nack_o` is meaningful
for a completed write. Arbitration loss and command error are terminal for the
reported command.

### Resolved bus

| Port | Direction | Meaning |
| --- | --- | --- |
| `scl_i` | input | resolved SCL pad level |
| `sda_i` | input | resolved SDA pad level |
| `scl_low_o` | output | high requests that SCL be driven low |
| `sda_low_o` | output | high requests that SDA be driven low |

The core never drives a bus line high. Map each drive-low output to an
open-drain output-enable and return the resolved pad level to its input:

```vhdl
scl_io <= '0' when s_scl_low = '1' else 'Z';
sda_io <= '0' when s_sda_low = '1' else 'Z';

s_scl_in <= scl_io;
s_sda_in <= sda_io;
```

External pull-ups are required. Follow the target device's electrical and I/O
buffer guidance.

## Target public interface

### Configuration and status

| Port | Direction | Meaning |
| --- | --- | --- |
| `clk_i` | input | system clock |
| `rst_n_i` | input | active-low synchronous reset |
| `enable_i` | input | permit selection by the sampled address |
| `address_i[6:0]` | input | exact 7-bit target address |
| `active_o` | output | this target is selected in the current transfer |
| `read_o` | output | selected direction: zero is controller write, one is controller read |
| `addressed_o` | output | one-cycle pulse for each enabled address match |
| `stop_o` | output | one-cycle pulse for STOP while selected |

`enable_i` and `address_i` must be static or synchronous to `clk_i`. Both are
sampled at each synchronized START. Later changes cannot affect the current
address byte. Selection requires the sampled enable value to be high and bits
7 through 1 of the received address byte to match the sampled address exactly.
Bit 0 becomes `read_o`. General call and 10-bit address recognition are not
implemented.

An enabled match asserts `active_o`, updates `read_o`, pulses `addressed_o`,
and ACKs the address. A repeated START immediately cancels the old selection
and begins a new sampled address phase. A repeated match pulses
`addressed_o` again. A mismatch or disabled target never ACKs, stretches,
drives SDA, or emits an application handshake.

`active_o` remains high after an application NACK or controller NACK while the
core waits for STOP or repeated START. STOP while selected releases both lines,
clears `active_o`, returns `read_o` to zero, and pulses `stop_o`. STOP while not
selected produces no target transaction event.

### Controller-to-target stream

| Port | Direction | Meaning |
| --- | --- | --- |
| `rx_valid_o` | output | one received byte is pending |
| `rx_ready_i` | input | application accepts or rejects the pending byte |
| `rx_data_o[7:0]` | output | received byte, MSB first on the bus |
| `rx_nack_i` | input | decision captured with the RX handshake; one requests NACK |

After a selected controller-write byte, `rx_valid_o` is asserted with stable
`rx_data_o`. Both remain stable until a rising `clk_i` edge with
`rx_ready_i = '1'`. The core stretches the following LOW phase until this
handshake occurs, so the byte cannot be overwritten and the application can
reject it without data loss.

`rx_nack_i` is meaningful only on the `rx_valid_o`/`rx_ready_i` handshake
edge. Zero transmits ACK and accepts another byte. One transmits NACK, releases
SDA, and suppresses all further RX bytes until STOP or repeated START.

### Target-to-controller stream

| Port | Direction | Meaning |
| --- | --- | --- |
| `tx_valid_i` | input | application presents one transmit byte |
| `tx_ready_o` | output | target is requesting and can capture that byte |
| `tx_data_i[7:0]` | input | byte captured on the TX handshake |

For a selected controller read, `tx_ready_o` remains high until a rising
`clk_i` edge with `tx_valid_i = '1'`. The complete byte is captured atomically
on that edge and is then transmitted MSB first. If it is unavailable when
needed, the target stretches SCL LOW indefinitely.

The TX handshake consumes the application byte before the controller later
ACKs or NACKs that byte on the bus. Controller ACK causes the target to request
the next byte. Controller NACK suppresses another request and leaves SDA
released until STOP or repeated START. The core contains only the
protocol-required byte register, not a transmit FIFO.

### Target bus synchronization, timing, and stretching

The target uses two synchronization flip-flops per resolved input and makes all
START, STOP, SCL-edge, data, ACK/NACK, and stretching decisions from those
synchronized values. Synchronizer latency is included in its LOW-phase
takeover assertion and test coverage. No analog or digital spike filtering is
claimed.

The target pulls SCL low only after observing a physical falling edge and only
while selected work requires more LOW time. It stretches for RX backpressure,
TX starvation, and the internal hold/setup interval needed for a
target-generated SDA transition. It never stretches while disabled, after an
address mismatch, or while otherwise passive. Releasing `scl_low_o` does not
complete a HIGH phase; the target waits until synchronized physical `scl_i`
has actually risen.

For address ACK, received-byte ACK/NACK, read-data bits, and release before the
controller ACK/NACK bit, the target first takes over the LOW phase, preserves a
conservative 300 ns from the physical SCL falling edge to its SDA change, then
preserves mode-specific tSU;DAT before releasing SCL. It never actively drives
either line high and never creates START or STOP.

### Target reset and abort behavior

Reset is synchronous and active low. On its rising `clk_i` edge it releases
SCL and SDA, clears selection and direction, clears the status pulses, discards
pending RX data and an accepted but not yet transmitted TX byte, cancels both
ready/valid handshakes, and clears all address and bit state. Reset immediately
ends local stretching.

Reset during a physical transfer does not generate STOP. The external
controller can therefore observe a NACK or incomplete transfer. A new target
transaction requires reset release followed by a fresh START; no stale RX or
TX handshake is retained.

## Ownership and bus-free behavior

Local ownership and physical bus state are intentionally separate.

After reset, the core releases SCL and SDA, clears local ownership and any
pending response, and keeps `bus_busy_o = '1'`. A continuously HIGH bus is not
by itself proof that another controller is idle: it may be a logic-one HIGH
phase in an active transfer.

The core qualifies the bus free after tBUF only when either:

- it observes a real STOP on synchronized SCL and SDA; or
- `bus_assume_free_i = '1'` and synchronized SCL and SDA remain continuously
  HIGH for the complete mode-specific tBUF interval.

`bus_assume_free_i` must be static or synchronous to `clk_i`. It is sampled
directly and is not synchronized inside the core.

Tie `bus_assume_free_i` low when reset may occur during another controller's
transfer. In that mode the core waits indefinitely for an observed STOP. Tie
it high only when system integration guarantees reset is released onto an
idle, released bus. This assumption cannot protect against resetting the core
in the middle of a foreign transfer whose current SCL and SDA levels are both
HIGH. Assertion while either line is LOW never qualifies the bus, and reset
always clears an earlier qualification.

For an accepted command with `cmd_start_i = '1'`:

- without local ownership, the core waits internally until the physical bus
  is qualified free, then generates an initial START;
- with local ownership, the core generates a repeated START after a complete
  tLOW preparation interval.

The waiting command keeps `cmd_ready_o` low and `busy_o` high. It never pulls
SDA low in the middle of another controller's transfer.

A command without `cmd_start_i` is legal only while this core owns the bus. If
there is no ownership, the command produces a deterministic
`rsp_cmd_error_o = '1'` response without bus activity.

Ownership begins when this core successfully generates START and ends when it
generates STOP, loses arbitration, or is reset.

## Clock stretching and arbitration

Whenever the controller releases SCL, it waits for synchronized physical
`scl_i = '1'` before starting the HIGH timer. SDA remains stable throughout
the wait. Stretching is indefinite; reset is the local way to abort a stuck
command.

Arbitration is checked whenever the controller transmits a released logic one
while physical SCL is high, including the NACK after a read. If physical SDA is
low, the core:

1. releases SCL and SDA;
2. clears local ownership;
3. produces one stable response with `rsp_arb_lost_o = '1'`;
4. does not generate STOP;
5. keeps physical `bus_busy_o` asserted until the winning controller issues a
   real STOP and the bus is subsequently qualified free.

Automatic arbitration retry is intentionally left to the caller.

## Transfer examples

The caller transmits a 7-bit address as `address[6:0] & direction`. Address
`0x50` is therefore `0xA0` for write and `0xA1` for read.

### Register write

Write `0xA5` to register `0x12` at address `0x50`:

| Command | START | STOP | STOP_ONLY | READ | DATA |
| --- | ---: | ---: | ---: | ---: | --- |
| Address + write direction | 1 | 0 | 0 | 0 | `0xA0` |
| Register index | 0 | 0 | 0 | 0 | `0x12` |
| Payload | 0 | 1 | 0 | 0 | `0xA5` |

Require `rsp_nack_o = '0'` on each write response.

### Combined register read

Read register `0x12` from address `0x50`:

| Command | START | STOP | STOP_ONLY | READ | NACK | DATA |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Address + write direction | 1 | 0 | 0 | 0 | ignored | `0xA0` |
| Register index | 0 | 0 | 0 | 0 | ignored | `0x12` |
| Repeated START + read direction | 1 | 0 | 0 | 0 | ignored | `0xA1` |
| Read final byte | 0 | 1 | 0 | 1 | 1 | ignored |

For a multi-byte read, use `cmd_nack_i = '0'` to ACK every byte except the
last, then use `cmd_nack_i = '1'` to NACK the final byte.

### NACK recovery

If an address or data write returns `rsp_nack_o = '1'` without an appended
STOP, submit a command with `cmd_stop_only_i = '1'`. The response confirms
that STOP completed. No dummy data byte is placed on the bus.

## Target application examples

The target deliberately assigns no meaning to byte values. A register index,
payload, command, or memory pointer is an application-level convention above
this core.

### Small target write

For target address `0x52`, a controller sends address byte `0xA4` followed by
`0x12` and STOP:

1. `addressed_o` pulses, `active_o = '1'`, and `read_o = '0'`.
2. `rx_valid_o` rises with `rx_data_o = 0x12`.
3. The application presents `rx_ready_i = '1'` and `rx_nack_i = '0'` on one
   rising `clk_i` edge, consuming and ACKing the byte.
4. STOP clears `active_o` and pulses `stop_o`.

To reject `0x12`, the application performs the same handshake with
`rx_nack_i = '1'`. The target sends NACK and accepts no later byte in that
transfer.

### Small target read

For address byte `0xA5`, the target pulses `addressed_o` with `read_o = '1'`
and asserts `tx_ready_o`. The application holds `tx_valid_i = '1'` and
`tx_data_i = 0x3C` until the handshake edge. The target then transmits `0x3C`.
If the controller ACKs, `tx_ready_o` requests another byte. If it NACKs, no
new byte is requested.

### Controller and target integration

The two cores can share the same resolved open-drain bus in a system or
testbench:

```vhdl
s_scl <= '0' when
  s_controller_scl_low = '1' or s_target_scl_low = '1'
  else '1';
s_sda <= '0' when
  s_controller_sda_low = '1' or s_target_sda_low = '1'
  else '1';

-- Feed s_scl and s_sda to scl_i and sda_i on both lm_i2c_master and
-- lm_i2c_target. Connect each entity's drive-low outputs to the corresponding
-- controller or target terms above.
```

For a write to target `0x52`, `lm_i2c_master` first submits `0xA4` with START,
then submits the payload byte. The target pulses `addressed_o` and delivers the
payload through RX. For a read, the controller submits `0xA5`, the target
accepts TX data, and the controller submits a read command. A combined
register-style transfer is built from a write address and application-defined
index, repeated START with `0xA5`, then one or more read commands. The target
core itself does not store or increment the index.

## Timing and achieved frequency

All published minimum times are converted to system-clock cycles with ceiling
division. Standard-mode limits are selected through 100 kHz; Fast-mode limits
are selected above 100 kHz through 400 kHz.

The internal values are conceptually:

```text
period_cycles = ceil(g_clk_freq_hz / g_i2c_freq_hz)
hold_cycles   = ceil(g_clk_freq_hz * 300 ns)
low_cycles    = max(ceil(g_clk_freq_hz * tLOW),
                    hold_cycles + ceil(g_clk_freq_hz * tSU;DAT))
high_cycles   = max(ceil(g_clk_freq_hz * tHIGH),
                    period_cycles - low_cycles)
repeat_total  = max(high_cycles,
                    ceil(g_clk_freq_hz * tSU;STA) +
                    ceil(g_clk_freq_hz * tHD;STA))
```

The controller does not change the next SDA value until the deliberate hold
interval has elapsed after pulling SCL low. The remainder of tLOW preserves
the required data setup before SCL is released.

Repeated START reserves the mode-minimum hold interval and assigns the
remaining `repeat_total` cycles to setup. Consequently its setup and hold
minima are preserved while its complete HIGH side is never shorter than a
normal requested-frequency HIGH interval.

With no target stretching, the resolved SCL period is approximately:

```text
(low_cycles + high_cycles + 3) / g_clk_freq_hz
```

The additional cycles cover SCL release, the two input synchronizer stages,
and FSM observation before the HIGH timer runs. An asynchronous target release
can add up to one more `clk_i` cycle depending on its phase relative to the
system clock. This is a conservative timing model, not an exact-cycle promise.
Ceiling division and synchronization keep the achieved SCL frequency at or
below the requested value. Clock stretching reduces it further.

## Limitations

The repository does not implement:

- 10-bit target addressing or general-call recognition;
- Fast-mode Plus, High-speed mode, SMBus, or PMBus behavior;
- target register maps, RAM, automatic register pointers, or deep FIFOs;
- interrupts or AXI, Wishbone, or APB interfaces;
- stretch timeouts, stuck-bus recovery, or automatic controller retry;
- controller behavior inside `lm_i2c_target`.

Application-specific address maps, access policy, buffering, and recovery
belong above these byte-stream interfaces.

## Verification

GHDL 6 or later is recommended. Run the complete native PowerShell regression:

```powershell
./sim/run_ghdl.ps1
```

Run the Bash regression:

```bash
bash sim/run_ghdl.sh
```

Both runners:

- analyze and synthesize both RTL entities as VHDL-93;
- run 10 MHz with 50, 100, 137, 200, 333, and 400 kHz requests, plus
  12 MHz/100 kHz and 50 MHz/400 kHz for the controller;
- run the target at Standard-mode, Fast-mode, both 8:1 endpoint ratios, and
  with an actual 50 kHz controller below a configured 400 kHz maximum;
- run reset injection through every major controller and target bus phase;
- verify unsupported generic failures for their intended assertions;
- require unique functional and per-reset success markers for both entities;
- reject a zero-exit truncated simulation that did not reach its marker;
- remove temporary work on success and failure.

The main testbench uses a passive monitor that observes only resolved SCL and
SDA. It checks tLOW, tHIGH, requested frequency, START/repeated-START/STOP
timing, tBUF, data setup, the deliberate data hold, stable SDA while SCL is
high, and expected START/STOP counts. The target and competing-controller
models exercise late legal ACK/read-data changes, repeated-START and STOP-only
stretching, response backpressure, reset-time bus qualification, physical
bus-busy protection, and arbitration-loss behavior.

The target testbench instantiates the real synthesizable `lm_i2c_master` and
`lm_i2c_target` on one resolved bus and independently checks both application
streams. Its directed controller model additionally verifies disabled and
mismatched address passivity, exact ACK slots, RX backpressure and application
NACK, TX starvation and controller ACK/NACK, multi-byte transfers, repeated
START direction changes and deselection, sampled configuration, slower SCL,
and fresh transfers after reset. A passive monitor checks target SDA stability
while SCL is HIGH, the literal 300 ns hold policy, mode-specific data setup,
selected-only LOW extension, and open-drain release.

Repository policy checks are also available in both shells:

```powershell
./tools/check_repo_hygiene.ps1 -Mode Full
```

```bash
bash tools/check_repo_hygiene.sh --full
```

## License

Licensed under the [Apache License 2.0](LICENSE).
