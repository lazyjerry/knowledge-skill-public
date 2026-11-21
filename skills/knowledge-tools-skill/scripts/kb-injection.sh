#!/bin/sh
# kb-injection.sh
# 功能：維運各 AI 指令檔（AGENTS.md / CLAUDE.md / GEMINI.md）中的「共用知識庫優先參考」
#       注入區塊——檢視哪些檔案的區塊已落後、首次注入，並就地更新為現行版本。
#       讓只裝了 skill（未 clone repo）的使用者也能完成首次注入；
#       repo 的 scripts/init-injection.sh 保留給未裝 skill 的遠端單檔執行。
# 用法：sh kb-injection.sh [list [目標路徑]|inject <檔案路徑> [--create] [--yes]|update <檔案路徑> [--yes]]
# 參數：
#   無參數 / list [目標路徑]  唯讀列出各指令檔的區塊狀態；即使 stdin 是 tty 也不讀取
#                             目標路徑可為目錄（檢查其下三個檔名）或單一 .md 檔，預設檢查全域指令檔
#   inject <檔案路徑>         在檔頭插入現行區塊；已有區塊則不動（落後時提示改用 update）
#   --create                  （僅 inject）檔案不存在時建立；只接受四個全域指令檔，且工具目錄需已存在
#   update <檔案路徑>         就地以現行區塊取代該檔既有區塊（保留區塊原位置）
#   --yes                     非互動環境明確授權改檔
# 流程：
#   1. 依 KNOWLEDGE_BASE_DIR 產生現行區塊文字
#   2. (list) 逐檔比對既有區塊與現行區塊，回報「無區塊／需更新／最新」；全域模式另列「未建立」
#   3. (inject) 取得授權 → 備份原檔 → 區塊置於檔頭、原內容接在其後
#   4. (update) 取得授權 → 備份原檔 → 以 awk 置換 BEGIN…END 之間內容
# 產出：inject／update 時改寫目標檔，並留下 <目標檔>.knowledge-skill.bak.<timestamp> 備份
#       （inject 新建的檔案沒有原檔，不留備份）
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成（含唯讀列表、inject 遇既有區塊）；1 參數錯誤、檔案不存在、無既有區塊（update）
#         或不允許建立（inject --create）；3 未取得授權而中止
#
# ⚠️ make_block() 的文字必須與 repo 的 scripts/init-injection.sh 逐字相同（兩者各自散佈：
#    skill 目錄可獨立安裝，init-injection.sh 支援單檔遠端執行，無法共用同一份來源）。
#    修改任一邊後執行 test-injection-block.sh 驗證兩者仍一致。
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
KB_RAW="$KB_DIR"
# 顯示用路徑：把家目錄前綴換回 ~，避免寫死絕對家目錄（檔案可能被 commit）
case "$KB_RAW" in
    "$HOME") KB_DISPLAY="~" ;;
    "$HOME"/*) KB_DISPLAY="~/${KB_RAW#"$HOME"/}" ;;
    *) KB_DISPLAY="$KB_RAW" ;;
esac

MARKER_BEGIN="<!-- BEGIN knowledge-skill:shared-kb -->"
MARKER_END="<!-- END knowledge-skill:shared-kb -->"
TS="$(date +%Y%m%d%H%M%S)"

TMP_BLOCK=""
TMP_OUT=""
cleanup() {
    [ -n "$TMP_BLOCK" ] && rm -f "$TMP_BLOCK"
    [ -n "$TMP_OUT" ] && rm -f "$TMP_OUT"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# 取出檔案中既有的區塊（含前後標記行）；無區塊則無輸出
# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較多位元組字串會失準，
# 而這些指令檔通篇中文，需確保標記比對走位元組語意。
extract_block() {
    LC_ALL=C awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" '
        index($0, B) > 0 { inblock=1 }
        inblock { print }
        inblock && index($0, E) > 0 { exit }
    ' "$1"
}

# 狀態：none（無區塊）／stale（需更新）／current（最新）
block_status() {
    if ! grep -qF "$MARKER_BEGIN" "$1"; then
        echo "none"
        return 0
    fi
    if extract_block "$1" | diff -q - "$TMP_BLOCK" >/dev/null 2>&1; then
        echo "current"
    else
        echo "stale"
    fi
}

# 依目標參數決定要檢查的檔案清單；未指定則檢查常用 AI 工具全域指令檔
collect_targets() {
    target="${1:-}"
    if [ -z "$target" ]; then
        printf '%s\n' \
            "$HOME/.codex/AGENTS.md" \
            "$HOME/.claude/CLAUDE.md" \
            "$HOME/.gemini/GEMINI.md" \
            "$HOME/.ai-global/AGENTS.md"
        return 0
    fi
    if [ -d "$target" ]; then
        printf '%s\n' "$target/AGENTS.md" "$target/CLAUDE.md" "$target/GEMINI.md"
        return 0
    fi
    printf '%s\n' "$target"
}

# 只有四個全域指令檔允許 inject --create：專案目錄的指令檔不憑空建立，避免污染專案
is_global_target() {
    collect_targets "" | grep -qxF "$1"
}

# 可建立的條件：全域指令檔、工具目錄已存在（代表有在用該工具）、不是失效的 symlink
can_create() {
    is_global_target "$1" || return 1
    [ -d "$(dirname "$1")" ] || return 1
    if [ -L "$1" ] && [ ! -e "$1" ]; then
        return 1
    fi
    return 0
}

print_list() {
    # 變數後面緊接全形字元時一定要加大括號：bash 3.2（macOS /bin/sh）會把後續多位元組
    # 字元的位元組吃進變數名，`$KB_DISPLAY）` 會展開成空字串並吃掉半個「）」。
    echo "📚 共用知識庫注入區塊狀態（知識庫：${KB_DISPLAY}）："
    stale_count=0
    none_count=0
    missing_count=0
    found=0
    list_target="${1:-}"
    targets="$(collect_targets "$list_target")"
    # 以換行切分，避免含空白的路徑被 word splitting 拆開
    old_ifs="$IFS"
    IFS='
'
    for f in $targets; do
        IFS="$old_ifs"
        if [ ! -f "$f" ]; then
            # 全域模式下，工具目錄已在但指令檔還沒建：首次安裝的常見狀態，列出供 inject --create
            if [ -z "$list_target" ] && can_create "$f"; then
                missing_count=$((missing_count + 1))
                printf '  🆕 未建立 %s\n' "$(to_display "$f")"
            fi
            continue
        fi
        found=$((found + 1))
        case "$(block_status "$f")" in
            current) printf '  ✅ 最新   %s\n' "$(to_display "$f")" ;;
            stale)
                stale_count=$((stale_count + 1))
                printf '  ⚠️  需更新 %s\n' "$(to_display "$f")"
                ;;
            none)
                none_count=$((none_count + 1))
                printf '  ➖ 無區塊 %s\n' "$(to_display "$f")"
                ;;
        esac
    done
    IFS="$old_ifs"

    if [ "$found" -eq 0 ] && [ "$missing_count" -eq 0 ]; then
        echo "  （找不到可檢查的 AGENTS.md / CLAUDE.md / GEMINI.md）"
        return 0
    fi
    if [ "$stale_count" -gt 0 ] || [ "$none_count" -gt 0 ] || [ "$missing_count" -gt 0 ]; then
        echo ""
    fi
    if [ "$stale_count" -gt 0 ]; then
        printf 'ℹ️  %s 份需更新，逐份執行：sh kb-injection.sh update <檔案路徑> --yes\n' "$stale_count"
    fi
    if [ "$none_count" -gt 0 ]; then
        printf 'ℹ️  %s 份尚未注入，逐份執行：sh kb-injection.sh inject <檔案路徑> --yes\n' "$none_count"
    fi
    if [ "$missing_count" -gt 0 ]; then
        printf 'ℹ️  %s 份尚未建立，要建立並注入時執行：sh kb-injection.sh inject <檔案路徑> --create --yes\n' "$missing_count"
    fi
    return 0
}

update_file() {
    f="$1"
    assume_yes="$2"

    if [ ! -f "$f" ]; then
        printf '❌ 檔案不存在：%s\n' "$(to_display "$f")"
        return 1
    fi
    if ! grep -qF "$MARKER_BEGIN" "$f"; then
        printf '❌ 檔案沒有共用知識庫區塊，本命令只負責更新：%s\n' "$(to_display "$f")"
        echo "   首次注入請用：sh kb-injection.sh inject <檔案路徑> --yes"
        return 1
    fi
    if [ "$(block_status "$f")" = "current" ]; then
        printf 'ℹ️  區塊已是最新，未改動：%s\n' "$(to_display "$f")"
        return 0
    fi

    if [ "$assume_yes" -ne 1 ]; then
        if [ -t 0 ]; then
            printf "確定更新「%s」的注入區塊？（輸入 yes 確認）： " "$(to_display "$f")"
            read -r ans || ans=""
            if [ "$ans" != "yes" ]; then
                echo "已取消，未改動任何內容。"
                return 3
            fi
        else
            echo "⚠️  非互動環境且未帶 --yes，已中止，未改動任何內容。"
            return 3
        fi
    fi

    TMP_OUT="$f.kbinject.$$"
    # 就地置換：保留區塊在檔案中的原位置，區塊外的內容原樣保留
    LC_ALL=C awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" -v blk="$TMP_BLOCK" '
        index($0, B) > 0 {
            while ((getline line < blk) > 0) print line
            close(blk)
            inblock = 1
            next
        }
        inblock { if (index($0, E) > 0) inblock = 0; next }
        { print }
    ' "$f" > "$TMP_OUT"

    cp "$f" "$f.knowledge-skill.bak.$TS"
    # 用 cat 寫回而不用 mv，保留 symlink（理由同 inject_file）
    cat "$TMP_OUT" > "$f"
    rm -f "$TMP_OUT"
    TMP_OUT=""
    printf '✅ 已更新注入區塊：%s（備份 .knowledge-skill.bak.%s）\n' "$(to_display "$f")" "$TS"
    return 0
}

# 首次注入：區塊置於檔頭，原內容接在其後；已有區塊則不動，交給 update
inject_file() {
    f="$1"
    assume_yes="$2"
    allow_create="$3"

    case "$(basename "$f")" in
        AGENTS.md|CLAUDE.md|GEMINI.md) ;;
        *)
            printf '❌ 只接受 AGENTS.md / CLAUDE.md / GEMINI.md：%s\n' "$(to_display "$f")"
            return 1
            ;;
    esac

    created=0
    if [ ! -f "$f" ]; then
        if [ "$allow_create" -ne 1 ]; then
            printf '❌ 檔案不存在：%s\n' "$(to_display "$f")"
            if can_create "$f"; then
                echo "   這是全域指令檔，要建立並注入請加上 --create。"
            fi
            return 1
        fi
        if ! can_create "$f"; then
            printf '❌ 不允許建立：%s\n' "$(to_display "$f")"
            echo "   --create 只接受全域指令檔（~/.codex/AGENTS.md、~/.claude/CLAUDE.md、~/.gemini/GEMINI.md、~/.ai-global/AGENTS.md），"
            echo "   且該工具目錄需已存在；失效的 symlink 不建立。"
            return 1
        fi
        created=1
    elif grep -qF "$MARKER_BEGIN" "$f"; then
        if [ "$(block_status "$f")" = "current" ]; then
            printf 'ℹ️  已有區塊且為最新，未改動：%s\n' "$(to_display "$f")"
        else
            printf 'ℹ️  已有區塊但需更新，未改動：%s\n' "$(to_display "$f")"
            echo "   請改用：sh kb-injection.sh update <檔案路徑> --yes"
        fi
        return 0
    fi

    if [ "$assume_yes" -ne 1 ]; then
        if [ -t 0 ]; then
            if [ "$created" -eq 1 ]; then
                printf "確定建立「%s」並注入共用知識庫區塊？（輸入 yes 確認）： " "$(to_display "$f")"
            else
                printf "確定在「%s」檔頭注入共用知識庫區塊？（輸入 yes 確認）： " "$(to_display "$f")"
            fi
            read -r ans || ans=""
            if [ "$ans" != "yes" ]; then
                echo "已取消，未改動任何內容。"
                return 3
            fi
        else
            echo "⚠️  非互動環境且未帶 --yes，已中止，未改動任何內容。"
            return 3
        fi
    fi

    TMP_OUT="$f.kbinject.$$"
    cat "$TMP_BLOCK" > "$TMP_OUT"
    if [ "$created" -eq 0 ] && [ -s "$f" ]; then
        printf '\n' >> "$TMP_OUT"
        cat "$f" >> "$TMP_OUT"
    fi
    if [ "$created" -eq 0 ]; then
        cp "$f" "$f.knowledge-skill.bak.$TS"
    fi
    # 用 cat 寫回而不用 mv：全域指令檔常是指向 ~/.ai-global/AGENTS.md 的 symlink，
    # mv 會把 symlink 換成一般檔案，讓各工具從此不再共用同一份指令檔
    cat "$TMP_OUT" > "$f"
    rm -f "$TMP_OUT"
    TMP_OUT=""

    if [ "$created" -eq 1 ]; then
        printf '✅ 已建立並注入共用知識庫區塊：%s\n' "$(to_display "$f")"
    else
        printf '✅ 已注入共用知識庫區塊：%s（備份 .knowledge-skill.bak.%s）\n' "$(to_display "$f")" "$TS"
    fi
    return 0
}

COMMAND=""
TARGET=""
ASSUME_YES=0
ALLOW_CREATE=0
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --create) ALLOW_CREATE=1 ;;
        list|inject|update) [ -z "$COMMAND" ] && COMMAND="$arg" ;;
        "") ;;
        *) TARGET="$arg" ;;
    esac
done
[ -z "$COMMAND" ] && COMMAND="list"

TMP_BLOCK="$(mktemp "${TMPDIR:-/tmp}/kb-injection-block.XXXXXX")"
make_block > "$TMP_BLOCK"

case "$COMMAND" in
    list)
        print_list "$TARGET"
        ;;
    update)
        if [ -z "$TARGET" ]; then
            echo "❌ update 需指定檔案路徑：sh kb-injection.sh update <檔案路徑> [--yes]"
            exit 1
        fi
        RESULT=0
        update_file "$TARGET" "$ASSUME_YES" || RESULT=$?
        echo ""
        print_list "$TARGET"
        exit "$RESULT"
        ;;
    inject)
        if [ -z "$TARGET" ]; then
            echo "❌ inject 需指定檔案路徑：sh kb-injection.sh inject <檔案路徑> [--create] [--yes]"
            exit 1
        fi
        RESULT=0
        inject_file "$TARGET" "$ASSUME_YES" "$ALLOW_CREATE" || RESULT=$?
        echo ""
        print_list "$TARGET"
        exit "$RESULT"
        ;;
esac
