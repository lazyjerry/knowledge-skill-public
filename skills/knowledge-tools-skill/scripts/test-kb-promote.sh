#!/bin/sh
# 隔離 smoke test：驗證 kb-promote.sh 寫入「狀態」欄位，以及 --require-verification、
# --auto 兩個旗標的行為。
#
#   1. --yes 安裝 → 狀態為「人工審核確認」（草稿沒有狀態欄、或手填了別的值都一樣）
#   2. --require-verification：「## 驗證」段只有 - 或範本佔位時拒絕安裝
#   3. --auto：狀態為「AI 自動確認」、來源前綴「自動收錄：」、隱含驗證段檢查
#   4. --auto 與 --yes 不可並用
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-promote-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge"
unset KNOWLEDGE_AUTO_RECORD
KB="$KNOWLEDGE_BASE_DIR"
mkdir -p "$HOME"
for category in ui ux dev ops data else; do
    mkdir -p "$KB/$category"
done
printf '# 公用知識庫索引\n\n## 分類目錄\n\n| 分類 | 筆數 | 知識標題 |\n|------|------|----------|\n' > "$KB/index.md"

fail() {
    printf '❌ %s\n' "$1"
    exit 1
}

expect() {
    [ "$2" = "$3" ] || fail "$1：預期 [$3]，實際 [$2]"
    echo "✅ $1"
}

# $1 草稿路徑、$2 標題、$3「## 驗證」段內容、$4 front matter 額外一行（可省略）
make_draft() {
    {
        printf -- '---\n標題: %s\n觸發時機: 遇到%s時\n取代: -\n被取代於: -\n' "$2" "$2"
        [ -z "${4:-}" ] || printf '%s\n' "$4"
        printf -- '---\n\n## 摘要\n%s的結論\n\n## 脈絡與問題陳述\n背景\n\n## 決策驅力\n-\n\n' "$2"
        printf '## 考量選項\n- 甲\n\n## 各選項利弊\n-\n\n## 決策結果\n選甲\n\n## 影響\n好處\n\n'
        printf '## 驗證\n%s\n\n## 補充資訊\n測試\n' "$3"
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

# 執行並取結束碼（set -e 下不中止）。輸出存到 $ROOT/out。
run() {
    set +e
    "$@" > "$ROOT/out" 2>&1
    CODE=$?
    set -e
}

# --- 1. --yes → 人工審核確認 ---
make_draft "$ROOT/d1.md" "一般記錄" "-"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d1.md" dev/go/manual.md --yes --source "測試"
expect "--yes 安裝成功" "$CODE" "0"
expect "草稿無狀態欄 → 人工審核確認" "$(fm_get "$KB/dev/go/manual.md" "狀態")" "人工審核確認"

make_draft "$ROOT/d2.md" "手填狀態" "-" "狀態: AI 自動確認"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d2.md" dev/go/handfilled.md --yes
expect "手填的狀態由腳本覆寫" "$(fm_get "$KB/dev/go/handfilled.md" "狀態")" "人工審核確認"
expect "狀態欄只有一行" "$(grep -c '^狀態:' "$KB/dev/go/handfilled.md")" "1"

# --- 2. --require-verification ---
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d1.md" dev/go/noverify.md --yes --require-verification
expect "驗證段只有 - → 拒絕（結束碼 1）" "$CODE" "1"
[ ! -e "$KB/dev/go/noverify.md" ] || fail "驗證段為空時不應安裝"
echo "✅ 驗證段為空時未安裝"

make_draft "$ROOT/d3.md" "佔位驗證" "[驗證方式]"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d3.md" dev/go/placeholder.md --yes --require-verification
expect "驗證段是範本佔位 → 拒絕" "$CODE" "1"

make_draft "$ROOT/d4.md" "有驗證" "- 在隔離環境重跑，結果符合預期"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d4.md" dev/go/verified.md --yes --require-verification
expect "驗證段有內容 → 安裝" "$CODE" "0"
expect "帶 --yes 仍是人工審核確認" "$(fm_get "$KB/dev/go/verified.md" "狀態")" "人工審核確認"

# --- 3. --auto ---
make_draft "$ROOT/d5.md" "自動收錄" "- 實測三次皆重現"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d5.md" ops/docker/auto.md --auto --source "對話：容器除錯"
expect "--auto 安裝成功" "$CODE" "0"
expect "--auto → AI 自動確認" "$(fm_get "$KB/ops/docker/auto.md" "狀態")" "AI 自動確認"
grep -Fq '來源：自動收錄：對話：容器除錯（sha256:' "$KB/ops/docker/auto.md" || fail "--auto 的來源應帶「自動收錄：」前綴"
echo "✅ 來源帶「自動收錄：」前綴"

make_draft "$ROOT/d6.md" "自動但沒驗證" "-"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d6.md" ops/docker/auto-noverify.md --auto --source "測試"
expect "--auto 隱含驗證段檢查 → 拒絕" "$CODE" "1"
[ ! -e "$KB/ops/docker/auto-noverify.md" ] || fail "--auto 驗證段為空時不應安裝"

# --- 4. --auto 與 --yes 不可並用 ---
make_draft "$ROOT/d7.md" "並用" "- 實測"
run sh "$SCRIPT_DIR/kb-promote.sh" "$ROOT/d7.md" ops/docker/both.md --auto --yes --source "測試"
expect "--auto 與 --yes 並用 → 拒絕" "$CODE" "1"
[ ! -e "$KB/ops/docker/both.md" ] || fail "--auto 與 --yes 並用時不應安裝"

echo "✅ 全部通過"
