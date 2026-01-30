# Vision: tzu (TOON Zig)

## Mission

Provide a fast, correct, and embeddable TOON implementation in Zig that serves both as a standalone CLI tool and a zero-dependency library.

## Core Principles

### 1. Spec-First

The [TOON Specification v3.0](https://github.com/toon-format/spec) is the source of truth. We implement the spec, not interpretations of it. When behavior is ambiguous, we match the reference TypeScript implementation exactly.

### 2. Dual Citizenship

CLI and library are equal priorities:

```
+-------------------+     +-------------------+
|    CLI (tzu)      |     |  Library (toon_zig)|
|   - encode cmd    |     |   - encode()       |
|   - decode cmd    |     |   - decode()       |
|   - stats cmd     |     |   - streaming API  |
+--------+----------+     +---------+----------+
         |                          |
         +----------+---------------+
                    |
            +-------v-------+
            |   Core Engine |
            |  (shared impl)|
            +---------------+
```

### 3. Zero Compromises on Correctness

- Deterministic output: identical inputs always produce identical TOON
- Lossless round-trip: JSON -> TOON -> JSON preserves semantics exactly
- Full validation: strict mode catches all spec violations
- 349 official test fixtures must pass

### 4. Performance Without Complexity

- Streaming by default: process arbitrarily large files without full buffering
- No runtime dependencies: single static binary, no allocator overhead in hot paths
- Memory efficiency: arena allocators for batch operations, explicit lifetimes

### 5. Zig Idioms

- Explicit allocator passing (no hidden allocations)
- Error unions for all fallible operations
- Comptime validation where possible
- No undefined behavior

## Non-Goals

- **Backwards compatibility with pre-v3.0 TOON**: We target v3.0 only
- **YAML/TOML compatibility modes**: TOON is its own format
- **Async I/O**: Synchronous streaming is sufficient; async adds complexity
- **Plugin systems**: Keep the core simple; users can wrap if needed

## Success Metrics

1. **Correctness**: 100% of toon-format/spec test fixtures pass
2. **Performance**: Comparable to or faster than toon_rust on benchmarks
3. **Usability**: Single command converts files; library API is obvious
4. **Adoption**: Can be used as a drop-in replacement for toon_rust CLI

## Roadmap

### Phase 1: Foundation
- Core data types and error handling
- String/number utilities
- Basic encode/decode without advanced features

### Phase 2: Full Decode
- Scanner, parser, event builder
- Strict mode validation
- Path expansion

### Phase 3: Full Encode
- Primitive and structure encoding
- Key folding
- Tabular array detection

### Phase 4: CLI and Polish
- Argument parsing and commands
- Stats/benchmarking
- CI/CD and releases

### Phase 5: Optimization
- Profiling and hot path optimization
- Memory usage reduction
- Streaming performance

---

*tzu: the Zig implementation of TOON*
