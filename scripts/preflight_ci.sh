#!/usr/bin/env bash
# DSNovel v3.3.9 本地 / CI 一键预检门禁脚本 (scripts/preflight_ci.sh)
# 覆盖：22 条架构规则、内置解析器单一事实源、JS 自检/Fuzz/BOM、YAML/JSON 语法、AppIcon 零透明通道、Swift 6 静态防线
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "============================================================"
echo "  DSNovel v3.3.9 Pre-Flight CI Gate (scripts/preflight_ci.sh)"
echo "============================================================"

# 1. 22 条静态架构与设计规则
echo ""
echo "[1/6] Running scripts/verify_rules.sh (22 rules)..."
/bin/bash "$REPO_ROOT/scripts/verify_rules.sh"

# 2. 内置解析器单一事实源 + JS 自检 / 链式自检 / Fuzz / 语法 / BOM
echo ""
echo "[2/6] Verifying bundled parser single-source-of-truth & JS runtime..."
PARSER_FILES=(App/Resources/BundledParsers/ximalaya_parser-v*.js)
if [ "${#PARSER_FILES[@]}" -ne 1 ] || [ ! -f "${PARSER_FILES[0]}" ]; then
  echo "[FAIL] Expected exactly 1 bundled parser script, found ${#PARSER_FILES[@]}"
  exit 1
fi
BUNDLED_PARSER="${PARSER_FILES[0]}"

python3 - "$BUNDLED_PARSER" <<'PY'
import os, sys
parser_path = sys.argv[1]
base_no_ext = os.path.splitext(os.path.basename(parser_path))[0]
loader = open("App/BundledParserLoader.swift", encoding="utf-8").read()
pyml = open("project.yml", encoding="utf-8").read()
assert f'bundledResourceName = "{base_no_ext}"' in loader, f"BundledParserLoader mismatch: {base_no_ext}"
assert parser_path in pyml, f"project.yml missing {parser_path}"
print(f"  [OK] Single-source-of-truth verified: {parser_path}")
PY

node parser-tools/ep_selfcheck.js
node parser-tools/chain_selfcheck.js
node parser-tools/ep_fuzz.js
node --check App/Resources/prelude.js
node --check App/Resources/prelude_parser.js
node --check "$BUNDLED_PARSER"

TMP_JS_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_JS_DIR"' EXIT
BUNDLE_ZIP="App/Resources/BundledSources/ShunAudiobookPro-v5.6.zip"
if [ ! -f "$BUNDLE_ZIP" ]; then
  echo "[FAIL] Missing bundled source archive: $BUNDLE_ZIP"
  exit 1
fi
unzip -qq "$BUNDLE_ZIP" -d "$TMP_JS_DIR"
python3 - "$TMP_JS_DIR/manifest.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
raw = p.read_bytes()
if raw.startswith(b"\xef\xbb\xbf"):
    raise SystemExit("[FAIL] manifest.json contains UTF-8 BOM")
data = json.loads(raw.decode("utf-8"))
assert data.get("scripts"), "[FAIL] manifest.json scripts empty"
print(f"  [OK] manifest.json BOM-free ({len(data['scripts'])} scripts)")
PY
for js in "$TMP_JS_DIR"/*.js; do
  node --check "$js"
done
echo "  [OK] All bundled source JS scripts passed node --check"

# 3. YAML 与 JSON 配置文件语法校验
echo ""
echo "[3/6] Validating YAML & JSON manifests..."
python3 - <<'PY'
import json, pathlib, sys
try:
    import yaml
    for yml_path in ["project.yml", ".github/workflows/ios-ipa-build.yml"]:
        with open(yml_path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
        assert isinstance(doc, dict) and doc, f"{yml_path} parsed empty"
        print(f"  [OK] YAML valid: {yml_path}")
except ImportError:
    print("  [WARN] PyYAML not installed; skipping deep YAML parse")

for jp in [
    "App/Resources/Assets.xcassets/Contents.json",
    "App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
]:
    p = pathlib.Path(jp)
    assert p.exists(), f"Missing {jp}"
    json.loads(p.read_text(encoding="utf-8"))
    print(f"  [OK] JSON valid: {jp}")
PY

# 4. AppIcon 1024x1024 RGB 零透明通道校验（纯 PNG 头解析，零外部依赖）
echo ""
echo "[4/6] Validating AppIcon 1024x1024 RGB (zero alpha channel)..."
python3 - <<'PY'
import pathlib, struct, sys

icon_dir = pathlib.Path("App/Resources/Assets.xcassets/AppIcon.appiconset")
pngs = sorted(icon_dir.glob("*.png"))
assert pngs, f"No PNG icons found in {icon_dir}"
for png in pngs:
    raw = png.read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", f"{png.name} is not a valid PNG"
    width, height, bit_depth, color_type = struct.unpack(">IIBB", raw[16:26])
    assert width == 1024 and height == 1024, f"{png.name} size {width}x{height} != 1024x1024"
    assert color_type == 2, f"{png.name} color_type={color_type} (expected 2 = RGB without alpha)"
    assert b"tRNS" not in raw[:2048], f"{png.name} contains tRNS transparency chunk"
    print(f"  [OK] {png.name}: {width}x{height} RGB (bit_depth={bit_depth}, no alpha)")
PY

# 5. Swift 6 静态并发与测试模块防线校验
echo ""
echo "[5/6] Running Swift 6 concurrency & test-module guardrails..."
python3 - <<'PY'
import pathlib, re, sys

errors = []

# 5a. 测试模块名必须是 @testable import DSNovel，严禁 DSNovelV3
for tf in sorted(pathlib.Path("Tests").rglob("*.swift")):
    text = tf.read_text(encoding="utf-8")
    if "@testable import DSNovelV3" in text:
        errors.append(f"{tf}: invalid '@testable import DSNovelV3' (must be '@testable import DSNovel')")

# 5b. 所有 @unchecked Sendable 必须附带 // SAFETY: 注释
for root in ["App", "Packages"]:
    for sf in sorted(pathlib.Path(root).rglob("*.swift")):
        lines = sf.read_text(encoding="utf-8").splitlines()
        for idx, line in enumerate(lines):
            if "@unchecked Sendable" in line:
                window = "\n".join(lines[max(0, idx - 3):idx + 1])
                if "SAFETY:" not in window:
                    errors.append(f"{sf}:{idx + 1}: @unchecked Sendable missing // SAFETY: justification")

# 5b2. 防止 CI b171 回归：@MainActor 类型内的 nonisolated 方法不得引用未标 nonisolated 的 static let 作为默认参数
for root in ["App", "Packages"]:
    for sf in sorted(pathlib.Path(root).rglob("*.swift")):
        text = sf.read_text(encoding="utf-8")
        if "@MainActor" not in text or "nonisolated" not in text:
            continue
        isolated_consts = set(re.findall(r"(?m)^\s*(?:public\s+|internal\s+|private\s+)?static\s+let\s+(\w+)", text))
        noniso_consts = set(re.findall(r"(?m)^\s*(?:(?:public|internal|private)\s+)?nonisolated\s+(?:(?:public|internal|private)\s+)?static\s+let\s+(\w+)", text))
        risky = isolated_consts - noniso_consts
        if not risky:
            continue
        for m in re.finditer(r"nonisolated[^\{]*?func\s+\w+\(([^)]*)\)", text, re.S):
            params = m.group(1)
            for name in risky:
                if re.search(rf"=\s*(?:Self\.)?{re.escape(name)}\b", params):
                    errors.append(f"{sf}: nonisolated func default arg references @MainActor-isolated static let '{name}' (mark it nonisolated static let)")

# 5c. 防止 CI b167 回归：RemoteCommandController+Route.swift 不得使用 @MainActor static let personalAudioOutputPorts
route_file = pathlib.Path("Packages/DSPlayback/Sources/DSPlayback/RemoteCommandController+Route.swift")
if route_file.exists():
    rtext = route_file.read_text(encoding="utf-8")
    if "static let personalAudioOutputPorts" in rtext:
        errors.append(f"{route_file}: forbidden static let personalAudioOutputPorts (use nonisolated pure switch)")

if errors:
    for e in errors:
        print(f"  [FAIL] {e}")
    sys.exit(1)
print("  [OK] Test module imports, @unchecked Sendable SAFETY notes, and Swift 6 route isolation verified")
PY

# 6. UI 测试标识符完整性抽查
echo ""
echo "[6/6] Verifying XCUITest accessibilityIdentifier bindings..."
python3 - <<'PY'
import pathlib, sys

required_ids = [
    "library_root",
    "me_root",
    "me_storage_entry",
    "me_about_entry",
    "about_version_label",
    "storage_downloads_entry",
    "source_list_root",
    "source_list_health_check_button",
    "me_playback_prefs_entry",
]
app_text = "\n".join(
    p.read_text(encoding="utf-8")
    for p in pathlib.Path("App").rglob("*.swift")
)
missing = [rid for rid in required_ids if f'"{rid}"' not in app_text]
if missing:
    print(f"  [FAIL] Missing accessibilityIdentifier in App/: {missing}")
    sys.exit(1)
print(f"  [OK] All {len(required_ids)} core XCUITest accessibilityIdentifiers present")
PY

echo ""
echo "[PASS] preflight_ci.sh: All 6 pre-flight gates passed!"
