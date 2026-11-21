#!/bin/bash
# Тесты чистой логики режима «отошёл». Без XCTest. Выход 1 при провале.
set -e
cd "$(dirname "$0")/.."
swiftc src/away.swift tests/away_tests.swift -o /tmp/away_tests && /tmp/away_tests
