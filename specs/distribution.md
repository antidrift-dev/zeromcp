# Distribution — registries vs GitHub

## Status
Punted (2026-10-13). For now, releases go to GitHub; registry publishing decisions come later. Nothing changed.

## The idea
Keep publishing to **npm** (`nodejs/`) and **PyPI** (`python/`). Stop pushing the other eight to package registries; people get them from GitHub.

## How it ships
Every language is developed in this monorepo and pushed to its own subtree repo: `antidrift-dev/zeromcp-{node,python,go,rust,java,kotlin,swift,csharp,ruby,php}`. All ten exist and were last pushed around 2026-08-06 (v0.3.0); `zeromcp-node` was pushed again on 2026-08-10. `scripts/release.sh` pushes all ten. CI (`.github/workflows/publish-*.yml`) pushes only Go, Swift and PHP; the other seven workflows publish to registries.

Going forward, GitHub (the subtree repos) is the distribution channel for everything except npm and PyPI, which keep publishing.

## Registry publishing that would stop
- Rust (crates.io), Java (Maven Central), C# (NuGet), Ruby (rubygems).
- Kotlin has a workflow but no publish repository configured, so it isn't published anywhere today.
- PHP is on Packagist, which reads from `zeromcp-php`; whether to keep that listing is open.

## Open questions
- CI subtree pushes for the seven languages that don't have one (Node, Python, Rust, Java, Kotlin, C#, Ruby), or keep using `scripts/release.sh`.
- What happens to the versions already on crates.io, Maven Central, NuGet and rubygems. They stay up; whether they get a deprecation notice pointing to GitHub.
- Which registry workflows get deleted or disabled.

## GitHub Release pages (for now)
Releases are announced as GitHub Release pages so people can see what shipped.

**Today:** the monorepo has Release pages for v0.3.0 and v0.2.1 only (`gh release list -R antidrift-dev/zeromcp`). None of the ten subtree repos has any Release page, only tags.

**Proposal for 0.4.0:**
- A Release page on the monorepo with the full notes, as for v0.3.0.
- A Release page on each subtree repo (`zeromcp-<lang>`) at the same tag, with that language's section of the notes and a link to the monorepo release. That's where per-language users land.
- Added to the release flow (`scripts/release.sh` or CI) so it happens on every tag, not by hand.
