# Build fixes — Java jar name, Ruby webrick

## Status
Done (2026-10-13). Verified in the Docker image: Java and Ruby conformance suites pass, Ruby unit tests pass (115).

## 1. Java: conformance image references a stale jar

**Today:** `java/pom.xml:8-9` is `zeromcp` / `0.3.0`, so `mvn package` writes `java/target/zeromcp-0.3.0.jar`. The conformance image and runners still name `zeromcp-0.2.2.jar`:
- `Dockerfile:94` (`javac -cp "target/zeromcp-0.2.2.jar:..."`): a `RUN` step, so a missing jar fails `docker build`.
- `tests/conformance/run-all.js:71, 111, 179, 274, 356, 424, 597, 669`
- `tests/conformance/run-route.js:68`

Every version bump breaks this again, because the version is part of the file name.

**Change:** stop putting the version in the local jar name.
- `java/pom.xml`: add `<finalName>zeromcp</finalName>` inside `<build>`. `mvn package` then writes `target/zeromcp.jar` (plus `zeromcp-sources.jar` / `zeromcp-javadoc.jar` from the source and javadoc plugins). `publish-java.yml:28` runs `mvn deploy`, which publishes by coordinates (`io.antidrift:zeromcp:0.3.0`), so the published artifact names don't change.
- `Dockerfile:94` and the 9 runner lines above: `zeromcp-0.2.2.jar` → `zeromcp.jar`.
- Version bumps no longer touch these files.

**Verify:**
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Java"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
```

## 2. Ruby: `webrick` is required but never declared

**Today:** `ruby/lib/zeromcp/server.rb:6` does a top-level `require 'webrick'`. `ruby/zeromcp.gemspec` declares no dependencies and requires Ruby `>= 3.0.0`. Since Ruby 3.0, webrick is not part of the standard library, so on a plain Ruby install `require 'zeromcp'` fails, including for stdio-only servers that never use HTTP.

This does not affect the Docker image: Ubuntu 24.04's `ruby` package (3.2.3) loads `webrick` (checked with `docker run ubuntu:24.04 … ruby -e 'require "webrick"'`).

**Change:** keep the gem at 0 dependencies (the brain's language matrix lists Ruby as 0 deps) by requiring webrick only where HTTP is used.
- `server.rb`: remove the top-level `require 'webrick'`. In `serve_http`, `require 'webrick'` first, and on `LoadError` raise with a clear message: `webrick is required for the HTTP transport: gem install webrick (or add it to your Gemfile)`.
- stdio, `handle_request` and `Registry` load without webrick.
- `ruby/README.md`: one line under HTTP transport saying it needs the `webrick` gem on Ruby 3.0+.

**Tests:** a test that the `zeromcp` lib loads with webrick hidden from the load path, and that `serve_http` raises the message above.

**Verify:**
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd ruby && ruby -I lib -I test -e '"'"'Dir["test/**/test_*.rb"].each { |f| require File.expand_path(f) }'"'"''
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Ruby"
```
