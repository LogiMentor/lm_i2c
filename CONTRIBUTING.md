# Contributing

Contributions must keep the public interface, implementation, verification,
and README contract aligned.

## Workflow

1. Start from an up-to-date branch and keep each change focused.
2. Update README behavior whenever the public contract changes.
3. Implement the smallest coherent change that satisfies that contract.
4. Add deterministic, self-checking verification for normal, boundary, reset,
   error, timing, arbitration, stretching, and backpressure behavior.
5. Run the native regression and repository hygiene tools.
6. Open a pull request that includes the commands run and measured evidence.

The command interface is ready/valid: a command is accepted only when
`cmd_valid_i` and `cmd_ready_o` are high on the same rising edge. The response
interface is independently ready/valid. Tests for interface changes must hold
`rsp_ready_i` low for multiple cycles, prove every response field remains
stable, and prove no new command is accepted while a response is pending.

Before opening or updating a pull request, run:

```powershell
./tools/check_repo_hygiene.ps1 -Mode Full
./tools/check_repo_hygiene.ps1 -Mode History -RevisionRange HEAD
./sim/run_ghdl.ps1
git diff --check
```

and, from Bash:

```bash
bash tools/check_repo_hygiene.sh --full
bash tools/check_repo_hygiene.sh --history --revision-range HEAD
bash sim/run_ghdl.sh
```

## VHDL policy

All VHDL must follow
[`LM_VHDL_coding_standard.md`](LM_VHDL_coding_standard.md). Synthesizable RTL
uses a conservative VHDL-93/VHDL-2002-compatible subset, IEEE libraries only,
clock enables instead of derived clocks, and no vendor primitives. VHDL-2008
is permitted for testbenches and verification infrastructure.

README.md is the sole user-facing normative document. Resolve any disagreement
between README behavior, RTL, and verification in the same change.

## Pull requests

Pull requests should:

- identify affected interfaces and requirements;
- include resolved-bus tests for timing-sensitive changes;
- verify ready/valid backpressure and reset cancellation;
- remain vendor independent;
- include commands, results, and actual measurements;
- avoid generated artifacts, private references, and unrelated changes.
