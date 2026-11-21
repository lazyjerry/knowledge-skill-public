#!/bin/sh
# kb-new.sh
# 功能：從 canonical MADR 範本產生一份知識草稿，並預先擋掉會讓後續 promote 失敗的情況
#       （知識庫不完整、路徑不合法、目標已存在）。只產草稿，不寫入知識庫。
# 用法：sh kb-new.sh <knowledge-相對路徑> [--out <草稿路徑>]
# 參數：
#   <knowledge-相對路徑>  目標相對 knowledge/ 的路徑（含分類目錄，如 dev/ai-llm/x.md）
#   --out <草稿路徑>      草稿輸出位置；省略時建於暫存目錄
# 流程：
#   1. 驗證相對路徑（需 .md、不得絕對路徑／含 ..／位於 deprecated/）
#   2. 檢查知識庫完整（目錄與 index.md 存在）
#   3. 目標已存在則拒絕——同主題應合併進既有檔，要淘汰請走 kb-supersede.sh
#   4. 複製 canonical 範本 knowledge-skill/assets/knowledge.md 為草稿
# 產出：草稿檔（不動知識庫）；stdout 最後一行為草稿絕對路徑，供呼叫端取用。
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成；1 參數／結構錯誤、目標已存在或找不到範本
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
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SKILL_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
# canonical 範本集中於 knowledge-skill/assets（假設兩 skill 並存安裝）
TEMPLATE="$SKILL_DIR/../knowledge-skill/assets/knowledge.md"

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

usage() {
    echo "用法：sh kb-new.sh <knowledge-相對路徑> [--out <草稿路徑>]"
    echo "  例：sh kb-new.sh dev/ai-llm/prompt-cache.md"
}

REL=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            shift
            [ $# -gt 0 ] || { echo "❌ --out 缺少草稿路徑"; usage; exit 1; }
            OUT="$1"
            ;;
        *)
            if [ -z "$REL" ]; then REL="$1"
            else echo "❌ 參數過多：$1"; usage; exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$REL" ]; then
    usage
    exit 1
fi

REL="${REL#./}"
case "$REL" in
    deprecated/*) echo "❌ 目標不可位於 deprecated/：$REL"; exit 1 ;;
    /*) echo "❌ 目標需為相對 knowledge/ 的路徑：$REL"; exit 1 ;;
    *..*) echo "❌ 目標路徑不可含 ..：$REL"; exit 1 ;;
esac
case "$REL" in *.md) ;; *) echo "❌ 目標需為 .md：$REL"; exit 1 ;; esac

if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
    echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
    echo "   請先執行 scripts/init-knowledge-base.sh 建立知識庫。"
    exit 1
fi

if [ -e "$KB_DIR/$REL" ]; then
    echo "❌ 目標已存在：$REL"
    echo "   同主題請合併進既有知識檔；要以新知識淘汰舊的請用 kb-supersede.sh。"
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "❌ 找不到 canonical MADR 範本：$TEMPLATE"
    echo "   knowledge-skill 與 knowledge-tools-skill 需並存安裝。"
    exit 1
fi

if [ -n "$OUT" ]; then
    OUT_DIR="$(dirname "$OUT")"
    [ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"
    [ ! -e "$OUT" ] || { echo "❌ 草稿檔已存在，不覆蓋：$OUT"; exit 1; }
    DRAFT="$OUT"
else
    # BSD mktemp 只認結尾的 X，副檔名要靠目錄再組一層檔名
    DRAFT="$(mktemp -d "${TMPDIR:-/tmp}/kb-draft.XXXXXX")/draft.md"
fi

cp "$TEMPLATE" "$DRAFT"

echo "📝 已建立知識草稿（尚未寫入知識庫）"
echo "   目標：$REL"
echo "   範本：canonical assets/knowledge.md"
echo "   填完草稿後安裝："
echo "   sh $SCRIPT_DIR/kb-promote.sh \"$DRAFT\" \"$REL\" --yes"
echo "$DRAFT"
