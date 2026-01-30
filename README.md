# tzu - TOON Zig

A spec-first Zig implementation of [TOON (Token-Oriented Object Notation)](https://toonformat.dev/), a compact, human-readable data serialization format designed specifically for minimizing token usage in large language model applications.

## What is TOON?

TOON is an alternative to JSON that achieves **40-60% token reduction** on real-world data by leveraging indentation-based structure instead of verbose punctuation. It preserves the full JSON data model (objects, arrays, strings, numbers, booleans, null) while being more efficient for LLM input/output.

```
JSON (25 tokens):                    TOON (15 tokens):
{                                    id: 123
  "id": 123,                         name: Alice
  "name": "Alice",                   active: true
  "active": true,                    score: 98.5
  "score": 98.5,                     role: admin
  "role": "admin"
}
```

## Features

- **Spec-compliant**: Full conformance with [TOON Specification v3.0](https://github.com/toon-format/spec)
- **High performance**: Native Zig implementation with zero runtime dependencies
- **Streaming decoder**: Process large inputs without full buffering
- **Deterministic output**: Stable diffs and reproducible pipelines
- **Strict validation**: Optional relaxed mode for lenient parsing
- **Cross-platform**: Builds for Linux, macOS, Windows (x86_64 and aarch64)

## Installation

### From Releases

Download pre-built binaries from the [Releases](https://github.com/hotschmoe/toon_zig/releases) page.

### From Source

Requires Zig 0.15.2 or later.

```bash
git clone https://github.com/hotschmoe/toon_zig.git
cd toon_zig
zig build -Doptimize=ReleaseFast
```

The binary will be at `zig-out/bin/tzu`.

## Usage

### CLI

```bash
# Encode JSON to TOON
tzu encode input.json -o output.toon
tzu encode input.json              # writes to stdout

# Decode TOON to JSON
tzu decode input.toon -o output.json
tzu decode input.toon              # writes to stdout

# Auto-detect based on file extension
tzu convert data.json              # .json -> TOON output
tzu convert data.toon              # .toon -> JSON output

# Show token savings
tzu stats input.json
```

### Library

```zig
const toon = @import("toon_zig");
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Encode JSON to TOON
    const json_input =
        \\{"name": "Alice", "age": 30}
    ;
    const toon_output = try toon.encode(allocator, json_input);
    defer allocator.free(toon_output);

    // Decode TOON to JSON
    const json_output = try toon.decode(allocator, toon_output);
    defer allocator.free(json_output);
}
```

## TOON Format Overview

### Objects

```
user:
  id: 123
  name: Ada
  active: true
```

### Arrays

Primitive arrays (inline):
```
numbers[5]: 1,2,3,4,5
tags[3]: red,green,blue
```

Tabular arrays (uniform objects):
```
users[3]{id,name,score}:
  1,Alice,95
  2,Bob,87
  3,Carol,92
```

Expanded lists (mixed types):
```
items[3]:
  - first
  - second
  - third
```

### Key Folding

Nested single-key objects collapse into dotted paths:
```
config.database.host: localhost
config.database.port: 5432
```

## Building

```bash
# Debug build
zig build

# Release build (optimized for speed)
zig build -Doptimize=ReleaseFast

# Release build (optimized for size)
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test

# Cross-compile
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows
```

## Project Structure

```
toon_zig/
  build.zig         # Build configuration
  build.zig.zon     # Package manifest
  src/
    main.zig        # CLI entry point
    root.zig        # Library root (public API)
    encoder.zig     # JSON -> TOON encoder
    decoder.zig     # TOON -> JSON decoder
    parser.zig      # TOON parser
    value.zig       # Value representation
  tests/
    fixtures/       # Test fixtures from spec
```

## Specification Compliance

This implementation targets full compliance with [TOON Specification v3.0](https://github.com/toon-format/spec), including:

- Line-oriented, indentation-based format
- UTF-8 encoding with LF line endings
- 2-space indentation (configurable)
- Canonical number representation
- Delimiter support (comma, tab, pipe)
- Key folding and path expansion
- Strict validation mode

## Related Projects

- [toon](https://github.com/toon-format/toon) - Reference TypeScript implementation
- [toon_rust](https://github.com/Dicklesworthstone/toon_rust) - Rust implementation
- [TOON Spec](https://github.com/toon-format/spec) - Official specification

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

This project is currently in early development. Issues and discussions welcome.
