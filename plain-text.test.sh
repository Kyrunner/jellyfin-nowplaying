#!/usr/bin/env bash
# Every string this plugin draws is drawn as plain text.
#
#   bash plain-text.test.sh
#
# Qt's default Text.textFormat is AutoText: a string that *looks* like markup is
# rendered as rich text, and rich text can pull remote resources (<img src=...>)
# into the shared shell. Titles, user names, download names and so on come from
# a server, so they must never be interpreted. Rather than audit which elements
# happen to show server data today, the rule covers the whole class: every
# Text-like element in every .qml file sets `textFormat: Text.PlainText`, and no
# rich format is named anywhere.
#
# The checker parses QML structure (braces, strings, comments), so a
# `textFormat` in a child element or in a comment does not count for its parent.
# It first proves itself against fixtures, so a checker that sees nothing cannot
# pass for a clean tree.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

cat >"$WORK/check.py" <<'PY'
import re, sys

TEXTLIKE = {"Text", "Label", "TextEdit", "TextArea", "TextField", "TextInput",
            "StyledText", "RichText"}
BANNED = re.compile(r"\b(?:Text\.)?(RichText|StyledText|AutoText|MarkdownText)\b")


def strip(src):
    """Blank out comments and string contents, keeping offsets and newlines."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(c + re.sub(r"[^\n]", " ", src[i + 1:j]) + c); i = j + 1
        else:
            out.append(c); i += 1
    return "".join(out)


def check(path):
    src = open(path, encoding="utf-8").read()
    code = strip(src)
    problems, count = [], 0
    for m in BANNED.finditer(code):
        line = code.count("\n", 0, m.start()) + 1
        problems.append(f"{path}:{line}: names rich format {m.group(1)}")
    for m in re.finditer(r"(?<![\w.])([A-Z]\w*)\s*\{", code):
        if m.group(1) not in TEXTLIKE:
            continue
        count += 1
        start = m.end()
        depth, i = 1, start
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        body = code[start:i - 1]
        # keep only depth-0 text of the body: drop nested {...} blocks
        flat, d = [], 0
        for ch in body:
            if ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
            elif d == 0:
                flat.append(ch)
        flat = "".join(flat)
        if not re.search(r"(?:^|[;\n])\s*textFormat\s*:\s*Text\.PlainText\s*(?:$|[;\n])", flat):
            line = code.count("\n", 0, m.start()) + 1
            problems.append(f"{path}:{line}: {m.group(1)} without textFormat: Text.PlainText")
    return count, problems


total, bad = 0, []
for p in sys.argv[1:]:
    c, probs = check(p)
    total += c
    bad += probs
for b in bad:
    print(b)
print(f"COUNT {total}")
sys.exit(1 if bad else 0)
PY

expect() { # name, want-exit, want-substring, files...
  local name="$1" want="$2" sub="$3"; shift 3
  local out rc
  out=$(python3 "$WORK/check.py" "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && [[ "$out" == *"$sub"* ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (exit %s, want %s)\n%s\n' "$name" "$rc" "$want" "$out" | sed 's/^/        /'
  fi
}

echo "the checker catches what it must:"
printf 'Item {\n  Text {\n    text: model.title\n  }\n}\n' >"$WORK/auto.qml"
expect "Text with no textFormat is rejected" 1 "without textFormat" "$WORK/auto.qml"
printf 'Item {\n  Text {\n    textFormat: Text.RichText\n    text: t\n  }\n}\n' >"$WORK/rich.qml"
expect "Text.RichText is rejected" 1 "RichText" "$WORK/rich.qml"
printf 'Item {\n  Text {\n    // textFormat: Text.PlainText\n    text: t\n  }\n}\n' >"$WORK/comment.qml"
expect "a commented-out textFormat does not count" 1 "without textFormat" "$WORK/comment.qml"
printf 'Item {\n  Text {\n    text: t\n    Text { textFormat: Text.PlainText; text: u }\n  }\n}\n' >"$WORK/nested.qml"
expect "a child's textFormat does not cover its parent" 1 "without textFormat" "$WORK/nested.qml"
printf 'Item {\n  Label { text: t }\n}\n' >"$WORK/label.qml"
expect "Label is covered too" 1 "Label without textFormat" "$WORK/label.qml"
printf 'Item {\n  Text {\n    textFormat: Text.PlainText\n    text: "<b>x</b>"\n  }\n}\n' >"$WORK/ok.qml"
expect "a PlainText Text passes" 0 "COUNT 1" "$WORK/ok.qml"

echo
echo "every Text-like element in this plugin is plain text:"
mapfile -t QML < <(find "$PLUGIN" -name '*.qml' -not -path '*/.git/*' | sort)
out=$(python3 "$WORK/check.py" "${QML[@]}" 2>&1); rc=$?
n=$(printf '%s\n' "$out" | sed -n 's/^COUNT //p')
if [ "$rc" -eq 0 ] && [ "${n:-0}" -gt 0 ]; then
  PASS=$((PASS + 1)); printf '  ok    %s Text-like elements across %s .qml files\n' "$n" "${#QML[@]}"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  plugin QML (exit %s, %s elements)\n' "$rc" "${n:-0}"
  printf '%s\n' "$out" | grep -v '^COUNT' | sed 's/^/        /'
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
