#!/bin/sh
# kb-ensure-setup.sh
# 功能：確認本機的知識庫設定是現行做法——把舊版寫進 shell 設定檔的 KNOWLEDGE_BASE_DIR
#       搬到設定檔 ~/.config/knowledge-skill/config，並確保知識庫目錄、六個分類目錄與索引齊全
#       （新裝置上一次建好）。供升級腳本每次執行；已是現行狀態時不改任何檔案。
# 用法：sh kb-ensure-setup.sh [--dry-run] [--yes]
# 參數：
#   --dry-run  只列出會做的變更，不改檔
#   --yes      已取得授權，直接套用（非互動環境必帶，否則中止）
# 流程：
#   1. 掃描 ~/.zshrc、~/.zshenv、~/.bashrc、~/.profile 的 KNOWLEDGE_BASE_DIR 指派
#   2. 值可解析、不是暫存區路徑、且與設定檔不衝突 → 寫入設定檔（已有相同值則不寫），
#      再從 shell 設定檔移除該行與 knowledge-skill 註解行（改前備份）
#   3. 建立缺少的知識庫目錄與 ui／ux／dev／ops／data／else；位置落在暫存區時不建（視為殘留的測試設定）
#   4. 缺 index.md 時呼叫同目錄的 kb-reindex.sh 依知識檔重建（新裝置、或索引未隨雲端同步時）
# 產出：可能改寫 ~/.config/knowledge-skill/config 與上述 shell 設定檔
#       （備份為 <檔案>.knowledge-skill.bak.<timestamp>），可能新增知識庫目錄、分類目錄與索引。
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成或無需變更；1 建立目錄或重建索引失敗；2 有無法自動處理的衝突（未改動該項）；
#         3 未取得授權而中止
set -e

DRY_RUN=0
YES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes) YES=1 ;;
        *) echo "❌ 未知參數：$arg"; echo "用法：sh kb-ensure-setup.sh [--dry-run] [--yes]"; exit 1 ;;
    esac
done

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

TS="$(date +%Y%m%d%H%M%S)"
CONFLICT=0
PLANNED="$(mktemp "${TMPDIR:-/tmp}/kb-ensure-setup.XXXXXX")"
trap 'rm -f "$PLANNED"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# 取一行指派的值並正規化：去成對引號，展開開頭的 ~/、$HOME/、${HOME}/。
# 其餘含 $ 的值（其他變數、命令替換）無法在不執行 shell 的前提下確定，回傳空字串交給呼叫端當衝突。
normalize_value() {
    value="$(printf '%s' "$1" | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
    case "$value" in
        "~/"*) value="$HOME/${value#"~/"}" ;;
        '$HOME/'*) value="$HOME/${value#'$HOME/'}" ;;
        '${HOME}/'*) value="$HOME/${value#'${HOME}/'}" ;;
    esac
    case "$value" in
        *'$'*|*'`'*) value="" ;;
    esac
    printf '%s' "$value"
}

# 暫存區路徑寫進設定檔，目錄被系統清掉後所有工具都會指向不存在的位置
is_volatile_path() {
    case "$1" in
        /tmp|/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
    esac
    return 1
}

confirm() {
    [ "$YES" -eq 1 ] && return 0
    if [ ! -t 0 ]; then
        echo "❌ 非互動環境且未帶 --yes，已中止（未改動任何檔案）。"
        exit 3
    fi
    printf "確定套用上述變更？(y/N): "
    read -r ans || ans=""
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
    esac
    echo "已取消，未改動任何檔案。"
    exit 3
}

# ============================================================
# 步驟 1：盤點 shell 設定檔中的 KNOWLEDGE_BASE_DIR
# ============================================================

RC_HITS=""
RC_VALUE=""
RC_VALUE_OK=1
seen=""
for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.profile"; do
    case " $seen " in *" $rc "*) continue ;; esac
    seen="$seen $rc"
    [ -f "$rc" ] || continue
    lines="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_BASE_DIR=//p' "$rc")"
    [ -n "$lines" ] || continue
    RC_HITS="$RC_HITS $rc"
    # 同一檔多行時 shell 以最後一行為準
    v="$(normalize_value "$(printf '%s\n' "$lines" | tail -n 1)")"
    if [ -z "$v" ]; then
        RC_VALUE_OK=0
        echo "⚠️  $(to_display "$rc") 的 KNOWLEDGE_BASE_DIR 含無法靜態解析的內容，請手動處理。"
    elif [ -n "$RC_VALUE" ] && [ "$v" != "$RC_VALUE" ]; then
        RC_VALUE_OK=0
        printf '⚠️  多個 shell 設定檔的 KNOWLEDGE_BASE_DIR 不一致（%s 與 %s），請手動決定。\n' "$(to_display "$RC_VALUE")" "$(to_display "$v")"
    else
        RC_VALUE="$v"
    fi
done

MIGRATE=0
WRITE_CONFIG=0
if [ -n "$RC_HITS" ]; then
    EXISTING=""
    if [ -f "$KB_CONFIG" ]; then
        EXISTING="$(normalize_value "$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_BASE_DIR=//p' "$KB_CONFIG" | tail -n 1)")"
    fi
    if [ "$RC_VALUE_OK" -eq 0 ]; then
        CONFLICT=1
    elif is_volatile_path "$RC_VALUE" && ! is_volatile_path "$KB_CONFIG"; then
        # 設定檔本身也在暫存區＝換過 HOME 的沙箱，此時指向暫存區是預期行為
        CONFLICT=1
        printf '⚠️  shell 設定檔的 KNOWLEDGE_BASE_DIR 指向暫存區（%s），多半是測試殘留；不搬進設定檔，請確認後手動移除。\n' "$RC_VALUE"
    elif [ -n "$EXISTING" ] && [ "$EXISTING" != "$RC_VALUE" ]; then
        CONFLICT=1
        printf '⚠️  設定檔已指向 %s，shell 設定檔卻是 %s；未改動，請手動決定以哪個為準。\n' "$(to_display "$EXISTING")" "$(to_display "$RC_VALUE")"
    else
        MIGRATE=1
        [ -z "$EXISTING" ] && WRITE_CONFIG=1
        [ "$WRITE_CONFIG" -eq 1 ] && printf '寫入設定檔 %s：KNOWLEDGE_BASE_DIR=%s\n' "$(to_display "$KB_CONFIG")" "$(to_display "$RC_VALUE")" >> "$PLANNED"
        for rc in $RC_HITS; do
            echo "從 $(to_display "$rc") 移除 KNOWLEDGE_BASE_DIR 指派與 knowledge-skill 註解行（先備份）" >> "$PLANNED"
        done
        KB_DIR="$RC_VALUE"
    fi
fi

# ============================================================
# 步驟 2：盤點缺少的知識庫目錄、分類目錄與索引
# ============================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
MISSING_CATS=""
NEED_INDEX=0
if is_volatile_path "$KB_DIR" && ! is_volatile_path "$KB_CONFIG"; then
    # 解析到暫存區多半是殘留的 KNOWLEDGE_BASE_DIR；在那裡建知識庫會讓知識分叉到一個會消失的位置
    CONFLICT=1
    printf '⚠️  知識庫位置落在暫存區（%s，來源：%s），不在此建立或補目錄；請確認是否為殘留的測試設定。\n' "$KB_DIR" "$KB_SOURCE"
else
    [ -d "$KB_DIR" ] || echo "建立知識庫目錄 $(to_display "$KB_DIR")" >> "$PLANNED"
    for category in ui ux dev ops data else; do
        if [ ! -d "$KB_DIR/$category" ]; then
            MISSING_CATS="$MISSING_CATS $category"
            echo "建立分類目錄 $(to_display "$KB_DIR/$category")" >> "$PLANNED"
        fi
    done
    if [ ! -f "$KB_DIR/index.md" ]; then
        NEED_INDEX=1
        echo "以 kb-reindex.sh 建立索引 $(to_display "$KB_DIR/index.md")" >> "$PLANNED"
    fi
fi

# ============================================================
# 步驟 3：列出並套用
# ============================================================

if [ ! -s "$PLANNED" ]; then
    [ "$CONFLICT" -eq 1 ] && exit 2
    echo "✅ 知識庫設定已是現行狀態，無需變更：$(to_display "$KB_DIR")"
    exit 0
fi

echo "將進行以下變更："
sed 's/^/  • /' "$PLANNED"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "（--dry-run：未改動任何檔案）"
    [ "$CONFLICT" -eq 1 ] && exit 2
    exit 0
fi

confirm

if [ "$MIGRATE" -eq 1 ]; then
    if [ "$WRITE_CONFIG" -eq 1 ]; then
        mkdir -p "$(dirname "$KB_CONFIG")"
        if [ ! -f "$KB_CONFIG" ]; then
            cat > "$KB_CONFIG" <<'EOF'
# knowledge-skill 設定檔（由 init-knowledge-base.sh 管理）
# 不會被 shell source；腳本只解析 KNOWLEDGE_BASE_DIR= 與 KNOWLEDGE_AUTO_RECORD= 這兩行，路徑開頭的 ~ 或 $HOME 會展開。
# 解析順序：環境變數 KNOWLEDGE_BASE_DIR > 本檔 > 預設 ~/.knowledge-skill/knowledge
EOF
        fi
        printf 'KNOWLEDGE_BASE_DIR=%s\n' "$(to_display "$RC_VALUE")" >> "$KB_CONFIG"
        echo "✅ 已寫入設定檔：$(to_display "$KB_CONFIG")"
    fi
    for rc in $RC_HITS; do
        cp "$rc" "$rc.knowledge-skill.bak.$TS"
        # LC_ALL=C：shell 設定檔常含中文，macOS awk 在 UTF-8 locale 下比對多位元組字串會失準
        LC_ALL=C awk '
            index($0, "# knowledge-skill: 共用知識庫位置") > 0 { next }
            /^[[:space:]]*(export[[:space:]]+)?KNOWLEDGE_BASE_DIR=/ { next }
            { print }
        ' "$rc" > "$rc.tmp.$$"
        mv "$rc.tmp.$$" "$rc"
        printf '✅ 已從 %s 移除 KNOWLEDGE_BASE_DIR（備份 .knowledge-skill.bak.%s）\n' "$(to_display "$rc")" "$TS"
    done
    echo "ℹ️  已開啟的終端機與編輯器仍帶著舊的環境變數，重開後才改走設定檔。"
fi

for category in $MISSING_CATS; do
    if ! mkdir -p "$KB_DIR/$category"; then
        echo "❌ 無法建立分類目錄：$(to_display "$KB_DIR/$category")"
        exit 1
    fi
    echo "✅ 已建立分類目錄：$(to_display "$KB_DIR/$category")"
done

if [ "$NEED_INDEX" -eq 1 ]; then
    if ! KNOWLEDGE_BASE_DIR="$KB_DIR" sh "$SCRIPT_DIR/kb-reindex.sh" >/dev/null; then
        echo "❌ kb-reindex.sh 建立索引失敗：$(to_display "$KB_DIR/index.md")"
        exit 1
    fi
    echo "✅ 已建立索引：$(to_display "$KB_DIR/index.md")"
fi

[ "$CONFLICT" -eq 1 ] && exit 2
exit 0
