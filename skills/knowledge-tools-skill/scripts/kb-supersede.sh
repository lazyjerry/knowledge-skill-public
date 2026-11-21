#!/bin/sh
# kb-supersede.sh
# 功能：以新知識取代舊知識——寫入雙方的取代關係 front matter，把舊檔移入 deprecated/
#       （鏡像分類路徑），再由 kb-reindex.sh 重建生效與停用兩份索引。
# 用法：sh kb-supersede.sh <舊檔相對路徑> <新檔相對路徑> [--yes]
# 參數：
#   <舊檔相對路徑>  將被停用的生效知識檔（相對 knowledge/，含分類目錄）
#   <新檔相對路徑>  取代它的生效知識檔（需已存在）
#   --yes           非互動環境明確授權停用（不可逆性低，但仍需同意）
# 流程：
#   1. 解析 KNOWLEDGE_BASE_DIR 並驗證新舊檔皆為生效知識檔
#   2. 取得授權（--yes 或互動輸入 yes，否則中止 結束碼 3）
#   3. 舊檔寫入「被取代於: <新檔>」、新檔寫入「取代: <舊檔>」（idempotent）
#   4. 把舊檔移入 deprecated/ 下的鏡像相對路徑
#   5. 呼叫 kb-reindex.sh 重建兩份索引
# 產出：移動 <KB>/<舊檔> → <KB>/deprecated/<舊檔>；改寫雙方 front matter；重建索引
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成；1 參數或結構錯誤；3 未取得授權而中止
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
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

usage() {
    echo "用法：sh kb-supersede.sh <舊檔相對路徑> <新檔相對路徑> [--yes]"
    echo "  例：sh kb-supersede.sh dev/ai-llm/old.md dev/ai-llm/new.md"
}

# 設定 front matter 單一欄位（存在則覆寫該欄，無 front matter 則前置一段最小區塊）
# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為
# true，會讓「標題」「觸發時機」「取代」全部被誤判為目標欄位而遭刪除，只剩下寫入的那一欄。
set_frontmatter() {
    _file="$1"; _key="$2"; _val="$3"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/kb-fm.XXXXXX")"
    if [ "$(head -n 1 "$_file")" = "---" ]; then
        LC_ALL=C awk -v key="$_key" -v val="$_val" '
            BEGIN { fm=0; done=0 }
            NR==1 && $0=="---" { print; fm=1; next }
            fm==1 && $0=="---" {
                if (!done) { print key ": " val; done=1 }
                print; fm=0; next
            }
            fm==1 {
                idx=index($0, ":")
                if (idx>0) {
                    k=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/, "", k)
                    if (k==key) { if (!done) { print key ": " val; done=1 } next }
                }
                print; next
            }
            { print }
        ' "$_file" > "$_tmp"
    else
        { printf -- '---\n%s: %s\n---\n\n' "$_key" "$_val"; cat "$_file"; } > "$_tmp"
    fi
    mv "$_tmp" "$_file"
}

OLD=""
NEW=""
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        *)
            if [ -z "$OLD" ]; then OLD="$arg"
            elif [ -z "$NEW" ]; then NEW="$arg"
            else echo "❌ 參數過多：$arg"; usage; exit 1
            fi
            ;;
    esac
done

if [ -z "$OLD" ] || [ -z "$NEW" ]; then
    usage
    exit 1
fi

# 正規化：去除可能誤帶的前綴與尾斜線
OLD="${OLD#./}"; NEW="${NEW#./}"

# 兩個路徑都會被改寫 front matter，舊檔還會被搬走：只接受知識庫內的知識檔
for _rel in "$OLD" "$NEW"; do
    case "$_rel" in
        /*) echo "❌ 需為相對 knowledge/ 的路徑：$_rel"; exit 1 ;;
        *..*) echo "❌ 路徑不可含 ..：$_rel"; exit 1 ;;
        index.md|*/index.md) echo "❌ 不可對索引檔操作：$_rel"; exit 1 ;;
    esac
    case "$_rel" in *.md) ;; *) echo "❌ 需為 .md 知識檔：$_rel"; exit 1 ;; esac
done

if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
    echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
    exit 1
fi

case "$OLD" in deprecated/*) echo "❌ 舊檔已在 deprecated/ 內：$OLD"; exit 1 ;; esac
case "$NEW" in deprecated/*) echo "❌ 新檔不可位於 deprecated/：$NEW"; exit 1 ;; esac

if [ "$OLD" = "$NEW" ]; then
    echo "❌ 新舊檔不可相同：$OLD"
    exit 1
fi
if [ ! -f "$KB_DIR/$OLD" ]; then
    echo "❌ 找不到舊知識檔：$(to_display "$KB_DIR/$OLD")"
    exit 1
fi
if [ ! -f "$KB_DIR/$NEW" ]; then
    echo "❌ 找不到新知識檔：$(to_display "$KB_DIR/$NEW")"
    echo "   請先建立新知識檔，再執行取代。"
    exit 1
fi

echo "ℹ️  即將以新知識取代舊知識並停用舊檔："
echo "   舊：$OLD  →  移入 deprecated/$OLD"
echo "   新：$NEW  （標記為取代來源）"

# 取得授權
if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "確定停用舊知識並建立取代關係？（輸入 yes 確認）： "
        read -r ans || ans=""
        if [ "$ans" != "yes" ]; then
            echo "已取消，未變更任何內容。"
            exit 3
        fi
    else
        echo "⚠️  非互動環境且未帶 --yes，已中止，未變更任何內容。"
        exit 3
    fi
fi

# 寫入取代關係
set_frontmatter "$KB_DIR/$OLD" "被取代於" "$NEW"
set_frontmatter "$KB_DIR/$NEW" "取代" "$OLD"

# 移入 deprecated/ 鏡像路徑
mkdir -p "$(dirname "$DEP_DIR/$OLD")"
mv "$KB_DIR/$OLD" "$DEP_DIR/$OLD"
echo "✅ 已停用並移入：deprecated/$OLD"

# 重建兩份索引
sh "$SCRIPT_DIR/kb-reindex.sh"
