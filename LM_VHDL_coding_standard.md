# VHDL Coding Standard

## 1. Scope

This coding standard applies to synthesizable RTL by default and to behavioral
models or testbenches when explicitly identified.

The goal is readable, consistent, review-friendly VHDL with predictable
synthesis and simulation behavior.

## 2. Naming and style

- Use lowercase letters for HDL keywords and names, except constants.
- Clock signal names use the `clk_*` prefix.
- Reset signal names use the `rst_*` prefix. The default reset is active-low
  and synchronous, for example `rst_n_i`.
- Input, output, and input/output ports end in `_i`, `_o`, and `_io`.
- Generics, signals, variables, types, constants, functions, and procedures use
  the prefixes `g_`, `s_`, `v_`, `t_`, `C_`, `f_`, and `p_`.
- Architectures use the `a_` prefix. Prefer `a_rtl`, `a_behav`, and `a_tb`.
- Instances, processes, and generate blocks use the prefixes `inst_`, `proc_`,
  and `gen_`.
- Use `(x downto 0)` for buses and `(0 to x)` for arrays.
- Use named association for generic and port maps.
- Indent with two spaces.
- Keep the entity and architecture, or package and package body, together.
- Use one synthesizable entity per RTL file and match the file name to it.
- Keep lines within 120-140 characters where practical.

## 3. File header

```vhdl
--=============================================================================
-- Module Name : <module_name>
-- Library     : -
-- Project     : -
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  <functional description>
--  <clock/reset assumptions>
--  <interface notes>
-------------------------------------------------------------------------------
```

## 4. Language and synthesis rules

- Use IEEE types only. Use `std_logic`, `std_logic_vector`, `signed`, and
  `unsigned` from `ieee.numeric_std`. Do not use non-standard arithmetic
  packages.
- Functions reference only arguments and local variables.
- Avoid embedded synthesis commands except `synthesis translate_off/on`.
- Avoid hard-coded architectural dimensions. Use generics or package constants.
- Do not gate, invert, or multiplex clocks. Use clock enables.
- Code each FSM in one clocked process with an enumerated state type.
- Do not use delay constants, default signal initialization, or inferred
  latches in RTL.
- Keep sensitivity lists complete. `process(all)` is allowed in VHDL-2008
  verification code.
- Use explicit `signed` or `unsigned` arithmetic and local conversions.
- Use `resize` for width adaptation.
- Register hierarchical outputs whenever practical.
- Use synchronous resets unless a documented interface requires otherwise.
- Synchronize asynchronous single-bit inputs. Use handshakes or FIFOs for
  multi-bit clock-domain crossings.
- Use assertions to reject invalid generic combinations.

## 5. Organization and interfaces

- Place RTL in `src/`, verification in `sim/`, and documentation in `docs/`.
- Order ports as clock/reset, inputs, outputs, then input/output ports.
- Group related ports and add short interface comments.
- Assign safe defaults in combinational logic and cover every case branch.
- Use only the libraries required by the source.

## 6. Verification

- Name testbench entities `tb_<dut_name>` and architectures `a_tb`.
- Testbenches must be self-checking.
- Isolate clock and reset generation in clearly named processes.
- Do not weaken tests to make an implementation pass.

Deviations from this standard must be justified in code comments or design
documentation.
