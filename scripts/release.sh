#!/usr/bin/env bash
set -euo pipefail

# ZeroMCP Release Script
# Tags the monorepo and pushes subtree splits to all 10 language repos.
#
# Usage: ./scripts/release.sh v0.1.0

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "  e.g. $0 v0.1.0"
  exit 1
fi

ORG="antidrift-dev"

# Map: monorepo directory → subtree repo name
declare -A SPLITS=(
  [nodejs]=zeromcp-node
  [python]=zeromcp-python
  [go]=zeromcp-go
  [rust]=zeromcp-rust
  [java]=zeromcp-java
  [kotlin]=zeromcp-kotlin
  [swift]=zeromcp-swift
  [csharp]=zeromcp-csharp
  [ruby]=zeromcp-ruby
  [php]=zeromcp-php
)

echo "=== ZeroMCP Release $VERSION ==="
echo ""

# Ensure we're on main and clean
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
  echo "ERROR: Must be on main branch (currently on $BRANCH)"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: Working tree is not clean. Commit or stash changes first."
  exit 1
fi

# Tag the monorepo
echo "Tagging monorepo $VERSION..."
git tag -a "$VERSION" -m "$VERSION"
git push origin "$VERSION"
echo "  ✓ Tag $VERSION pushed to $ORG/zeromcp"
echo ""

# Push subtrees
for dir in "${!SPLITS[@]}"; do
  repo="${SPLITS[$dir]}"
  remote_url="https://github.com/$ORG/$repo.git"
  echo "Pushing $dir/ → $ORG/$repo..."

  # Add remote if not exists
  if ! git remote get-url "$repo" &>/dev/null; then
    git remote add "$repo" "$remote_url"
  fi

  # Push subtree (force to handle first push to empty repo)
  git subtree push --prefix="$dir" "$repo" main 2>&1 | tail -1

  # Push the tag to the subtree repo
  # We need to create a tag on the subtree's HEAD
  SUBTREE_SHA=$(git subtree split --prefix="$dir" HEAD)
  git push "$repo" "$SUBTREE_SHA:refs/tags/$VERSION" 2>&1 | tail -1

  echo "  ✓ $repo main + $VERSION"
done

echo ""
echo "=== Release $VERSION complete ==="
echo ""
echo "Monorepo:  https://github.com/$ORG/zeromcp/releases/tag/$VERSION"
echo ""
echo "Subtrees:"
for dir in "${!SPLITS[@]}"; do
  repo="${SPLITS[$dir]}"
  echo "  https://github.com/$ORG/$repo/releases/tag/$VERSION"
done
echo ""
echo "Next steps:"
echo "  - npm publish (zeromcp-node)"
echo "  - twine upload (zeromcp-python)"
echo "  - cargo publish (zeromcp-rust)"
echo "  - mvn deploy (zeromcp-java)"
echo "  - gradle publish (zeromcp-kotlin)"
echo "  - dotnet nuget push (zeromcp-csharp)"
echo "  - gem push (zeromcp-ruby)"
echo "  - Go + Swift + PHP are live (tag-based)"
