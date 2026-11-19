#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

ALLOWLIST_FILE="scripts/rules_allowlist.txt"
TOUCHED_VIOLATIONS=0

is_allowed() {
  local rule="$1"
  local file="$2"
  if [[ -f "$ALLOWLIST_FILE" ]] && grep -Fqx "${rule}:${file}" "$ALLOWLIST_FILE"; then
    return 0
  fi
  return 1
}

check_grep_rule() {
  local rule="$1"
  local pattern="$2"
  shift 2
  local paths=("$@")

  local existing_paths=()
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] && existing_paths+=("$p")
  done
  [[ ${#existing_paths[@]} -eq 0 ]] && return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local file="${line%%:*}"
    if ! is_allowed "$rule" "$file"; then
      echo "[FAIL] ${rule} -> ${line}"
      TOUCHED_VIOLATIONS=$((TOUCHED_VIOLATIONS + 1))
    fi
  # 忽略注释行：规则本意是约束**代码**，不应因为注释/文档示例（如「第1集」出现在注释里）而失败。
  # 例外情况（确有必要的）走 rules_allowlist.txt。
  done < <(grep -rnE --include="*.swift" "$pattern" "${existing_paths[@]}" 2>/dev/null \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|///|\*|/\*)' || true)
}

# 1. no-availability-ios
check_grep_rule "no-availability-ios" "#available\(iOS|@available\(iOS" "DSNovel"

# 2. no-system-font-size
check_grep_rule "no-system-font-size" "\.font\(\.system\(size:" "DSNovel/Features" "DSNovel/DesignSystem/Components"

# 3. no-hardcoded-color
check_grep_rule "no-hardcoded-color" "Color\(red:|Color\(hex|UIColor\(red:" "DSNovel/Features"

# 4. no-repeat-forever
check_grep_rule "no-repeat-forever" "repeatForever" "DSNovel"

# 5. no-unvalued-animation (跨平台 python3 实现，兼容 macOS BSD grep 与 Linux GNU grep)
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file="${line%%:*}"
  if ! is_allowed "no-unvalued-animation" "$file"; then
    echo "[FAIL] no-unvalued-animation -> ${line}"
    TOUCHED_VIOLATIONS=$((TOUCHED_VIOLATIONS + 1))
  fi
done < <(python3 -c '
import pathlib, re
pat = re.compile(r"\.animation\([^,)]*\)(?!.*value)")
comment_pat = re.compile(r"^\s*(//|///|\*|/\*)")
root = pathlib.Path("DSNovel")
if root.exists():
    for path in sorted(root.rglob("*.swift")):
        rel = path.as_posix()
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for idx, line in enumerate(text.splitlines(), 1):
            if comment_pat.match(line):
                continue
            if pat.search(line):
                print(f"{rel}:{idx}:{line}")
' || true)

# 6. no-legacy-glass
check_grep_rule "no-legacy-glass" "LegacyGlass" "DSNovel"

# 7. no-geometryreader-in-cells
check_grep_rule "no-geometryreader-in-cells" "GeometryReader" "DSNovel/DesignSystem/Components" "DSNovel/Features/Discover"

# 8. no-body-collection-ops (on *View.swift under DSNovel/Features AND DSNovel/App)
while IFS= read -r view_file; do
  [[ -z "$view_file" ]] && continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! is_allowed "no-body-collection-ops" "$view_file"; then
      echo "[FAIL] no-body-collection-ops -> ${view_file}:${line}"
      TOUCHED_VIOLATIONS=$((TOUCHED_VIOLATIONS + 1))
    fi
  done < <(grep -nE "\.filter\(|\.filter[[:space:]]*\{|\.sorted\(|\.sorted[[:space:]]*\{|Dictionary\(grouping:" "$view_file" | grep -vE '^[0-9]+:[[:space:]]*(//|///|\*|/\*)' || true)
done < <(find DSNovel/Features DSNovel/App -type f \( -name "*View.swift" -o -name "*Section.swift" -o -name "AppShell.swift" \) 2>/dev/null || true)

# 9. no-ontapgesture-nav
check_grep_rule "no-ontapgesture-nav" "onTapGesture" "DSNovel/Features" "DSNovel/DesignSystem/Components"

# 10. no-ji-term
check_grep_rule "no-ji-term" "[0-9一二三四五六七八九十]+ ?集|播完.*集|第.*集" "DSNovel/Features" "DSNovel/DesignSystem"

# 11. no-fatalerror-container
check_grep_rule "no-fatalerror-container" 'fatalError\("无法初始化' "DSNovel/App"

# 12. uitest-flags-confined
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file="${line%%:*}"
  case "$file" in
    DSNovel/Debug/*|DSNovel/App/AppLaunchConfig.swift)
      ;;
    *)
      echo "[FAIL] uitest-flags-confined -> ${line}"
      TOUCHED_VIOLATIONS=$((TOUCHED_VIOLATIONS + 1))
      ;;
  esac
done < <(grep -rnE --include="*.swift" "DSNOVEL_UITEST" "DSNovel" || true)

# 13. no-hardcoded-bottom-52 & no-bottom-safeareainset-miniplayer (FIX-02)
check_grep_rule "no-hardcoded-bottom-52" "padding\(\.bottom, 52\)" "DSNovel"

# 14. root-views-inline-or-hidden-nav (FIX-01)
while IFS= read -r root_file; do
  [[ -z "$root_file" ]] && continue
  if ! grep -qE "navigationBarTitleDisplayMode\(\.inline\)|toolbar\(\.hidden, for: \.navigationBar\)" "$root_file"; then
    echo "[FAIL] root-views-inline-or-hidden-nav -> ${root_file}"
    TOUCHED_VIOLATIONS=$((TOUCHED_VIOLATIONS + 1))
  fi
done < <(find DSNovel/Features -type f -name "*RootView.swift" 2>/dev/null || true)

# 15. list-scroll-bg-hidden (FIX-01)
while IFS= read -r list_file; do
  [[ -z "$list_file" ]] && continue
  if grep -qE "\.listStyle\(\.(insetGrouped|grouped)\)" "$list_file"; then
    if ! grep -q "scrollContentBackground(.hidden)" "$list_file"; then
      echo "[FAIL] list-scroll-bg-hidden -> ${list_file}"
      TOUCHED_VIOLATIONS=$((TOUCHED_VIOLATIONS + 1))
    fi
  fi
done < <(find DSNovel/Features -type f -name "*.swift" 2>/dev/null || true)

# 16. discover-no-cell-scroll-anchor & discover-no-body-set-map (FIX-04)
check_grep_rule "discover-no-cell-scroll-anchor" "recordScrollAnchor" "DSNovel/Features/Discover/DiscoverContent.swift"
check_grep_rule "discover-no-body-set-map" "Set\([^)]*\.map\(" "DSNovel/Features/Discover/DiscoverRootView.swift"

# 17. no-global-skip-defaults (v2.6 per-book skip)
check_grep_rule "no-global-skip-defaults" "defaultSkipIntroSec|defaultSkipOutroSec|skipSettings|SkipSettingsDetailView" "DSNovel/Features" "DSNovel/App" "DSNovel/Playback"

if [[ $TOUCHED_VIOLATIONS -gt 0 ]]; then
  echo "verify_rules.sh failed with ${TOUCHED_VIOLATIONS} violation(s)."
  exit 1
fi

echo "[PASS] verify_rules.sh: all rule checks passed."
exit 0
