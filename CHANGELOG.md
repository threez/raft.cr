# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Changed

- Bumped `ameba` dev dependency from `~> 1.6.0` to `~> 1.7.0` and updated the
  `lib/ameba/bin/ameba` Makefile rule to explicitly `shards build ameba`
  after `shards install`, since ameba 1.7.0 no longer builds its binary via a
  `postinstall` hook.
- Restructured CI (`.github/workflows/ci.yml`) into separate `lint` (format
  check, ameba lint, compile check) and `test` (specs on Linux and macOS)
  jobs, with shard caching and a pinned Crystal version.

### Added

- Added `fmtcheck`, `fix`, `version`, and `tag` targets to the Makefile.
