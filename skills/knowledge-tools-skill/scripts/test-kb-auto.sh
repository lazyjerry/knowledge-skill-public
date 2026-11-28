#!/bin/sh
# 隔離 smoke test：驗證 kb-auto.sh 的自動收錄開關、「AI 自動確認」清單與確認流程，
# 以及 kb-promote.sh --auto 會遵守開關。
#
#   1. 開關：預設開啟；off／on 寫入設定檔且可重複執行、不動其他設定；環境變數優先；
#      認不得的值當關閉；未授權不改檔
#   2. kb-promote.sh --auto 在開關關閉時拒絕安裝（結束碼 3）
#   3. list 只列「AI 自動確認」；confirm 改為「人工審核確認」並更新索引
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-auto-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge"
unset KNOWLEDGE_AUTO_RECORD
KB="$KNOWLEDGE_BASE_DIR"
CONFIG="$HOME/.config/knowledge-skill/config"
mkdir -p "$HOME"
for category in ui ux dev ops data else; do
    mkdir -p "$KB/$category"
done
printf '# 公用知識庫索引\n\n## 分類目錄\n\n| 分類 | 筆數 | 知識標題 |\n|------|------|----------|\n' > "$KB/index.md"

fail() {
    printf '❌ %s\n' "$1"
    [ ! -f "$ROOT/out" ] || cat "$ROOT/out"
    exit 1
}

expect() {
    [ "$2" = "$3" ] || fail "$1：預期 [$3]，實際 [$2]"
    echo "✅ $1"
}

# 執行並取結束碼（set -e 下不中止）。輸出存到 $ROOT/out。
run() {
    set +e
    "$@" > "$ROOT/out" 2>&1 < /dev/null
    CODE=$?
    set -e
}

auto() {
    run sh "$SCRIPT_DIR/kb-auto.sh" "$@"
}

# $1 草稿路徑、$2 標題
make_draft() {
    {
        printf -- '---\n標題: %s\n觸發時機: 遇到%s時\n取代: -\n被取代於: -\n---\n\n' "$2" "$2"
        printf '## 摘要\n%s的結論\n\n## 脈絡與問題陳述\n背景\n\n## 決策驅力\n-\n\n' "$2"
        printf '## 考量選項\n- 甲\n\n## 各選項利弊\n-\n\n## 決策結果\n選甲\n\n## 影響\n好處\n\n'
        printf '## 驗證\n- 實測通過\n\n## 補充資訊\n測試\n'
    } > "$1"
}

fm_get() {
    LC_ALL=C awk -v key="$2" '
        NR==1 && $0=="---" { fm=1; next }
        fm && $0=="---" { exit }
        fm {
            i=index($0, ":")
            if (i>0) {
                k=substr($0,1,i-1); v=substr($0,i+1)
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k==key) { print v; exit }
            }
        }
    ' "$1"
}

# --- 1. 開關 ---
auto enabled
expect "預設開啟（enabled 結束碼 0）" "$CODE" "0"
auto status
grep -Fq '開啟' "$ROOT/out" || fail "status 應顯示開啟"
echo "✅ status 顯示開啟"

auto off
expect "未帶 --yes 的 off → 結束碼 3" "$CODE" "3"
[ ! -f "$CONFIG" ] || fail "未授權時不應建立設定檔"
echo "✅ 未授權時未改檔"

mkdir -p "$(dirname "$CONFIG")"
printf '# 既有設定\nKNOWLEDGE_BASE_DIR=~/somewhere/knowledge\n' > "$CONFIG"
auto off --yes
expect "off --yes 成功" "$CODE" "0"
auto enabled
expect "關閉後 enabled 結束碼 1" "$CODE" "1"
grep -Fxq 'KNOWLEDGE_BASE_DIR=~/somewhere/knowledge' "$CONFIG" || fail "off 不應動到 KNOWLEDGE_BASE_DIR"
echo "✅ 既有設定保留"
auto off --yes
expect "重複 off 只留一行" "$(grep -c 'KNOWLEDGE_AUTO_RECORD=' "$CONFIG")" "1"
auto status
grep -Fq '關閉' "$ROOT/out" || fail "status 應顯示關閉"
echo "✅ status 顯示關閉"

# --- 2. 開關關閉時 kb-promote.sh --auto 拒絕 ---
make_draft "$ROOT/d0.md" "關閉時的候選"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d0.md" dev/go/blocked.md --auto --source "測試"
expect "開關關閉時 --auto → 結束碼 3" "$CODE" "3"
[ ! -e "$KB/dev/go/blocked.md" ] || fail "開關關閉時不應安裝"
echo "✅ 開關關閉時未安裝"

auto on --yes
auto enabled
expect "on 之後 enabled 結束碼 0" "$CODE" "0"
expect "on 之後仍只有一行" "$(grep -c 'KNOWLEDGE_AUTO_RECORD=' "$CONFIG")" "1"

run env KNOWLEDGE_AUTO_RECORD=off sh "$SCRIPT_DIR/kb-auto.sh" enabled
expect "環境變數優先於設定檔" "$CODE" "1"

printf 'KNOWLEDGE_AUTO_RECORD=maybe\n' > "$CONFIG"
auto enabled
expect "認不得的值當關閉" "$CODE" "1"
rm -f "$CONFIG"

# --- 3. list／confirm ---
make_draft "$ROOT/d1.md" "自動甲"
make_draft "$ROOT/d2.md" "自動乙"
make_draft "$ROOT/d3.md" "人工丙"
sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d1.md" dev/go/auto-a.md --auto --source "測試" > /dev/null
sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d2.md" ops/docker/auto-b.md --auto --source "測試" > /dev/null
sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d3.md" dev/go/manual-c.md --yes > /dev/null

auto list
grep -Fq 'dev/go/auto-a.md' "$ROOT/out" || fail "list 應列出 dev/go/auto-a.md"
grep -Fq 'ops/docker/auto-b.md' "$ROOT/out" || fail "list 應列出 ops/docker/auto-b.md"
if grep -Fq 'manual-c.md' "$ROOT/out"; then fail "list 不應列出人工審核確認的知識"; fi
echo "✅ list 只列 AI 自動確認"

auto confirm dev/go/auto-a.md
expect "未帶 --yes 的 confirm → 結束碼 3" "$CODE" "3"
expect "未授權時狀態不變" "$(fm_get "$KB/dev/go/auto-a.md" "狀態")" "AI 自動確認"

auto confirm dev/go/nope.md --yes
expect "確認不存在的知識 → 結束碼 1" "$CODE" "1"

auto confirm dev/go/auto-a.md --yes
expect "confirm 成功" "$CODE" "0"
expect "confirm 後為人工審核確認" "$(fm_get "$KB/dev/go/auto-a.md" "狀態")" "人工審核確認"
expect "另一則不受影響" "$(fm_get "$KB/ops/docker/auto-b.md" "狀態")" "AI 自動確認"
expect "其他欄位保留" "$(fm_get "$KB/dev/go/auto-a.md" "標題")" "自動甲"

auto confirm --all --yes
expect "confirm --all 成功" "$CODE" "0"
expect "--all 後全部為人工審核確認" "$(fm_get "$KB/ops/docker/auto-b.md" "狀態")" "人工審核確認"
auto list
if grep -Fq '.md' "$ROOT/out"; then fail "全部確認後 list 應為空"; fi
echo "✅ 全部確認後 list 為空"

echo "✅ 全部通過"
