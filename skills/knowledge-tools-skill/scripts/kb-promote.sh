#!/bin/sh
# kb-promote.sh
# 功能：把審核通過的候選 MADR 檔確定性安裝成生效知識——驗證格式、拒絕覆蓋、原子安裝、
#       記錄來源 provenance，再由 kb-reindex.sh 重建索引。
# 用法：sh kb-promote.sh <候選-MADR.md> <knowledge-相對路徑> [--yes] [--source <來源說明>]
# 參數：
#   <候選-MADR.md>        審核通過的候選知識檔（canonical MADR 格式）
#   <knowledge-相對路徑>  目標相對 knowledge/ 的路徑（含分類目錄，如 dev/ai-llm/x.md）
#   --yes                 非互動環境明確授權安裝
#   --source <來源說明>   provenance 的來源描述；省略時記錄候選檔路徑。草稿放在暫存目錄
#                         （如 knowledge-record-skill 的沉澱流程）時，暫存路徑無追溯價值，
#                         改填任務資料夾或對話來源才有意義
# 流程：
#   1. 驗證候選 front matter（標題／觸發時機 非佔位）與必要段落（## 摘要／## 決策結果）
#   2. 解析 KNOWLEDGE_BASE_DIR；目標已存在則拒絕（改走 supersede）
#   3. 取得授權（--yes 或互動 yes，否則中止 結束碼 3）
#   4. 原子安裝（mktemp + mv），於檔尾補 provenance（來源候選與 sha256）
#   5. 呼叫 kb-reindex.sh 重建索引，提示跑 status
# 產出：寫入 <KB>/<相對路徑>；重建索引。
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成；1 參數／格式／結構錯誤或目標已存在；3 未取得授權而中止
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

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

usage() {
    echo "用法：sh kb-promote.sh <候選-MADR.md> <knowledge-相對路徑> [--yes] [--source <來源說明>]"
    echo "  例：sh kb-promote.sh docs/knowledge-skill/記憶候選_claude-001/madr.md dev/ai-llm/x.md"
}

# 讀 front matter 單一欄位值（無則空）。
fm_value() {
    # LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為
    # true，key 是中文欄名時第一個有冒號的欄位就會被誤判命中。
    LC_ALL=C awk -v key="$2" '
        BEGIN { fm=0 }
        NR==1 && $0=="---" { fm=1; next }
        fm==1 && $0=="---" { exit }
        fm==1 {
            i=index($0,":")
            if (i>0) {
                k=substr($0,1,i-1); v=substr($0,i+1)
                gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v)
                if (k==key) { print v; exit }
            }
        }
    ' "$1"
}

CAND=""
REL=""
SOURCE=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) ASSUME_YES=1 ;;
        --source)
            shift
            [ $# -gt 0 ] || { echo "❌ --source 缺少來源說明"; usage; exit 1; }
            SOURCE="$1"
            ;;
        *)
            if [ -z "$CAND" ]; then CAND="$1"
            elif [ -z "$REL" ]; then REL="$1"
            else echo "❌ 參數過多：$1"; usage; exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$CAND" ] || [ -z "$REL" ]; then
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

if [ ! -f "$CAND" ]; then
    echo "❌ 找不到候選檔：$CAND"
    exit 1
fi
if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
    echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
    exit 1
fi

# 格式驗證
if [ "$(head -n 1 "$CAND")" != "---" ]; then
    echo "❌ 候選缺 YAML front matter（需以 --- 開頭）：$CAND"
    exit 1
fi
TITLE="$(fm_value "$CAND" "標題")"
TRIGGER="$(fm_value "$CAND" "觸發時機")"
if [ -z "$TITLE" ]; then echo "❌ front matter 缺 標題"; exit 1; fi
case "$TITLE" in "["*) echo "❌ front matter 標題 仍是範本佔位：$TITLE"; exit 1 ;; esac
if [ -z "$TRIGGER" ]; then echo "❌ front matter 缺 觸發時機"; exit 1; fi
case "$TRIGGER" in "["*) echo "❌ front matter 觸發時機 仍是範本佔位"; exit 1 ;; esac
grep -q '^## 摘要' "$CAND" || { echo "❌ 缺 ## 摘要 段"; exit 1; }
grep -q '^## 決策結果' "$CAND" || { echo "❌ 缺 ## 決策結果 段"; exit 1; }

TARGET="$KB_DIR/$REL"
if [ -e "$TARGET" ]; then
    echo "❌ 目標已存在：$(to_display "$TARGET")"
    echo "   不覆蓋；若要以新知識取代，請改用 kb-supersede.sh。"
    exit 1
fi

HASH="$(shasum -a 256 "$CAND" | awk '{print $1}')"

echo "ℹ️  即將安裝候選為生效知識："
echo "   候選：$CAND"
echo "   目標：$REL"
echo "   標題：$TITLE"

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "確定安裝此知識檔？（輸入 yes 確認）： "
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

# 原子安裝：先寫暫存（含 provenance），再 mv 到位
mkdir -p "$(dirname "$TARGET")"
TMP="$(mktemp "${TMPDIR:-/tmp}/kb-promote.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat "$CAND" > "$TMP"
# canonical 範本的 ## 補充資訊 為最末段，於檔尾補 provenance（idempotent）
if ! grep -Fq "kb-promote.sh 安裝" "$TMP"; then
    printf -- '\n- 由 kb-promote.sh 安裝；來源：%s（sha256:%s）\n' "${SOURCE:-$CAND}" "$HASH" >> "$TMP"
fi
mv "$TMP" "$TARGET"
trap - EXIT INT TERM
echo "✅ 已安裝：$REL"

# 重建索引
sh "$SCRIPT_DIR/kb-reindex.sh"
echo "👉 建議再執行 status 驗證：sh $SCRIPT_DIR/kb-tools.sh status"
