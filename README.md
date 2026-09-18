# BuildGraphGuard

**Apple just restructured a core developer artifact because machines, not humans, are now editing it.**

Xcode 27.2 beta replaces `project.pbxproj` with `project.xcproj`: a JSON tree that mirrors the navigator, with `target-membership` arrays instead of the four-place registration dance, names and paths instead of 24-character hex ids, and one `build-settings` block with `KEY[config=Debug]` conditions instead of per-target-per-configuration `XCBuildConfiguration` duplication. Apple's stated design goal includes making the file *easier for coding agents to edit*.

That is the problem. A file an agent can confidently rewrite is a file an agent will confidently rewrite — and nothing in the toolchain distinguishes "added a source file" from "silently turned off `ENABLE_USER_SCRIPT_SANDBOXING`, dropped the deployment floor, or re-pointed a package dependency at a look-alike repository."

`BuildGraphGuard` is the missing layer: parse the build graph, canonicalise it, diff it **semantically**, and judge the diff against a policy that says which parts of the graph an automated writer may touch and which are frozen.

---

## Why this matters

Code review catches changes to code. Nobody reviews the project file — it was unreadable by design for twenty years, so teams learned to skim it. The JSON format makes it readable, which sounds like the fix and is actually the setup: now it is readable *and* machine-writable, and the same review habit still applies.

Three failure modes this library is built around, all of which a `git diff` shows you and none of which it makes you notice:

1. **The conditioned override.** An agent adds `CODE_SIGN_IDENTITY[config=Release]` and leaves the unconditioned key alone. A reviewer reading the Debug column sees nothing wrong. The Release build ships unsigned.
2. **The look-alike re-point.** `example-org` becomes `example-0rg`. Every version number in the file stays plausible. The dependency's *code* is substituted without a single version bump.
3. **The migration flood.** On the day you convert `pbxproj` → `xcproj`, a textual diff reports every setting in the file as changed, so nobody reads it — which is the one day something hostile could hide in it.

---

## What it does

```
project.xcproj (JSON)  ─┐
                        ├─→ ProjectGraph ─→ canonicalise ─→ semantic diff ─→ policy ─→ verdict
project.pbxproj (legacy)┘      (bridge)
```

| Stage | Type | What it is for |
|---|---|---|
| Decode | `XcprojDecoder` | Schema-gated reader for the JSON format. Inverts the navigator tree into `target → [path]`, which is the direction review needs. |
| Bridge | `PbxprojBridge` | Projects the legacy OpenStep-plist format into the *same* graph, so a migration branch is comparable to `main`. Includes a hand-written plist scanner. |
| Canonicalise | `GraphCanonicalizer` | Sorts, deduplicates, normalises paths, collapses `"YES"`/`true`, strips `.git` from repository URLs. Idempotent, and tested to be. |
| Diff | `GraphDiffer` | Structural change only — two channels: the literal key, and the **effective value per configuration**. |
| Judge | `PolicyEngine` | Rules with ids, severities and explanations. Exit code 1 only on a blocking finding. |
| Rank | `RiskScorer` | 0–100 heuristic for ordering a review queue. Deliberately **not** an input to the verdict. |

### The effective-value channel is the load-bearing idea

A key-level diff of failure mode 1 above reports "an unfamiliar key appeared", which is easy to wave through. Resolving each configuration's effective value instead reports:

```
Storefront [Release]: CODE_SIGN_IDENTITY effectively 'Apple Development' → '-'
```

which is not. `SettingTable.resolved(for:)` implements Xcode's precedence — more-qualified keys win, ties break by canonical key order so the result never depends on dictionary iteration order.

---

## Design decisions, and what was rejected

**Semantic diff, not textual.** The file is machine-written, so key order, whitespace and boolean spelling all move for free. Rejected: diffing canonicalised JSON text. It still reports a re-ordered `files` array as a change, and it cannot express "the Release build's effective signing identity moved" at all, because that value appears nowhere in either file as a literal.

**Canonicalisation is its own phase.** Rejected: folding it into the decoders. The library's central claim — semantic, not textual — is only checkable if canonicalisation is a function you can call twice and compare, and separating it keeps the `xcproj` and `pbxproj` paths from drifting apart silently.

**A hand-written plist scanner.** Rejected: `PropertyListSerialization`, which does not exist on Linux, and the migration gate has to run in the same CI job as everything else on whatever runner is cheapest. The scanner also throws with a byte offset rather than an opaque Foundation error, which is what a reviewer reading a red log needs. It works over UTF-8 bytes with an explicit index and bounds-checked reads; `OpenStepPlistTests` walks every truncation of a real fixture to prove it throws rather than traps.

**Uniform settings are hoisted during the bridge.** `pbxproj` stores a setting once per configuration; `xcproj` stores it once. Without hoisting, migration day reports every setting in the file as changed. `testWithoutHoistingTheSameMigrationWouldBeNoisy` builds the un-hoisted projection and asserts it *is* noisy, so the hoisted result's silence is known to be earned rather than accidental.

**Allow-with-a-frozen-list, not deny-by-default.** A deny-by-default setting policy is tighter on paper and abandoned in practice: an agent adding a source file legitimately touches membership and often a warning flag, so it fires on every commit and gets `--no-verify`'d inside a week. The baseline freezes only what is never an incidental side effect — signing, entitlements, sandboxing, deployment floor, dependency pins. Security that survives contact with a sprint beats security that is theoretically tighter.

**The risk score cannot block.** Rejected: a score threshold as the gate. A number that blocks is a number people tune until it stops blocking, and a threshold in a config file is far easier to argue down than a named rule that says `CODE_SIGN_IDENTITY changed`. The score exists to order a queue of forty "Needs review" pull requests.

**The literal channel is collapsed into the effective one for *findings*.** Both channels stay in the diff — each catches something the other misses — but reporting one edit three times is how a reviewer learns to scroll past findings. Per-configuration findings are kept separate, because Debug dropping to 15.0 and Release dropping to 14.0 are two different problems.

---

## Not crashing is a feature, not a detail

This runs in CI on whatever is on the branch, including a file a crashed merge left half-written. A trap there is not a caught bug — it is an outage, and "the gate crashed" reads like flaky infrastructure rather than a rejected change. So:

- **No unjustified force-unwraps.** Collection access is bounds-checked; the plist scanner's `peek` returns `Optional` and is the only read path.
- **No trapping arithmetic.** `SaturatingMath` routes every `+`, `*`, `/` and `Int(Double)` that Swift could trap on. `Int` ceilings derive from `Int.max` rather than 64-bit literals.
- **No unbounded recursion.** Both tree walks use an explicit stack with a depth cap (`XcprojDecoder.DecodingLimits`, default 64 deep / 200,000 nodes) — a stack overflow is uncatchable, a thrown error names the file.
- **No infinite walks.** The `pbxproj` group tree is walked with a visited set, because a bad merge can produce a cycle.
- **Version comparison is numeric.** `"9.0" > "17.0"` lexically, so a string-compared deployment floor would wave through exactly the regression it exists to catch.

`Package.swift` declares only iOS and macOS — the two platforms CI actually builds. Declaring watchOS or tvOS would be an unverified claim.

---

## Usage

```swift
import BuildGraphGuard

let baseline = try XcprojDecoder.decode(Data(contentsOf: baselineURL))
let proposed = try XcprojDecoder.decode(Data(contentsOf: proposedURL))

let diff = GraphDiffer.diff(baseline: baseline, proposed: proposed)
let assessment = PolicyEngine(policy: try BuildGraphPolicy.decode(policyData)).assess(diff)

for violation in assessment.violations {
    print("[\(violation.severity.label)] \(violation.ruleID): \(violation.explanation)")
}
exit(assessment.verdict.exitCode)   // 1 only when something blocking was found
```

A legacy branch goes through the bridge and produces the same type:

```swift
let legacy = try PbxprojBridge.decode(String(contentsOf: pbxprojURL, encoding: .utf8))
let diff = GraphDiffer.diff(baseline: legacy, proposed: proposed)   // diff.isCrossFormat == true
```

A starting policy is in [`Examples/buildgraph-policy.json`](Examples/buildgraph-policy.json) — it is `BuildGraphPolicy.baseline` serialised.

### Rules

| Rule id | Severity | Fires when |
|---|---|---|
| `setting.frozen` | Blocking | A frozen setting name or prefix changes |
| `setting.deployment-floor` | Blocking | A deployment target drops below the floor, or is removed |
| `setting.deployment-floor-unreadable` | Warning | The new value is not a plain version, so the rule cannot run |
| `policy.malformed-floor` | Warning | The policy's own floor is not a version |
| `target.frozen` | Blocking | Any edit to a target the policy freezes |
| `target.creation` / `target.removal` | Blocking | Target added/removed while the policy forbids it |
| `target.product-type` | Blocking | A target's product type changes |
| `membership.escapes-project` | Blocking | A target compiles a file outside the project directory |
| `package.repointed` | Blocking | A dependency's repository URL changes |
| `package.floating-pin` | Blocking | A dependency would track a branch |
| `package.pin-frozen` | Blocking | Any pin moves while the policy freezes them |
| `volume.membership` | Warning | Membership edits exceed the ceiling |
| `format.cross-format-comparison` | Advisory | The two sides came from different on-disk formats |

---

## Requirements

Swift 6.0, iOS 17+, macOS 14+. No dependencies.

```swift
.package(url: "https://github.com/rajatslakhina/build-graph-guard-kit.git", from: "1.0.0")
```

Products: `BuildGraphGuard` (the engine) and `BuildGraphGuardUI` (a SwiftUI review screen, `#if canImport(SwiftUI)`).

---

## Demo app

Demo app: (added after the companion repo is pushed — see below)

---

## Verification

(filled in after CI reports — see below)

---

## A note on the format

`project.xcproj` is a beta format. `XcprojDecoder` targets the structure described by Apple's published `xcode-project-format` spec and the 27.2 beta, and gates on `schema-version`: a file outside the supported range is **refused**, not best-guessed. A guard layer that misreads a format it does not know is worse than one that admits it does not know it.

## Licence

MIT. See [LICENSE](LICENSE).
