# TOON Specification Conformance

tzu is validated against the official TOON v3.0 specification fixtures from [toon-format/spec](https://github.com/toon-format/spec).

## Status

| Category | Fixtures | Tests | Status |
|----------|----------|-------|--------|
| Encode   | 9        | 168   | PASS |
| Decode   | 13       | 224   | PASS |
| **Total** | **22**  | **392** | **PASS** |

**Current Status:** Full conformance achieved - 22/22 fixture files passing (392 tests).

## Running Conformance Tests

```bash
# Initialize submodule (first time only)
git submodule update --init --recursive

# Run conformance tests
zig build test-conformance

# Run all tests (unit + conformance)
zig build test
```

Note: Conformance tests are currently separate from the main test suite (`zig build test`) to track spec compliance progress without blocking development builds.

## Fixture-to-Spec Mapping

### Encode Fixtures

| File | Tests | Spec Section | Description |
|------|-------|--------------|-------------|
| primitives.json | 39 | 2, 7.1-7.2 | Primitive encoding (strings, numbers, booleans, null) |
| objects.json | 27 | 3.1-3.3 | Object encoding with key quoting |
| arrays-primitive.json | 10 | 4.1-4.2 | Inline primitive array encoding |
| arrays-nested.json | 16 | 4.3-4.4 | Nested array encoding |
| arrays-objects.json | 29 | 4.5 | Array of objects encoding |
| arrays-tabular.json | 5 | 4.5 | Tabular array encoding |
| delimiters.json | 22 | 11 | Delimiter options (comma, tab, pipe) |
| key-folding.json | 15 | 13.4 | Key path folding |
| whitespace.json | 5 | 7.1 | Whitespace handling |

### Decode Fixtures

| File | Tests | Spec Section | Description |
|------|-------|--------------|-------------|
| primitives.json | 25 | 4, 7.4 | Primitive decoding and unescaping |
| numbers.json | 22 | 4 | Number parsing |
| objects.json | 29 | 3.1-3.3 | Object decoding |
| arrays-primitive.json | 13 | 4.1-4.2 | Inline primitive array decoding |
| arrays-nested.json | 33 | 4.3-4.4 | Nested array decoding |
| arrays-tabular.json | 10 | 4.5 | Tabular array decoding |
| delimiters.json | 29 | 11 | Delimiter handling |
| path-expansion.json | 14 | 13.4 | Path expansion |
| blank-lines.json | 15 | 7 | Blank line handling |
| whitespace.json | 8 | 7.1 | Whitespace handling |
| root-form.json | 1 | 5 | Root form detection |
| validation-errors.json | 10 | 14 | Error conditions |
| indentation-errors.json | 15 | 14 | Indentation validation |

## Resolved Issues

All previously known issues have been fixed:

1. **Escape sequences**: Tab escape handling in strings
2. **Value quoting**: Strings containing colons and delimiters properly quoted
3. **Empty containers**: Empty object list items encoded as bare hyphen
4. **Key folding**: Sibling literal-key collision detection in safe mode
5. **Path expansion**: Dotted key expansion to nested objects
6. **Blank lines**: Blank line handling in arrays (strict mode rejection)
7. **Error detection**: Missing colon and multiple root primitives detected

## Test Architecture

Conformance tests are in `tests/conformance.zig` and work by:

1. Embedding fixture JSON files at compile time via `@embedFile`
2. Parsing fixture format (version, category, tests array)
3. For encode tests: Convert input JSON to Value, encode to TOON, compare to expected string
4. For decode tests: Decode TOON input to Value, compare to expected JSON
5. Handle `shouldError` cases by verifying encoding/decoding returns an error

## Contributing

When fixing conformance issues:

1. Run `zig build test-conformance` to identify failing tests
2. Fix the implementation in the relevant module (encoder.zig, decoder.zig, etc.)
3. Verify unit tests still pass with `zig build test`
4. Re-run conformance tests to verify the fix
