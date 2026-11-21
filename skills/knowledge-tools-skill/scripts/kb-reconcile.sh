#!/bin/sh
# kb-reconcile.sh
# 功能：遞迴列出生效知識的關鍵欄位（相對路徑／標題／觸發時機／摘要／決策結果），
#       供代理比對新舊知識是否矛盾。唯讀，不修改任何檔案；矛盾的停用動作由
#       kb-supersede.sh 在取得使用者同意後執行。
# 用法：sh kb-reconcile.sh [分類前綴]
# 參數：分類前綴  選填，只盤點該前綴下的知識（如 dev 或 dev/php-laravel）。
# 流程：遞迴掃描生效知識檔（排除 index.md 與 deprecated/）→ 解析欄位 → 逐檔輸出區塊。
# 產出：唯讀，僅輸出報告。
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成（含無條目）；1 結構缺失
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
PREFIX="${1:-}"
PREFIX="${PREFIX#./}"; PREFIX="${PREFIX%/}"

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
    echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
    exit 1
fi

# 解析欄位 → title<TAB>trigger<TAB>summary<TAB>decision（相容無 front matter 的舊格式）
# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為
# true，會讓每個中文欄位都命中第一個分支（「標題」），trigger 永遠取不到值。
parse_fields() {
    LC_ALL=C awk '
        BEGIN { fm=0 }
        NR==1 && $0=="---" { fm=1; next }
        fm==1 && $0=="---" { fm=0; next }
        fm==1 {
            idx=index($0, ":")
            if (idx>0) {
                k=substr($0,1,idx-1); v=substr($0,idx+1)
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k=="標題") title=v
                else if (k=="觸發時機") trigger=v
            }
            next
        }
        /^# /  { if (h1=="") { h1=substr($0,3); gsub(/^[ \t]+|[ \t]+$/, "", h1) } next }
        /^## 摘要/      { sec="s"; next }
        /^## 觸發時機/  { sec="t"; next }
        /^## 決策結果/  { sec="d"; next }
        /^## /  { sec=""; next }
        {
            line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line=="") next
            if (sec=="s" && summary=="") summary=line
            if (sec=="t" && tbody=="") tbody=line
            if (sec=="d" && decision=="" && line!="-") decision=line
        }
        END {
            if (trigger=="" || trigger=="-") trigger=tbody
            if (title=="" || title=="-") title=h1
            printf "%s\t%s\t%s\t%s\n", title, trigger, summary, decision
        }
    ' "$1"
}

KB_DISP="$(to_display "$KB_DIR")"
if [ -n "$PREFIX" ]; then
    SCOPE="分類前綴 $PREFIX"
else
    SCOPE="全部分類"
fi
# 以 printf 帶入變數，避免某些 shell 在變數緊鄰全形括號時的展開錯誤
printf '📚 盤點生效知識（%s）：%s\n\n' "$SCOPE" "$KB_DISP"

# 先把符合條件的相對路徑收進暫存檔，避免在 subshell 內計數
MATCH="$(mktemp "${TMPDIR:-/tmp}/kb-reconcile.XXXXXX")"
trap 'rm -f "$MATCH"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

find "$KB_DIR" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r f; do
        rel="${f#"$KB_DIR"/}"
        if [ -n "$PREFIX" ]; then
            case "$rel" in
                "$PREFIX"/*) : ;;
                "$PREFIX") : ;;
                *) continue ;;
            esac
        fi
        printf '%s\n' "$rel"
    done > "$MATCH"

count="$(grep -c . "$MATCH" 2>/dev/null || true)"
if [ "${count:-0}" -eq 0 ]; then
    echo "ℹ️  無符合條件的生效知識條目。"
    exit 0
fi

while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    fields="$(parse_fields "$KB_DIR/$rel")"
    title="$(printf '%s' "$fields" | cut -f1)"
    trigger="$(printf '%s' "$fields" | cut -f2)"
    summary="$(printf '%s' "$fields" | cut -f3)"
    decision="$(printf '%s' "$fields" | cut -f4)"
    echo "• $rel"
    [ -n "$title" ]    && echo "  標題：$title"
    [ -n "$trigger" ]  && echo "  觸發時機：$trigger"
    [ -n "$summary" ]  && echo "  摘要：$summary"
    [ -n "$decision" ] && echo "  決策結果：$decision"
    echo ""
done < "$MATCH"

echo "👉 比對上列知識是否有矛盾（同一觸發情境給出相衝突的決策結果）。"
echo "   確認要以新知識取代舊知識時，取得使用者同意後執行："
echo "   sh kb-supersede.sh <舊檔相對路徑> <新檔相對路徑> --yes"
