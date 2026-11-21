#!/bin/sh
# init-injection.sh
# 將「共用知識庫優先參考」區塊注入指定路徑的 AGENTS.md / CLAUDE.md / GEMINI.md，
# 讓該專案的 AI 工具在執行動作前，先查閱跨專案共用知識庫。
#
# 用法:
#   sh scripts/init-injection.sh [--refresh] <目標路徑> [AGENTS.md|CLAUDE.md|GEMINI.md]
#     <目標路徑> 為目錄 → 注入該目錄下的 AGENTS.md、CLAUDE.md 與 GEMINI.md（預設三者）
#     <目標路徑> 為檔案 → 只注入該檔（不存在則略過並提示，不建立）
#     未提供目標路徑 → 從已存在的常用 AI 工具全域指令檔中選擇
#     第二參數可選，限定只注入其中一個（僅當目標為目錄時有效）
#     --refresh 需放在第一個參數；把既有區塊就地更新為現行版本（改檔前自動備份）
#
# 環境變數:
#   KNOWLEDGE_BASE_DIR  共用知識庫路徑；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
#
# 特性：以標記包夾、可重複執行（idempotent）；預設若已存在同名區塊則停止不覆蓋，避免破壞既有內容，
#       要更新落後的區塊需明確帶 --refresh。
#
# ⚠️ make_block() 的文字必須與 skills/knowledge-tools-skill/scripts/kb-injection.sh 逐字相同
#    （本檔支援單檔遠端執行、skill 目錄可獨立安裝，兩者無法共用同一份來源）。
#    修改任一邊後執行 skills/knowledge-tools-skill/scripts/test-injection-block.sh 驗證。

set -e

REFRESH=0
if [ "${1:-}" = "--refresh" ]; then
    REFRESH=1
    shift
fi

TARGET="${1:-}"
ONLY="${2:-}"
TS="$(date +%Y%m%d%H%M%S)"

show_usage() {
    echo "用法: sh scripts/init-injection.sh [--refresh] <目標路徑> [AGENTS.md|CLAUDE.md|GEMINI.md]"
    echo "  <目標路徑>：目錄（注入 AGENTS.md、CLAUDE.md 與 GEMINI.md）或單一 .md 檔"
    echo "  未提供目標路徑時，會列出已存在的常用 AI 工具全域指令檔供選擇"
    echo "  --refresh：既有區塊就地更新為現行版本（改檔前備份），不帶時遇既有區塊會略過"
}

add_choice() {
    label="$1"
    path="$2"

    if [ ! -f "$path" ]; then
        return 0
    fi

    choice_count=$((choice_count + 1))
    eval "CHOICE_${choice_count}_LABEL=\$label"
    eval "CHOICE_${choice_count}_PATH=\$path"
    echo "  [$choice_count] $label: $path"
}

choose_target() {
    choice_count=0

    echo "未提供目標路徑。請選擇要注入的既有 AI 工具全域指令檔："
    add_choice "Codex 全域 AGENTS.md" "$HOME/.codex/AGENTS.md"
    add_choice "Claude Code 全域 CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    add_choice "Antigravity CLI 全域 GEMINI.md" "$HOME/.gemini/GEMINI.md"
    add_choice "ai-global AGENTS.md" "$HOME/.ai-global/AGENTS.md"

    if [ "$choice_count" -eq 0 ]; then
        echo "找不到可選擇的既有 AGENTS.md / CLAUDE.md / GEMINI.md。"
        show_usage
        exit 1
    fi

    printf "請輸入編號: "
    if ! read -r selection; then
        echo "錯誤：未讀取到選擇"
        exit 1
    fi

    case "$selection" in
        *[!0-9]*|"")
            echo "錯誤：請輸入有效編號"
            exit 1
            ;;
    esac

    if [ "$selection" -lt 1 ] || [ "$selection" -gt "$choice_count" ]; then
        echo "錯誤：選擇超出範圍"
        exit 1
    fi

    eval "TARGET=\$CHOICE_${selection}_PATH"
}

if [ -z "$TARGET" ]; then
    choose_target
fi

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
KB_RAW="$KB_DIR"
# 顯示用路徑：把家目錄前綴換回 ~，避免寫死絕對家目錄（檔案可能被 commit）
case "$KB_RAW" in
    "$HOME") KB_DISPLAY="~" ;;
    "$HOME"/*) KB_DISPLAY="~/${KB_RAW#"$HOME"/}" ;;
    *) KB_DISPLAY="$KB_RAW" ;;
esac

MARKER_BEGIN="<!-- BEGIN knowledge-skill:shared-kb -->"
MARKER_END="<!-- END knowledge-skill:shared-kb -->"

# 產生注入區塊（H1 標題 + 描述 + 列點，格式對齊 ~/.claude/CLAUDE.md）
make_block() {
cat <<EOF
$MARKER_BEGIN
# 共用知識庫優先參考

動手做會改變東西的任務（寫程式、改設定、除錯、部署）前，先讀跨專案共用知識庫，沿用既有慣例與已知陷阱；純問答、閒聊不用讀。

- 知識庫位置：\`$KB_DISPLAY/\`（可由環境變數 \`KNOWLEDGE_BASE_DIR\` 覆寫）
- 索引分兩層，逐層下探，不要一次讀完整棵樹：
  1. 動作前先讀頂層索引 \`$KB_DISPLAY/index.md\`——只有分類目錄與各分類的知識標題
  2. 有可能相關的分類，才讀該分類子索引 \`$KB_DISPLAY/{分類}/index.md\`，裡面才有完整「觸發時機」與「摘要」
  3. 觸發時機相符，才讀該知識檔
- 有匹配 → 載入該知識檔作為參考再執行；無匹配 → 直接執行，不需強記
$MARKER_END
EOF
}

# 就地把既有區塊換成現行版本：保留區塊在檔案中的原位置，區塊外內容原樣保留
# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較多位元組字串會失準，
# 而這些指令檔通篇中文，需確保標記比對走位元組語意。
refresh_file() {
    f="$1"

    blk="$f.kbblock.$$"
    cur="$f.kbcurrent.$$"
    tmp="$f.kbinject.$$"
    trap 'rm -f "$blk" "$cur" "$tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    make_block > "$blk"

    LC_ALL=C awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" '
        index($0, B) > 0 { inblock=1 }
        inblock { print }
        inblock && index($0, E) > 0 { exit }
    ' "$f" > "$cur"

    if diff -q "$cur" "$blk" >/dev/null 2>&1; then
        rm -f "$blk" "$cur"
        trap - EXIT INT TERM
        echo "ℹ️  區塊已是現行版本，未改動: $f"
        return 0
    fi

    LC_ALL=C awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" -v blk="$blk" '
        index($0, B) > 0 {
            while ((getline line < blk) > 0) print line
            close(blk)
            inblock = 1
            next
        }
        inblock { if (index($0, E) > 0) inblock = 0; next }
        { print }
    ' "$f" > "$tmp"

    cp "$f" "$f.knowledge-skill.bak.$TS"
    # 用 cat 寫回而不用 mv：全域指令檔常是指向 ~/.ai-global/AGENTS.md 的 symlink，
    # mv 會把 symlink 換成一般檔案，讓各工具從此不再共用同一份指令檔
    cat "$tmp" > "$f"
    rm -f "$tmp" "$blk" "$cur"
    trap - EXIT INT TERM

    echo "✅ 已更新共用知識庫區塊: ${f}（備份 .knowledge-skill.bak.${TS}）"
}

inject_file() {
    f="$1"

    # 不存在則略過，不建立（避免憑空產生空檔污染專案）
    if [ ! -f "$f" ]; then
        echo "⚠️  檔案不存在，已略過（不建立）: $f"
        return 0
    fi

    # 已有同名區塊：預設略過不覆蓋（避免破壞既有內容），帶 --refresh 才就地更新
    if grep -qF "$MARKER_BEGIN" "$f"; then
        if [ "$REFRESH" -ne 1 ]; then
            echo "⚠️  已存在共用知識庫區塊，已略過（不覆蓋）: $f"
            echo "    如需更新為現行版本，請加上 --refresh 重新執行"
            return 0
        fi
        refresh_file "$f"
        return 0
    fi

    # 於檔頭插入最新區塊
    tmp="$f.kbinject.$$"
    make_block > "$tmp"

    # 若原檔有內容，區塊後補一個空行再接原內容
    if [ -s "$f" ]; then
        printf '\n' >> "$tmp"
        cat "$f" >> "$tmp"
    fi
    # 用 cat 寫回而不用 mv，保留 symlink（理由同 refresh_file）
    cat "$tmp" > "$f"
    rm -f "$tmp"

    echo "✅ 已注入共用知識庫指引: $f"
}

if [ -d "$TARGET" ]; then
    case "$ONLY" in
        AGENTS.md) inject_file "$TARGET/AGENTS.md" ;;
        CLAUDE.md) inject_file "$TARGET/CLAUDE.md" ;;
        GEMINI.md) inject_file "$TARGET/GEMINI.md" ;;
        "")
            inject_file "$TARGET/AGENTS.md"
            inject_file "$TARGET/CLAUDE.md"
            inject_file "$TARGET/GEMINI.md"
            ;;
        *)
            printf '錯誤：第二參數只接受 AGENTS.md、CLAUDE.md 或 GEMINI.md（收到: %s）\n' "$ONLY"
            exit 1
            ;;
    esac
else
    base=$(basename "$TARGET")
    case "$base" in
        AGENTS.md|CLAUDE.md|GEMINI.md) inject_file "$TARGET" ;;
        *)
            echo "錯誤：目標既非現存目錄，檔名也不是 AGENTS.md / CLAUDE.md / GEMINI.md: $TARGET"
            echo "請提供目錄，或路徑結尾為 AGENTS.md / CLAUDE.md / GEMINI.md 的檔案。"
            exit 1
            ;;
    esac
fi

echo ""
echo "📚 已指向知識庫: $KB_DISPLAY"
