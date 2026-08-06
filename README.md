# lm_i2c

[![ci](https://github.com/LogiMentor/lm_i2c/actions/workflows/ci.yml/badge.svg)](https://github.com/LogiMentor/lm_i2c/actions/workflows/ci.yml)

Dependency-free I2C master core written in portable VHDL.

This release provides the synthesizable `lm_i2c_master` controller. A
synthesizable target/slave core is planned for a later pull request.

## Scope and reference

The core supports I2C Standard-mode through 100 kHz and Fast-mode through
400 kHz. Fast-mode Plus and High-speed mode are not supported.

Bus behavior and timing follow
[NXP UM10204, revision 7.0](https://www.nxp.com/docs/en/user-guide/UM10204.pdf).
This README defines the public interface and integration contract for the
repository.

## Highlights

- IEEE-library-only RTL that analyzes and synthesizes as VHDL-93
- one-byte commands plus an ownership-checked STOP-only command
- optional START or repeated START before the byte
- optional STOP after the byte
- ready/valid command and backpressured ready/valid response interfaces
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
| `sim/tb_lm_i2c_master.vhd` | Resolved-bus functional and timing regression |
| `sim/tb_lm_i2c_master_reset.vhd` | Reset-abort phase regression |
| `sim/tb_lm_i2c_master_invalid.vhd` | Expected-failure generic checks |
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
`g_i2c_freq_hz`. The requested bus frequency must not exceed 400 kHz.
Unsupported combinations fail an assertion.

## Public interface

### Clock and command

| Port | Direction | Meaning |
| --- | --- | --- |
| `clk_i` | input | system clock |
| `rst_n_i` | input | active-low synchronous reset |
| `bus_assume_free_i` | input | permit reset-time HIGH+tBUF qualification |
| `cmd_valid_i` | input | command fields are valid |
| `cmd_ready_o` | output | command can be accepted |
| `cmd_start_i` | input | prepend START or repeated START |
| `cmd_stop_i` | input | append STOP |
| `cmd_stop_only_i` | input | generate only STOP; ignore other command fields |
| `cmd_read_i` | input | zero writes; one reads |
| `cmd_data_i[7:0]` | input | byte transmitted by a write |
| `cmd_nack_i` | input | bit transmitted after a read |

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

- analyze and synthesize the RTL as VHDL-93;
- run 10 MHz with 50, 100, 137, 200, 333, and 400 kHz requests, plus
  12 MHz/100 kHz and 50 MHz/400 kHz;
- run reset injection through every major bus phase;
- verify unsupported generic failures for their intended assertions;
- require the unique `lm_i2c_master self-check passed` marker;
- reject a zero-exit truncated simulation that did not reach that marker;
- remove temporary work on success and failure.

The main testbench uses a passive monitor that observes only resolved SCL and
SDA. It checks tLOW, tHIGH, requested frequency, START/repeated-START/STOP
timing, tBUF, data setup, the deliberate data hold, stable SDA while SCL is
high, and expected START/STOP counts. The target and competing-controller
models exercise late legal ACK/read-data changes, repeated-START and STOP-only
stretching, response backpressure, reset-time bus qualification, physical
bus-busy protection, and arbitration-loss behavior.

Repository policy checks are also available in both shells:

```powershell
./tools/check_repo_hygiene.ps1 -Mode Full
```

```bash
bash tools/check_repo_hygiene.sh --full
```

## License

Licensed under the [Apache License 2.0](LICENSE).
