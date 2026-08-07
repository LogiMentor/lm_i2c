# Changelog

All notable changes to this project will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/) and keeps
unreleased changes under the heading below.

## Unreleased

- Add the initial dependency-free Standard-mode/Fast-mode I2C master.
- Refactor the public API to one-byte commands and backpressured responses.
- Add explicit ownership, qualified physical bus-busy tracking, indefinite
  stretching, arbitration release, and conservative bus timing.
- Add independent resolved-bus timing, reset-phase, negative-generic, and
  success-marker regression checks.
- Add Bash and native PowerShell regression/hygiene parity in CI.
- Consolidate the public controller contract in README.md.
