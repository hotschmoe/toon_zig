# TOON Specification Reference

This document summarizes the [TOON Specification v1.5](https://github.com/toon-format/spec) that this implementation targets.

## Overview

**Token-Oriented Object Notation (TOON)** is a line-oriented, indentation-based text format encoding JSON data with explicit structure and minimal quoting.

## Data Model

TOON preserves the JSON data model:
- Objects (key-value maps)
- Arrays (ordered lists)
- Strings
- Numbers
- Booleans (true, false)
- Null

**Ordering**: Array order MUST be preserved. Object key order MUST be preserved as encountered by the encoder.

## Format Rules

### Encoding

- UTF-8 encoding
- LF (U+000A) line endings required
- 2 spaces per indentation level (default)
- Tabs forbidden for indentation
- One space after colons and headers

### Key Encoding

Unquoted keys must match: `^[A-Za-z_][A-Za-z0-9_.]*$`

Keys requiring quotes:
- Special characters
- Spaces
- Structural symbols

### String Quoting

Strings must be quoted when:
- Empty or containing leading/trailing whitespace
- Matching reserved words: `true`, `false`, `null`
- Appearing numeric (including leading zeros like "05")
- Containing colons, quotes, backslashes, brackets, braces
- Containing delimiters (comma, tab, pipe)
- Starting with hyphens

Valid escape sequences: `\\`, `\"`, `\n`, `\r`, `\t`

### Number Canonicalization

Encoders must emit numbers in decimal form without:
- Exponent notation (1e6 becomes 1000000)
- Leading zeros (except single "0")
- Trailing fractional zeros (1.5000 becomes 1.5)
- Negative zero (-0 becomes 0)

## Syntax

### Objects

Primitive fields:
```
key: value
```

Nested objects:
```
user:
  id: 123
  name: Ada
```

### Arrays

#### Header Format
```
key[N<delimiter?>]{field1,field2}:
```

Where:
- N = declared length
- delimiter = optional (HTAB or pipe, comma is default)
- fields = applies only to tabular arrays

#### Primitive Arrays (Inline)
```
numbers[5]: 1,2,3,4,5
tags[3]: red,green,blue
```

#### Tabular Arrays
Objects with uniform keys and primitive-only values:
```
items[2]{id,name}:
  1,Alice
  2,Bob
```

#### Expanded Lists
Non-uniform arrays with hyphen markers:
```
items[3]:
  - value1
  - value2
  - value3
```

### Delimiters

Three options:
- **Comma** (default): no symbol in brackets
- **Tab**: HTAB (U+0009) inside brackets
- **Pipe**: "|" inside brackets

## Key Folding (Optional)

Encoder feature collapsing nested single-key objects:

```json
{"a": {"b": {"c": 1}}}
```

Becomes:
```
a.b.c: 1
```

Safe mode: all segments must match `^[A-Za-z_][A-Za-z0-9_]*$`

## Path Expansion (Optional)

Decoder feature splitting dotted keys:
```
a.b.c: 1
```

Becomes:
```json
{"a": {"b": {"c": 1}}}
```

## Root Form Detection

1. First depth-0 line is valid array header -> decode root array
2. Single non-empty line, neither header nor key-value -> decode primitive
3. Otherwise -> decode object
4. Empty document -> empty object `{}`

## Strict Mode

When enabled (default), decoders enforce:
- Array counts matching declared N
- Tabular row widths matching field counts
- Indentation as exact multiples of indentSize
- No tabs in indentation
- No blank lines within array/tabular blocks
- Valid escape sequences only
- Required colons after all keys

## Host Type Normalization

Before encoding, normalize:
- Dates -> ISO 8601 strings
- Sets/Maps -> arrays/objects
- NaN, +/-Infinity -> null
- Undefined/functions -> null
- BigInt -> number (if in range) or quoted string

## Conformance

### Encoders MUST:
- Produce deterministic output with preserved key/array order
- Apply consistent delimiter-aware quoting
- Emit matching array length counts
- Normalize numbers canonically

### Decoders MUST:
- Parse headers and apply declared delimiters correctly
- Enforce strict-mode rules
- Preserve ordering
- Handle path expansion safely (when enabled)

## References

- [Official Specification](https://github.com/toon-format/spec)
- [TOON Website](https://toonformat.dev/)
- [Reference Implementation](https://github.com/toon-format/toon)
