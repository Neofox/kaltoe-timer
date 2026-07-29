# Typed throws on FlexClient.fetchWeek

Follow-up item 14. **No separate implementation plan**: the change was implemented
and verified during feasibility probing, so a plan describing finished work would
have been ceremony. This document is the design record, and the change was
reviewed as a whole.

## Problem

Both `refresh()` implementations open with the same awkward line:

```swift
} catch let e as FlexClient.FlexError where e == .noSession || e == .sessionExpired {
```

A type-cast plus a `where` clause, followed by a generic `catch` that exists only
to mop up everything else. `AppState.refresh()` and `HeadlessState.refresh()`
each carry a copy.

## What made this less trivial than it looked

`fetchWeek` was **not** throwing only `FlexError`. It threw three families:

- its own `FlexError.noSession` / `.sessionExpired` / `.badResponse`
- `URLError` from `session.data(for:)` — offline, DNS failure, timeout
- `DecodingError` from `FlexRecordParser.parse`, via `JSONDecoder`

So `throws(FlexError)` was never a drop-in annotation: it required deciding what
becomes of the other two families, which means changing what the public
`FlexError` means. The original "small and contained" estimate was made without
reading the function and was wrong.

## Approach

`FlexError` gains one case, and `fetchWeek` maps the foreign errors at its own
boundary:

```swift
    public enum FlexError: Error, Equatable, Sendable {
        case noSession, sessionExpired, badResponse
        /// The request never completed: offline, DNS failure, timeout.
        case transport
    }
```

- `URLError` → `.transport`, mapped in the private `fetch(_:)` helper.
- Decoding failures → `.badResponse`. A body that cannot be decoded _is_ a bad
  response, so this needs no new case.

Rejected alternatives: collapsing everything into `.badResponse` would make one
case mean both "HTTP 500" and "you are offline", which is a worse public API and
the kind of lossy shortcut that reads fine now and confuses a later debugger. An
associated-value `case transport(any Error)` would preserve the underlying error
but break `Equatable`, which the `where` comparisons and several tests rely on.

Adding a case is **additive** — no existing case changes meaning — and keeps
`Equatable`.

## Consequences

### Both catch ladders become exhaustive switches

```swift
        } catch {
            switch error {
            case .noSession, .sessionExpired:
                hasSession = false
            case .badResponse, .transport:
                syncError = "Flex sync failed — showing last known data"
            }
        }
```

No cast, no `where`, no generic arm. `AppState`'s version keeps its
`guard generation == refreshGeneration else { return }` ahead of the switch, so
the superseded-refresh guard is unaffected.

**No observable behaviour change.** `.transport` and `.badResponse` map to the
same `syncError` string that `URLError` and `DecodingError` produced through the
old generic `catch`, and the session cases are unchanged.

### Two defensive test arms became provably unreachable

`FlexClientTests` had, twice:

```swift
        } catch let e as FlexClient.FlexError {
            XCTAssertEqual(e, .noSession)
        } catch { XCTFail("unexpected error \(error)") }
```

With the throw typed, the `as` test is always true — the compiler says so — and
the `XCTFail` arm can never run. Both collapse to a single `catch` whose `error`
is already a `FlexError`. **This is the actual payoff of the change**: the type
system deleted a defensive branch that could never fire.

### The daemon's test fake narrowed with it

`HeadlessStateTests`' `Script` served `Result<ParseResult, Error>` and threw
`URLError(.timedOut)` for the non-session case. Both narrow to
`FlexClient.FlexError`, and the case now throws `.transport`. This was predicted
when item 13 landed — narrowing the seam's throw type below `any Error` could not
be a recompile-only change — and is why item 13 was sequenced first.

## Two implementation details that do not infer

Both were found by compiling, not by reading:

1. **The default closure needs to be a method reference.**
   `{ try await client.fetchWeek(from: $0, to: $1) }` infers `throws any Error`
   and fails to convert. `client.fetchWeek(from:to:)` has exactly the right type,
   and is tidier.
2. **A closure literal needs its throw type spelled out.** Inference does not
   propagate through the optional parameter, so the test helper needs
   `{ (_, _) throws(FlexClient.FlexError) in try script.next() }`. Without the
   annotation: `invalid conversion of thrown error type 'any Error' to
'FlexClient.FlexError'`.

## Error handling

No new failure paths, and no failure path removed. Every error `fetchWeek` could
previously throw still causes the same state transition in both callers; only its
static type and its label change.

## Testing

**No new tests.** This is a type-level change with no behavioural surface, and
the existing suite already covers every arm of both catch ladders:
`HeadlessStateTests` pins `.noSession`, `.sessionExpired` and the non-session case
(now `.transport`), and `FlexClientTests` pins `.noSession` from two different
preconditions.

Counts are unchanged at **140 macOS / 114 Linux**, which is the point: a type
change that altered a count would mean behaviour moved.

## Verification

All performed:

1. `rm -rf .build && swift build --build-tests` — **0 warnings**, run once, cold.
   This gate earned its keep here: it caught the two `'as' test is always true`
   warnings that `swift build` alone cannot see, because they are in a test target.
2. `swift test` → **140, 0 failures.**
3. `./scripts/build-linux.sh` → succeeded.
4. Linux `swift test` in Docker with `-e TZ=Asia/Seoul` → **114, 0 failures.**

## Out of scope

- Giving `AppState` the same injected-fetch seam `HeadlessState` has. Its
  `refresh()` remains untestable; recorded as a follow-up.
- Threading the underlying `URLError` through for diagnostics. Nothing logs it
  today, and preserving it costs `Equatable`.
- Typed throws anywhere else — `FlexRecordParser.parse` and `CookieVault` still
  throw untyped, deliberately.
