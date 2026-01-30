# tzu Implementation Beads

## Constants Module
type: task
priority: P0
labels: foundation, phase-1

**Goal**: Define all character and string constants used throughout the codebase.

**Technical Approach**:
Create `src/shared/constants.zig` with all TOON syntax constants:
- LIST_ITEM_MARKER, LIST_ITEM_PREFIX
- COMMA, COLON, SPACE, PIPE, DOT
- OPEN_BRACKET, CLOSE_BRACKET, OPEN_BRACE, CLOSE_BRACE
- NULL_LITERAL, TRUE_LITERAL, FALSE_LITERAL
- BACKSLASH, DOUBLE_QUOTE, NEWLINE, CARRIAGE_RETURN, TAB
- DEFAULT_DELIMITER

Create `src/shared.zig` as the shared module root.

**Validation**:
- `zig build` compiles without errors
- Constants importable via `@import("shared").constants`

---

## Error Types
type: task
priority: P0
labels: foundation, phase-1

**Goal**: Define ToonError error set and ToonErrorContext struct.

**Technical Approach**:
Create `src/error.zig` with:
- ToonError error set: InvalidJson, InvalidToon, UnterminatedString, InvalidEscapeSequence, MissingColon, UnexpectedEndOfInput, InvalidIndentation, TabsInIndentation, CountMismatch, BlankLineInArray, MalformedArrayHeader, FieldCountMismatch, PathExpansionConflict, DuplicateKey, OutOfMemory
- ToonErrorContext struct with err, message, line_number, column fields
- format() method for readable error output

**Validation**:
- `zig build` compiles
- Errors usable in error unions
- ToonErrorContext.format produces readable output

---

## Literal Utilities
type: task
priority: P0
labels: foundation, phase-1

**Goal**: Implement boolean/null/numeric literal detection functions.

**Technical Approach**:
Create `src/shared/literal_utils.zig`:
1. `isBooleanOrNullLiteral(value: []const u8) -> bool` - exact match "true", "false", "null"
2. `isNumericLike(value: []const u8) -> bool` - looks like number (for quoting decisions), leading zeros return true
3. `isNumericLiteral(value: []const u8) -> bool` - strict JSON number validation, no leading zeros, proper exponent handling

**Validation**:
- `zig build test` passes
- `isBooleanOrNullLiteral("true")` = true, `("TRUE")` = false
- `isNumericLike("007")` = true, `isNumericLiteral("007")` = false
- `isNumericLiteral("1.5e-10")` = true

---

## String Utilities
type: task
priority: P0
labels: foundation, phase-1

**Goal**: Implement string escape/unescape and quote-finding utilities.

**Technical Approach**:
Create `src/shared/string_utils.zig`:
1. `escapeString(allocator, value) -> ![]u8` - escape \, ", \n, \r, \t
2. `unescapeString(allocator, value) -> ![]u8` - reverse, error on invalid escapes
3. `findClosingQuote(content, start) -> ?usize` - find matching " skipping \"
4. `findUnquotedChar(content, target, start) -> ?usize` - find char outside quotes

**Validation**:
- `zig build test` passes
- Escape/unescape roundtrip works
- `unescapeString("\\x")` returns InvalidEscapeSequence
- `findClosingQuote("\"hello\"", 0)` = 6

---

## Validation Utilities
type: task
priority: P0
labels: foundation, phase-1

**Goal**: Implement key and value validation for quoting decisions.

**Technical Approach**:
Create `src/shared/validation.zig`:
1. `isValidUnquotedKey(key) -> bool` - first char alpha/_, rest alphanumeric/_/.
2. `isIdentifierSegment(segment) -> bool` - no dots (for key folding segments)
3. `isSafeUnquoted(value, delimiter) -> bool` - not empty, no leading/trailing space, not literal, no special chars, no delimiter, not starting with -

**Validation**:
- `zig build test` passes
- `isValidUnquotedKey("foo.bar")` = true, `("123abc")` = false
- `isIdentifierSegment("foo.bar")` = false
- `isSafeUnquoted("a,b", ',')` = false

---

## Value Types
type: task
priority: P0
labels: data-types, phase-2

**Goal**: Define JsonPrimitive and JsonValue as core data representation.

**Technical Approach**:
Create `src/value.zig`:
- JsonPrimitive union: null, boolean(bool), number(f64), string([]const u8)
- JsonPrimitive.fromF64(f64) - normalize NaN/Inf to null, -0.0 to 0.0
- JsonPrimitive.eql(), deinit()
- ObjectEntry struct: key, value
- JsonValue union: primitive, array([]JsonValue), object([]ObjectEntry)
- JsonValue.eql(), clone(), deinit()

**Validation**:
- `zig build test` passes
- `JsonPrimitive.fromF64(nan)` = .null
- `JsonPrimitive.fromF64(-0.0)` = .{ .number = 0.0 }
- Clone/deinit work without leaks

---

## Stream Events and Options
type: task
priority: P0
labels: data-types, phase-2

**Goal**: Define streaming event types and encode/decode options.

**Technical Approach**:
Create `src/events.zig`:
- JsonStreamEvent union: start_object, end_object, start_array{length}, end_array, key{key, was_quoted}, primitive{value}

Create `src/options.zig`:
- Delimiter enum: comma, tab, pipe with char() method
- KeyFoldingMode enum: off, safe
- ExpandPathsMode enum: off, safe
- EncodeOptions: indent(2), delimiter(comma), key_folding(off), flatten_depth(max)
- DecodeOptions: indent(2), strict(true), expand_paths(off)
- DecodeStreamOptions: indent(2), strict(true)

**Validation**:
- `zig build` compiles
- Options instantiable with defaults
- Delimiter.char() returns correct byte

---

## Scanner Module
type: task
priority: P0
labels: decoder, phase-3

**Goal**: Implement line-by-line scanner for TOON parsing.

**Technical Approach**:
Create `src/decode/scanner.zig`:
- ParsedLine struct: raw, indent, content, depth, line_number
- BlankLineInfo struct: line_number, indent, depth
- StreamingScanState struct: line_number, blank_lines ArrayList
- parseLineIncremental(raw, state, indent_size, strict) -> !?ParsedLine
  - Count spaces, error on tabs (strict), validate indent multiple
  - Skip blank lines, record in state
- parseLinesSync(source, indent_size, strict, state) -> ![]ParsedLine
- computeDepthFromIndent(indent_spaces, indent_size) -> usize
- StreamingLineCursor struct: lines, index, blank_lines with peek/advance/next/current/atEnd

**Validation**:
- `zig build test` passes
- "  key: value" parses with indent=2, depth=1
- Strict rejects tabs and odd indents

---

## Parser - Headers and Keys
type: task
priority: P0
labels: decoder, phase-3

**Goal**: Implement array header and key token parsing.

**Technical Approach**:
Create `src/decode/parser.zig`:
- FieldName struct: name, was_quoted
- ArrayHeaderInfo: key, key_was_quoted, length, delimiter, fields
- ArrayHeaderParseResult: header, inline_values
- parseArrayHeaderLine(allocator, content, default_delimiter) -> !?ArrayHeaderParseResult
- parseBracketSegment(segment, default_delimiter) -> !(length, delimiter)
- parseKeyToken(content, start) -> !(key, end_pos, was_quoted)
- parseUnquotedKey(content, start) -> !(key, end_pos)
- parseQuotedKey(allocator, content, start) -> !(key, end_pos)
- isArrayHeaderContent(content) -> bool
- isKeyValueContent(content) -> bool

**Validation**:
- `zig build test` passes
- `parseArrayHeaderLine("users[3]{id,name}: 1,Alice", ',')` returns correct header
- `parseBracketSegment("[5|]", ',')` = (5, '|')

---

## Parser - Value Parsing
type: task
priority: P0
labels: decoder, phase-3

**Goal**: Implement delimited value splitting and primitive parsing.

**Technical Approach**:
Add to `src/decode/parser.zig`:
- parseDelimitedValues(allocator, input, delimiter) -> ![][]const u8
  - Split respecting quotes, handle escapes
- mapRowValuesToPrimitives(allocator, values) -> ![]JsonPrimitive
- parsePrimitiveToken(allocator, token) -> !JsonPrimitive
  - Trim whitespace, empty = empty string, quoted = unescape
  - "true"/"false"/"null" = typed, valid number = f64, else = string
- parseStringLiteral(allocator, token) -> ![]const u8

**Validation**:
- `zig build test` passes
- `parseDelimitedValues("\"a,b\",c", ',')` = ["\"a,b\"", "c"]
- `parsePrimitiveToken("true")` = .{ .boolean = true }
- `parsePrimitiveToken("123")` = .{ .number = 123.0 }

---

## Decoder - Core Dispatch
type: task
priority: P1
labels: decoder, phase-3

**Goal**: Implement main decode stream dispatcher.

**Technical Approach**:
Create `src/decode/decoders.zig`:
- DecoderContext struct: indent, strict, allocator
- decodeStreamSync(allocator, source, options) -> !ArrayList(JsonStreamEvent)
  - Scan lines, detect root form (array/object/primitive/empty)
  - Dispatch to appropriate decoder
- decodeKeyValue(events, content, cursor, base_depth, ctx) -> !void
  - Parse key, emit .key, detect value type, dispatch
- decodeObjectFields(events, cursor, base_depth, ctx) -> !void
  - Parse lines at base_depth as key-values or arrays

Root form detection: empty=object, array header=array, key-value=object, single line=primitive

**Validation**:
- `zig build test` passes
- "key: value" emits start_object, key, primitive, end_object
- "[2]: a,b" emits start_array(2), 2 primitives, end_array
- "" emits start_object, end_object

---

## Decoder - Arrays
type: task
priority: P1
labels: decoder, phase-3

**Goal**: Implement array decoding for inline, tabular, list forms.

**Technical Approach**:
Add to `src/decode/decoders.zig`:
- decodeArrayFromHeader(events, header, inline_values, cursor, base_depth, ctx) -> !void
  - Dispatch to inline/tabular/list based on header
- decodeInlinePrimitiveArray(events, header, inline_values, ctx) -> !void
  - Split inline, parse primitives, validate count
- decodeTabularArray(events, header, cursor, base_depth, ctx) -> !void
  - Parse rows, emit object per row with fields
- decodeListArray(events, header, cursor, base_depth, ctx) -> !void
  - Parse "- " items
- decodeListItem(events, cursor, base_depth, ctx) -> !void
  - Detect nested array/object/primitive
- yieldObjectFromFields(events, fields, primitives) -> void

**Validation**:
- `zig build test` passes
- Inline "nums[3]: 1,2,3" produces 3 primitives
- Tabular with fields produces objects
- List "- item" format works
- Strict count mismatch errors

---

## Decoder - Validation
type: task
priority: P1
labels: decoder, phase-3

**Goal**: Implement strict mode validation helpers.

**Technical Approach**:
Create `src/decode/validation.zig`:
- assertExpectedCount(actual, expected, item_type, strict) -> !void
- validateNoExtraListItems(next_line, item_depth, expected, actual, strict) -> !void
- validateNoExtraTabularRows(next_line, row_depth, header, actual, strict) -> !void
- validateNoBlankLinesInRange(start, end, blank_lines, strict) -> !void
- isDataRow(content, delimiter) -> bool

**Validation**:
- `zig build test` passes
- `assertExpectedCount(2, 3, "items", true)` = CountMismatch
- `assertExpectedCount(2, 3, "items", false)` = ok
- Blank line detection works

---

## Decoder - Event Builder
type: task
priority: P1
labels: decoder, phase-3

**Goal**: Build JsonValue tree from stream events.

**Technical Approach**:
Create `src/decode/event_builder.zig`:
- NodeValue union: primitive, array(ArrayList), object(ObjectNode)
- ObjectNode struct: entries(ArrayList), quoted_keys(StringHashMap)
- buildNodeFromEvents(allocator, events) -> !NodeValue
  - Stack-based builder, push on start, pop on end
  - Handle key events, attach primitives
- nodeToJson(allocator, node) -> !JsonValue
  - Convert tree recursively

**Validation**:
- `zig build test` passes
- Events [start_object, key("a"), primitive(1), end_object] = {a: 1}
- Nested structures build correctly

---

## Decoder - Main API
type: task
priority: P1
labels: decoder, phase-3

**Goal**: Implement public decoder functions.

**Technical Approach**:
Create `src/decoder.zig`:
- decode(allocator, input, options) -> !JsonValue
  - Stream decode, build tree, optionally expand paths
- tryDecode(allocator, input, options) -> ToonError!JsonValue
- decodeFromLines(allocator, lines, options) -> !JsonValue
  - Join lines, decode

Export from root.zig.

**Validation**:
- `zig build test` passes
- `decode("key: value", null)` = object with key/value
- `decode("[2]: a,b", null)` = array with 2 strings
- Invalid input with strict returns errors

---

## Encoder - Normalization
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement value normalization and type predicates.

**Technical Approach**:
Create `src/encode/normalize.zig`:
- normalizeJsonValue(allocator, value) -> !JsonValue
  - Recursively normalize numbers (NaN/Inf -> null, -0 -> 0)
- Predicates: isJsonPrimitive, isJsonArray, isJsonObject, isEmptyObject
- isArrayOfPrimitives, isArrayOfArrays, isArrayOfObjects

**Validation**:
- `zig build test` passes
- `-0.0` normalizes to `0.0`
- `NaN` normalizes to `null`
- Predicates work correctly

---

## Encoder - Primitives
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement primitive and key encoding.

**Technical Approach**:
Create `src/encode/primitives.zig`:
- encodePrimitive(allocator, value, delimiter) -> ![]u8
  - null="null", bool="true"/"false", number=formatted, string=quoted if needed
- encodeStringLiteral(allocator, value, delimiter) -> ![]u8
  - Use isSafeUnquoted, quote+escape if needed
- encodeKey(allocator, key) -> ![]u8
  - Use isValidUnquotedKey, quote if needed
- encodeAndJoinPrimitives(allocator, values, delimiter) -> ![]u8
- formatHeader(allocator, length, key, fields, delimiter) -> ![]u8
- formatNumber(allocator, value) -> ![]u8
  - "0" for 0.0, "null" for NaN/Inf, shortest representation

**Validation**:
- `zig build test` passes
- `encodeStringLiteral("a,b", ',')` = "\"a,b\""
- `encodeKey("invalid-key")` = "\"invalid-key\""
- `formatNumber(1.0)` = "1"

---

## Encoder - Line Formatting
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement indentation and line formatting helpers.

**Technical Approach**:
Create `src/encode/formatting.zig`:
- indentedLine(allocator, depth, content, indent_size) -> ![]u8
- indentedKeyValueLine(allocator, depth, key, value, indent_size) -> ![]u8
- indentedKeyColonLine(allocator, depth, key, indent_size) -> ![]u8
- indentedListItem(allocator, depth, content, indent_size) -> ![]u8
- indentedListItemKeyValue(allocator, depth, key, value, indent_size) -> ![]u8
- indentedListItemKeyColon(allocator, depth, key, indent_size) -> ![]u8
- indentedListItemKeyHeader(allocator, depth, header, indent_size) -> ![]u8

**Validation**:
- `zig build test` passes
- `indentedLine(1, "content", 2)` = "  content"
- `indentedListItem(1, "item", 2)` = "  - item"

---

## Encoder - Key Folding
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement key folding for single-key object chains.

**Technical Approach**:
Create `src/encode/folding.zig`:
- FoldResult struct: folded_key, remainder, leaf_value, segment_count
- tryFoldKeyChain(allocator, key, value, siblings, options, root_keys, prefix, depth) -> !?FoldResult
  - Only fold if key_folding=.safe
  - All segments must be valid identifiers
  - Check for sibling conflicts
- collectSingleKeyChain(start_key, start_value, max_depth) -> (segments, tail, leaf)
- joinPath(allocator, prefix, segments) -> ![]u8

**Validation**:
- `zig build test` passes
- `{a: {b: {c: 1}}}` folds to `a.b.c: 1`
- `{a: {b: 1, c: 2}}` does not fold
- Flatten depth respected

---

## Encoder - Object and Array
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement main encoding dispatch.

**Technical Approach**:
Create `src/encode/encoders.zig`:
- encodeJsonValue(allocator, value, options) -> ![][]u8
  - Dispatch to primitive/array/object encoding
- encodeObjectLines(allocator, entries, depth, options, root_keys, prefix) -> ![][]u8
- encodeKeyValuePairLines(allocator, key, value, depth, options, siblings, root_keys, prefix) -> ![][]u8
  - Try key folding first
  - Dispatch based on value type

**Validation**:
- `zig build test` passes
- Simple `{a: 1}` encodes to "a: 1"
- Nested objects indent correctly
- Key folding produces dotted keys

---

## Encoder - Array Variants
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement array encoding (inline, tabular, list).

**Technical Approach**:
Add to `src/encode/encoders.zig`:
- encodeArrayLines(allocator, key, items, depth, options) -> ![][]u8
  - Empty = just header, primitives = inline, objects = tabular check, else = list
- extractTabularHeader(items) -> ?[][]const u8
- isTabularArray(items, header) -> bool
- encodeInlineArrayLine(allocator, items, delimiter, key, depth, indent) -> ![]u8
- encodeArrayOfObjectsAsTabularLines(...) -> ![][]u8
- encodeMixedArrayAsListItemsLines(...) -> ![][]u8
- encodeObjectAsListItemLines(...) -> ![][]u8
- encodeListItemValueLines(...) -> ![][]u8

**Validation**:
- `zig build test` passes
- `[1,2,3]` = "[3]: 1,2,3"
- Uniform objects = tabular format
- Mixed = list items

---

## Encoder - Main API
type: task
priority: P1
labels: encoder, phase-4

**Goal**: Implement public encoder functions.

**Technical Approach**:
Create `src/encoder.zig`:
- encode(allocator, value, options) -> ![]u8
  - Normalize, encode lines, join with \n
- encodeLines(allocator, value, options) -> ![][]u8
- encodeWriter(writer, value, options) -> !void

Export from root.zig.

**Validation**:
- `zig build test` passes
- `encode(jsonValue, null)` returns valid TOON
- `encodeWriter` works with any std.io.Writer

---

## Path Expansion
type: task
priority: P2
labels: decoder, advanced, phase-5

**Goal**: Implement path expansion for dotted keys.

**Technical Approach**:
Create `src/decode/expand.zig`:
- expandPathsSafe(allocator, value, strict) -> !NodeValue
  - Recursively expand dotted keys in objects
- expandObject(allocator, obj, strict) -> !ObjectNode
  - For unquoted keys with dots, split and expand
- insertPathEntries(entries, segments, value, strict) -> !void
- insertLiteralEntry(entries, key, value, strict) -> !void
- mergeObjects(target, source, strict) -> !void

**Validation**:
- `zig build test` passes
- `{a.b.c: 1}` expands to `{a: {b: {c: 1}}}`
- Quoted keys `{"a.b": 1}` don't expand
- Conflicts in strict = PathExpansionConflict

---

## High-Level API
type: task
priority: P2
labels: api, phase-5

**Goal**: Implement JSON string conversion functions.

**Technical Approach**:
Update `src/root.zig`:
- jsonToToon(allocator, json, options) -> ![]u8
  - Parse JSON with std.json, convert to JsonValue, encode
- toonToJson(allocator, toon, options) -> ![]u8
  - Decode to JsonValue, stringify to JSON
- jsonValueFromStd(allocator, value) -> !JsonValue
- jsonStringify(allocator, value) -> ![]u8

Re-export: JsonValue, JsonPrimitive, JsonStreamEvent, EncodeOptions, DecodeOptions, ToonError, encode, decode, etc.

**Validation**:
- `zig build test` passes
- `jsonToToon("{\"a\":1}", null)` = "a: 1"
- `toonToJson("a: 1", null)` = `{"a":1}`
- Roundtrip preserves semantics

---

## CLI - Argument Parsing
type: task
priority: P2
labels: cli, phase-6

**Goal**: Implement command-line argument parsing.

**Technical Approach**:
Create `src/cli/args.zig`:
- Command enum: encode, decode, convert, stats, help, version
- Args struct: command, input, output, delimiter, indent, strict, key_folding, flatten_depth, expand_paths
- Args.toEncodeOptions(), Args.toDecodeOptions()
- parseArgs(args) -> !Args
  - Handle: tzu encode|decode|convert|stats [options] [input] [-o output]
  - Options: -e, -d, -o, --delimiter, --indent, --no-strict, --key-folding, etc.
- detectMode(args) -> Command
- isStdin(args) -> bool
- printHelp(writer), printVersion(writer)

**Validation**:
- `zig build test` passes
- `parseArgs(["encode", "input.json"])` works
- Auto-detect from extension works

---

## CLI - JSON Output
type: task
priority: P2
labels: cli, phase-6

**Goal**: Implement JSON stringification for CLI.

**Technical Approach**:
Create `src/cli/json_stringify.zig`:
- jsonStringify(allocator, value, indent) -> ![]u8
- jsonStringifyWriter(writer, value, indent, depth) -> !void
- stringifyPrimitive(writer, p) -> !void
- writeEscapedJsonString(writer, s) -> !void
- writeIndent(writer, spaces) -> !void

**Validation**:
- `zig build test` passes
- Compact and indented output work
- Special chars escaped

---

## CLI - Main Entry
type: task
priority: P2
labels: cli, phase-6

**Goal**: Implement CLI main function.

**Technical Approach**:
Update `src/main.zig`:
- main() -> !void
  - Parse args, dispatch to command handler
- runEncode(allocator, args) -> !void
- runDecode(allocator, args) -> !void
- runStats(allocator, args) -> !void
  - Show JSON/TOON byte/token comparison
- readInput(allocator, args) -> ![]u8
- writeOutput(args, data) -> !void
- estimateTokens(text) -> usize

**Validation**:
- `zig build` produces `tzu` binary
- `tzu encode input.json` works
- `tzu decode input.toon -o out.json` works
- `tzu stats input.json` shows comparison
- `tzu --help`, `tzu --version` work

---

## Unit Tests
type: task
priority: P2
labels: testing, phase-7

**Goal**: Add comprehensive unit tests.

**Technical Approach**:
Add inline test blocks to each module:
- shared/literal_utils.zig: boolean/null/numeric edge cases
- shared/string_utils.zig: escape/unescape roundtrip, all sequences, errors
- shared/validation.zig: key validation, safe unquoted
- encode/primitives.zig: all types, number formatting
- decode/parser.zig: header parsing, value splitting
- decode/scanner.zig: indent handling, strict mode

Use std.testing.allocator for leak detection.

**Validation**:
- `zig build test` passes with no leaks
- Edge cases covered
- Error paths tested

---

## Integration Tests
type: task
priority: P2
labels: testing, phase-7

**Goal**: Add end-to-end encode/decode tests.

**Technical Approach**:
Create `tests/integration.zig`:
- Test roundtrip for: simple object, nested object, primitive array, tabular array, mixed array, key folding, delimiter variants, strict mode errors

Update build.zig with test-integration step.

**Validation**:
- `zig build test-integration` passes
- Roundtrips maintain semantic equality

---

## Conformance Tests
type: task
priority: P2
labels: testing, phase-7

**Goal**: Validate against TOON spec fixtures.

**Technical Approach**:
Create `tests/conformance.zig`:
- Load fixtures from toon-format/spec submodule
- Test encode fixtures: JSON -> TOON comparison
- Test decode fixtures: TOON -> JSON comparison
- Handle error cases

Requires spec submodule setup.

**Validation**:
- `zig build test-conformance` passes
- All 349 spec fixtures pass

---

## Build Configuration
type: task
priority: P2
labels: build, phase-7

**Goal**: Finalize build.zig with all targets.

**Technical Approach**:
Update `build.zig`:
- Static library target (toon_zig)
- Executable target (tzu)
- Unit test step
- Integration test step
- Conformance test step
- All tests step
- Run step

Update `build.zig.zon` with metadata.

**Validation**:
- `zig build` produces library and executable
- All test commands work
- Release build optimized

---

## CI/CD Pipeline
type: task
priority: P3
labels: ci, phase-7

**Goal**: Set up GitHub Actions.

**Technical Approach**:
Create `.github/workflows/ci.yml`:
- Test on ubuntu, macos, windows
- Format check

Create `.github/workflows/release.yml`:
- Build on tag push
- Cross-compile for 5 targets
- Upload release artifacts

**Validation**:
- CI runs on PRs
- Tests pass on all platforms
- Tags trigger releases
