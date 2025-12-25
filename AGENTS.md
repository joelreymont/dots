# Dots - Agent Instructions

Fast CLI issue tracker in Zig with SQLite storage.

## Build

```bash
zig build -Doptimize=ReleaseSmall
strip zig-out/bin/dot
```

## Test

```bash
zig build test
```

## References

- [Zig 0.15 I/O API](docs/zig-0.15-io-api.md) - Critical API changes for I/O, ArrayList, JSON
