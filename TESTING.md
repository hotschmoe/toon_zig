# TESTING.md - tzu Testing Strategy

This document defines how tzu approaches testing, aligned with our philosophy that **tests are diagnostic tools, not success criteria**.

---

## Philosophy

From CLAUDE.md:

> A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should we fix the code.

---

## Test Categories

### 1. Conformance Tests (External)

**Source:** Official TOON spec fixtures from [toon-format/spec](https://github.com/toon-format/spec)

**Location:** `tests/fixtures/` (git submodule)

**Purpose:** Validate spec compliance against the 349 language-agnostic test cases.

```
tests/fixtures/
  encode/           # JSON -> TOON conversion
    primitives/
    objects/
    arrays/
    delimiters/
    key-folding/
    whitespace/
  decode/           # TOON -> JSON parsing
    primitives/
    numbers/
    objects/
    arrays/
    validation/
    indentation/
    path-expansion/
```

**Fixture Format:**
```json
{
  "description": "What this test validates",
  "input": "...",
  "expected": "...",
  "options": { ... },
  "error": false,
  "spec_section": "3.2.1"
}
```

**How to run:**
```bash
zig build test-conformance
```

**Interpretation:**
- Failing conformance tests indicate spec divergence
- Before "fixing" code, verify the fixture matches current spec version
- Document any intentional divergences in SPEC.md

### 2. Unit Tests (Internal)

**Location:** Inline in source files using Zig's `test` blocks

**Purpose:** Document current behavior of internal functions.

**Coverage targets:**

| Module | Key Functions |
|--------|---------------|
| `shared/literal_utils.zig` | `isBooleanOrNullLiteral`, `isNumericLiteral`, `isNumericLike` |
| `shared/string_utils.zig` | `escapeString`, `unescapeString`, `findClosingQuote` |
| `shared/validation.zig` | `isValidUnquotedKey`, `isSafeUnquoted` |
| `encode/primitives.zig` | `encodePrimitive`, `formatNumber`, `encodeKey` |
| `decode/scanner.zig` | `parseLineIncremental`, `computeDepthFromIndent` |
| `decode/parser.zig` | `parseArrayHeaderLine`, `parseDelimitedValues`, `parsePrimitiveToken` |

**How to run:**
```bash
zig build test
```

**Writing good unit tests:**
```zig
test "escapeString handles backslashes" {
    const allocator = std.testing.allocator;
    const result = try escapeString(allocator, "path\\to\\file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}
```

### 3. Integration Tests

**Location:** `tests/integration/`

**Purpose:** Test complete encode/decode pipelines on realistic data.

**Test cases:**

| Name | Description |
|------|-------------|
| `simple_object` | Basic key-value encoding/decoding |
| `nested_object` | Multi-level nesting |
| `primitive_array` | Inline arrays |
| `tabular_array` | Uniform object arrays |
| `mixed_array` | Heterogeneous list items |
| `key_folding` | Dotted path collapse/expand |
| `delimiter_variants` | Comma, pipe, tab delimiters |
| `strict_mode_errors` | Validation rejection |
| `large_file` | Streaming memory bounds |

**How to run:**
```bash
zig build test-integration
```

### 4. Roundtrip Tests

**Location:** `tests/roundtrip/`

**Purpose:** Verify lossless JSON -> TOON -> JSON transformation.

**Property:** `decode(encode(json)) == normalize(json)`

Where `normalize` applies:
- Key ordering (preserved)
- Number canonicalization
- Whitespace normalization

**How to run:**
```bash
zig build test-roundtrip
```

### 5. Fuzz Tests

**Location:** Inline fuzz blocks in source files

**Purpose:** Find edge cases and crashes through random input generation.

**Targets:**
- `decode`: Random byte sequences
- `encode`: Random JSON structures
- `parseArrayHeader`: Random header strings
- `escapeString` / `unescapeString`: Random strings

**How to run:**
```bash
zig build test --fuzz
```

---

## Test Infrastructure

### Submodule Setup

The official test fixtures are included as a git submodule:

```bash
git submodule add https://github.com/toon-format/spec tests/fixtures
git submodule update --init
```

To update fixtures:
```bash
cd tests/fixtures
git pull origin main
cd ../..
git add tests/fixtures
git commit -m "Update spec fixtures"
```

### Test Runner

The build system configures test execution:

```zig
// build.zig
const test_step = b.step("test", "Run unit tests");
const conformance_step = b.step("test-conformance", "Run spec fixtures");
const integration_step = b.step("test-integration", "Run integration tests");
const all_tests = b.step("test-all", "Run all tests");
```

### CI Integration

GitHub Actions runs tests on every push:

```yaml
test:
  strategy:
    matrix:
      os: [ubuntu-latest, macos-latest, windows-latest]
  steps:
    - uses: actions/checkout@v4
      with:
        submodules: recursive
    - uses: goto-bus-stop/setup-zig@v2
    - run: zig build test-all
```

---

## Test Data Guidelines

### Fixture Principles

1. **One behavior per fixture**: Each test validates exactly one thing
2. **Minimal input**: Smallest input that exercises the behavior
3. **Clear naming**: `encode_tabular_array_with_pipe_delimiter.json`
4. **Error tests are explicit**: `error: true` with expected message pattern

### Avoiding Brittle Tests

**Bad:**
```zig
test "encode produces exact output" {
    // Fails if we change whitespace, ordering, etc.
    try expectEqualStrings(expected_exact_string, result);
}
```

**Better:**
```zig
test "encode then decode roundtrips" {
    const encoded = try encode(allocator, input);
    const decoded = try decode(allocator, encoded);
    try expectEqualJson(input, decoded);
}
```

### Test Independence

- Tests must not depend on execution order
- Tests must not share mutable state
- Each test allocates and frees its own memory

---

## Debugging Test Failures

### Step 1: Understand the failure

```bash
zig build test 2>&1 | head -50
```

### Step 2: Run single test

```bash
zig build test --test-filter "specific test name"
```

### Step 3: Add diagnostic output

```zig
test "debugging example" {
    std.debug.print("intermediate value: {s}\n", .{value});
    // ...
}
```

### Step 4: Check if test is correct

Before modifying code, verify:
- Does the test match the spec?
- Is the test testing the right behavior?
- Has the spec changed since the test was written?

---

## Performance Testing

### Benchmarks

**Location:** `tests/bench/`

**Metrics:**
- Encode throughput (MB/s)
- Decode throughput (MB/s)
- Memory usage (peak allocation)
- Token efficiency (vs JSON baseline)

**How to run:**
```bash
zig build bench -Doptimize=ReleaseFast
```

### Reference Data

| Dataset | Size | toon_rust encode | toon_rust decode |
|---------|------|------------------|------------------|
| small.json | 336B | 3ms | - |
| medium.json | 100KB | ~10ms | ~20ms |
| large.json | 784KB | 24ms | 59ms |

tzu should be within 2x of these numbers.

---

## Coverage

We do not target a coverage percentage. Coverage is a diagnostic, not a goal.

**What matters:**
- All public API functions have at least one test
- All error paths are exercised
- Edge cases from the spec are covered

**How to check:**
```bash
zig build test -Dcoverage
# View report in zig-cache/coverage/
```

---

## Adding New Tests

### For new features

1. Check if official fixtures exist in toon-format/spec
2. If yes, ensure submodule is updated
3. If no, add integration test in `tests/integration/`
4. Add unit tests for helper functions

### For bug fixes

1. Add a test that fails without the fix
2. Apply the fix
3. Verify the test passes
4. Ensure no other tests regress

### For refactors

1. Run full test suite before refactor
2. Make changes
3. Run full test suite after
4. Investigate any differences (may be intentional)

---

## Test Maintenance

### Quarterly Review

- Update spec fixture submodule
- Review and remove obsolete tests
- Check for flaky tests
- Update benchmark baselines

### When Spec Changes

1. Pull new fixtures: `cd tests/fixtures && git pull`
2. Run conformance tests
3. Update SPEC.md if our interpretation changed
4. Update code if our behavior was wrong

---

## Summary

| Test Type | Location | Purpose | Run Command |
|-----------|----------|---------|-------------|
| Unit | `src/*.zig` | Document function behavior | `zig build test` |
| Conformance | `tests/fixtures/` | Validate spec compliance | `zig build test-conformance` |
| Integration | `tests/integration/` | End-to-end pipelines | `zig build test-integration` |
| Roundtrip | `tests/roundtrip/` | Lossless transformation | `zig build test-roundtrip` |
| Fuzz | inline | Find edge cases | `zig build test --fuzz` |
| Benchmark | `tests/bench/` | Performance regression | `zig build bench` |

**Remember:** Tests tell us what the code does, not what it should do. The spec and our vision define correctness.
