# Contributing

Contributions should keep the public interface, implementation, verification,
and documentation aligned.

## Workflow

1. Start from an up-to-date branch and keep each change focused.
2. Update the normative specification before changing public behavior.
3. Implement the smallest change that satisfies the documented requirement.
4. Add or update deterministic, self-checking verification.
5. Run the complete local regression and repository hygiene check.
6. Open a pull request that explains the behavior and verification evidence.

Before opening a pull request, run:

```powershell
./tools/check_repo_hygiene.ps1
./sim/run_ghdl.ps1
git diff --check
```

## VHDL policy

All VHDL must follow
[`LM_VHDL_coding_standard.md`](LM_VHDL_coding_standard.md). Synthesizable RTL
uses a conservative VHDL-93/VHDL-2002-compatible subset, IEEE libraries only,
clock enables instead of derived clocks, and no vendor primitives. VHDL-2008
is permitted for testbenches and verification infrastructure.

The normative behavior is defined in
[`docs/i2c_master_spec.md`](docs/i2c_master_spec.md). Deliberately resolve any
disagreement between the specification and implementation before changing
behavior.

## Pull requests

Pull requests should:

- identify affected interfaces and requirements;
- include tests for normal, boundary, reset, error, and backpressure behavior;
- remain vendor independent;
- include the commands run and their results;
- avoid generated artifacts, private references, and unrelated changes.
