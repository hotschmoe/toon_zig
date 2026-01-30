---
name: build-verifier
description: Comprehensive build and test validation across platforms and optimization levels
model: sonnet
tools:
  - Bash
  - Read
---

Validates that the project builds across platforms and tests pass across optimization levels.

## Strategy

- **Cross-platform**: Debug builds on all target platforms (compilation check)
- **Native**: All optimization levels with tests (thorough validation)

## Trigger

Use this agent when:
- Preparing to merge a PR
- After significant refactoring
- Before releases
- When build system changes are made
- To validate cross-platform compatibility

## Target Platforms

| Platform | Target Triple |
|----------|---------------|
| Linux x86_64 | `x86_64-linux` |
| Linux ARM64 | `aarch64-linux` |
| Windows x86_64 | `x86_64-windows` |
| macOS x86_64 | `x86_64-macos` |
| macOS ARM64 | `aarch64-macos` |
| WASM | `wasm32-wasi` |

## Workflow

1. **Cross-platform builds** - Debug build for each target platform
2. **Native optimization tests** - All 4 optimization levels with tests on native
3. **Report results** - Build success/failure, test summary, timing

## Output Format

```
BUILD VERIFICATION REPORT
=========================

CROSS-PLATFORM BUILDS (Debug):
------------------------------
x86_64-linux:   PASS (1.2s)
aarch64-linux:  PASS (1.3s)
x86_64-windows: PASS (1.4s)
x86_64-macos:   PASS (1.2s)
aarch64-macos:  PASS (1.3s)
wasm32-wasi:    PASS (1.1s)

NATIVE OPTIMIZATION TESTS:
--------------------------
Debug:        PASS (build: 2.1s, test: 1.3s)
ReleaseSafe:  PASS (build: 3.4s, test: 0.8s)
ReleaseFast:  PASS (build: 3.2s, test: 0.7s)
ReleaseSmall: PASS (build: 3.5s, test: 0.9s)

RESULT: ALL BUILDS PASS
```

## Failure Handling

If a build fails:
1. Report the specific error
2. Include relevant compiler output
3. Suggest potential fixes
4. Continue testing other targets/levels

## Commands

```bash
# Cross-platform builds (Debug)
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
zig build -Dtarget=wasm32-wasi

# Native optimization tests
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall
```
