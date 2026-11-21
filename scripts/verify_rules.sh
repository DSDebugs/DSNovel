#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

python3 - <<'PY'
import pathlib
import re
import sys

ROOT = pathlib.Path(".")
violations = []
warnings = []


def swift_files(*roots):
    out = []
    for r in roots:
        p = ROOT / r
        if p.exists():
            out.extend(sorted(p.rglob("*.swift")))
    return out


def source_files():
    files = swift_files("App")
    pkg_root = ROOT / "Packages"
    if pkg_root.exists():
        for src in sorted(pkg_root.glob("*/Sources")):
            files.extend(sorted(src.rglob("*.swift")))
    return files


def strip_swift_comments(text: str, blank_strings: bool = False) -> str:
    """Strip single-line // and nested /* ... */ comments while preserving exact line numbers.
    Properly handles normal strings "...", multiline strings \"\"\"...\"\"\" (including escaped \\\"\"\"
    and \\(...) interpolation stacks), and extended multi-# strings #+"..."#+ / #+\"\"\"...\"\"\"#+
    with \\#(...) interpolation stacks.
    """
    out = []
    n = len(text)

    def emit_blank_or_raw(segment: str):
        if blank_strings:
            for c in segment:
                out.append("\n" if c == "\n" else " ")
        else:
            out.append(segment)

    def scan_block_comment(idx: int) -> int:
        depth = 1
        out.extend((" ", " "))
        idx += 2
        while idx < n and depth > 0:
            if text[idx] == "/" and idx + 1 < n and text[idx + 1] == "*":
                depth += 1
                out.extend((" ", " "))
                idx += 2
            elif text[idx] == "*" and idx + 1 < n and text[idx + 1] == "/":
                depth -= 1
                out.extend((" ", " "))
                idx += 2
            elif text[idx] == "\n":
                out.append("\n")
                idx += 1
            else:
                out.append(" ")
                idx += 1
        return idx

    def scan_string(start_idx: int) -> int:
        i = start_idx
        hashes = 0
        while i < n and text[i] == "#":
            hashes += 1
            i += 1
        is_multiline = text[i:i + 3] == '"""'
        quote_delim = '"""' if is_multiline else '"'
        open_delim = ("#" * hashes) + quote_delim
        close_delim = quote_delim + ("#" * hashes)
        esc_prefix = "\\" + ("#" * hashes)

        emit_blank_or_raw(open_delim)
        i += len(quote_delim)

        while i < n:
            if text.startswith(close_delim, i):
                emit_blank_or_raw(close_delim)
                i += len(close_delim)
                return i
            if text.startswith(esc_prefix, i):
                after_esc = i + len(esc_prefix)
                if after_esc < n and text[after_esc] == "(":
                    # Interpolation \(...) or \#(...) with nested paren/comment/string stack
                    emit_blank_or_raw(esc_prefix + "(")
                    i = after_esc + 1
                    paren_stack = 1
                    while i < n and paren_stack > 0:
                        c = text[i]
                        if c == "/" and i + 1 < n and text[i + 1] == "/":
                            while i < n and text[i] != "\n":
                                out.append(" ")
                                i += 1
                        elif c == "/" and i + 1 < n and text[i + 1] == "*":
                            i = scan_block_comment(i)
                        elif c == '"':
                            i = scan_string(i)
                        elif c == "#":
                            j = i
                            while j < n and text[j] == "#":
                                j += 1
                            if j < n and text[j] == '"':
                                i = scan_string(i)
                            else:
                                out.append(c)
                                i += 1
                        elif c == "(":
                            paren_stack += 1
                            out.append("(")
                            i += 1
                        elif c == ")":
                            paren_stack -= 1
                            if paren_stack == 0:
                                out.append(" " if blank_strings else ")")
                            else:
                                out.append(")")
                            i += 1
                        else:
                            out.append(c)
                            i += 1
                    continue
                if is_multiline and text.startswith('"""', after_esc):
                    emit_blank_or_raw(esc_prefix + '"""')
                    i = after_esc + 3
                    continue
                if after_esc < n:
                    emit_blank_or_raw(text[i:after_esc + 1])
                    i = after_esc + 1
                    continue
                emit_blank_or_raw(text[i:])
                return n
            emit_blank_or_raw(text[i])
            i += 1
        return i

    i = 0
    while i < n:
        ch = text[i]
        # Single-line comment
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        # Nested block comment
        elif ch == "/" and i + 1 < n and text[i + 1] == "*":
            i = scan_block_comment(i)
        # Extended string literal #+"..."#+ or #+"""..."""#+
        elif ch == "#":
            j = i
            while j < n and text[j] == "#":
                j += 1
            if j < n and text[j] == '"':
                i = scan_string(i)
            else:
                out.append(ch)
                i += 1
        # Normal or multiline string literal "..." / """..."""
        elif ch == '"':
            i = scan_string(i)
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def extract_brace_block(text: str, open_brace_idx: int) -> str:
    """Return substring from open_brace_idx to matching closing brace (inclusive)."""
    depth = 0
    n = len(text)
    i = open_brace_idx
    while i < n:
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace_idx:i + 1]
        i += 1
    return text[open_brace_idx:]


def has_direct_level_deinit(type_block: str) -> bool:
    """Check if `deinit {` appears at direct class member level (brace depth == 1)."""
    depth = 0
    i = 0
    n = len(type_block)
    deinit_pat = re.compile(r"\bdeinit\s*\{")
    while i < n:
        ch = type_block[i]
        if ch == "{":
            depth += 1
            i += 1
        elif ch == "}":
            depth -= 1
            i += 1
        elif depth == 1 and ch == "d":
            m = deinit_pat.match(type_block, i)
            if m and (i == 0 or not (type_block[i - 1].isalnum() or type_block[i - 1] == "_")):
                return True
            i += 1
        else:
            i += 1
    return False


def line_number_at(text: str, idx: int) -> int:
    return text.count("\n", 0, idx) + 1


ALL_SRC = source_files()
APP_FEATURES = swift_files("App/Features")
APP_ROOT = swift_files("App")
DS_SRC = swift_files("Packages/DSDesignSystem/Sources")
DS_COMPONENTS = swift_files("Packages/DSDesignSystem/Sources/DSDesignSystem")

RAW_CACHE = {}
NOCOMMENT_CACHE = {}
CODE_CACHE = {}

for f in ALL_SRC:
    raw = f.read_text(encoding="utf-8", errors="ignore")
    RAW_CACHE[f] = raw
    NOCOMMENT_CACHE[f] = strip_swift_comments(raw, blank_strings=False)
    CODE_CACHE[f] = strip_swift_comments(raw, blank_strings=True)


def check_regex(rule, pattern, files, file_filter=None, blank_strings=False):
    pat = re.compile(pattern)
    for f in files:
        if file_filter and not file_filter(f):
            continue
        rel = f.as_posix()
        clean_lines = (CODE_CACHE[f] if blank_strings else NOCOMMENT_CACHE[f]).splitlines()
        raw_lines = RAW_CACHE[f].splitlines()
        for idx, line in enumerate(clean_lines, 1):
            if pat.search(line):
                raw_line = raw_lines[idx - 1].strip() if idx - 1 < len(raw_lines) else line.strip()
                violations.append(f"[FAIL] {rule} -> {rel}:{idx}:{raw_line}")


# 1. no-availability-ios
check_regex("no-availability-ios", r"#available\(iOS|@available\(iOS", ALL_SRC, blank_strings=True)

# 2. no-system-font-size
check_regex("no-system-font-size", r"\.font\(\.system\(size:", APP_FEATURES + DS_COMPONENTS, blank_strings=True)

# 3. no-hardcoded-color
check_regex("no-hardcoded-color", r"Color\(red:|Color\(hex|UIColor\(red:", APP_FEATURES, blank_strings=True)

# 4. no-repeat-forever
check_regex("no-repeat-forever", r"repeatForever", ALL_SRC, blank_strings=True)

# 5. no-unvalued-animation (supports nested parens and exempts iOS 17+ trailing closure `.animation(.easeInOut) { ... }`)
ANIM_RE = re.compile(r"\.animation\s*\(")
for f in ALL_SRC:
    code = CODE_CACHE[f]
    raw_lines = RAW_CACHE[f].splitlines()
    for m in ANIM_RE.finditer(code):
        start = m.end() - 1  # index of '('
        depth = 0
        i = start
        n = len(code)
        while i < n:
            if code[i] == "(":
                depth += 1
            elif code[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        # Exempt iOS 17+ trailing closure form: .animation(.easeInOut) { ... }
        j = i + 1
        while j < n and code[j].isspace():
            j += 1
        if j < n and code[j] == "{":
            continue
        args = code[start + 1:i]
        # Scan top-level arguments inside .animation(...) for 'value:'
        top_level = []
        d = 0
        for ch in args:
            if ch in "([{":
                d += 1
            elif ch in ")]}":
                d -= 1
            elif d == 0:
                top_level.append(ch)
        top_str = "".join(top_level)
        if not re.search(r",\s*value\s*:", top_str):
            ln = line_number_at(code, m.start())
            violations.append(f"[FAIL] no-unvalued-animation -> {f.as_posix()}:{ln}:{raw_lines[ln - 1].strip()}")

# 6. no-legacy-glass
check_regex("no-legacy-glass", r"LegacyGlass", ALL_SRC, blank_strings=True)

# 7. no-geometryreader-in-cells
check_regex("no-geometryreader-in-cells", r"GeometryReader", DS_COMPONENTS + swift_files("App/Features/Discover"), blank_strings=True)

# 8. no-body-collection-ops (scans ALL_SRC files containing `var body: some View`, `var xxx: some View`, or `@ViewBuilder` `some View` helpers)
SOME_VIEW_VAR_RE = re.compile(r"\bvar\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*some\s+View\s*\{")
VIEWBUILDER_DECL_RE = re.compile(r"@ViewBuilder\b[^{}]*?\bsome\s+View\s*\{")
BODY_OPS_RE = re.compile(r"\.filter\(|\.filter\s*\{|\.sorted\(|\.sorted\s*\{|Dictionary\(grouping:")
for f in ALL_SRC:
    code = CODE_CACHE[f]
    if "some View" not in code:
        continue
    raw_lines = RAW_CACHE[f].splitlines()
    seen_braces = set()
    for decl_re in (SOME_VIEW_VAR_RE, VIEWBUILDER_DECL_RE):
        for m in decl_re.finditer(code):
            brace_idx = m.end() - 1
            if brace_idx in seen_braces:
                continue
            seen_braces.add(brace_idx)
            block = extract_brace_block(code, brace_idx)
            for om in BODY_OPS_RE.finditer(block):
                ln = line_number_at(code, brace_idx + om.start())
                violations.append(f"[FAIL] no-body-collection-ops -> {f.as_posix()}:{ln}:{raw_lines[ln - 1].strip()}")

# 9. no-ontapgesture-nav
check_regex("no-ontapgesture-nav", r"onTapGesture", APP_FEATURES + DS_SRC, blank_strings=True)

# 10. no-ji-term (covers "\(count)集", 两集, 百集, etc.)
check_regex(
    "no-ji-term",
    r"(?:[0-9一二两三四五六七八九十百千万]|\)\s*)\s*集|播完[^\n\"']*集|第[^\n\"']*集",
    APP_FEATURES + DS_SRC,
    blank_strings=False,
)

# 11. no-fatalerror-container (covers general fatalError(...) across App & Packages)
check_regex("no-fatalerror-container", r"\bfatalError\s*\(", ALL_SRC, blank_strings=True)

# 12. uitest-flags-confined
for f in ALL_SRC:
    rel = f.as_posix()
    if rel.endswith("App/AppLaunchConfig.swift"):
        continue
    clean_lines = NOCOMMENT_CACHE[f].splitlines()
    raw_lines = RAW_CACHE[f].splitlines()
    for idx, line in enumerate(clean_lines, 1):
        if "DSNOVEL_UITEST" in line:
            violations.append(f"[FAIL] uitest-flags-confined -> {rel}:{idx}:{raw_lines[idx - 1].strip()}")

# 13. no-hardcoded-bottom-52
check_regex("no-hardcoded-bottom-52", r"padding\(\.bottom,\s*52\)", ALL_SRC, blank_strings=True)

# 14. root-views-inline-or-hidden-nav
for f in APP_FEATURES:
    if f.name.endswith("RootView.swift"):
        code = CODE_CACHE[f]
        if not re.search(r"navigationBarTitleDisplayMode\(\.inline\)|toolbar\(\.hidden,\s*for:\s*\.navigationBar\)", code):
            violations.append(f"[FAIL] root-views-inline-or-hidden-nav -> {f.as_posix()}")

# 15. list-scroll-bg-hidden (every List( / List { / Form { in App must configure scrollContentBackground(.hidden))
LIST_DECL_RE = re.compile(r"\b(?:List\s*(?:\(|\{)|Form\s*\{)")
for f in APP_ROOT:
    code = CODE_CACHE[f]
    list_count = len(LIST_DECL_RE.findall(code))
    scroll_bg_count = len(re.findall(r"scrollContentBackground\(\.hidden\)", code))
    if list_count > 0 and scroll_bg_count < list_count:
        violations.append(
            f"[FAIL] list-scroll-bg-hidden -> {f.as_posix()} (List/Form={list_count} > scrollContentBackground(.hidden)={scroll_bg_count})"
        )

# 16. no-confirmation-dialog
check_regex("no-confirmation-dialog", r"\.confirmationDialog\(", ALL_SRC, blank_strings=True)

# 17. no-global-skip-defaults
check_regex("no-global-skip-defaults", r"defaultSkipIntroSec|defaultSkipOutroSec|skipSettings|SkipSettingsDetailView", ALL_SRC, blank_strings=True)

# 18. max-file-lines-400 (v3.0 ironclad rule; >= 385 lines emits non-blocking [WARN])
for f in ALL_SRC:
    lines = RAW_CACHE[f].splitlines()
    if len(lines) > 400:
        violations.append(f"[FAIL] max-file-lines-400 -> {f.as_posix()} ({len(lines)} lines > 400)")
    elif len(lines) >= 385:
        warnings.append(f"[WARN] max-file-lines-385 -> {f.as_posix()} ({len(lines)} lines >= 385, approaching 400-line limit)")

# 19. no-split-view-or-precondition-failure (v3.0 ironclad rule)
check_regex("no-split-view-or-precondition-failure", r"\bNavigationSplitView\b|\bpreconditionFailure\b", ALL_SRC, blank_strings=True)

# 20. no-shared-singleton-in-features (v3.0 ironclad rule)
check_regex("no-shared-singleton-in-features", r"\.shared\b", APP_FEATURES, blank_strings=True)

# 21. no-force-unwrap-or-mainactor-deinit-hazard (global across all production Swift files)
FORCE_UNWRAP_RE = re.compile(r"\btry!|\bas!|(?<=[A-Za-z0-9_)\]])!(?!=)")
OBJC_IUO_DELEGATE_TYPES = (
    r"WKNavigation|WKWebView|WKNavigationAction|WKNavigationResponse|WKWebViewConfiguration|"
    r"WKWindowFeatures|WKFrameInfo|WKSecurityOrigin|WKScriptMessage|URLSession|URLSessionTask|"
    r"URLSessionDownloadTask|URLAuthenticationChallenge|URLResponse|HTTPURLResponse|Error|NSError"
)
FUNC_START_RE = re.compile(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:<[^>]*>)?\s*\(")
OBJC_IUO_PARAM_RE = re.compile(rf"(:\s*(?:{OBJC_IUO_DELEGATE_TYPES}))!")
MAINACTOR_TYPE_RE = re.compile(r"@MainActor\b(?:\s*(?:@\w+(?:\([^)]*\))?|public|internal|private|fileprivate|open|final))*\s+class\b[^{]*\{")


def mask_objc_iuo_func_params(code: str) -> str:
    """Mask known ObjC/WKWebView delegate IUO parameter types inside single- or multi-line func(...) signatures while preserving line numbers."""
    out = []
    n = len(code)
    pos = 0
    for m in FUNC_START_RE.finditer(code):
        if m.start() < pos:
            continue
        paren_start = m.end() - 1
        depth = 0
        i = paren_start
        while i < n:
            ch = code[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        paren_end = i + 1 if i < n else n
        out.append(code[pos:paren_start])
        sig = code[paren_start:paren_end]
        out.append(OBJC_IUO_PARAM_RE.sub(r"\1 ", sig))
        pos = paren_end
    out.append(code[pos:])
    return "".join(out)


for f in ALL_SRC:
    rel = f.as_posix()
    code = CODE_CACHE[f]
    raw_lines = RAW_CACHE[f].splitlines()
    # Strictly mask only known ObjC/WKWebView delegate IUO parameter types across single- or multi-line func(...) signatures
    masked_code = mask_objc_iuo_func_params(code)
    for idx, line in enumerate(masked_code.splitlines(), 1):
        if FORCE_UNWRAP_RE.search(line):
            violations.append(f"[FAIL] no-force-unwrap -> {rel}:{idx}:{raw_lines[idx - 1].strip()}")
    for tm in MAINACTOR_TYPE_RE.finditer(code):
        brace_idx = tm.end() - 1
        type_block = extract_brace_block(code, brace_idx)
        if has_direct_level_deinit(type_block):
            violations.append(
                f"[FAIL] mainactor-deinit-hazard -> {rel}: @MainActor class should use nonisolated observer bag instead of deinit"
            )

# 22. no-captured-local-var-in-bg-task (Swift 6: func/init, balanced params (...), typed/optional/inferred UIBackgroundTaskIdentifier)
CALLABLE_HEAD_RE = re.compile(r"\b(?:func\s+[A-Za-z_][A-Za-z0-9_]*|init\??)\s*(?:<[^>]*>)?\s*\(")
LOCAL_BG_VAR_RE = re.compile(
    r"\bvar\s+\w+\s*(?::\s*UIBackgroundTaskIdentifier\??\b|=\s*(?:UIBackgroundTaskIdentifier\.|UIApplication\.shared\.beginBackgroundTask))"
)
for f in ALL_SRC:
    rel = f.as_posix()
    code = CODE_CACHE[f]
    if "beginBackgroundTask" not in code:
        continue
    n = len(code)
    for fm in CALLABLE_HEAD_RE.finditer(code):
        # Match full balanced parameter list (...)
        p_idx = fm.end() - 1
        p_depth = 0
        while p_idx < n:
            if code[p_idx] == "(":
                p_depth += 1
            elif code[p_idx] == ")":
                p_depth -= 1
                if p_depth == 0:
                    p_idx += 1
                    break
            p_idx += 1
        # Advance to function/init body '{'
        brace_idx = p_idx
        while brace_idx < n and code[brace_idx] not in "{;":
            brace_idx += 1
        if brace_idx >= n or code[brace_idx] != "{":
            continue
        fn_block = extract_brace_block(code, brace_idx)
        if "beginBackgroundTask" in fn_block and LOCAL_BG_VAR_RE.search(fn_block):
            ln = line_number_at(code, brace_idx)
            violations.append(f"[FAIL] no-captured-local-var-in-bg-task -> {rel}:{ln}")

if warnings:
    for w in warnings:
        print(w)

if violations:
    for v in violations:
        print(v)
    print(f"verify_rules.sh failed with {len(violations)} violation(s) across 22 rules.")
    sys.exit(1)

print(f"[PASS] verify_rules.sh: 22/22 rules passed ({len(ALL_SRC)} Swift source files checked, 0 violations, {len(warnings)} warning(s)).")
PY
