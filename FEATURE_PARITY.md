# Feature Parity: toon_rust -> tzu (TOON Zig)

This document tracks feature parity between the Rust reference implementation (`toon_rust`) and our Zig implementation (`tzu`). Each section maps to a module or capability in the Rust codebase.

**Target Spec Version:** [TOON v3.0](https://github.com/toon-format/spec) (2025-11-24)

---

## Status Legend

- [ ] Not started
- [~] In progress
- [x] Complete
- [-] Intentionally skipped (document reason)

---

## Conformance Test Gaps

Conformance tests (21/22 fixture files passing) reveal the following implementation gaps:

### Encoder Gaps

All encoder fixture files now pass (9/9):
- primitives, objects, arrays-primitive, arrays-nested, arrays-objects
- arrays-tabular, delimiters, key-folding, whitespace

### Decoder Gaps

12/13 decoder fixture files pass. Remaining gap:

- **Validation errors** (decode/validation-errors): 2 tests fail
  - Missing colon detection in key-value context (`a:\n  user` should error)
  - Multiple root primitives in strict mode (`hello\nworld` should error)

### Recently Fixed (commits 27f7c08, 9f5944e, 00271c4)

- **Escape sequences**: Tab escape handling in strings
- **Value quoting**: Strings containing colons and delimiters properly quoted
- **Empty containers**: Empty object list items encoded as bare hyphen
- **Key folding**: Sibling literal-key collision detection in safe mode
- **Path expansion**: Dotted key expansion to nested objects in safe mode
- **Blank lines**: Blank line handling in arrays
- **Empty items**: List arrays with empty items
- **Delimiter handling**: Nested arrays with tab delimiter
- **Tabular headers**: Keys requiring quotes now properly quoted
- **Tabular detection**: Same-key objects detected regardless of key order
- **Memory leaks**: Path expansion memory management fixed

See [CONFORMANCE.md](./CONFORMANCE.md) for detailed test results.

---

## 1. Core Data Types

### 1.1 Value Representation (`src/value.zig`)

The Rust implementation uses `JsonValue` as its core representation:

```
JsonValue
  |-- Primitive(StringOrNumberOrBoolOrNull)
  |-- Array(Vec<JsonValue>)
  |-- Object(Vec<(String, JsonValue)>)
```

**Tasks:**

- [ ] **1.1.1** Define `JsonPrimitive` union type
  - `String` - owned string slice
  - `Number` - f64 (handle -0.0 normalization to 0.0)
  - `Bool` - boolean
  - `Null` - void/null sentinel

- [ ] **1.1.2** Define `JsonValue` tagged union
  - `.primitive` -> `JsonPrimitive`
  - `.array` -> `ArrayList(JsonValue)` or slice
  - `.object` -> `ArrayList(Entry)` where `Entry = struct { key: []const u8, value: JsonValue }`

- [ ] **1.1.3** Implement `JsonValue` helpers
  - `fromF64(f64) -> JsonPrimitive` (normalize NaN/Infinity to null, -0.0 to 0.0)
  - `eql(JsonValue, JsonValue) -> bool` for equality comparison
  - `deinit(allocator)` for memory cleanup
  - `clone(allocator) -> JsonValue` for deep copy

### 1.2 Stream Events (`src/value.zig` or `src/events.zig`)

Rust uses `JsonStreamEvent` for streaming decode:

```rust
pub enum JsonStreamEvent {
    StartObject,
    EndObject,
    StartArray { length: usize },
    EndArray,
    Key { key: String, was_quoted: bool },
    Primitive { value: JsonPrimitive },
}
```

**Tasks:**

- [ ] **1.2.1** Define `JsonStreamEvent` tagged union
  - `.start_object`
  - `.end_object`
  - `.start_array` with `length: usize`
  - `.end_array`
  - `.key` with `key: []const u8` and `was_quoted: bool`
  - `.primitive` with `value: JsonPrimitive`

---

## 2. Shared Utilities

### 2.1 Constants (`src/shared/constants.zig`)

**Tasks:**

- [ ] **2.1.1** Define character constants
  ```zig
  pub const LIST_ITEM_MARKER = "-";
  pub const LIST_ITEM_PREFIX = "- ";
  pub const COMMA: u8 = ',';
  pub const COLON: u8 = ':';
  pub const SPACE: u8 = ' ';
  pub const PIPE: u8 = '|';
  pub const DOT: u8 = '.';
  pub const OPEN_BRACKET: u8 = '[';
  pub const CLOSE_BRACKET: u8 = ']';
  pub const OPEN_BRACE: u8 = '{';
  pub const CLOSE_BRACE: u8 = '}';
  pub const NULL_LITERAL = "null";
  pub const TRUE_LITERAL = "true";
  pub const FALSE_LITERAL = "false";
  pub const BACKSLASH: u8 = '\\';
  pub const DOUBLE_QUOTE: u8 = '"';
  pub const NEWLINE: u8 = '\n';
  pub const CARRIAGE_RETURN: u8 = '\r';
  pub const TAB: u8 = '\t';
  pub const DEFAULT_DELIMITER: u8 = COMMA;
  ```

### 2.2 Literal Utilities (`src/shared/literal_utils.zig`)

**Tasks:**

- [ ] **2.2.1** `isBooleanOrNullLiteral(value: []const u8) -> bool`
  - Match "true", "false", "null" exactly

- [ ] **2.2.2** `isNumericLike(value: []const u8) -> bool`
  - Detect values that look like numbers (for quoting decisions)
  - Handle sign, digits, decimal point, exponent notation
  - Leading zeros should return true (force quoting)

- [ ] **2.2.3** `isNumericLiteral(value: []const u8) -> bool`
  - Strict JSON number validation
  - No leading zeros (except "0" or "0.x")
  - Proper exponent handling
  - Must parse to finite f64

### 2.3 String Utilities (`src/shared/string_utils.zig`)

**Tasks:**

- [ ] **2.3.1** `escapeString(allocator, value: []const u8) -> ![]u8`
  - Escape: `\` -> `\\`, `"` -> `\"`, `\n` -> `\\n`, `\r` -> `\\r`, `\t` -> `\\t`

- [ ] **2.3.2** `unescapeString(allocator, value: []const u8) -> ![]u8`
  - Reverse of escape
  - Return error for invalid escape sequences
  - Return error for trailing backslash

- [ ] **2.3.3** `findClosingQuote(content: []const u8, start: usize) -> ?usize`
  - Find matching `"` accounting for escaped quotes
  - Skip `\"` sequences

- [ ] **2.3.4** `findUnquotedChar(content: []const u8, target: u8, start: usize) -> ?usize`
  - Find character outside of quoted strings
  - Track in_quotes state, handle escapes

### 2.4 Validation Utilities (`src/shared/validation.zig`)

**Tasks:**

- [ ] **2.4.1** `isValidUnquotedKey(key: []const u8) -> bool`
  - First char: ASCII alpha or `_`
  - Rest: ASCII alphanumeric, `_`, or `.`

- [ ] **2.4.2** `isIdentifierSegment(segment: []const u8) -> bool`
  - First char: ASCII alpha or `_`
  - Rest: ASCII alphanumeric or `_`
  - (No dots - used for key folding segments)

- [ ] **2.4.3** `isSafeUnquoted(value: []const u8, delimiter: u8) -> bool`
  - Not empty
  - No leading/trailing whitespace
  - Not a literal (bool/null/numeric)
  - No special chars: `:`, `"`, `\`, `[`, `]`, `{`, `}`, `\n`, `\r`, `\t`
  - Doesn't contain delimiter
  - Doesn't start with `-`

---

## 3. Options

### 3.1 Encode Options (`src/options.zig`)

**Tasks:**

- [ ] **3.1.1** Define `KeyFoldingMode` enum
  ```zig
  pub const KeyFoldingMode = enum { off, safe };
  ```

- [ ] **3.1.2** Define `EncodeOptions` struct
  ```zig
  pub const EncodeOptions = struct {
      indent: u8 = 2,
      delimiter: u8 = ',',
      key_folding: KeyFoldingMode = .off,
      flatten_depth: usize = std.math.maxInt(usize),
      // Note: replacer callback omitted for now (complex Zig semantics)
  };
  ```

### 3.2 Decode Options (`src/options.zig`)

**Tasks:**

- [ ] **3.2.1** Define `ExpandPathsMode` enum
  ```zig
  pub const ExpandPathsMode = enum { off, safe };
  ```

- [ ] **3.2.2** Define `DecodeOptions` struct
  ```zig
  pub const DecodeOptions = struct {
      indent: u8 = 2,
      strict: bool = true,
      expand_paths: ExpandPathsMode = .off,
  };
  ```

- [ ] **3.2.3** Define `DecodeStreamOptions` struct (subset)
  ```zig
  pub const DecodeStreamOptions = struct {
      indent: u8 = 2,
      strict: bool = true,
  };
  ```

---

## 4. Error Handling

### 4.1 Error Types (`src/error.zig`)

**Tasks:**

- [ ] **4.1.1** Define `ToonError` error set
  ```zig
  pub const ToonError = error{
      InvalidJson,
      InvalidToon,
      UnterminatedString,
      InvalidEscapeSequence,
      MissingColon,
      UnexpectedEndOfInput,
      InvalidIndentation,
      TabsInIndentation,
      CountMismatch,
      BlankLineInArray,
      PathExpansionConflict,
      MalformedArrayHeader,
      // ... additional errors as needed
  };
  ```

- [ ] **4.1.2** Define `ToonErrorWithMessage` for detailed errors
  ```zig
  pub const ToonErrorWithMessage = struct {
      err: ToonError,
      message: []const u8,
      line_number: ?usize = null,
  };
  ```

---

## 5. Encoder

### 5.1 Main Encoder (`src/encoder.zig`)

**Tasks:**

- [ ] **5.1.1** `encode(allocator, value: JsonValue, options: ?EncodeOptions) -> ![]u8`
  - Main entry point
  - Returns TOON string with newline-joined lines

- [ ] **5.1.2** `encodeLines(allocator, value: JsonValue, options: ?EncodeOptions) -> ![][]u8`
  - Return array of lines (for streaming output)

- [ ] **5.1.3** `encodeWriter(writer: anytype, value: JsonValue, options: ?EncodeOptions) -> !void`
  - Stream directly to writer (for large files)

### 5.2 Primitive Encoding (`src/encode/primitives.zig`)

**Tasks:**

- [ ] **5.2.1** `encodePrimitive(allocator, value: JsonPrimitive, delimiter: u8) -> ![]u8`
  - null -> "null"
  - bool -> "true"/"false"
  - number -> formatted string (handle 0.0, NaN, Infinity)
  - string -> quoted if necessary, otherwise raw

- [ ] **5.2.2** `encodeStringLiteral(allocator, value: []const u8, delimiter: u8) -> ![]u8`
  - Check `isSafeUnquoted` first
  - If safe, return as-is
  - Otherwise wrap in quotes and escape

- [ ] **5.2.3** `encodeKey(allocator, key: []const u8) -> ![]u8`
  - Check `isValidUnquotedKey` first
  - If valid, return as-is
  - Otherwise wrap in quotes and escape

- [ ] **5.2.4** `encodeAndJoinPrimitives(allocator, values: []JsonPrimitive, delimiter: u8) -> ![]u8`
  - Join encoded primitives with delimiter

- [ ] **5.2.5** `formatHeader(allocator, length: usize, key: ?[]const u8, fields: ?[][]const u8, delimiter: u8) -> ![]u8`
  - Format: `key[length]{field1,field2}:` or `[length]:` etc.
  - Include delimiter in bracket if not comma

- [ ] **5.2.6** `formatNumber(value: f64) -> []u8`
  - "0" for 0.0
  - "null" for NaN/Infinity
  - Standard float formatting otherwise

### 5.3 Normalization (`src/encode/normalize.zig`)

**Tasks:**

- [ ] **5.3.1** `normalizeJsonValue(allocator, value: JsonValue) -> !JsonValue`
  - Recursively normalize all numbers
  - NaN/Infinity -> null
  - -0.0 -> 0.0

- [ ] **5.3.2** Helper predicates
  - `isJsonPrimitive(value: JsonValue) -> bool`
  - `isJsonArray(value: JsonValue) -> bool`
  - `isJsonObject(value: JsonValue) -> bool`
  - `isEmptyObject(entries: []Entry) -> bool`
  - `isArrayOfPrimitives(items: []JsonValue) -> bool`
  - `isArrayOfArrays(items: []JsonValue) -> bool`
  - `isArrayOfObjects(items: []JsonValue) -> bool`

### 5.4 Key Folding (`src/encode/folding.zig`)

Key folding collapses single-child object chains into dotted paths:
`{a: {b: {c: 1}}}` -> `a.b.c: 1`

**Tasks:**

- [ ] **5.4.1** Define `FoldResult` struct
  ```zig
  pub const FoldResult = struct {
      folded_key: []const u8,
      remainder: ?JsonValue,
      leaf_value: JsonValue,
      segment_count: usize,
  };
  ```

- [ ] **5.4.2** `tryFoldKeyChain(key, value, siblings, options, root_literal_keys, path_prefix, flatten_depth) -> ?FoldResult`
  - Only fold if key_folding == .safe
  - Only fold objects with single key
  - All segments must be valid identifiers
  - Check for sibling key conflicts
  - Check for root literal key conflicts

- [ ] **5.4.3** `collectSingleKeyChain(start_key, start_value, max_depth) -> (segments, tail, leaf)`
  - Walk single-key object chain
  - Stop at max_depth or non-single-key object

### 5.5 Object/Array Encoding (`src/encode/encoders.zig`)

**Tasks:**

- [ ] **5.5.1** `encodeJsonValue(allocator, value: JsonValue, options: EncodeOptions) -> ![][]u8`
  - Main dispatch: primitive, array, or object

- [ ] **5.5.2** `encodeObjectLines(allocator, entries, depth, options, ...) -> !void`
  - Iterate entries, encode each key-value pair
  - Handle key folding

- [ ] **5.5.3** `encodeKeyValuePairLines(allocator, key, value, depth, options, ...) -> !void`
  - Try key folding first
  - Dispatch based on value type

- [ ] **5.5.4** `encodeArrayLines(allocator, key, items, depth, options) -> !void`
  - Empty array: just header
  - Array of primitives: inline on one line
  - Array of arrays (all primitive): list items
  - Array of objects: tabular if homogeneous, list items otherwise
  - Mixed: list items

- [ ] **5.5.5** `extractTabularHeader(items: []JsonValue) -> ?[][]u8`
  - Check if all objects have same keys in same order
  - All values must be primitives

- [ ] **5.5.6** `isTabularArray(items, header) -> bool`
  - Validate all rows match header exactly

- [ ] **5.5.7** `encodeInlineArrayLine(allocator, items, delimiter, key) -> ![]u8`
  - Format: `key[N]: val1, val2, val3`

- [ ] **5.5.8** `encodeArrayOfObjectsAsTabularLines(...)`
  - Header row with fields
  - Data rows with values only

- [ ] **5.5.9** `encodeMixedArrayAsListItemsLines(...)`
  - Each item on its own line with `- ` prefix

- [ ] **5.5.10** `encodeObjectAsListItemLines(...)`
  - First key-value inline with `-`
  - Rest indented

- [ ] **5.5.11** `encodeListItemValueLines(...)`
  - Handle primitive, array, object as list item

- [ ] **5.5.12** Line formatting helpers
  - `indentedLine(allocator, depth, content, indent_size) -> ![]u8`
  - `indentedKeyValueLine(allocator, depth, key, value, indent_size) -> ![]u8`
  - `indentedKeyColonLine(allocator, depth, key, indent_size) -> ![]u8`
  - `indentedListItem(allocator, depth, content, indent_size) -> ![]u8`
  - `indentedListItemKeyValue(...) -> ![]u8`
  - `indentedListItemKeyColon(...) -> ![]u8`
  - `indentedListItemKeyHeader(...) -> ![]u8`

---

## 6. Decoder

### 6.1 Scanner (`src/decode/scanner.zig`)

**Tasks:**

- [ ] **6.1.1** Define `ParsedLine` struct
  ```zig
  pub const ParsedLine = struct {
      raw: []const u8,
      indent: usize,
      content: []const u8,
      depth: usize,
      line_number: usize,
  };
  ```

- [ ] **6.1.2** Define `BlankLineInfo` struct
  ```zig
  pub const BlankLineInfo = struct {
      line_number: usize,
      indent: usize,
      depth: usize,
  };
  ```

- [ ] **6.1.3** Define `StreamingScanState` struct
  ```zig
  pub const StreamingScanState = struct {
      line_number: usize,
      blank_lines: ArrayList(BlankLineInfo),
  };
  ```

- [ ] **6.1.4** `parseLineIncremental(raw, state, indent_size, strict) -> !?ParsedLine`
  - Count leading spaces for indent
  - Skip blank lines (record in state.blank_lines)
  - Validate strict mode: no tabs, indent multiple of size

- [ ] **6.1.5** `parseLinesSync(source, indent_size, strict, state) -> ![]ParsedLine`
  - Parse all lines from iterator

- [ ] **6.1.6** `computeDepthFromIndent(indent_spaces, indent_size) -> usize`

- [ ] **6.1.7** Define `StreamingLineCursor` struct
  ```zig
  pub const StreamingLineCursor = struct {
      lines: []ParsedLine,
      index: usize,
      last_line: ?ParsedLine,
      blank_lines: []BlankLineInfo,

      pub fn peek(self) -> ?*const ParsedLine
      pub fn advance(self) -> void
      pub fn next(self) -> ?ParsedLine
      pub fn current(self) -> ?*const ParsedLine
      pub fn atEnd(self) -> bool
  };
  ```

### 6.2 Parser (`src/decode/parser.zig`)

**Tasks:**

- [ ] **6.2.1** Define `ArrayHeaderInfo` struct
  ```zig
  pub const ArrayHeaderInfo = struct {
      key: ?[]const u8,
      key_was_quoted: bool,
      length: usize,
      delimiter: u8,
      fields: ?[]FieldName,
  };
  ```

- [ ] **6.2.2** Define `FieldName` struct
  ```zig
  pub const FieldName = struct {
      name: []const u8,
      was_quoted: bool,
  };
  ```

- [ ] **6.2.3** Define `ArrayHeaderParseResult` struct
  ```zig
  pub const ArrayHeaderParseResult = struct {
      header: ArrayHeaderInfo,
      inline_values: ?[]const u8,
  };
  ```

- [ ] **6.2.4** `parseArrayHeaderLine(content, default_delimiter) -> !?ArrayHeaderParseResult`
  - Parse: `key[N]{fields}: values` or `[N]: values`
  - Handle quoted keys
  - Extract length, delimiter, fields, inline values

- [ ] **6.2.5** `parseBracketSegment(seg, default_delimiter) -> !(usize, u8)`
  - Extract length and delimiter from `[N]` or `[N|]`

- [ ] **6.2.6** `parseDelimitedValues(input, delimiter) -> [][]u8`
  - Split by delimiter, respecting quotes
  - Handle escaped characters inside quotes

- [ ] **6.2.7** `mapRowValuesToPrimitives(values) -> ![]JsonPrimitive`
  - Convert string tokens to typed primitives

- [ ] **6.2.8** `parsePrimitiveToken(token) -> !JsonPrimitive`
  - Empty -> empty string
  - Quoted -> unescape string
  - "true"/"false"/"null" -> bool/null
  - Numeric -> f64
  - Otherwise -> unquoted string

- [ ] **6.2.9** `parseStringLiteral(token) -> ![]u8`
  - Handle quoted strings with escapes

- [ ] **6.2.10** `parseUnquotedKey(content, start) -> !([]u8, usize)`
  - Read until colon

- [ ] **6.2.11** `parseQuotedKey(content, start) -> !([]u8, usize)`
  - Read quoted string, validate colon follows

- [ ] **6.2.12** `parseKeyToken(content, start) -> !([]u8, usize, bool)`
  - Dispatch to quoted or unquoted parser

- [ ] **6.2.13** `isArrayHeaderContent(content) -> bool`
  - Quick check: starts with `[` and has `:`

- [ ] **6.2.14** `isKeyValueContent(content) -> bool`
  - Quick check: has unquoted `:`

### 6.3 Decoders (`src/decode/decoders.zig`)

**Tasks:**

- [ ] **6.3.1** Define `DecoderContext` struct
  ```zig
  pub const DecoderContext = struct {
      indent: usize,
      strict: bool,
  };
  ```

- [ ] **6.3.2** `decodeStreamSync(source, options) -> ![]JsonStreamEvent`
  - Main entry point for streaming decode
  - Scan lines, parse events

- [ ] **6.3.3** `decodeKeyValue(events, content, cursor, base_depth, options) -> !void`
  - Parse key-value pair, emit events
  - Handle nested objects

- [ ] **6.3.4** `decodeObjectFields(events, cursor, base_depth, options) -> !void`
  - Parse object fields at given depth

- [ ] **6.3.5** `decodeArrayFromHeader(events, header_info, cursor, base_depth, options) -> !void`
  - Dispatch to inline, tabular, or list array decoding

- [ ] **6.3.6** `decodeInlinePrimitiveArray(events, header, inline_values, options) -> !void`
  - Parse inline primitive array

- [ ] **6.3.7** `decodeTabularArray(events, header, cursor, base_depth, options) -> !void`
  - Parse tabular array rows
  - Validate row counts

- [ ] **6.3.8** `decodeListArray(events, header, cursor, base_depth, options) -> !void`
  - Parse list-style array items

- [ ] **6.3.9** `decodeListItem(events, cursor, base_depth, options) -> !void`
  - Parse single list item (primitive, array, or object)

- [ ] **6.3.10** `yieldObjectFromFields(events, fields, primitives) -> void`
  - Emit object events from field names and values

- [ ] **6.3.11** `isKeyValueLine(line: ParsedLine) -> bool`
  - Check if line contains unquoted colon

### 6.4 Validation (`src/decode/validation.zig`)

**Tasks:**

- [ ] **6.4.1** `assertExpectedCount(actual, expected, item_type, strict) -> !void`
  - Error if strict and counts differ

- [ ] **6.4.2** `validateNoExtraListItems(next_line, item_depth, expected_count, strict) -> !void`
  - Check for extra list items beyond expected

- [ ] **6.4.3** `validateNoExtraTabularRows(next_line, row_depth, header, strict) -> !void`
  - Check for extra tabular rows beyond expected

- [ ] **6.4.4** `validateNoBlankLinesInRange(start, end, blank_lines, strict, context) -> !void`
  - Error if blank lines found within range in strict mode

- [ ] **6.4.5** `isDataRow(content, delimiter) -> bool`
  - Determine if line is data row vs key-value

### 6.5 Event Builder (`src/decode/event_builder.zig`)

**Tasks:**

- [ ] **6.5.1** Define `NodeValue` union
  ```zig
  pub const NodeValue = union(enum) {
      primitive: JsonPrimitive,
      array: ArrayList(NodeValue),
      object: ObjectNode,
  };
  ```

- [ ] **6.5.2** Define `ObjectNode` struct
  ```zig
  pub const ObjectNode = struct {
      entries: ArrayList(Entry),
      quoted_keys: StringHashSet,
  };
  ```

- [ ] **6.5.3** `buildNodeFromEvents(events) -> !NodeValue`
  - Build tree from event stream
  - Track object/array stack
  - Handle key events

- [ ] **6.5.4** `nodeToJson(node: NodeValue) -> JsonValue`
  - Convert NodeValue tree to JsonValue

### 6.6 Path Expansion (`src/decode/expand.zig`)

**Tasks:**

- [ ] **6.6.1** `expandPathsSafe(value: NodeValue, strict: bool) -> !NodeValue`
  - Main entry point
  - Recursively expand dotted keys in objects

- [ ] **6.6.2** `expandObject(obj: ObjectNode, strict: bool) -> !ObjectNode`
  - For each key with dots (not quoted), expand to nested structure

- [ ] **6.6.3** `insertPathEntries(entries, segments, value, strict) -> !void`
  - Insert value at nested path

- [ ] **6.6.4** `insertLiteralEntry(entries, key, value, strict) -> !void`
  - Insert or merge entry

- [ ] **6.6.5** `mergeObjects(target, source, strict) -> !void`
  - Merge two object nodes

### 6.7 Main Decoder API (`src/decoder.zig`)

**Tasks:**

- [ ] **6.7.1** `decode(allocator, input: []const u8, options: ?DecodeOptions) -> !JsonValue`
  - Main decode entry point

- [ ] **6.7.2** `tryDecode(allocator, input: []const u8, options: ?DecodeOptions) -> ToonError!JsonValue`
  - Fallible version with typed error

- [ ] **6.7.3** `decodeFromLines(allocator, lines, options) -> !JsonValue`
  - Decode from line iterator

- [ ] **6.7.4** `decodeStreamSync(lines, options) -> ![]JsonStreamEvent`
  - Stream decode to events

---

## 7. High-Level API

### 7.1 Public API (`src/root.zig`)

**Tasks:**

- [ ] **7.1.1** `jsonToToon(allocator, json: []const u8) -> ![]u8`
  - Parse JSON, encode to TOON

- [ ] **7.1.2** `toonToJson(allocator, toon: []const u8) -> ![]u8`
  - Decode TOON, stringify to JSON

- [ ] **7.1.3** `encode(allocator, value: JsonValue, options: ?EncodeOptions) -> ![]u8`
  - Encode JsonValue to TOON

- [ ] **7.1.4** `decode(allocator, toon: []const u8, options: ?DecodeOptions) -> !JsonValue`
  - Decode TOON to JsonValue

- [ ] **7.1.5** Re-export types
  - `JsonValue`, `JsonPrimitive`, `JsonStreamEvent`
  - `EncodeOptions`, `DecodeOptions`
  - `ToonError`

---

## 8. CLI

### 8.1 Argument Parsing (`src/cli/args.zig`)

**Tasks:**

- [ ] **8.1.1** Define CLI arguments structure
  - `input: ?[]const u8` - input file or "-" for stdin
  - `output: ?[]const u8` - output file or stdout
  - `encode: bool` - force encode mode
  - `decode: bool` - force decode mode
  - `delimiter: u8` - ',' (default), '|', '\t'
  - `indent: u8` - indentation size (default 2)
  - `no_strict: bool` - disable strict mode
  - `key_folding: KeyFoldingMode` - off/safe
  - `flatten_depth: ?usize` - max fold depth
  - `expand_paths: ExpandPathsMode` - off/safe
  - `stats: bool` - show token statistics

- [ ] **8.1.2** `parseArgs(args: [][]const u8) -> !Args`
  - Parse command line arguments
  - Handle `-e`/`--encode`, `-d`/`--decode`
  - Handle `-o`/`--output`
  - Handle `--delimiter`, `--indent`, etc.

- [ ] **8.1.3** `detectMode(args: Args) -> Mode`
  - Auto-detect based on file extension if not explicit
  - `.json` -> encode, `.toon` -> decode

- [ ] **8.1.4** `isStdin(args: Args) -> bool`
  - Check if reading from stdin

### 8.2 CLI Main (`src/main.zig`)

**Tasks:**

- [ ] **8.2.1** `main() !void`
  - Parse args
  - Run encode or decode
  - Handle errors, exit codes

- [ ] **8.2.2** `runEncode(args: Args) -> !void`
  - Read input (file or stdin)
  - Parse JSON
  - Encode to TOON
  - Write output
  - Optionally show stats

- [ ] **8.2.3** `runDecode(args: Args) -> !void`
  - Read input (file or stdin)
  - Decode TOON
  - Stringify to JSON
  - Write output

- [ ] **8.2.4** `readInput(args: Args) -> ![]u8`
  - Read from file or stdin

- [ ] **8.2.5** `writeOutput(args: Args, data: []const u8) -> !void`
  - Write to file or stdout

- [ ] **8.2.6** `estimateTokens(text: []const u8) -> usize`
  - Simple heuristic: ~4 chars per token

### 8.3 JSON Streaming Output (`src/cli/json_stream.zig`)

**Tasks:**

- [ ] **8.3.1** `jsonStreamFromEvents(events, indent) -> ![][]u8`
  - Convert stream events to JSON chunks
  - Proper formatting with indentation

### 8.4 JSON Stringify (`src/cli/json_stringify.zig`)

**Tasks:**

- [ ] **8.4.1** `jsonStringifyLines(value: JsonValue, indent: usize) -> ![][]u8`
  - Convert JsonValue to formatted JSON lines

---

## 9. Testing

### 9.1 Unit Tests

**Tasks:**

- [ ] **9.1.1** Test `shared/literal_utils.zig`
  - Boolean/null detection
  - Numeric literal validation

- [ ] **9.1.2** Test `shared/string_utils.zig`
  - Escape/unescape roundtrip
  - Quote finding
  - Unquoted char finding

- [ ] **9.1.3** Test `shared/validation.zig`
  - Key validation
  - Safe unquoted detection

- [ ] **9.1.4** Test `encode/primitives.zig`
  - Primitive encoding
  - Number formatting
  - Header formatting

- [ ] **9.1.5** Test `decode/parser.zig`
  - Array header parsing
  - Delimited value parsing
  - Key token parsing

- [ ] **9.1.6** Test `decode/scanner.zig`
  - Line parsing
  - Indentation handling
  - Strict mode validation

### 9.2 Integration Tests

**Tasks:**

- [ ] **9.2.1** Encode fixtures
  - Test various JSON structures
  - Verify TOON output matches expected

- [ ] **9.2.2** Decode fixtures
  - Test various TOON inputs
  - Verify JSON output matches expected

- [ ] **9.2.3** Roundtrip tests
  - JSON -> TOON -> JSON
  - Verify semantic equivalence

### 9.3 Conformance Tests

**Tasks:**

- [x] **9.3.1** Import TOON spec test cases
  - Validate against official spec examples
  - Implemented in `tests/conformance.zig`
  - 22 fixture files with 392 total tests
  - Run with `zig build test-conformance`

- [~] **9.3.2** Cross-validate with spec fixtures
  - 21/22 fixture files fully passing
  - 1 remaining: decode/validation-errors (strict mode error detection)
  - See [CONFORMANCE.md](./CONFORMANCE.md) for detailed status

---

## 10. Build & Distribution

### 10.1 Build Configuration

**Tasks:**

- [ ] **10.1.1** Configure `build.zig`
  - Library target (`libtzu`)
  - Executable target (`tzu`)
  - Test target
  - Release optimizations

- [ ] **10.1.2** Configure `build.zig.zon`
  - Package metadata
  - Dependencies (if any)

### 10.2 CI/CD

**Tasks:**

- [ ] **10.2.1** GitHub Actions workflow
  - Build on Linux, macOS, Windows
  - Run tests
  - Cross-compile releases

- [ ] **10.2.2** Release automation
  - Create GitHub releases
  - Attach binaries for all platforms

---

## Implementation Order

Recommended implementation sequence:

### Phase 1: Foundation
1. Constants (2.1)
2. Error types (4.1)
3. Literal utilities (2.2)
4. String utilities (2.3)
5. Validation utilities (2.4)

### Phase 2: Data Types
6. Value types (1.1)
7. Stream events (1.2)
8. Options (3.1, 3.2)

### Phase 3: Decoder Core
9. Scanner (6.1)
10. Parser (6.2)
11. Decoders (6.3)
12. Validation (6.4)
13. Event builder (6.5)
14. Main decoder API (6.7)

### Phase 4: Encoder Core
15. Normalization (5.3)
16. Primitive encoding (5.2)
17. Object/Array encoding (5.5)
18. Key folding (5.4)
19. Main encoder API (5.1)

### Phase 5: Advanced Features
20. Path expansion (6.6)
21. High-level API (7.1)

### Phase 6: CLI
22. Argument parsing (8.1)
23. JSON output (8.3, 8.4)
24. CLI main (8.2)

### Phase 7: Polish
25. Unit tests (9.1)
26. Integration tests (9.2)
27. Conformance tests (9.3)
28. Build & CI (10.1, 10.2)

---

## Notes

### Differences from Rust

1. **Memory Management**: Zig requires explicit allocator passing. All functions returning allocated memory must accept an allocator.

2. **Error Handling**: Use Zig error unions (`!T`) instead of Result. Consider using `errdefer` for cleanup.

3. **Strings**: Zig uses `[]const u8` slices. No built-in UTF-8 validation - handle carefully.

4. **Generics**: Use `anytype` and `@typeInfo` for generic iteration/writing.

5. **No Closures**: The Rust `replacer` callback would need to be redesigned as a function pointer with context.

6. **Async**: Zig's async is different from Rust's. The async decode functions may need redesign or omission.

### Performance Considerations

1. Use `std.mem.Allocator` consistently for allocation
2. Consider arena allocators for temporary operations
3. Pre-allocate where sizes are known (estimate_line_count equivalent)
4. Use `std.ArrayList` with `ensureTotalCapacity` for vectors
5. Consider `std.io.BufferedWriter` for file output
