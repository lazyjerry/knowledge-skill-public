#!/bin/sh
# kb-delete.sh
# 功能：手動整理共用知識庫——列出條目並刪除指定的單一知識檔，刪除後自動重建索引。
#       知識檔依分類目錄遞迴存放，條目以相對路徑表示。
# 用法：sh kb-delete.sh [list|<編號或相對路徑> [--yes]]
# 參數：
#   無參數               列出條目；互動 tty 會再讀取一個選擇
#   list                 只列出目前條目並結束，即使 stdin 是 tty 也不讀取
#   <編號或相對路徑>      指定要刪除的條目；互動 tty 需輸入 yes 確認，非互動需帶 --yes
#   --yes                非互動環境明確授權刪除（不可逆）
# 流程：
#   1. 解析 KNOWLEDGE_BASE_DIR 並確認 knowledge 目錄與 index.md 存在
#   2. 以遞迴相對路徑（排除 index.md 與 deprecated/）為條目來源並穩定編號
#   3. (刪除模式) 解析選擇 → 取得授權 → 刪除檔案 → 由 kb-reindex.sh 重建索引
#   4. 無論是否刪除，動作後重列最新條目清單
# 產出：刪除 <KB>/<相對路徑>；刪除後呼叫 kb-reindex.sh 重建 index.md（不手改索引）
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成（含唯讀列表）；1 結構缺失或選擇無效；3 未取得授權而中止
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

# 生效知識檔相對路徑（遞迴；排除 index.md 與 deprecated/），穩定排序
collect_files() {
    find "$KB_DIR" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r f; do printf '%s\n' "${f#"$KB_DIR"/}"; done
}

# 取知識檔觸發時機（先 front matter 的「觸發時機:」，回退「## 觸發時機」段第一行）
# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為
# true，會讓「標題」等其他中文欄名也命中「觸發時機」的判斷而回傳錯誤的值。
first_trigger() {
    LC_ALL=C awk '
        BEGIN { fm=0 }
        NR==1 && $0=="---" { fm=1; next }
        fm==1 && $0=="---" { fm=0; next }
        fm==1 {
            idx=index($0, ":")
            if (idx>0) {
                k=substr($0,1,idx-1); v=substr($0,idx+1)
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k=="觸發時機" && v!="" && v!="-") { print v; exit }
            }
            next
        }
        /^## 觸發時機/ { sec=1; next }
        /^## / { sec=0 }
        sec && NF { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
    ' "$1"
}

print_list() {
    files="$(collect_files)"
    if [ -z "$files" ]; then
        echo "ℹ️  知識庫目前沒有任何生效知識條目。"
        return 0
    fi
    echo "📚 目前共用知識庫條目（$(to_display "$KB_DIR")）："
    n=0
    printf '%s\n' "$files" | while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        n=$((n + 1))
        trigger="$(first_trigger "$KB_DIR/$rel")"
        if [ -n "$trigger" ]; then
            printf '  [%s] %s — %s\n' "$n" "$rel" "$trigger"
        else
            printf '  [%s] %s\n' "$n" "$rel"
        fi
    done
}

# 將選擇（編號或相對路徑）解析成磁碟上的相對路徑，成功印出路徑並回傳 0
resolve_selection() {
    sel="$1"
    files="$(collect_files)"
    case "$sel" in
        ''|*[!0-9]*)
            target="$sel"
            case "$target" in
                *.md) ;;
                *) target="$target.md" ;;
            esac
            printf '%s\n' "$files" | grep -Fxq "$target" || return 1
            printf '%s\n' "$target"
            ;;
        *)
            printf '%s\n' "$files" | awk -v i="$sel" '
                NF { c++; if (c == i) { print; found=1 } }
                END { exit !found }
            '
            ;;
    esac
}

ASSUME_YES=0
SELECTION=""
LIST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        list) LIST_ONLY=1 ;;
        "") ;;
        *) SELECTION="$arg" ;;
    esac
done

if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
    echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
    echo "   請先執行 init-knowledge-base.sh 建立。"
    exit 1
fi

# 無指定條目：list 直接結束；只有無參數且為互動 tty 才讀取選擇
if [ -z "$SELECTION" ]; then
    print_list
    if [ "$LIST_ONLY" -eq 1 ]; then
        exit 0
    fi
    if [ -t 0 ] && [ -n "$(collect_files)" ]; then
        printf "\n請輸入要刪除的編號或相對路徑（直接 Enter 離開）： "
        read -r SELECTION || SELECTION=""
        [ -z "$SELECTION" ] && exit 0
    else
        exit 0
    fi
fi

# 刪除模式
if ! TARGET="$(resolve_selection "$SELECTION")"; then
    echo "❌ 找不到對應條目：$SELECTION"
    echo ""
    print_list
    exit 1
fi

RESULT=0
if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "確定刪除知識條目「%s」？此動作不可逆（輸入 yes 確認）： " "$TARGET"
        read -r ans || ans=""
        if [ "$ans" != "yes" ]; then
            echo "已取消，未刪除任何內容。"
            RESULT=3
        fi
    else
        echo "⚠️  非互動環境且未帶 --yes，已中止，未刪除任何內容。"
        RESULT=3
    fi
fi

if [ "$RESULT" -eq 0 ]; then
    rm -f "$KB_DIR/$TARGET"
    echo "✅ 已刪除：$(to_display "$KB_DIR/$TARGET")"
    # 由腳本確定性重建索引，移除剛刪檔造成的斷鏈（不手改 index.md）
    sh "$SCRIPT_DIR/kb-reindex.sh"
fi

echo ""
print_list
exit "$RESULT"
