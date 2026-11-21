#!/bin/sh
# kb-repair.sh
# 功能：修復 kb-health.sh 回報中「修法唯一、不需語意判斷」的問題——回填斷裂的取代關係、
#       補上缺少的關係欄位，最後重建索引。需要判斷的項目一律不動，改為列出並指出 code。
# 用法：sh kb-repair.sh [--dry-run] [--yes] [相對路徑...]
# 參數：
#   --dry-run       只列出將進行的修復，不改任何檔案（結束碼 0）
#   --yes           非互動環境明確授權改檔
#   [相對路徑...]   只修復指定的知識檔（相對 knowledge/；停用檔請帶 deprecated/ 前綴）
# 流程：
#   1. 解析 KNOWLEDGE_BASE_DIR 並確認 knowledge 目錄與 index.md 存在
#   2. 掃描生效與停用知識檔，逐項判定可確定性修復或需人工處理
#   3. 列出修復計畫；--dry-run 或無事可做則結束
#   4. 取得授權（--yes 或互動輸入 yes，否則中止 結束碼 3）
#   5. 備份後改檔，最後由 kb-reindex.sh 重建索引
# 產出：改寫知識檔 front matter 的「取代」／「被取代於」；備份至 <KB 上層>/backups/；重建索引
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成（含無事可做與 --dry-run）；1 結構錯誤；3 未取得授權而中止
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
BACKUP_DIR="$(dirname "$KB_DIR")/backups"
TS="$(date +%Y%m%d%H%M%S)"
TAB="$(printf '\t')"

DRY_RUN=0
ASSUME_YES=0
FILTERS=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        -*) echo "❌ 未知參數：$arg"; echo "用法：sh kb-repair.sh [--dry-run] [--yes] [相對路徑...]"; exit 1 ;;
        *) _f="${arg#./}"; FILTERS="$FILTERS$_f
" ;;
    esac
done

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

if [ ! -d "$KB_DIR" ] || [ ! -f "$KB_DIR/index.md" ]; then
    echo "❌ 知識庫不完整（缺目錄或 index.md）：$(to_display "$KB_DIR")"
    echo "   請先執行 init-knowledge-base.sh 建立。"
    exit 1
fi

PLAN="$(mktemp "${TMPDIR:-/tmp}/kb-repair-plan.XXXXXX")"
MANUAL="$(mktemp "${TMPDIR:-/tmp}/kb-repair-manual.XXXXXX")"
ACTIVE_ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-repair-active.XXXXXX")"
DEP_ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-repair-dep.XXXXXX")"
trap 'rm -f "$PLAN" "$MANUAL" "$ACTIVE_ROWS" "$DEP_ROWS"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為 true，
# 少了它每個中文欄位名都會命中第一個分支，取到的值全錯。
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

fm_has() {
    LC_ALL=C awk -v key="$2" '
        BEGIN { fm=0; found=0 }
        NR==1 && $0=="---" { fm=1; next }
        fm && $0=="---" { exit }
        fm {
            i=index($0, ":"); k=substr($0,1,i-1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (i>0 && k==key) { found=1; exit }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# 判準與 kb-health.sh 的 valid_rel_path 一致；兩邊必須同步修改。
valid_rel_path() {
    case "$1" in
        /*|../*|*/../*|*/..|deprecated/*) return 1 ;;
    esac
    case "$1" in
        ui/*.md|ux/*.md|dev/*.md|ops/*.md|data/*.md|else/*.md) return 0 ;;
        *) return 1 ;;
    esac
}

# 無過濾參數時全收；有過濾時只收被點名的路徑（停用檔以 deprecated/ 前綴表示）。
selected() {
    [ -z "$FILTERS" ] && return 0
    printf '%s' "$FILTERS" | grep -Fxq "$1"
}

add_plan() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$PLAN"
}

add_manual() {
    printf '   • %s [%s] %s\n' "$1" "$2" "$3" >> "$MANUAL"
}

find "$KB_DIR" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
    | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "${f#"$KB_DIR"/}"; done > "$ACTIVE_ROWS"
if [ -d "$DEP_DIR" ]; then
    find "$DEP_DIR" -type f -name '*.md' ! -name 'index.md' 2>/dev/null \
        | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "${f#"$DEP_DIR"/}"; done > "$DEP_ROWS"
fi

# 計算有幾個生效知識宣稱取代某個停用檔。兩個以上時無從判定該由誰回填，只能交人工。
count_claimers() {
    _target="$1"; _n=0
    while IFS= read -r _rel; do
        [ -z "$_rel" ] && continue
        [ "$(fm_value "$KB_DIR/$_rel" "取代")" = "$_target" ] && _n=$((_n + 1))
    done < "$ACTIVE_ROWS"
    printf '%s' "$_n"
}

# ---- 掃描生效知識 ----
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    file="$KB_DIR/$rel"
    selected "$rel" || continue

    for key in "取代" "被取代於"; do
        fm_has "$file" "$key" || add_plan "$rel" "frontmatter_missing" "$key" "-"
    done

    superseded_by="$(fm_value "$file" "被取代於")"
    if [ -n "$superseded_by" ] && [ "$superseded_by" != "-" ]; then
        # 修法有兩個相反方向（清成 - ／把檔案移進 deprecated/），不可臆測。
        add_manual "$rel" "active_marked_superseded" "生效知識被標記為已取代，請確認應清除標記或改為停用"
    fi

    supersede="$(fm_value "$file" "取代")"
    [ -z "$supersede" ] && continue
    [ "$supersede" = "-" ] && continue
    if ! valid_rel_path "$supersede"; then
        add_manual "$rel" "supersede_target_invalid" "取代欄位不是合法知識相對路徑：$supersede"
        continue
    fi
    if [ ! -f "$DEP_DIR/$supersede" ]; then
        add_manual "$rel" "supersede_target_missing" "取代指向的停用知識不存在：$supersede"
        continue
    fi
    current="$(fm_value "$DEP_DIR/$supersede" "被取代於")"
    [ "$current" = "$rel" ] && continue
    if [ -n "$current" ] && [ "$current" != "-" ]; then
        add_manual "$rel" "supersede_not_reciprocal" \
            "deprecated/$supersede 已登記被 $current 取代，與本檔的宣告衝突"
        continue
    fi
    if [ "$(count_claimers "$supersede")" -gt 1 ]; then
        add_manual "$rel" "supersede_not_reciprocal" \
            "有多個生效知識都宣稱取代 $supersede，無從判定該回填哪一個"
        continue
    fi
    add_plan "deprecated/$supersede" "supersede_not_reciprocal" "被取代於" "$rel"
done < "$ACTIVE_ROWS"

# ---- 掃描停用知識 ----
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    file="$DEP_DIR/$rel"
    full_rel="deprecated/$rel"
    selected "$full_rel" || continue

    for key in "取代" "被取代於"; do
        fm_has "$file" "$key" || add_plan "$full_rel" "frontmatter_missing" "$key" "-"
    done

    target="$(fm_value "$file" "被取代於")"
    if [ -z "$target" ] || [ "$target" = "-" ]; then
        # 唯一一個生效知識宣稱取代它時可確定性回填，那筆計畫已在上一段產生；
        # 這裡只處理無人宣稱或多人宣稱的情形。
        claimers="$(count_claimers "$rel")"
        [ "$claimers" -eq 1 ] && continue
        if [ "$claimers" -eq 0 ]; then
            add_manual "$full_rel" "superseded_by_missing" "沒有任何生效知識宣稱取代它，需人工指定"
        else
            add_manual "$full_rel" "superseded_by_missing" "有 $claimers 個生效知識宣稱取代它，需人工判定"
        fi
        continue
    fi
    if ! valid_rel_path "$target"; then
        add_manual "$full_rel" "superseded_by_target_invalid" "被取代於不是合法知識相對路徑：$target"
        continue
    fi
    if [ ! -f "$KB_DIR/$target" ]; then
        add_manual "$full_rel" "superseded_by_target_missing" "被取代於指向的生效知識不存在：$target"
        continue
    fi
    current="$(fm_value "$KB_DIR/$target" "取代")"
    [ "$current" = "$rel" ] && continue
    if [ -n "$current" ] && [ "$current" != "-" ]; then
        add_manual "$full_rel" "superseded_by_not_reciprocal" \
            "$target 已登記取代 $current，與本檔的宣告衝突"
        continue
    fi
    add_plan "$target" "superseded_by_not_reciprocal" "取代" "$rel"
done < "$DEP_ROWS"

echo "📍 知識庫：$(to_display "$KB_DIR")"

PLAN_COUNT="$(wc -l < "$PLAN" | tr -d ' ')"
MANUAL_COUNT="$(wc -l < "$MANUAL" | tr -d ' ')"

if [ "$PLAN_COUNT" -gt 0 ]; then
    echo "🔧 可確定性修復 $PLAN_COUNT 項："
    awk -F'\t' '{ printf "   • %s [%s] 將把「%s」設為：%s\n", $1, $2, $3, $4 }' "$PLAN"
fi
if [ "$MANUAL_COUNT" -gt 0 ]; then
    echo "🙋 需人工或 AI 判斷 $MANUAL_COUNT 項（本腳本不處理）："
    cat "$MANUAL"
fi

if [ "$PLAN_COUNT" -eq 0 ]; then
    echo "✅ 沒有可自動修復的項目。"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "ℹ️  --dry-run：未變更任何內容。"
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "確定套用上述修復？（輸入 yes 確認）： "
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

# 設定 front matter 單一欄位（存在則覆寫該欄，無 front matter 則前置一段最小區塊）。
# 與 kb-supersede.sh 的 set_frontmatter 同一份寫法，LC_ALL=C 同樣不可省略。
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

mkdir -p "$BACKUP_DIR"
BACKED_UP=""
backup_once() {
    _rel="$1"
    printf '%s' "$BACKED_UP" | grep -Fxq "$_rel" && return 0
    cp "$KB_DIR/$_rel" "$BACKUP_DIR/repair-$(printf '%s' "$_rel" | tr '/' '-')-$TS.md"
    BACKED_UP="$BACKED_UP$_rel
"
}

CHANGED=0
while IFS="$TAB" read -r rel code key val; do
    [ -z "$rel" ] && continue
    backup_once "$rel"
    set_frontmatter "$KB_DIR/$rel" "$key" "$val"
    echo "✅ $rel：「$key」已設為 $val（$code）"
    CHANGED=$((CHANGED + 1))
done < "$PLAN"

echo "🔁 重建索引…"
sh "$SCRIPT_DIR/kb-reindex.sh"
echo "📊 已修復 $CHANGED 項；仍有 $MANUAL_COUNT 項需人工或 AI 判斷。"
