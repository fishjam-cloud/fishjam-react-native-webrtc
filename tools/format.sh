#!/bin/bash

#set -x

CLANG_FORMAT="${CLANG_FORMAT:-clang-format-15}"

if ! command -v "$CLANG_FORMAT" >/dev/null 2>&1; then
  echo "Missing formatter: $CLANG_FORMAT" >&2
  echo "Install clang-format-15, or run with CLANG_FORMAT=clang-format npm run format" >&2
  exit 127
fi

exec git ls-files | grep -e "\(\.java\|\.h\|\.m\)$" | grep -v examples | xargs "$CLANG_FORMAT" -i

