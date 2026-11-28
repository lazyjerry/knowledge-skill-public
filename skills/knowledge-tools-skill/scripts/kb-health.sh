#!/bin/sh
# kb-health.sh
# 功能：以確定性規則檢查共用知識庫的索引、MADR 結構與取代關係，並留下可追溯結果。
# 用法：sh kb-health.sh [--format text|json] [--source cli|tray|ui]
# 產出：stdout 為文字或 JSON；另寫入 $HOME/.knowledge-skill/logs/health/{latest.json,history.jsonl}。
# 結束碼：0 健康；1 執行或結構錯誤；2 發現不健康項目。
set -e
export LC_ALL=C

FORMAT="text"
SOURCE="cli"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --format)
            [ "$#" -ge 2 ] || { echo "❌ --format 缺少值" >&2; exit 1; }
            FORMAT="$2"
            shift 2
            ;;
        --source)
            [ "$#" -ge 2 ] || { echo "❌ --source 缺少值" >&2; exit 1; }
            SOURCE="$2"
            shift 2
            ;;
        *) echo "❌ 未知參數：$1" >&2; exit 1 ;;
    esac
done

case "$FORMAT" in text|json) ;; *) echo "❌ --format 只接受 text 或 json" >&2; exit 1 ;; esac
case "$SOURCE" in cli|tray|ui) ;; *) echo "❌ --source 只接受 cli、tray 或 ui" >&2; exit 1 ;; esac

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
INDEX="$KB_DIR/index.md"
DEP_DIR="$KB_DIR/deprecated"
DEP_INDEX="$DEP_DIR/index.md"
LOG_DIR="$HOME/.knowledge-skill/logs/health"
TAB="$(printf '\t')"

if [ ! -d "$KB_DIR" ] || [ ! -f "$INDEX" ]; then
    if [ "$FORMAT" = "json" ]; then
        printf '{"version":1,"error":"知識庫不完整（缺目錄或 index.md）","path":"%s"}\n' "$KB_DIR"
    else
        echo "❌ 知識庫不完整（缺目錄或 index.md）：$KB_DIR"
    fi
    exit 1
fi

FINDINGS="$(mktemp "${TMPDIR:-/tmp}/kb-health-findings.XXXXXX")"
INDEX_ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-health-index.XXXXXX")"
DISK_ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-health-disk.XXXXXX")"
DEP_INDEX_ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-health-dep-index.XXXXXX")"
DEP_DISK_ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-health-dep-disk.XXXXXX")"
RESULT="$(mktemp "${TMPDIR:-/tmp}/kb-health-result.XXXXXX")"
trap 'rm -f "$FINDINGS" "$INDEX_ROWS" "$DISK_ROWS" "$DEP_INDEX_ROWS" "$DEP_DISK_ROWS" "$RESULT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

add_finding() {
    # 欄位不得含 tab/newline；訊息皆為本腳本固定文字，path 另外正規化空白。
    clean_path="$(printf '%s' "$1" | tr '\t\r\n' '   ')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$clean_path" "$2" "$3" "$4" "$5" >> "$FINDINGS"
}

parse_index() {
    LC_ALL=C awk -F'|' '
        NF >= 4 {
            cell=$2; trigger=$3; summary=$4
            gsub(/^[ \t]+|[ \t]+$/, "", cell)
            gsub(/^[ \t]+|[ \t]+$/, "", trigger)
            gsub(/^[ \t]+|[ \t]+$/, "", summary)
            if (cell=="知識" || cell ~ /^-+$/ || cell ~ /^<!--/) next
            if (match(cell, /\]\([^)]*\)$/)) {
                path=substr(cell, RSTART+2, RLENGTH-3)
                title=substr(cell, 1, RSTART-1)
                sub(/^\[/, "", title)
                gsub(/\t/, " ", title); gsub(/\t/, " ", trigger); gsub(/\t/, " ", summary)
                print path "\t" title "\t" trigger "\t" summary
            }
        }
    ' "$1"
}

# 走訪一棵知識樹的兩層索引（頂層 index.md 與各分類 {分類}/index.md），輸出格式同
# parse_index，但路徑一律補成相對該樹根目錄——子索引登錄的是相對該分類目錄的檔名，
# 後續的雙向比對才不必分辨資料來自哪一層。舊的單層索引前綴為空，自然相容。
# $1 樹根目錄、$2 模式（active 需排除 deprecated/ 子樹；deprecated 走完整棵）
collect_index_rows() {
    _root="$1"; _mode="$2"
    if [ "$_mode" = "active" ]; then
        find "$_root" -type f -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null
    else
        find "$_root" -type f -name 'index.md' 2>/dev/null
    fi | LC_ALL=C sort | while IFS= read -r idx; do
        _dir="$(dirname "${idx#"$_root"/}")"
        parse_index "$idx" | while IFS= read -r row; do
            if [ "$_dir" = "." ]; then
                printf '%s\n' "$row"
            else
                printf '%s/%s\n' "$_dir" "$row"
            fi
        done
    done
}

fm_value() {
    awk -v key="$2" '
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
    awk -v key="$2" '
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

section_count() {
    awk -v heading="$2" '
        {
            line=$0; sub(/^[ \t]+/, "", line)
            if (line ~ /^```/ || line ~ /^~~~/) { fence=!fence; next }
            if (!fence && $0 == "## " heading) n++
        }
        END { print n+0 }
    ' "$1"
}

section_body() {
    awk -v heading="$2" '
        {
            line=$0; sub(/^[ \t]+/, "", line)
            is_fence=(line ~ /^```/ || line ~ /^~~~/)
            if (!fence && $0 == "## " heading) { in_section=1; next }
            if (in_section && !fence && /^## /) exit
            if (in_section) body = body $0 "\n"
            if (is_fence) fence=!fence
        }
        END { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", body); print body }
    ' "$1"
}

first_line() {
    section_body "$1" "$2" | awk 'NF { print; exit }'
}

is_placeholder() {
    case "$1" in
        \[*\]|*"[知識主題]"*|*"[何時應參考"*|*"[一句話描述"*|*"[背景與要解決"*|*"[選項 A]"*|*"[選擇哪個選項"*|*"[好處 / 壞處]"*|*"[來源任務"*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_rel_path() {
    case "$1" in
        /*|../*|*/../*|*/..|deprecated/*) return 1 ;;
    esac
    case "$1" in
        ui/*.md|ux/*.md|dev/*.md|ops/*.md|data/*.md|else/*.md) return 0 ;;
        *) return 1 ;;
    esac
}

# 把知識檔的欄位值轉成它「寫進索引後」應有的樣子，供 stale 比對。
#
# 索引是 Markdown 表格，欄位值裡的 `|` 會打斷欄位，故 kb-reindex.sh 的 parse_fields
# 一律把它換成 `/` 才寫入。比對若拿 front matter 原值，含 `|` 的知識檔就會永遠 stale：
# reindex 只是把索引重寫成一模一樣的內容，使用者按幾次「重新整理索引」都消不掉。
# 正規化規則的真源是 kb-reindex.sh 的 parse_fields，兩邊必須同步修改。
normalize_cell() {
    printf '%s' "$1" | tr '|' '/'
}

check_index_matches_file() {
    rel="$1"; scope="$2"; file="$3"; row_file="$4"
    row_exists="$(awk -F'\t' -v p="$rel" '$1==p { print 1; exit }' "$row_file")"
    [ "$row_exists" = "1" ] || return 0
    index_title="$(awk -F'\t' -v p="$rel" '$1==p { print $2; exit }' "$row_file")"
    index_trigger="$(awk -F'\t' -v p="$rel" '$1==p { print $3; exit }' "$row_file")"
    index_summary="$(awk -F'\t' -v p="$rel" '$1==p { print $4; exit }' "$row_file")"
    file_title="$(normalize_cell "$(fm_value "$file" "標題")")"
    file_trigger="$(normalize_cell "$(fm_value "$file" "觸發時機")")"
    file_summary="$(normalize_cell "$(first_line "$file" "摘要")")"
    [ "$index_title" = "$file_title" ] || add_finding "$rel" "$scope" "index_title_stale" "索引標題與知識檔不一致" "edit,reindex"
    [ "$index_trigger" = "$file_trigger" ] || add_finding "$rel" "$scope" "index_trigger_stale" "索引觸發時機與知識檔不一致" "edit,reindex"
    [ "$index_summary" = "$file_summary" ] || add_finding "$rel" "$scope" "index_summary_stale" "索引摘要與知識檔不一致" "edit,reindex"
}

collect_index_rows "$KB_DIR" "active" > "$INDEX_ROWS"
find "$KB_DIR" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null \
    | LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "${file#"$KB_DIR"/}"; done > "$DISK_ROWS"

if [ -f "$DEP_INDEX" ]; then
    collect_index_rows "$DEP_DIR" "deprecated" > "$DEP_INDEX_ROWS"
fi
if [ -d "$DEP_DIR" ]; then
    find "$DEP_DIR" -type f -name '*.md' ! -name 'index.md' 2>/dev/null \
        | LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "${file#"$DEP_DIR"/}"; done > "$DEP_DISK_ROWS"
fi

# 索引結構是否已是兩層。
#
# 為什麼需要這個檢查：索引解析對舊的單層全量索引刻意向後相容（讀得到、不報錯），代價是
# 停在舊結構完全沒有徵兆——健康檢查全綠、tray 清單照常顯示，使用者不會知道該重建。
# 落後版本的 kb-reindex.sh 也會把兩層索引整份寫回單層，同樣需要被指出來。
#
# 判準：頂層索引直接登錄了「路徑含目錄分隔符」的知識連結。兩層結構下頂層只有分類目錄
# （第一欄非連結，解析不出條目），唯一的例外是根目錄的未分類知識，其路徑不含 /。
is_single_tier_index() {
    parse_index "$INDEX" | awk -F'\t' '$1 ~ /\// { found=1 } END { exit found ? 0 : 1 }'
}
if is_single_tier_index; then
    add_finding "index.md" "index" "index_single_tier" \
        "索引仍是舊的單層結構，請重建為兩層（頂層分類目錄 + 各分類子索引）" "reindex"
fi

# 索引與磁碟的雙向一致性。
while IFS="$TAB" read -r rel _rest; do
    [ -z "$rel" ] && continue
    [ -f "$KB_DIR/$rel" ] || add_finding "$rel" "index" "broken_link" "索引有登錄但檔案不存在" "reindex"
done < "$INDEX_ROWS"
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    awk -F'\t' -v p="$rel" '$1==p { found=1 } END { exit found ? 0 : 1 }' "$INDEX_ROWS" || \
        add_finding "$rel" "active" "orphan_file" "檔案存在但生效索引未登錄" "edit,delete,reindex"
done < "$DISK_ROWS"

if [ -s "$DEP_DISK_ROWS" ] && [ ! -f "$DEP_INDEX" ]; then
    add_finding "deprecated/index.md" "index" "deprecated_index_missing" "停用知識存在但缺少 deprecated/index.md" "reindex"
fi
while IFS="$TAB" read -r rel _rest; do
    [ -z "$rel" ] && continue
    [ -f "$DEP_DIR/$rel" ] || add_finding "deprecated/$rel" "index" "deprecated_broken_link" "停用索引有登錄但檔案不存在" "reindex"
done < "$DEP_INDEX_ROWS"
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    awk -F'\t' -v p="$rel" '$1==p { found=1 } END { exit found ? 0 : 1 }' "$DEP_INDEX_ROWS" || \
        add_finding "deprecated/$rel" "deprecated" "deprecated_orphan_file" "停用檔案存在但停用索引未登錄" "edit,reindex"
done < "$DEP_DISK_ROWS"

# 生效知識：完整 MADR 結構、內容、索引欄位與取代關係。
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    file="$KB_DIR/$rel"
    valid_rel_path "$rel" || add_finding "$rel" "active" "invalid_category" "知識檔不在允許的分類路徑" "edit,delete"

    title="$(fm_value "$file" "標題")"
    trigger="$(fm_value "$file" "觸發時機")"
    supersede="$(fm_value "$file" "取代")"
    superseded_by="$(fm_value "$file" "被取代於")"
    # 只有兩個關係欄位（`-`）與狀態（人工審核確認）補得出確定性預設值；標題與觸發時機的
    # 內容無從代填，故不宣告 repair，避免使用者按了修復卻發現這兩項原地不動。
    for key in "標題" "觸發時機"; do
        fm_has "$file" "$key" || add_finding "$rel" "active" "frontmatter_missing" "front matter 缺少欄位：$key" "edit,delete"
    done
    for key in "取代" "被取代於" "狀態"; do
        fm_has "$file" "$key" || add_finding "$rel" "active" "frontmatter_missing" "front matter 缺少欄位：$key" "edit,delete,repair"
    done
    # 狀態只由 kb-promote.sh 與 kb-auto.sh 寫入；出現其他值代表被手改過，兩種狀態都說得通，
    # 不宣告 repair。
    if fm_has "$file" "狀態"; then
        case "$(fm_value "$file" "狀態")" in
            "AI 自動確認"|"人工審核確認") ;;
            *) add_finding "$rel" "active" "invalid_status" "狀態必須是「AI 自動確認」或「人工審核確認」" "edit" ;;
        esac
    fi
    if [ -z "$title" ] || is_placeholder "$title"; then
        add_finding "$rel" "active" "invalid_title" "標題不可空白或保留範本文字" "edit,delete"
    fi
    if [ -z "$trigger" ] || is_placeholder "$trigger"; then
        add_finding "$rel" "active" "invalid_trigger" "觸發時機不可空白或保留範本文字" "edit,delete"
    fi
    if [ -n "$superseded_by" ] && [ "$superseded_by" != "-" ]; then
        add_finding "$rel" "active" "active_marked_superseded" "生效知識的被取代於必須為 -" "edit,delete"
    fi

    for heading in "摘要" "脈絡與問題陳述" "決策驅力" "考量選項" "各選項利弊" "決策結果" "影響" "驗證" "補充資訊"; do
        count="$(section_count "$file" "$heading")"
        if [ "$count" -ne 1 ]; then
            add_finding "$rel" "active" "section_count" "MADR 段落「$heading」必須恰好出現一次" "edit,delete"
            continue
        fi
        body="$(section_body "$file" "$heading")"
        if [ -z "$body" ] || is_placeholder "$body"; then
            add_finding "$rel" "active" "section_content" "MADR 段落「$heading」不可空白或保留範本文字" "edit,delete"
            continue
        fi
        case "$heading" in
            "決策驅力"|"各選項利弊"|"驗證") ;;
            *) [ "$body" != "-" ] || add_finding "$rel" "active" "section_content" "MADR 段落「$heading」不可只填 -" "edit,delete" ;;
        esac
    done

    check_index_matches_file "$rel" "active" "$file" "$INDEX_ROWS"
    if [ -n "$supersede" ] && [ "$supersede" != "-" ]; then
        if ! valid_rel_path "$supersede"; then
            add_finding "$rel" "active" "supersede_target_invalid" "取代欄位不是合法知識相對路徑：$supersede" "edit"
        elif [ ! -f "$DEP_DIR/$supersede" ]; then
            add_finding "$rel" "active" "supersede_target_missing" "取代指向的停用知識不存在：$supersede" "edit"
        elif [ "$(fm_value "$DEP_DIR/$supersede" "被取代於")" != "$rel" ]; then
            add_finding "$rel" "active" "supersede_not_reciprocal" "取代關係未在停用知識中互惠登記" "edit,repair"
        fi
    fi
done < "$DISK_ROWS"

# 停用知識只檢查分類、索引欄位與取代關係，不強迫補齊現行 MADR 內容。
while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    file="$DEP_DIR/$rel"
    full_rel="deprecated/$rel"
    valid_rel_path "$rel" || add_finding "$full_rel" "deprecated" "invalid_category" "停用知識不在允許的鏡像分類路徑" "edit"
    check_index_matches_file "$rel" "deprecated" "$file" "$DEP_INDEX_ROWS"
    target="$(fm_value "$file" "被取代於")"
    if [ -z "$target" ] || [ "$target" = "-" ]; then
        add_finding "$full_rel" "deprecated" "superseded_by_missing" "停用知識未登記被取代於" "edit,repair"
    elif ! valid_rel_path "$target"; then
        add_finding "$full_rel" "deprecated" "superseded_by_target_invalid" "被取代於不是合法知識相對路徑：$target" "edit"
    elif [ ! -f "$KB_DIR/$target" ]; then
        add_finding "$full_rel" "deprecated" "superseded_by_target_missing" "被取代於指向的生效知識不存在：$target" "edit"
    elif [ "$(fm_value "$KB_DIR/$target" "取代")" != "$rel" ]; then
        add_finding "$full_rel" "deprecated" "superseded_by_not_reciprocal" "生效知識未互惠登記取代關係" "edit,repair"
    fi
done < "$DEP_DISK_ROWS"

FINDING_COUNT="$(wc -l < "$FINDINGS" | tr -d ' ')"
UNHEALTHY_COUNT="$(awk -F'\t' '$1!="" { seen[$1]=1 } END { for (p in seen) n++; print n+0 }' "$FINDINGS")"
ACTIVE_COUNT="$(wc -l < "$DISK_ROWS" | tr -d ' ')"
DEPRECATED_COUNT="$(wc -l < "$DEP_DISK_ROWS" | tr -d ' ')"
CHECKED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
HEALTHY="true"
[ "$FINDING_COUNT" -gt 0 ] && HEALTHY="false"

LC_ALL=C awk -F'\t' -v run_id="$RUN_ID" -v checked_at="$CHECKED_AT" -v source="$SOURCE" \
    -v healthy="$HEALTHY" -v active="$ACTIVE_COUNT" -v deprecated="$DEPRECATED_COUNT" \
    -v unhealthy="$UNHEALTHY_COUNT" -v finding_count="$FINDING_COUNT" '
    function esc(s) {
        gsub(/\\/, "\\\\", s); gsub(/\"/, "\\\"", s); gsub(/\r/, "\\r", s); gsub(/\n/, "\\n", s); gsub(/\t/, "\\t", s)
        return s
    }
    BEGIN {
        printf "{\"version\":1,\"run_id\":\"%s\",\"checked_at\":\"%s\",\"source\":\"%s\",", esc(run_id), esc(checked_at), esc(source)
        printf "\"healthy\":%s,\"counts\":{\"active\":%d,\"deprecated\":%d,\"unhealthy_pages\":%d,\"findings\":%d},\"findings\":[", healthy, active, deprecated, unhealthy, finding_count
    }
    {
        if (n++) printf ","
        printf "{\"path\":\"%s\",\"scope\":\"%s\",\"code\":\"%s\",\"message\":\"%s\",\"actions\":[", esc($1), esc($2), esc($3), esc($4)
        count=split($5, actions, ",")
        for (i=1; i<=count; i++) { if (i>1) printf ","; printf "\"%s\"", esc(actions[i]) }
        printf "]}"
    }
    END { print "]}" }
' "$FINDINGS" > "$RESULT"

mkdir -p "$LOG_DIR"
chmod 700 "$HOME/.knowledge-skill" "$HOME/.knowledge-skill/logs" "$LOG_DIR" 2>/dev/null || true
LATEST_TMP="$(mktemp "$LOG_DIR/latest.XXXXXX")"
cp "$RESULT" "$LATEST_TMP"
chmod 600 "$LATEST_TMP"
mv "$LATEST_TMP" "$LOG_DIR/latest.json"
tr -d '\n' < "$RESULT" >> "$LOG_DIR/history.jsonl"
printf '\n' >> "$LOG_DIR/history.jsonl"
chmod 600 "$LOG_DIR/history.jsonl"

if [ "$FORMAT" = "json" ]; then
    cat "$RESULT"
else
    echo "📍 知識庫：$KB_DIR"
    echo "🕒 檢查時間：$CHECKED_AT"
    echo "📊 生效 $ACTIVE_COUNT 筆 · 停用 $DEPRECATED_COUNT 筆 · 不健康頁面 $UNHEALTHY_COUNT 筆 · 問題 $FINDING_COUNT 項"
    if [ "$FINDING_COUNT" -eq 0 ]; then
        echo "✅ 共用知識庫內容健康。"
    else
        echo "⚠️  發現不健康內容："
        awk -F'\t' '{ printf "   • %s [%s] %s\n", $1, $3, $4 }' "$FINDINGS"
        echo "📝 最新結果：$LOG_DIR/latest.json"
    fi
fi

[ "$FINDING_COUNT" -eq 0 ] && exit 0
exit 2
