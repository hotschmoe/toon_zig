# tzu - TOON Zig

A spec-first Zig implementation of [TOON (Token-Oriented Object Notation)](https://toonformat.dev/), a compact, human-readable data serialization format designed specifically for minimizing token usage in large language model applications.

**Status: Full TOON v3.0 conformance (22/22 test suites, 392 tests passing)**

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

- **Full spec conformance**: 100% compliance with [TOON Specification v3.0](https://github.com/toon-format/spec)
- **High performance**: Native Zig implementation with zero runtime dependencies
- **Streaming decoder**: Event-based processing for large inputs
- **Deterministic output**: Stable diffs and reproducible pipelines
- **Strict validation**: Optional lenient mode for relaxed parsing
- **Cross-platform**: Builds for Linux, macOS, Windows (x86_64 and aarch64)

## Installation

### As a Zig Package (Library)

Add toon_zig to your project using `zig fetch`:

```bash
zig fetch --save git+https://github.com/hotschmoe/toon_zig.git
```

Then add it to your `build.zig`:

```zig
const toon_dep = b.dependency("toon_zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toon", toon_dep.module("toon_zig"));
```

### Pre-built Binaries

Download pre-built binaries from the [Releases](https://github.com/hotschmoe/toon_zig/releases) page.

### Build from Source

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

### Library API

```zig
const toon = @import("toon");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Encode JSON string to TOON string
    const json_input = "{\"name\": \"Alice\", \"age\": 30}";
    const toon_output = try toon.jsonToToon(allocator, json_input);
    defer allocator.free(toon_output);
    // Result: "name: Alice\nage: 30\n"

    // Decode TOON string to JSON string
    const toon_input = "name: Alice\nage: 30\n";
    const json_output = try toon.toonToJson(allocator, toon_input);
    defer allocator.free(json_output);
    // Result: "{\"name\":\"Alice\",\"age\":30}"

    // Work with Value trees directly
    var val = try toon.decode(allocator, toon_input);
    defer val.deinit(allocator);

    const name = val.object.get("name").?.string; // "Alice"
    const age = val.object.get("age").?.number;   // 30.0
    _ = name;
    _ = age;
}
```

#### Encoding Options

```zig
const encoded = try toon.jsonToToonWithOptions(allocator, json, .{
    .indent = 2,                    // spaces per indent level (default: 2)
    .delimiter = .comma,            // .comma, .pipe, or .tab
    .key_folding = .safe,           // .off or .safe (collapse nested objects)
});
```

#### Decoding Options

```zig
const decoded = try toon.toonToJsonWithOptions(allocator, input, .{
    .strict = true,                 // enforce spec validation (default: true)
    .expand_paths = .safe,          // .off or .safe (expand dotted keys)
    .indent = 2,                    // expected indent size
});
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
  build.zig             # Build configuration
  build.zig.zon         # Package manifest
  src/
    main.zig            # CLI entry point
    root.zig            # Library root (public API)
    encoder.zig         # JSON -> TOON encoder
    decoder.zig         # TOON -> JSON decoder
    scanner.zig         # Line tokenizer
    parser.zig          # Semantic parser
    value.zig           # Value representation
    stream.zig          # Streaming types and options
    errors.zig          # Error types
    constants.zig       # Shared constants
    shared/
      literal_utils.zig # Boolean/null/number detection
      string_utils.zig  # Escape/unescape helpers
      validation.zig    # Key and value validation
  tests/
    conformance.zig     # Conformance test runner
    fixtures/           # TOON spec test fixtures
```

## Specification Conformance

**Full conformance achieved: 22/22 test suites (392 tests)**

This implementation is validated against the [TOON Specification v3.0](https://github.com/toon-format/spec) official test suite.

```bash
# Run conformance tests
zig build test-conformance
```

See [CONFORMANCE.md](./CONFORMANCE.md) for detailed results.

### Implemented Features

Complete TOON v3.0 support:

- Line-oriented, indentation-based format
- UTF-8 encoding with LF line endings
- Configurable indentation (default: 2 spaces)
- Canonical number representation
- All delimiter types (comma, tab, pipe)
- Key folding (nested objects to dotted paths)
- Path expansion (dotted keys to nested objects)
- Tabular arrays (uniform object arrays)
- Inline primitive arrays
- Expanded list arrays
- Strict mode validation
- Lenient mode parsing

## Related Projects

- [toon](https://github.com/toon-format/toon) - Reference TypeScript implementation
- [toon_rust](https://github.com/Dicklesworthstone/toon_rust) - Rust implementation
- [TOON Spec](https://github.com/toon-format/spec) - Official specification

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

This project is currently in early development. Issues and discussions welcome.
