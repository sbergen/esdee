# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2025-12-25

### Fixes
- Fixes a panic when encountering EDNS OPT pseudo-records

## [1.0.0] - 2025-12-25

Initial stable release.

### Fixed
- Replaces a local dev dependency with one from hex.
  This works around a bug that currently makes the LSP misbehave when
  browsing the package source.

[1.0.1]: https://github.com/sbergen/esdee/releases/tag/v1.0.1
[1.0.0]: https://github.com/sbergen/esdee/releases/tag/v1.0.0
