# lm_i2c

[![ci](https://github.com/LogiMentor/lm_i2c/actions/workflows/ci.yml/badge.svg)](https://github.com/LogiMentor/lm_i2c/actions/workflows/ci.yml)

Dependency-free I2C master and slave cores written in portable VHDL.

This first release provides the synthesizable `lm_i2c_master` core. A
synthesizable slave is intentionally outside the scope of this release.

## Highlights

- IEEE-library-only synthesizable RTL
- conservative VHDL-93 implementation
- byte-command ready/valid interface
- START, repeated START, STOP, byte write, and byte read operations
- controller-driven ACK or NACK after reads
- received ACK/NACK reporting after writes
- clock stretching with an optional bounded timeout
- SDA arbitration-loss detection and synchronized bus-busy reporting
- separate active-high drive-low outputs for portable open-drain integration
- standard-mode, fast-mode, and fast-mode plus targets up to 1 MHz
- self-checking GHDL regression and synthesis check

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/lm_i2c_master.vhd` | Synthesizable I2C master RTL |
| `sim/tb_lm_i2c_master.vhd` | Self-checking behavioral regression |
| `sim/run_ghdl.ps1` | Windows and PowerShell regression entry point |
| `sim/run_ghdl.sh` | POSIX shell regression entry point |
| `docs/i2c_master_spec.md` | Normative interface and behavior |

## Bus integration

The core never drives a logic high onto SCL or SDA. Map each active-high
drive-low output to the output-enable control of an open-drain-capable I/O
buffer, and return the resolved pad level to the corresponding input.

A portable top-level inference pattern is:

```vhdl
scl_io <= '0' when s_scl_low = '1' else 'Z';
sda_io <= '0' when s_sda_low = '1' else 'Z';

s_scl_in <= scl_io;
s_sda_in <= sda_io;
```

External pull-up resistors are required. Check the target device's I/O
guidance before relying on inferred tri-state buffers.

## Command model

A command is accepted on a rising `clk_i` edge when `cmd_valid_i` and
`cmd_ready_o` are both high. Operations within one command occur in this
order:

1. generate START or repeated START when `start_i = '1'`;
2. write `data_i` when `write_i = '1'`, or read one byte when
   `read_i = '1'`;
3. generate STOP when `stop_i = '1'`.

`read_i` and `write_i` are mutually exclusive. After a read, `ack_i = '0'`
transmits ACK and `ack_i = '1'` transmits NACK. A one-cycle `rsp_valid_o`
pulse marks completion; response status remains stable until the next command
is accepted.

The byte interface deliberately leaves address framing to the caller. This
keeps the core useful for 7-bit, 10-bit, combined, and device-specific
sequences.

### Example: write `0xA5` to 7-bit address `0x50`

| Command | `start_i` | `stop_i` | `write_i` | `data_i` |
| --- | ---: | ---: | ---: | --- |
| Address + write direction | 1 | 0 | 1 | `0xA0` |
| Payload | 0 | 1 | 1 | `0xA5` |

Check `nack_o` on each response.

### Example: read register `0x12` from 7-bit address `0x50`

| Command | `start_i` | `stop_i` | `read_i` | `write_i` | `ack_i` | `data_i` |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Address + write direction | 1 | 0 | 0 | 1 | - | `0xA0` |
| Register index | 0 | 0 | 0 | 1 | - | `0x12` |
| Repeated START + read direction | 1 | 0 | 0 | 1 | - | `0xA1` |
| Read final byte | 0 | 1 | 1 | 0 | 1 | ignored |

The final byte is available on `data_o` with `rsp_valid_o`. Use ACK instead of
NACK on every read command except the final byte of a multi-byte read.

## Configuration

The default configuration assumes a 50 MHz system clock and targets a 100 kHz
SCL rate.

| Generic | Default | Meaning |
| --- | ---: | --- |
| `g_clk_freq_hz` | 50,000,000 | `clk_i` frequency |
| `g_i2c_freq_hz` | 100,000 | requested SCL frequency, at most 1 MHz |
| `g_timeout_cycles` | 0 | SCL-high wait limit in `clk_i` cycles; zero disables it |

`g_clk_freq_hz` must be at least eight times `g_i2c_freq_hz`.

## Verification

Run the complete regression with GHDL 6 or later:

```powershell
./sim/run_ghdl.ps1
```

or:

```sh
./sim/run_ghdl.sh
```

The regression analyzes and synthesizes the core as VHDL-93, runs behavioral
tests at 100 kHz, 400 kHz, and 1 MHz, and verifies invalid generic rejection.
See the [I2C master specification](docs/i2c_master_spec.md) for the complete
behavior and tested scenarios.

## License

Licensed under the [Apache License 2.0](LICENSE).
