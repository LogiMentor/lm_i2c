# I2C Master Core Specification

## 1. Scope

This document defines the public behavior of `lm_i2c_master`.

The core is a synchronous byte-command I2C controller. It generates and
observes bus signaling but does not impose a register bus, address width, or
transaction descriptor format on its caller. The caller constructs transfers
from START, write-byte, read-byte, and STOP operations.

The synthesizable I2C slave is not part of this specification.

The words **must**, **shall**, **should**, and **may** are normative when used
to describe the public interface.

## 2. Design requirements

| ID | Requirement |
| --- | --- |
| IM-001 | Synthesizable RTL shall use only IEEE VHDL libraries and no vendor primitive. |
| IM-002 | RTL shall analyze and synthesize as VHDL-93. |
| IM-003 | The controller shall support START, repeated START, STOP, byte write, and byte read operations. |
| IM-004 | A read command shall transmit caller-selected ACK or NACK after the received byte. |
| IM-005 | A write response shall report the received ACK/NACK bit. |
| IM-006 | The controller shall pause while released SCL remains low. |
| IM-007 | A nonzero timeout shall bound each wait for SCL to become high. |
| IM-008 | The controller shall release SCL and SDA after timeout, arbitration loss, or reset. |
| IM-009 | The controller shall report loss when it releases SDA during an arbitrated bit but samples SDA low. |
| IM-010 | The physical bus-busy indication shall track synchronized START and STOP conditions. |
| IM-011 | Reset shall be active-low, synchronous to `clk_i`, and shall not generate a response. |
| IM-012 | Invalid command combinations shall report an error without changing bus drive controls. |
| IM-013 | Commands shall use a ready/valid acceptance handshake and produce one response pulse. |

## 3. Clock and reset

All state, command, response, and bus-drive outputs are synchronous to the
rising edge of `clk_i`.

`rst_n_i` is an active-low synchronous reset. A rising `clk_i` edge with
`rst_n_i = '0'`:

- cancels an active command;
- clears response and error status;
- clears `bus_busy_o`;
- releases both open-drain controls;
- returns the command interface to idle.

No `rsp_valid_o` pulse is generated for a command canceled by reset.

SCL and SDA inputs pass through two synchronizer stages. Observable status and
clock-stretch release therefore lag physical pad changes by synchronizer
latency.

## 4. Generics

| Generic | Type | Default | Constraint | Description |
| --- | --- | ---: | --- | --- |
| `g_clk_freq_hz` | `positive` | 50,000,000 | at least 8 times `g_i2c_freq_hz` | `clk_i` frequency in hertz |
| `g_i2c_freq_hz` | `positive` | 100,000 | no more than 1,000,000 | requested SCL frequency in hertz |
| `g_timeout_cycles` | `natural` | 0 | none | maximum SCL-high wait in `clk_i` cycles; zero disables timeout |

Invalid frequency combinations fail an elaboration-time assertion.

## 5. Ports

### 5.1 Clock and reset

| Port | Direction | Description |
| --- | --- | --- |
| `clk_i` | input | system clock |
| `rst_n_i` | input | active-low synchronous reset |

### 5.2 Command interface

| Port | Direction | Description |
| --- | --- | --- |
| `cmd_valid_i` | input | command request |
| `cmd_ready_o` | output | high when a command can be accepted |
| `start_i` | input | prepend START or repeated START |
| `stop_i` | input | append STOP |
| `read_i` | input | read one byte and then transmit `ack_i` |
| `write_i` | input | write `data_i` and sample the target ACK/NACK |
| `ack_i` | input | bit transmitted after a read: zero for ACK, one for NACK |
| `data_i` | input | byte transmitted by a write command |

### 5.3 Response and status interface

| Port | Direction | Description |
| --- | --- | --- |
| `rsp_valid_o` | output | one-`clk_i`-cycle response pulse |
| `data_o` | output | most recently received byte |
| `nack_o` | output | sampled write acknowledge bit; one means NACK |
| `busy_o` | output | high while a command is executing |
| `bus_busy_o` | output | synchronized physical START/STOP bus state |
| `arb_lost_o` | output | command ended because released SDA was sampled low |
| `timeout_o` | output | command ended because an SCL-high wait expired |
| `cmd_error_o` | output | command controls were invalid |

`data_o`, `nack_o`, `arb_lost_o`, `timeout_o`, and `cmd_error_o` are valid
when `rsp_valid_o` is high and remain stable until the next command is
accepted. `nack_o` is meaningful only for a completed write command.

`busy_o` describes command execution. `bus_busy_o` describes START/STOP state
observed on the wires. The two signals are intentionally independent.

### 5.4 I2C bus interface

| Port | Direction | Description |
| --- | --- | --- |
| `scl_i` | input | resolved SCL pad level |
| `sda_i` | input | resolved SDA pad level |
| `scl_drive_low_o` | output | high requests that SCL be driven low |
| `sda_drive_low_o` | output | high requests that SDA be driven low |

The core never requests a driven-high bus value. The integrator must use an
open-drain output buffer or a tri-state mapping and must return the resolved
pad value to the input ports. External pull-ups are required.

For an inferred top-level bidirectional port:

```vhdl
scl_io <= '0' when s_scl_drive_low = '1' else 'Z';
sda_io <= '0' when s_sda_drive_low = '1' else 'Z';

s_scl_input <= scl_io;
s_sda_input <= sda_io;
```

Device-specific I/O constraints and electrical limits remain the integrator's
responsibility.

## 6. Command protocol

### 6.1 Acceptance

A command is accepted on a rising `clk_i` edge when both `cmd_valid_i` and
`cmd_ready_o` are high. The caller shall hold all command fields stable for
that edge.

`cmd_ready_o` is low during execution. It returns high with the response,
allowing the caller to present the next command for the following rising edge.
A continuously asserted `cmd_valid_i` represents a new command whenever the
ready/valid condition is met.

### 6.2 Valid combinations

`read_i` and `write_i` shall not both be high. At least one of `start_i`,
`stop_i`, `read_i`, or `write_i` shall be high.

Commands execute asserted operations in this fixed order:

1. START or repeated START;
2. one byte read or write;
3. STOP.

The following classes are valid:

| Command class | START | STOP | READ | WRITE |
| --- | ---: | ---: | ---: | ---: |
| START only | 1 | 0 | 0 | 0 |
| STOP only | 0 | 1 | 0 | 0 |
| write byte | optional | optional | 0 | 1 |
| read byte | optional | optional | 1 | 0 |
| START then STOP | 1 | 1 | 0 | 0 |

An invalid command sets `cmd_error_o`, produces a normal response pulse, and
does not change the current SCL or SDA drive state.

### 6.3 Response

Every accepted command that is not canceled by reset produces exactly one
`rsp_valid_o` pulse. The pulse occurs after all requested bus operations have
completed or after the command terminates with an error.

The caller should treat `arb_lost_o`, `timeout_o`, and `cmd_error_o` as
terminal errors. A NACK is a completed I2C byte transfer and is reported
separately on `nack_o`.

### 6.4 Bus state between commands

- A write or read without STOP completes with SCL held low and SDA released.
- A START-only command completes with both SCL and SDA held low.
- STOP, timeout, arbitration loss, and reset release both lines.

Holding SCL low permits arbitrary `clk_i` latency between byte commands without
allowing an unintended SCL edge.

## 7. Transfer construction

### 7.1 7-bit addressing

The caller transmits a 7-bit address as:

```text
address_byte = address[6:0] & direction
```

For address `0x50`, the write address byte is `0xA0` and the read address byte
is `0xA1`.

### 7.2 Byte write

To write one byte:

1. submit the address byte with START and WRITE;
2. require `nack_o = '0'` on the response;
3. submit the payload with WRITE and optional STOP;
4. require `nack_o = '0'` on the response.

The core does not automatically stop after a NACK. The caller chooses whether
the write command itself includes STOP or submits a later STOP-only command.

### 7.3 Byte read

To read one byte:

1. transmit the read address byte using WRITE because the controller is
   driving that address byte;
2. submit a READ command with `ack_i = '1'` for the final byte;
3. sample `data_o` with `rsp_valid_o`;
4. include STOP in the read command or submit STOP separately.

For a multi-byte read, use `ack_i = '0'` for every byte except the last and
`ack_i = '1'` for the last byte.

### 7.4 Combined transaction

A typical register read uses:

| Step | START | STOP | READ | WRITE | ACK | DATA |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| write address | 1 | 0 | 0 | 1 | - | address + write bit |
| register index | 0 | 0 | 0 | 1 | - | index |
| repeated START and read address | 1 | 0 | 0 | 1 | - | address + read bit |
| receive final byte | 0 | 1 | 1 | 0 | 1 | ignored |

The repeated START is generated because START is requested while the core is
holding the active transaction.

### 7.5 10-bit and device-specific sequences

Because address bytes are not generated internally, the caller may issue the
address byte sequence required by 10-bit addressing or a device-specific
protocol. The core makes no semantic distinction between address and payload
bytes.

## 8. Timing

The nominal SCL period in `clk_i` cycles is:

```text
period_cycles = ceil(g_clk_freq_hz / g_i2c_freq_hz)
```

The controller allocates 52 percent of this period to SCL low and the
remainder to SCL high:

```text
low_cycles  = ceil(13 * period_cycles / 25)
high_cycles = period_cycles - low_cycles
```

This low/high allocation supports the minimum low time of standard-mode,
fast-mode, and fast-mode plus at their nominal maximum frequencies. Integer
rounding never shortens the low phase. Input synchronization and clock
stretching can lengthen the high phase and therefore reduce the achieved bus
frequency.

START, repeated START, STOP, and bus-free holds use the same conservative
derived phase counts.

The implementation is limited to `g_i2c_freq_hz <= 1 MHz`. High-speed mode is
not implemented.

## 9. Clock stretching and timeout

Whenever the controller releases SCL, it waits until synchronized `scl_i` is
high before timing the high phase. This implements target clock stretching.

When `g_timeout_cycles = 0`, the wait is unbounded.

When `g_timeout_cycles > 0`, each continuous wait for SCL high is limited to
that many `clk_i` cycles. Expiration:

- sets `timeout_o`;
- releases SCL and SDA;
- terminates the command;
- produces one response pulse.

The timeout applies independently to each SCL-high wait, not to the complete
command duration.

## 10. Arbitration and bus ownership

The controller samples SDA while it intends to release SDA during transmitted
arbitrated bits. A low sampled value terminates the command with
`arb_lost_o = '1'` and releases both lines.

A START request also reports arbitration loss when SDA remains low after SCL
is high and the bus-free/setup interval has elapsed.

`bus_busy_o` is set by a synchronized SDA falling edge while SCL is high and
cleared by a synchronized SDA rising edge while SCL is high. A system sharing
the bus should wait for `bus_busy_o = '0'` before beginning a new independent
transaction and should define its own retry policy after arbitration loss.

The core detects SDA contention but does not implement automatic retries or a
multi-controller transaction scheduler.

## 11. Reset and recovery

Reset is the unconditional local recovery mechanism. It releases both bus
controls even if a transaction is incomplete.

After timeout or arbitration loss, the controller also releases both controls.
The caller should wait for a free bus, perform any system-specific bus recovery
needed for a stuck target, and then issue a new START command.

The core does not generate the optional nine-pulse stuck-bus recovery sequence
automatically.

## 12. Verification

The self-checking regression verifies:

- reset entry and reset during an active command;
- acknowledged writes;
- target clock stretching below the configured timeout;
- repeated START;
- two-byte read with ACK followed by NACK;
- write NACK reporting;
- SDA arbitration loss;
- SCL-high timeout;
- START-only and STOP-only bus ownership;
- synchronized bus-busy transitions;
- invalid command rejection;
- invalid frequency generic rejection;
- VHDL-93 analysis and GHDL synthesis.

The behavioral matrix covers:

| `g_clk_freq_hz` | `g_i2c_freq_hz` | Purpose |
| ---: | ---: | --- |
| 10 MHz | 100 kHz | standard-mode target |
| 10 MHz | 400 kHz | fast-mode target |
| 12 MHz | 100 kHz | non-default divider ratio |
| 8 MHz | 1 MHz | fast-mode plus and minimum 8:1 ratio |

Run the complete regression with `sim/run_ghdl.ps1` or `sim/run_ghdl.sh`.
