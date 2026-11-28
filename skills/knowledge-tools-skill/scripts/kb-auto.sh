#!/bin/sh
# kb-auto.sh
# 功能：管理「免詢問自動收錄」——查詢與切換開關、列出狀態為「AI 自動確認」的知識、
#       把審核過的知識改為「人工審核確認」。
# 用法：sh kb-auto.sh <status|enabled|on|off|list|confirm> [參數]
# 參數：
#   status                              顯示開關狀態與「AI 自動確認」知識的數量（唯讀）
#   enabled                             供腳本判斷：開啟時結束碼 0、關閉時 1，不輸出
#   on [--yes]                          開啟自動收錄，寫入設定檔
#   off [--yes]                         關閉自動收錄，寫入設定檔
#   list                                列出狀態為「AI 自動確認」的生效知識（唯讀）
#   confirm <相對路徑...> [--yes]       把指定知識的狀態改為「人工審核確認」
#   confirm --all [--yes]               把所有「AI 自動確認」的知識改為「人工審核確認」
# 流程：
#   開關：解析順序為環境變數 KNOWLEDGE_AUTO_RECORD > 設定檔 > 預設（開啟）。on／off 只改寫
#         設定檔中 KNOWLEDGE_AUTO_RECORD= 那一行，其餘內容原樣保留。
#   confirm：驗證路徑 → 取得授權 → 改寫 front matter 的「狀態」→ 由 kb-reindex.sh 重建索引。
# 產出：on／off 寫入 ~/.config/knowledge-skill/config；confirm 改寫知識檔並重建索引。
# 環境變數：
#   KNOWLEDGE_BASE_DIR     共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
#   KNOWLEDGE_AUTO_RECORD  自動收錄開關（on／off）；設定時優先於設定檔
# 結束碼：0 完成（enabled：開啟）；1 參數或結構錯誤（enabled：關閉）；3 未取得授權而中止
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
DEP_DIR="$KB_DIR/deprecated"
STATUS_AUTO="AI 自動確認"
STATUS_REVIEWED="人工審核確認"

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

usage() {
    echo "用法：sh kb-auto.sh <status|enabled|on|off|list|confirm> [參數]"
    echo "  例：sh kb-auto.sh off --yes"
    echo "      sh kb-auto.sh confirm dev/shell/x.md --yes"
    echo "      sh kb-auto.sh confirm --all --yes"
}

# 開關的解析順序與知識庫位置相同：環境變數 > 設定檔 > 預設（開啟）。
# 認不得的值一律當關閉：這是「能不能不問就寫入」的開關，值寫錯時寧可回到詢問。
resolve_switch() {
    AUTO_RAW=""
    AUTO_SOURCE="預設值"
    if [ -n "${KNOWLEDGE_AUTO_RECORD:-}" ]; then
        AUTO_RAW="$KNOWLEDGE_AUTO_RECORD"
        AUTO_SOURCE="環境變數 KNOWLEDGE_AUTO_RECORD"
    elif [ -f "$KB_CONFIG" ]; then
        AUTO_RAW="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_AUTO_RECORD=//p' "$KB_CONFIG" | tail -n 1 | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
        [ -z "$AUTO_RAW" ] || AUTO_SOURCE="設定檔 ~/.config/knowledge-skill/config"
    fi
    case "$(printf '%s' "$AUTO_RAW" | tr '[:upper:]' '[:lower:]')" in
        ""|on|1|true|yes) AUTO_STATE="on" ;;
        off|0|false|no) AUTO_STATE="off" ;;
        *) AUTO_STATE="invalid" ;;
    esac
}

# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為 true。
fm_value() {
    LC_ALL=C awk -v key="$2" '
        BEGIN { fm=0 }
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

# 設定 front matter 單一欄位（存在則覆寫該欄，無 front matter 則前置一段最小區塊）。
# 與 kb-supersede.sh、kb-repair.sh 的 set_frontmatter 同一份寫法。
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

require_kb() {
    if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
        echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
        echo "   請先執行 init-knowledge-base.sh 建立。"
        exit 1
    fi
}

# 輸出狀態為「AI 自動確認」的生效知識相對路徑，一行一筆。
list_auto() {
    find "$KB_DIR" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
        | LC_ALL=C sort | while IFS= read -r _f; do
            [ "$(fm_value "$_f" "狀態")" = "$STATUS_AUTO" ] || continue
            printf '%s\n' "${_f#"$KB_DIR"/}"
        done
}

# 取得改檔授權：--yes 或互動輸入 yes，否則以結束碼 3 中止。$1 提示文字。
authorize() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ -t 0 ]; then
        printf '%s（輸入 yes 確認）： ' "$1"
        read -r ans || ans=""
        if [ "$ans" != "yes" ]; then
            echo "已取消，未變更任何內容。"
            exit 3
        fi
    else
        echo "⚠️  非互動環境且未帶 --yes，已中止，未變更任何內容。"
        exit 3
    fi
}

cmd_status() {
    resolve_switch
    case "$AUTO_STATE" in
        on)
            printf '🤖 自動收錄（免詢問）：開啟（來源：%s）\n' "$AUTO_SOURCE"
            echo "   關閉：sh kb-auto.sh off --yes"
            ;;
        off)
            printf '🤖 自動收錄（免詢問）：關閉（來源：%s）\n' "$AUTO_SOURCE"
            echo "   開啟：sh kb-auto.sh on --yes"
            ;;
        *)
            printf '⚠️  自動收錄（免詢問）：關閉（%s 的值無法辨識：%s）\n' "$AUTO_SOURCE" "$AUTO_RAW"
            echo "   請改為 on 或 off：sh kb-auto.sh on --yes ／ sh kb-auto.sh off --yes"
            ;;
    esac
    if [ -d "$KB_DIR" ]; then
        _count="$(list_auto | grep -c . || true)"
        printf '📊 %s、尚未人工審核：%s 則\n' "$STATUS_AUTO" "$_count"
        [ "$_count" -eq 0 ] || echo "   列出：sh kb-auto.sh list"
    fi
}

cmd_enabled() {
    resolve_switch
    [ "$AUTO_STATE" = "on" ]
}

# $1 on／off
cmd_switch() {
    _val="$1"
    if [ "$_val" = "on" ]; then
        authorize "確定開啟自動收錄？閘門全過的新知識會不經詢問直接寫入"
    else
        authorize "確定關閉自動收錄？"
    fi
    mkdir -p "$(dirname "$KB_CONFIG")"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/kb-auto.XXXXXX")"
    trap 'rm -f "$_tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ -f "$KB_CONFIG" ]; then
        # grep -v 在「沒有任何輸出行」時回 1，不算失敗。
        grep -v '^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_AUTO_RECORD=' "$KB_CONFIG" > "$_tmp" || true
    else
        cat > "$_tmp" <<'EOF'
# knowledge-skill 設定檔
# 不會被 shell source；腳本只解析 KNOWLEDGE_BASE_DIR= 與 KNOWLEDGE_AUTO_RECORD= 這兩行。
EOF
    fi
    printf 'KNOWLEDGE_AUTO_RECORD=%s\n' "$_val" >> "$_tmp"
    # 以內容覆寫而非 mv：保留既有設定檔的權限。
    cat "$_tmp" > "$KB_CONFIG"
    rm -f "$_tmp"
    trap - EXIT INT TERM
    if [ "$_val" = "on" ]; then
        echo "✅ 已開啟自動收錄：$(to_display "$KB_CONFIG")"
    else
        echo "✅ 已關閉自動收錄：$(to_display "$KB_CONFIG")"
    fi
    if [ -n "${KNOWLEDGE_AUTO_RECORD:-}" ]; then
        printf '⚠️  環境變數 KNOWLEDGE_AUTO_RECORD 目前為 %s，會蓋過設定檔。\n' "$KNOWLEDGE_AUTO_RECORD"
    fi
}

cmd_list() {
    require_kb
    _rows="$(list_auto)"
    echo "📍 知識庫：$(to_display "$KB_DIR")"
    if [ -z "$_rows" ]; then
        printf '✅ 沒有狀態為「%s」的知識。\n' "$STATUS_AUTO"
        return 0
    fi
    printf '🤖 %s、尚未人工審核 %s 則：\n' "$STATUS_AUTO" "$(printf '%s\n' "$_rows" | grep -c .)"
    printf '%s\n' "$_rows" | while IFS= read -r _rel; do
        printf '   • %s — %s\n' "$_rel" "$(fm_value "$KB_DIR/$_rel" "標題")"
    done
    echo "👉 審核過的：sh kb-auto.sh confirm <相對路徑> --yes（全部：confirm --all --yes）"
    echo "   不要的：sh kb-delete.sh <相對路徑> --yes"
}

cmd_confirm() {
    require_kb
    if [ "$CONFIRM_ALL" -eq 1 ]; then
        [ -z "$TARGETS" ] || { echo "❌ --all 不可與指定路徑並用"; usage; exit 1; }
        TARGETS="$(list_auto)"
        if [ -z "$TARGETS" ]; then
            printf '✅ 沒有狀態為「%s」的知識，無需變更。\n' "$STATUS_AUTO"
            return 0
        fi
    elif [ -z "$TARGETS" ]; then
        echo "❌ confirm 需指定知識相對路徑或 --all"
        usage
        exit 1
    fi

    # 先全部驗過再動手，避免改到一半才發現路徑有誤。
    _pending=""
    while IFS= read -r _rel; do
        [ -z "$_rel" ] && continue
        case "$_rel" in
            deprecated/*) echo "❌ 停用知識不需確認：$_rel"; exit 1 ;;
            /*) echo "❌ 需為相對 knowledge/ 的路徑：$_rel"; exit 1 ;;
            *..*) echo "❌ 路徑不可含 ..：$_rel"; exit 1 ;;
        esac
        case "$_rel" in *.md) ;; *) echo "❌ 需為 .md：$_rel"; exit 1 ;; esac
        case "$(basename "$_rel")" in index.md) echo "❌ 索引檔不是知識：$_rel"; exit 1 ;; esac
        [ -f "$KB_DIR/$_rel" ] || { echo "❌ 找不到知識檔：$_rel"; exit 1; }
        if [ "$(fm_value "$KB_DIR/$_rel" "狀態")" = "$STATUS_REVIEWED" ]; then
            printf 'ℹ️  已是「%s」，略過：%s\n' "$STATUS_REVIEWED" "$_rel"
            continue
        fi
        _pending="$_pending$_rel
"
    done <<EOF
$TARGETS
EOF

    if [ -z "$_pending" ]; then
        echo "✅ 無需變更。"
        return 0
    fi

    printf 'ℹ️  即將把下列知識的狀態改為「%s」：\n' "$STATUS_REVIEWED"
    printf '%s' "$_pending" | while IFS= read -r _rel; do
        [ -z "$_rel" ] || printf '   • %s\n' "$_rel"
    done
    authorize "確定更新狀態？"

    printf '%s' "$_pending" | while IFS= read -r _rel; do
        [ -z "$_rel" ] && continue
        set_frontmatter "$KB_DIR/$_rel" "狀態" "$STATUS_REVIEWED"
        printf '✅ 已確認：%s\n' "$_rel"
    done
    sh "$SCRIPT_DIR/kb-reindex.sh"
}

CMD="${1:-}"
[ $# -gt 0 ] && shift

ASSUME_YES=0
CONFIRM_ALL=0
TARGETS=""
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --all) CONFIRM_ALL=1 ;;
        -*) echo "❌ 未知參數：$arg"; usage; exit 1 ;;
        *) TARGETS="$TARGETS${arg#./}
" ;;
    esac
done

case "$CMD" in
    status) cmd_status ;;
    enabled) cmd_enabled ;;
    on|off)
        [ -z "$TARGETS" ] || { echo "❌ $CMD 不接受其他參數"; usage; exit 1; }
        cmd_switch "$CMD"
        ;;
    list) cmd_list ;;
    confirm) cmd_confirm ;;
    *) usage; exit 1 ;;
esac
