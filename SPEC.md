# SPEC.md - tzu Implementation Specification

This document specifies how tzu implements [TOON Specification v3.0](https://github.com/toon-format/spec). It serves as both a reference for contributors and a conformance checklist.

---

## 1. Format Overview

TOON (Token-Oriented Object Notation) is a line-oriented, indentation-based format that encodes the JSON data model with explicit structure and minimal quoting.

**Key Properties:**
- Media Type: `application/toon` (provisional)
- File Extension: `.toon`
- Encoding: UTF-8 only
- Line Terminator: LF (`\n`), not CRLF

---

## 2. Data Model

TOON preserves the complete JSON data model:

```
JsonValue
  |-- Primitive
  |     |-- Null
  |     |-- Bool (true | false)
  |     |-- Number (f64, canonical form)
  |     |-- String (UTF-8)
  |-- Array (ordered, length-declared)
  |-- Object (key-value pairs, insertion order preserved)
```

### 2.1 Number Representation

**Canonical Form (Encoding):**
- No exponent notation: `1e6` -> `1000000`
- No leading zeros: `007` is invalid as number (treated as string)
- No trailing fractional zeros: `1.5000` -> `1.5`
- Integer form when fractional part is zero: `1.0` -> `1`
- Negative zero normalizes: `-0` -> `0`
- NaN and Infinity encode as `null`

**Accepted on Decode:**
- Both decimal and exponent forms: `1e-6`, `-1E+9`
- Leading zeros are treated as strings, not numbers

### 2.2 String Representation

**Escape Sequences (Complete Set):**

| Escape | Character |
|--------|-----------|
| `\\`   | Backslash |
| `\"`   | Double quote |
| `\n`   | Newline (U+000A) |
| `\r`   | Carriage return (U+000D) |
| `\t`   | Tab (U+0009) |

**Invalid escapes trigger an error in strict mode.**

No Unicode escapes (`\uXXXX`) - UTF-8 is used directly.

---

## 3. Syntax

### 3.1 Indentation

- Default: 2 spaces per level
- Tabs are strictly forbidden in indentation
- Leading spaces must be exact multiples of indent size
- Blank lines are generally ignorable (validated in strict mode for arrays)

### 3.2 Objects

Key-value pairs with colon separator:

```
key: value
nested:
  inner: value
```

**Unquoted Key Pattern:** `^[A-Za-z_][A-Za-z0-9_.]*$`

Keys not matching this pattern must be quoted:

```
"special-key": value
"123numeric": value
```

### 3.3 Arrays

#### 3.3.1 Array Header Format

General form: `[N<delim?>]` or `key[N<delim?>]` or `key[N<delim?>]{fields}:`

- `N` = non-negative integer (element count)
- `<delim?>` = implicit comma (default), explicit `\t` (tab), or `|` (pipe)
- Colon MUST terminate every header

#### 3.3.2 Primitive Arrays (Inline)

Single line with delimiter-separated values:

```
numbers[3]: 1,2,3
flags[2]: true,false
names[3]|Alice|Bob|Carol
```

#### 3.3.3 Tabular Arrays (Uniform Objects)

Objects with identical keys in identical order:

```
users[3]{id,name,active}:
  1,Alice,true
  2,Bob,false
  3,Carol,true
```

Expands to:
```json
[
  {"id": 1, "name": "Alice", "active": true},
  {"id": 2, "name": "Bob", "active": false},
  {"id": 3, "name": "Carol", "active": true}
]
```

#### 3.3.4 Expanded List Form

Mixed or complex elements:

```
items[3]:
  - first
  - second
  - third
```

#### 3.3.5 List Items with Objects (v3.0)

Per v3.0, list-item objects with tabular arrays use this encoding:

```
data[2]:
  - id: 1
    rows[2]{x,y}:
      10,20
      30,40
  - id: 2
    rows[2]{x,y}:
      50,60
      70,80
```

The `- key[N]{fields}:` form places the header on the hyphen line.

### 3.4 Delimiters

Each array header declares an active delimiter for its scope:

| Symbol | Delimiter |
|--------|-----------|
| (none) | Comma `,` |
| `\|`   | Pipe      |
| `\t`   | Tab       |

Delimiter applies to:
- Inline primitive splits
- Field names in braces
- All rows/items under that header

Nested headers can change the delimiter for their scope.

### 3.5 Quoting Rules

**Quote a string value when it:**
- Contains the active delimiter
- Contains double quotes or backslashes
- Has leading/trailing whitespace
- Looks like a number, boolean, or null
- Is empty string
- Starts with `-` (list item marker)

### 3.6 Key Folding (Optional)

Collapses single-key object chains into dotted paths:

```
config:
  database:
    host: localhost
```

Folds to:

```
config.database.host: localhost
```

**Constraints:**
- Only when `keyFolding = safe`
- All segments must match `IdentifierSegment`: `^[A-Za-z_][A-Za-z0-9_]*$`
- No conflicts with sibling keys
- Respects `flattenDepth` limit

### 3.7 Path Expansion (Optional)

Inverse of key folding - splits dotted keys back to nested objects.

**Constraints:**
- Only when `expandPaths = safe`
- Only keys matching `IdentifierSegment` pattern are eligible
- Path separator is `.` (U+002E)

---

## 4. Root Form Detection

The decoder determines document structure by examining the first non-empty depth-0 line:

1. Valid array header -> root array
2. Single line (not header or key-value) -> single primitive
3. Otherwise -> root object
4. Empty document -> empty object `{}`

---

## 5. Options

### 5.1 Encode Options

```zig
pub const EncodeOptions = struct {
    indent: u8 = 2,                    // spaces per indent level
    delimiter: Delimiter = .comma,     // active delimiter
    key_folding: KeyFoldingMode = .off, // .off or .safe
    flatten_depth: usize = maxInt,     // max folding depth
};

pub const Delimiter = enum { comma, tab, pipe };
pub const KeyFoldingMode = enum { off, safe };
```

### 5.2 Decode Options

```zig
pub const DecodeOptions = struct {
    indent: u8 = 2,                       // expected indent size
    strict: bool = true,                  // enable strict validation
    expand_paths: ExpandPathsMode = .off, // .off or .safe
};

pub const ExpandPathsMode = enum { off, safe };
```

---

## 6. Error Handling

### 6.1 Error Categories

**Syntax Errors:**
- `UnterminatedString`: Missing closing quote
- `InvalidEscapeSequence`: Unknown escape like `\x`
- `MissingColon`: Key without colon separator
- `UnexpectedEndOfInput`: Truncated input

**Indentation Errors:**
- `InvalidIndentation`: Spaces not multiple of indent size
- `TabsInIndentation`: Tab character in leading whitespace

**Array Errors:**
- `CountMismatch`: Declared count differs from actual
- `BlankLineInArray`: Blank line within array (strict mode)
- `MalformedArrayHeader`: Invalid bracket/field syntax

**Structural Errors:**
- `PathExpansionConflict`: Dotted key conflicts with existing structure
- `InvalidJson`: Malformed JSON input (for encode)
- `InvalidToon`: Malformed TOON input (for decode)

### 6.2 Error Context

Errors include:
- Error code
- Human-readable message
- Line number (when applicable)
- Column/position (when applicable)

---

## 7. Strict Mode Validation

When `strict = true`, the decoder enforces:

| Check | Description |
|-------|-------------|
| Indentation multiples | Spaces must be exact multiple of indent size |
| No tabs | Tabs forbidden in indentation |
| Count validation | Array length must match declared count |
| No blank lines in arrays | Blank lines within array scope are errors |
| Field count match | Tabular rows must have exactly the declared fields |
| Valid escapes only | Only `\ " n r t` escapes permitted |

---

## 8. Conformance Requirements

### 8.1 Encoder MUST

1. Normalize numbers to canonical form
2. Use consistent delimiter (default: comma)
3. Quote strings/keys per specification
4. Count array elements accurately
5. Use LF line termination
6. Match field count in tabular rows

### 8.2 Decoder MUST

1. Parse headers with correct bracket/field/colon syntax
2. Unescape quoted strings/keys correctly
3. Detect root form (array vs object vs primitive)
4. Validate delimiter consistency within scope
5. Enforce indentation multiples
6. In strict mode: validate all counts and reject syntax errors

### 8.3 Validator MUST

1. Report all strict-mode errors
2. Validate count declarations
3. Check indentation consistency
4. Verify delimiter usage matches headers

---

## 9. Implementation-Specific Details

### 9.1 Memory Model

- All public functions accept an `Allocator`
- Returned slices are owned by caller (must free)
- Internal operations use arena allocators where beneficial
- No hidden allocations

### 9.2 Streaming

- `decodeStream` returns iterator of `JsonStreamEvent`
- `encodeWriter` writes directly to any `std.io.Writer`
- Memory usage bounded regardless of input size

### 9.3 Number Precision

- Internal representation: `f64`
- Canonical output uses shortest representation
- Values outside f64 range become `null`

---

## 10. References

- [TOON Specification v3.0](https://github.com/toon-format/spec/blob/main/SPEC.md)
- [Reference Implementation (TypeScript)](https://github.com/toon-format/toon)
- [toon_rust Implementation](https://github.com/Dicklesworthstone/toon_rust)
- [TOON Format Website](https://toonformat.dev/)

---

## Appendix A: Grammar (Informative)

```
document      = root-object | root-array | root-primitive | empty
empty         = ""

root-object   = { key-value-line }+
root-array    = array-header { array-content }
root-primitive = primitive-value

key-value-line = indent key ":" SP value NL
               | indent key ":" NL { nested-content }+

array-header  = [ key ] "[" count [ delimiter ] "]" [ "{" field-list "}" ] ":" [ SP inline-values ]
inline-values = value { delimiter value }*
field-list    = field-name { delimiter field-name }*

list-item     = indent "- " value NL
              | indent "- " key ":" SP value NL { nested-content }*

primitive     = null | bool | number | string
null          = "null"
bool          = "true" | "false"
number        = [ "-" ] int [ frac ] [ exp ]
string        = quoted-string | unquoted-string

quoted-string = DQUOTE { char | escape }* DQUOTE
unquoted-string = safe-char+
escape        = "\" ( "\" | DQUOTE | "n" | "r" | "t" )

key           = quoted-key | unquoted-key
unquoted-key  = ALPHA-UNDER { ALPHANUM-UNDER-DOT }*
quoted-key    = quoted-string

indent        = SP*
NL            = %x0A
SP            = %x20
DQUOTE        = %x22
```

---

## Appendix B: Changelog

| Version | Date | Changes |
|---------|------|---------|
| Draft   | 2025-01 | Initial tzu specification based on TOON v3.0 |
