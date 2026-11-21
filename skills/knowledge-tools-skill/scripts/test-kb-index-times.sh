#!/bin/sh
# 隔離 smoke test：驗證子索引的「創建時間／更新時間」兩欄。
#
# 創建時間只存在索引裡，kb-reindex.sh 每次重建都要從舊索引讀回，以下情境各驗一次：
#   1. 舊格式索引（無時間欄）遷移 → 1970-01-01 00:00:00；更新時間 = 知識檔 mtime
#   2. 重跑不變動（idempotent）
#   3. 舊索引存在但未登錄的新知識 → 當下時間，之後重跑沿用不變
#   4. 取代搬進 deprecated/ → 沿用原創建時間
#   5. 整份索引遺失 → 0000-00-00 00:00:00
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-index-times-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge"
KB="$KNOWLEDGE_BASE_DIR"
mkdir -p "$HOME"
for category in ui ux dev ops data else; do
    mkdir -p "$KB/$category"
done
mkdir -p "$KB/dev/go"

fail() {
    printf '❌ %s\n' "$1"
    exit 1
}

make_doc() {
    printf -- '---\n標題: %s\n觸發時機: %s時\n取代: -\n被取代於: -\n---\n\n## 摘要\n%s摘要\n' "$2" "$2" "$2" > "$1"
}

# 取某份子索引中某個連結的欄位：$1 索引、$2 連結檔名、$3 欄位（6 創建時間、7 更新時間）
cell() {
    awk -F'|' -v k="($2)" -v n="$3" '
        NF >= 8 && index($2, k) { v=$n; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
    ' "$1"
}

expect() {
    [ "$2" = "$3" ] || fail "$1：預期 [$3]，實際 [$2]"
    echo "✅ $1"
}

# --- 1. 舊格式遷移 ---
make_doc "$KB/dev/go/old.md" "舊知識"
touch -t 202601021530.45 "$KB/dev/go/old.md"
printf '# 公用知識庫索引\n\n| 分類 | 筆數 | 知識標題 |\n|------|------|----------|\n| `dev/go` | 1 | 舊知識 |\n' > "$KB/index.md"
printf '| 知識 | 觸發時機 | 摘要 | 取代 |\n|------|----------|------|------|\n| [舊知識](old.md) | 舊知識時 | 舊知識摘要 | - |\n' > "$KB/dev/go/index.md"
sh "$SCRIPT_DIR/kb-reindex.sh" >/dev/null
expect "舊格式列 → 1970" "$(cell "$KB/dev/go/index.md" old.md 6)" "1970-01-01 00:00:00"
expect "更新時間 = mtime" "$(cell "$KB/dev/go/index.md" old.md 7)" "2026-01-02 15:30:45"
grep -qF '| 知識 | 觸發時機 | 摘要 | 取代 | 創建時間 | 更新時間 |' "$KB/dev/go/index.md" || fail "子索引表頭缺時間欄"

# --- 2. 冪等 ---
sh "$SCRIPT_DIR/kb-reindex.sh" | grep -q '無需變更' || fail "重跑應無變更"
echo "✅ 重跑無變更"

# --- 3. 新知識 → 當下時間，重跑沿用 ---
make_doc "$KB/dev/go/new.md" "新知識"
sh "$SCRIPT_DIR/kb-reindex.sh" >/dev/null
NEW_CREATED="$(cell "$KB/dev/go/index.md" new.md 6)"
case "$NEW_CREATED" in
    1970-*|0000-*|"") fail "新知識應取當下時間，實際 [$NEW_CREATED]" ;;
esac
printf '✅ 新知識取當下時間（%s）\n' "$NEW_CREATED"
sleep 1
touch "$KB/dev/go/new.md"
sh "$SCRIPT_DIR/kb-reindex.sh" >/dev/null
expect "重跑沿用創建時間" "$(cell "$KB/dev/go/index.md" new.md 6)" "$NEW_CREATED"

# --- 4. 取代搬移沿用 ---
sh "$SCRIPT_DIR/kb-supersede.sh" dev/go/old.md dev/go/new.md --yes >/dev/null
expect "取代後沿用原創建時間" "$(cell "$KB/deprecated/dev/go/index.md" old.md 6)" "1970-01-01 00:00:00"
grep -qF '| 知識 | 觸發時機 | 摘要 | 被取代於 | 創建時間 | 更新時間 |' "$KB/deprecated/dev/go/index.md" || fail "停用子索引表頭缺時間欄"

# --- 5. 索引遺失 ---
find "$KB" -type f -name 'index.md' -exec rm -f {} +
sh "$SCRIPT_DIR/kb-reindex.sh" >/dev/null
expect "索引遺失 → 0000" "$(cell "$KB/dev/go/index.md" new.md 6)" "0000-00-00 00:00:00"

echo "✅ 全部通過"
