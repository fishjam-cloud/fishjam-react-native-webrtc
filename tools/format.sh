#!/bin/bash

#set -x

CLANG_FORMAT="${CLANG_FORMAT:-clang-format}"
exec git ls-files | grep -e "\(\.java\|\.h\|\.m\)$" | grep -v examples | xargs "$CLANG_FORMAT" -i

