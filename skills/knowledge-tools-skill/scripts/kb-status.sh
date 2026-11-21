#!/bin/sh
# kb-status.sh
# 功能：解析共用知識庫實際位置並檢查健康度（唯讀，不修改任何檔案）。
#       知識檔依分類目錄遞迴存放，索引以相對路徑登錄；停用知識另存 deprecated/。
# 用法：sh kb-status.sh
# 參數：無。
# 流程：
#   1. 解析知識庫位置（環境變數 > 設定檔 > 預設）並回報來源與路徑
#   2. 檢查 knowledge 目錄與 index.md 是否存在
#   3. 走訪兩層索引（頂層 index.md 與各分類 {分類}/index.md）→ 找出斷鏈（索引有、檔案無）
#   4. 遞迴掃描生效知識檔（排除 index.md 與 deprecated/）→ 找出孤兒檔（檔案有、索引無）
#   5. 回報 deprecated/ 停用知識數量與其索引一致性
# 產出：唯讀，僅輸出報告。
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 健康且一致；1 結構缺失（無目錄或無 index）；2 有斷鏈或孤兒
set -e

# BEGIN kb-resolve-dir（各腳本逐字相同，改動後執行 test-kb-resolve-dir.sh 驗證）
# 解析順序：環境變數 KNOWLEDGE_BASE_DIR > 設定檔 > 預設路徑。設定檔讓 hook、launchd
# 這類不讀 shell 設定檔的執行環境也能解析到同一位置；設定檔不 source，只取
# KNOWLEDGE_BASE_DIR= 那一行，開頭的 ~ 或 $HOME 才展開。
KB_CONFIG="$HOME/.config/knowledge-skill/config"
KB_DIR="$HOME/.knowledge-skill/knowledge"
KB_SOURCE="預設值"
if [ -n "${KNOWLEDGE_BASE_DIR:-}" ]; then
    KB_DIR="$KNOWLEDGE_BASE_DIR"
    KB_SOURCE="環境變數 KNOWLEDGE_BASE_DIR"
elif [ -f "$KB_CONFIG" ]; then
    KB_CONFIG_VALUE="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_BASE_DIR=//p' "$KB_CONFIG" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
    case "$KB_CONFIG_VALUE" in
        "~/"*) KB_CONFIG_VALUE="$HOME/${KB_CONFIG_VALUE#"~/"}" ;;
        '$HOME/'*) KB_CONFIG_VALUE="$HOME/${KB_CONFIG_VALUE#'$HOME/'}" ;;
    esac
    if [ -n "$KB_CONFIG_VALUE" ]; then
        KB_DIR="$KB_CONFIG_VALUE"
        KB_SOURCE="設定檔 ~/.config/knowledge-skill/config"
    fi
fi
# END kb-resolve-dir
DEP_DIR="$KB_DIR/deprecated"
DEP_INDEX="$DEP_DIR/index.md"

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

echo "📍 知識庫位置來源：$KB_SOURCE"
echo "   路徑：$(to_display "$KB_DIR")"
echo "   絕對：$KB_DIR"
echo ""

if [ ! -d "$KB_DIR" ]; then
    echo "❌ knowledge 目錄不存在，可執行 init-knowledge-base.sh 建立。"
    exit 1
fi
echo "✅ knowledge 目錄存在"

INDEX="$KB_DIR/index.md"
if [ ! -f "$INDEX" ]; then
    echo "❌ index.md 不存在，可執行 init-knowledge-base.sh 或 reindex 建立。"
    exit 1
fi
echo "✅ index.md 存在"
echo ""

# 解析單一索引檔登錄的相對路徑（表格第一欄的 Markdown 連結目標）。
# 只認第一欄含 Markdown 連結的列：頂層索引的分類目錄表第一欄是反引號純文字（分類名稱），
# 若一併收下會把分類誤算成知識檔。
# 樣式必須錨定行尾的 `](…)`：知識標題本身常含括號（如 `Schema::table(ALTER)`、
# `shouldReceive()`），只找「第一個括號」會抓到標題裡的括號而非連結目標，造成整批誤判為
# 斷鏈與孤兒檔。
parse_index_links() {
    awk -F'|' '
        NF >= 3 {
            cell=$2
            gsub(/^[ \t]+|[ \t]+$/, "", cell)
            if (!match(cell, /\]\([^)]*\)$/)) next
            cell=substr(cell, RSTART+2, RLENGTH-3)
            if (cell=="" || cell ~ /^<!--/) next
            print cell
        }
    ' "$1"
}

# 走訪兩層索引（頂層 index.md + 各分類 {分類}/index.md），輸出一律相對 KB_DIR。
# 子索引登錄的是相對該分類目錄的檔名，需補回目錄前綴；舊的單層索引前綴為空，自然相容。
INDEXED="$(find "$KB_DIR" -type f -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r idx; do
        dir="$(dirname "${idx#"$KB_DIR"/}")"
        parse_index_links "$idx" | while IFS= read -r link; do
            if [ "$dir" = "." ]; then
                printf '%s\n' "$link"
            else
                printf '%s/%s\n' "$dir" "$link"
            fi
        done
    done)"

# 磁碟上的生效知識檔相對路徑（遞迴；排除 index.md 與 deprecated/ 子樹）
DISK="$(find "$KB_DIR" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s\n' "${f#"$KB_DIR"/}"; done)"

# 斷鏈：索引有登錄、檔案不存在
BROKEN=""
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    [ -f "$KB_DIR/$rel" ] || BROKEN="$BROKEN$rel
"
done <<EOF
$INDEXED
EOF

# 孤兒：檔案存在、索引未登錄
ORPHAN=""
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if ! printf '%s\n' "$INDEXED" | grep -Fxq "$rel"; then
        ORPHAN="$ORPHAN$rel
"
    fi
done <<EOF
$DISK
EOF

FILE_COUNT=0
[ -n "$DISK" ] && FILE_COUNT="$(printf '%s' "$DISK" | grep -c . || true)"
echo "📊 生效知識檔數量：$FILE_COUNT"

if [ -d "$DEP_DIR" ]; then
    DEP_COUNT="$(find "$DEP_DIR" -type f -name '*.md' ! -name 'index.md' 2>/dev/null | grep -c . || true)"
    echo "🗄️  已停用知識檔數量（deprecated/）：$DEP_COUNT"
    if [ "$DEP_COUNT" -gt 0 ] && [ ! -f "$DEP_INDEX" ]; then
        echo "⚠️  deprecated/ 有檔案但缺 index.md，建議執行 reindex。"
    fi
fi
echo ""

STATUS=0

# 索引仍停在舊的單層結構。解析對單層刻意向後相容（讀得到、不算斷鏈也不算孤兒），
# 所以不提示的話使用者不會知道該重建；落後版本的 kb-reindex.sh 也會把兩層寫回單層。
# 判準：頂層索引直接登錄了含目錄分隔符的知識路徑——兩層結構下頂層只有分類目錄（非連結），
# 唯一例外的根目錄未分類知識其路徑不含 /。
if parse_index_links "$INDEX" | grep -q '/'; then
    STATUS=2
    echo "⚠️  索引仍是舊的單層結構（頂層直接登錄所有知識）。"
    echo "   兩層結構為：頂層 index.md 只列分類目錄，完整清單在各分類的 {分類}/index.md。"
    echo ""
fi

if [ -n "$BROKEN" ]; then
    STATUS=2
    echo "⚠️  斷鏈（索引有登錄、檔案不存在）："
    printf '%s' "$BROKEN" | while IFS= read -r n; do [ -z "$n" ] || echo "   • $n"; done
    echo ""
fi

if [ -n "$ORPHAN" ]; then
    STATUS=2
    echo "⚠️  孤兒檔（檔案存在、索引未登錄）："
    printf '%s' "$ORPHAN" | while IFS= read -r n; do [ -z "$n" ] || echo "   • $n"; done
    echo ""
fi

if [ "$STATUS" -eq 0 ]; then
    echo "✅ 知識庫健康，索引與檔案一致。"
else
    echo "👉 可執行 reindex 由腳本重建索引（補登錄孤兒、清除斷鏈）。"
fi

exit "$STATUS"
