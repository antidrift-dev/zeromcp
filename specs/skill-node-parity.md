# Skill spec — `zeromcp-parity`

## Status
Spec only. Not built.

## What it is
A project skill at `.claude/skills/zeromcp-parity/` that brings one or more languages up to what Node does, the same way it was done for Python on 2026-10-13. Node (`nodejs/src`) is the reference.

## Triggers
"bring <lang> up to node", "node parity", "what's <lang> missing", "check parity", `/zeromcp-parity [lang…]`.

## Files
- `SKILL.md`: the process and rules below.
- `brief.md`: the per-language checklist and spec format given to agents. Starts from the brief used on 2026-10-13.
- `verify.md`: the Docker commands for each language.

## Process

### 1. Find what changed in Node
- Each `specs/lang/<lang>/node-parity.md` records a **baseline**: the Node commit it was written or last brought up to date against.
- Run `git log <baseline>..HEAD -- nodejs/src` and read the diffs. Those are the candidate gaps.
- No baseline yet means the full checklist: remote federation and its allowlist, remote in the handler and the registry, runtime context, hot reload, tool sources and namespacing, transports, and the config keys.

### 2. Check the language
- For each candidate, check the target language with commands (grep, read, build). Cite file:line.
- Anything not proven by a command is marked "unverified" in the spec. Nothing is inferred from comments, file names or older trees.
- Mark a gap N/A when it can't apply, with the evidence. For example, hot reload and tool sources don't apply to languages that register tools in code.

### 3. Write the spec
- Write or update `specs/lang/<lang>/node-parity.md` in the fixed format: Status, Gaps, one section per gap (Node does / <Lang> today / Change / Tests), Already at parity, Verify.
- The spec covers that language and this ask only. Bugs, Node quirks, adjacent work and decisions that reverse an earlier spec go in the message to Chris, never in the spec.
- Port Node's behavior as it is. Don't fix Node in another language.
- More than one language: one agent per language, in parallel. Each writes only its own spec file. Afterwards, check every spec for cross-language content and scope creep.

### 4. Stop
- Report the gap list for each language and the held findings. Do not build until Chris says build.

### 5. Build
- Follow the `build-mode` skill.
- Build every gap in the spec, with tests in that language's existing test layout. Change nothing outside the spec. Side issues go at the end as questions.

### 6. Verify in Docker only
- Rebuild the image from the repo root after the last change. The image copies the source in, and the copy is taken at build start, so an image that was building while code changed doesn't have the change.
- Run that language's unit tests and `node tests/conformance/run-all.js --language "<Name>"`.
- The route suite at the end of `run-all.js` ignores `--language`. Read only the target language's row, and compare its failures with the image from before the change before treating one as new.
- Host toolchains don't count as verification.

### 7. Close out
- Set the spec Status to done, with the date and the Docker results.
- Move the baseline to the Node commit the work was checked against.
- Don't commit unless asked.

## Rules carried from CLAUDE.md
- A question about parity is not an instruction to build.
- Verify or say unverified.
- The spec covers only the specific ask.
- Decide, then propose. Never ship without a go.

## Not in scope
- Changes to Node itself.
- HTTP serving. No language ships a built-in HTTP server (decisions log, 2026-10-13). Node's built-in server, transports and HTTP options are not parity targets.
- Releases, version bumps and tags (`engineering/release-guide.md`).

## Needed before it works
- Add a `Baseline:` line to the nine existing `node-parity.md` specs. They were all written against `7d49c6d` (HEAD on 2026-10-13); the last change to `nodejs/src` before it is `fb00024`.
