#!/bin/sh
# uninstall-knowledge-base.sh
# 移除 knowledge-skill 安裝下的設定，反向處理 init-injection.sh 與 init-knowledge-base.sh：
#   1. shell 設定檔中的 KNOWLEDGE_BASE_DIR 環境變數（舊版寫入）與設定檔 ~/.config/knowledge-skill/config
#   2. AGENTS.md / CLAUDE.md / GEMINI.md 中以 knowledge-skill:shared-kb marker 包夾的注入區塊
# 共用知識庫目錄不在移除範圍：只在最後印出位置，由使用者自行確認後刪除。
#
# 用法:
#   sh scripts/uninstall-knowledge-base.sh [額外路徑...]
#     [額外路徑]：除預設全域指令檔外，要一併掃描注入區塊的檔案或專案目錄
#
# 安全性:
#   - 先列出所有將被移除的項目，經使用者確認後才執行，不會直接刪除。
#   - 修改任何檔案前，會先備份為 <檔名>.knowledge-skill.bak.<時間戳>。
#   - 不刪除知識庫目錄：裡面是使用者累積的資料，位置又可任意指定，腳本無從確認
#     路徑指到的真的是知識庫（設錯時可能是雲端同步資料夾或家目錄）。

set -e

MARKER_BEGIN="<!-- BEGIN knowledge-skill:shared-kb -->"
MARKER_END="<!-- END knowledge-skill:shared-kb -->"
COMMENT_LINE="# knowledge-skill: 共用知識庫位置"
TS="$(date +%Y%m%d%H%M%S)"
# 清單以換行分隔：POSIX sh 沒有陣列，路徑又可能含空白
NL='
'

# 把家目錄前綴換回 ~（顯示用）
to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# 清單 $1 是否已含 $2 這一行
list_has() {
    case "$NL$1$NL" in *"$NL$2$NL"*) return 0 ;; esac
    return 1
}

# ============================================================
# 步驟 1：盤點將被移除的項目
# ============================================================

# 待清除環境變數的 shell 設定檔
ENV_HITS=""
ENV_COUNT=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile" "${ZDOTDIR:-$HOME}/.zshrc"; do
    if list_has "$ENV_HITS" "$rc"; then continue; fi
    [ -f "$rc" ] || continue
    if grep -q "KNOWLEDGE_BASE_DIR" "$rc"; then
        ENV_HITS="${ENV_HITS:+$ENV_HITS$NL}$rc"
        ENV_COUNT=$((ENV_COUNT + 1))
    fi
done

# 設定檔（init-knowledge-base.sh 寫入的知識庫位置）
CONFIG_FILE="$HOME/.config/knowledge-skill/config"
CONFIG_HIT=0
[ -f "$CONFIG_FILE" ] && CONFIG_HIT=1

# 待清除注入區塊的指令檔（全域預設 + 使用者額外指定路徑）
BLOCK_HITS=""
BLOCK_COUNT=0
check_block_file() {
    if list_has "$BLOCK_HITS" "$1"; then return 0; fi
    [ -f "$1" ] || return 0
    if grep -qF "$MARKER_BEGIN" "$1"; then
        BLOCK_HITS="${BLOCK_HITS:+$BLOCK_HITS$NL}$1"
        BLOCK_COUNT=$((BLOCK_COUNT + 1))
    fi
}
for f in \
    "$HOME/.codex/AGENTS.md" \
    "$HOME/.claude/CLAUDE.md" \
    "$HOME/.gemini/GEMINI.md" \
    "$HOME/.ai-global/AGENTS.md"; do
    check_block_file "$f"
done
for extra in "$@"; do
    if [ -d "$extra" ]; then
        check_block_file "$extra/AGENTS.md"
        check_block_file "$extra/CLAUDE.md"
        check_block_file "$extra/GEMINI.md"
    else
        check_block_file "$extra"
    fi
done

# 知識庫目錄
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
# 知識庫目錄只回報位置。上層名稱是 .knowledge-skill 時回報整個專屬目錄（另含 backups/、logs/）
KB_RAW="$KB_DIR"
while [ "${KB_RAW%/}" != "$KB_RAW" ]; do KB_RAW="${KB_RAW%/}"; done
KB_PARENT="${KB_RAW%/*}"
KB_LEFT=""
if [ "${KB_RAW##*/}" = "knowledge" ] && [ "${KB_PARENT##*/}" = ".knowledge-skill" ]; then
    if [ -d "$KB_PARENT" ]; then KB_LEFT="$KB_PARENT"; fi
elif [ -n "$KB_RAW" ] && [ -d "$KB_RAW" ]; then
    KB_LEFT="$KB_RAW"
fi

report_kb_left() {
    if [ -n "$KB_LEFT" ]; then
        echo "📁 知識庫目錄不會由本腳本刪除（含累積的知識檔案）："
        printf '  • %s\n' "$(to_display "$KB_LEFT")"
        echo "   確認該位置確實是知識庫、內容也不再需要後，請自行刪除。"
        echo ""
    fi
}

# 沒有任何項目 → 結束
if [ "$ENV_COUNT" -eq 0 ] && [ "$CONFIG_HIT" -eq 0 ] && [ "$BLOCK_COUNT" -eq 0 ]; then
    echo "✅ 找不到任何 knowledge-skill 相關設定，無需移除。"
    echo ""
    report_kb_left
    exit 0
fi

# ============================================================
# 步驟 2：列出將被移除的項目
# ============================================================

echo "以下 knowledge-skill 相關項目將被移除："
echo ""

if [ "$ENV_COUNT" -gt 0 ]; then
    echo "【環境變數】KNOWLEDGE_BASE_DIR（含 knowledge-skill 註解行）"
    while IFS= read -r rc; do
        [ -n "$rc" ] || continue
        echo "  • $(to_display "$rc")"
        grep -nE "knowledge-skill: 共用知識庫位置|KNOWLEDGE_BASE_DIR" "$rc" | sed 's/^/      /'
    done <<EOF
$ENV_HITS
EOF
    echo ""
fi

if [ "$CONFIG_HIT" -eq 1 ]; then
    echo "【設定檔】知識庫位置設定"
    echo "  • $(to_display "$CONFIG_FILE")"
    echo ""
fi

if [ "$BLOCK_COUNT" -gt 0 ]; then
    echo "【注入區塊】knowledge-skill:shared-kb（marker 包夾段落）"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "  • $(to_display "$f")"
    done <<EOF
$BLOCK_HITS
EOF
    echo ""
fi

# ============================================================
# 步驟 3：移除設定（環境變數 + 設定檔 + 注入區塊）
# ============================================================

CONFIG_COUNT=$((ENV_COUNT + CONFIG_HIT + BLOCK_COUNT))

if [ "$CONFIG_COUNT" -gt 0 ]; then
    printf "確定移除上述「環境變數」「設定檔」與「注入區塊」設定？(y/N): "
    read -r ans || ans=""
    case "$ans" in
        y|Y|yes|YES)
            while IFS= read -r rc; do
                [ -n "$rc" ] || continue
                cp "$rc" "$rc.knowledge-skill.bak.$TS"
                awk '
                    index($0, "knowledge-skill: 共用知識庫位置") > 0 { next }
                    index($0, "KNOWLEDGE_BASE_DIR") > 0 { next }
                    { print }
                ' "$rc" > "$rc.tmp.$$"
                mv "$rc.tmp.$$" "$rc"
                printf '✅ 已移除環境變數: %s（備份 .knowledge-skill.bak.%s）\n' "$(to_display "$rc")" "$TS"
            done <<EOF
$ENV_HITS
EOF

            if [ "$CONFIG_HIT" -eq 1 ]; then
                mv "$CONFIG_FILE" "$CONFIG_FILE.knowledge-skill.bak.$TS"
                printf '✅ 已移除設定檔: %s（備份 .knowledge-skill.bak.%s）\n' "$(to_display "$CONFIG_FILE")" "$TS"
            fi

            while IFS= read -r f; do
                [ -n "$f" ] || continue
                cp "$f" "$f.knowledge-skill.bak.$TS"
                awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" '
                    index($0, B) > 0 { inblock=1; next }
                    inblock { if (index($0, E) > 0) { inblock=0; pendblank=1 } next }
                    pendblank == 1 { pendblank=0; if ($0 == "") next }
                    { print }
                ' "$f" > "$f.tmp.$$"
                mv "$f.tmp.$$" "$f"
                printf '✅ 已移除注入區塊: %s（備份 .knowledge-skill.bak.%s）\n' "$(to_display "$f")" "$TS"
            done <<EOF
$BLOCK_HITS
EOF
            ;;
        *)
            echo "已略過設定移除。"
            ;;
    esac
    echo ""
fi

# ============================================================
# 步驟 4：回報知識庫目錄位置（不刪除）
# ============================================================

report_kb_left

echo "完成。若移除了環境變數，請重新開啟終端機使其生效。"
