# Changelog

All notable changes to this project will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/) and keeps
unreleased changes under the heading below.

## Unreleased

## [0.1.0] - 2026-08-09

### Added

- Dependency-free, synthesizable VHDL-93 I2C controller/master and 7-bit target
  cores for Standard-mode through 100 kHz and Fast-mode through 400 kHz.
- Controller byte-command and backpressured response ready/valid interfaces
  supporting START, repeated START, STOP, byte reads and writes, and ACK/NACK.
- STOP-only recovery after NACK, indefinite clock stretching, arbitration-loss
  detection, explicit bus ownership, and qualified bus-free detection.
- Target RX and TX ready/valid byte streams, application-controlled ACK/NACK of
  received bytes, and application backpressure through clock stretching.
- Portable open-drain drive-low interfaces and conservative controller and
  target timing policies.
- A resolved-bus integration regression using the real controller and target,
  Linux/Bash and Windows/PowerShell GHDL regressions, and VHDL-93 GHDL
  synthesis checks.
- Repository hygiene checks.
