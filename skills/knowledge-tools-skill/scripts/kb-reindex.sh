#!/bin/sh
# kb-reindex.sh
# 功能：遞迴掃描分類目錄，依各知識檔 front matter（標題／觸發時機／取代／被取代於／狀態）與
#       「## 摘要」內容，確定性重建**兩層索引**：頂層 index.md 只列分類目錄（分類／筆數／
#       知識標題），各分類目錄下的 index.md 才是完整清單。停用知識於 deprecated/ 下
#       採同樣兩層結構。自然補登錄孤兒檔、移除指向不存在檔案的舊列與空分類的子索引。
#       相容無 front matter 的舊格式。
#       子索引（含未分類知識與 deprecated/）另有「創建時間／更新時間」兩欄：更新時間取知識檔
#       mtime；創建時間只存在索引裡，重建時從舊索引讀回（見 collect_old_created）。
#       生效知識的清單最後另有「狀態」欄（AI 自動確認／人工審核確認），取自 front matter，
#       沒有此欄的知識視為「人工審核確認」；停用知識的清單沒有這一欄。
# 用法：sh kb-reindex.sh
# 參數：無。
# 流程：
#   1. 解析 KNOWLEDGE_BASE_DIR 並確認 knowledge 目錄存在；缺 index.md 時以分類目錄骨架辨認後照常重建
#   2. 遞迴解析每個知識檔（排除各層 index.md 與 deprecated/ 子樹）→ 依所在目錄分組
#   3. 在暫存區組出完整的索引檔樹（頂層 + 各分類子索引），deprecated/ 同理
#   4. 與現有索引逐檔比對，只有內容不同才備份並寫入（idempotent）；並移除空分類的孤兒子索引
#   5. 把各層 index.md 標記為 Dropbox 忽略（macOS），索引不參與雲端同步、由各裝置自行重建
# 產出：覆寫 <KB>/index.md、<KB>/{分類}/index.md，以及（存在時）deprecated/ 下的對應索引；
#       變更時備份至 <KB 上層>/backups/
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成（含無變更）；1 結構缺失（無目錄，或缺 index 且分類目錄骨架不完整）
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
SKILL_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
# canonical 範本集中於 knowledge-skill/assets（假設兩 skill 並存安裝）
ASSETS_DIR="$SKILL_DIR/../knowledge-skill/assets"
TEMPLATE="$ASSETS_DIR/knowledge-index.md"
DEP_TEMPLATE="$ASSETS_DIR/knowledge-deprecated-index.md"
CAT_TEMPLATE="$ASSETS_DIR/knowledge-category-index.md"
DEP_CAT_TEMPLATE="$ASSETS_DIR/knowledge-deprecated-category-index.md"
INDEX="$KB_DIR/index.md"
DEP_DIR="$KB_DIR/deprecated"
DEP_INDEX="$DEP_DIR/index.md"
BACKUP_DIR="$(dirname "$KB_DIR")/backups"
TS="$(date +%Y%m%d%H%M%S)"

if [ ! -d "$KB_DIR" ]; then
    echo "❌ 知識庫不存在：$KB_DIR"
    echo "   請先執行 init-knowledge-base.sh 建立。"
    exit 1
fi

# 索引不進雲端同步（見 mark_sync_ignored），其他裝置拿到的知識庫本來就沒有 index.md，
# 缺索引因此是常態而非結構缺失。改以六個分類目錄骨架辨認知識庫：KNOWLEDGE_BASE_DIR
# 指錯時不能在無關目錄裡鋪滿 index.md。
if [ ! -f "$INDEX" ]; then
    for category in ui ux dev ops data else; do
        if [ ! -d "$KB_DIR/$category" ]; then
            echo "❌ 缺 index.md 且分類目錄骨架不完整（缺 $category/），無法確認這是知識庫：$KB_DIR"
            echo "   請先執行 init-knowledge-base.sh 建立。"
            exit 1
        fi
    done
    echo "⚠️  index.md 不存在，將依知識檔重建：$INDEX"
fi

# 創建時間的三種退回值：
#   舊索引有登錄但還沒有時間欄（本機制上線前的知識）→ LEGACY_CREATED
#   舊索引存在卻沒登錄這份（剛建立）→ NOW
#   整份頂層索引不存在（新裝置、索引被移除）→ UNKNOWN_CREATED，原值已無從得知
HAD_INDEX=0
if [ -f "$INDEX" ]; then
    HAD_INDEX=1
fi
LEGACY_CREATED="1970-01-01 00:00:00"
UNKNOWN_CREATED="0000-00-00 00:00:00"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
DEFAULT_STATUS="人工審核確認"

# 暫存區：STAGE 鏡像知識庫的索引檔樹，全部組完才與現況比對，避免中途失敗留下半套索引。
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kb-reindex-stage.XXXXXX")"
ROWS="$(mktemp "${TMPDIR:-/tmp}/kb-reindex-rows.XXXXXX")"
NEWLIST="$(mktemp "${TMPDIR:-/tmp}/kb-reindex-new.XXXXXX")"
OLDLIST="$(mktemp "${TMPDIR:-/tmp}/kb-reindex-old.XXXXXX")"
OLDCREATED="$(mktemp "${TMPDIR:-/tmp}/kb-reindex-created.XXXXXX")"
trap 'rm -rf "$STAGE"; rm -f "$ROWS" "$NEWLIST" "$NEWLIST.active" "$OLDLIST" "$OLDCREATED"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CHANGED=0

# 解析單一知識檔 → title<TAB>trigger<TAB>summary<TAB>supersedes<TAB>supersededby<TAB>status
# 優先讀 YAML front matter；缺欄位時回退舊格式（## 觸發時機 段、H1 標題）。
parse_file() {
    awk '
        BEGIN { fm=0 }
        NR==1 && $0=="---" { fm=1; next }
        fm==1 && $0=="---" { fm=0; next }
        fm==1 {
            line=$0
            if (line ~ /^標題:[ \t]*/) { sub(/^標題:[ \t]*/, "", line); title=line }
            else if (line ~ /^觸發時機:[ \t]*/) { sub(/^觸發時機:[ \t]*/, "", line); trigger=line }
            else if (line ~ /^取代:[ \t]*/) { sub(/^取代:[ \t]*/, "", line); supersedes=line }
            else if (line ~ /^被取代於:[ \t]*/) { sub(/^被取代於:[ \t]*/, "", line); supersededby=line }
            else if (line ~ /^狀態:[ \t]*/) { sub(/^狀態:[ \t]*/, "", line); status=line }
            next
        }
        /^# /  { if (h1=="") { h1=substr($0,3); gsub(/^[ \t]+|[ \t]+$/, "", h1) } next }
        /^## 摘要/      { sec="s"; next }
        /^## 觸發時機/  { sec="t"; next }
        /^## /  { sec=""; next }
        {
            line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line=="") next
            if (sec=="s" && summary=="") summary=line
            if (sec=="t" && tbody=="") tbody=line
        }
        END {
            if (trigger=="" || trigger=="-") trigger=tbody
            if (title=="" || title=="-") title=h1
            # `|` 會打斷 Markdown 表格欄位，一律換成 `/`。這是索引欄位正規化的真源，
            # kb-health.sh 的 normalize_cell 比對 stale 時必須套用同一規則，否則含 `|`
            # 的知識檔會永遠被判定為 index_*_stale 且無法藉 reindex 修復。
            gsub(/\|/, "/", title); gsub(/\|/, "/", trigger)
            gsub(/\|/, "/", summary); gsub(/\|/, "/", supersedes); gsub(/\|/, "/", supersededby)
            gsub(/\|/, "/", status); gsub(/[ \t]+$/, "", status)
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", title, trigger, summary, supersedes, supersededby, status
        }
    ' "$1"
}

# 解析既有索引登錄的連結目標（第一欄的 Markdown 連結），供變更統計使用。
# 只認第一欄含 Markdown 連結的列：頂層索引的分類目錄表第一欄是反引號純文字（刻意不做成
# 連結），若把無連結的列也當成登錄項，分類名稱會被誤算成知識檔而讓統計虛胖。
# 樣式必須錨定行尾的 `](…)`：知識標題本身常含括號（如 `Schema::table(ALTER)`、
# `shouldReceive()`），只找「第一個括號」會抓到標題裡的括號而非連結目標。
parse_index_links() {
    awk -F'|' '
        NF >= 3 {
            cell=$2
            gsub(/^[ \t]+|[ \t]+$/, "", cell)
            if (!match(cell, /\]\([^)]*\)$/)) next
            cell=substr(cell, RSTART+2, RLENGTH-3)
            if (cell=="" || cell ~ /^<!--/) next
            print cell
        }
    ' "$1"
}

# 創建時間只存在索引裡（知識檔不帶此欄），重建時必須先從舊索引讀回，否則每次都會遺失。
# 生效與停用兩棵樹一起收：取代會把知識檔搬進 deprecated/，要能用對應路徑沿用原值。
# 輸出「相對 KB_DIR 的路徑<TAB>創建時間」，停用樹的路徑自然帶 deprecated/ 前綴。
# 欄位順序：$2 知識、$3 觸發時機、$4 摘要、$5 取代／被取代於、$6 創建時間、$7 更新時間；
# 生效清單另有 $8 狀態（排在最後，不影響前面的欄位位置）；少於 8 個欄位的是舊格式列，
# 填 LEGACY_CREATED。
collect_old_created() {
    find "$KB_DIR" -type f -name 'index.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r idx; do
        dir="$(dirname "${idx#"$KB_DIR"/}")"
        awk -F'|' -v d="$dir" -v legacy="$LEGACY_CREATED" '
            NF >= 3 {
                cell=$2
                gsub(/^[ \t]+|[ \t]+$/, "", cell)
                if (!match(cell, /\]\([^)]*\)$/)) next
                link=substr(cell, RSTART+2, RLENGTH-3)
                if (link=="" || link ~ /^<!--/) next
                created=""
                if (NF >= 8) { created=$6; gsub(/^[ \t]+|[ \t]+$/, "", created) }
                if (created=="") created=legacy
                printf "%s\t%s\n", (d=="." ? link : d "/" link), created
            }
        ' "$idx"
    done
}

# 查詢一份知識的創建時間。$1 相對 KB_DIR 的路徑、$2 對應路徑（生效 ↔ deprecated/）。
lookup_created() {
    created="$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$OLDCREATED")"
    if [ -z "$created" ]; then
        created="$(awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$OLDCREATED")"
    fi
    if [ -z "$created" ]; then
        if [ "$HAD_INDEX" -eq 1 ]; then
            created="$NOW"
        else
            created="$UNKNOWN_CREATED"
        fi
    fi
    printf '%s' "$created"
}

# 更新時間取知識檔 mtime。GNU 與新版 BSD 的 date -r 都吃檔案；不支援時退回 BSD stat。
file_mtime() {
    date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1" 2>/dev/null \
        || printf '%s' "$UNKNOWN_CREATED"
}

# 由分類目錄深度組出回到該層總索引的相對路徑（dev/php-laravel → ../../index.md）。
back_to_root() {
    printf '%s' "$1" | awk -F/ '{ p=""; for (i=1;i<=NF;i++) p=p "../"; printf "%sindex.md", p }'
}

# 取範本的表頭（第一行至分隔列）；範本不存在時由呼叫端提供內嵌備援。
template_head() {
    [ -f "$1" ] || return 1
    sed -n '1,/^|---/p' "$1"
}

# 寫出單一分類的子索引到 STAGE。
# $1 根目錄（KB_DIR 或 DEP_DIR 在 STAGE 中的對應位置）、$2 分類相對路徑、$3 範本、$4 模式
write_category_index() {
    stage_root="$1"; dir="$2"; tmpl="$3"; mode="$4"
    out="$stage_root/$dir/index.md"
    mkdir -p "$stage_root/$dir"
    back="$(back_to_root "$dir")"
    if template_head "$tmpl" > "$out.tmpl" 2>/dev/null; then
        # 範本以 {{CATEGORY}}／{{BACK}} 佔位；分類路徑含 /，故 sed 用 | 當分隔符。
        # 不用 sed -i（非 POSIX，且 BSD／GNU 語法不同），改寫到目標檔後刪暫存。
        sed -e "s|{{CATEGORY}}|$dir|g" -e "s|{{BACK}}|$back|g" "$out.tmpl" > "$out"
        rm -f "$out.tmpl"
    else
        rm -f "$out.tmpl"
        if [ "$mode" = "deprecated" ]; then
            printf '# 公用知識庫——`%s` 分類已停用索引\n\n> 由 kb-reindex.sh 自動重建，請勿手動編輯。回停用總索引：[%s](%s)。\n\n| 知識 | 觸發時機 | 摘要 | 被取代於 | 創建時間 | 更新時間 |\n|------|----------|------|----------|----------|----------|\n' \
                "$dir" "$back" "$back" > "$out"
        else
            printf '# 公用知識庫——`%s` 分類索引\n\n> 由 kb-reindex.sh 自動重建，請勿手動編輯。回總索引：[%s](%s)。\n\n| 知識 | 觸發時機 | 摘要 | 取代 | 創建時間 | 更新時間 | 狀態 |\n|------|----------|------|------|----------|----------|------|\n' \
                "$dir" "$back" "$back" > "$out"
        fi
    fi
}

# 掃描一棵知識樹並在 STAGE 組出完整索引檔樹。
# $1 來源根目錄、$2 STAGE 中的對應根目錄、$3 頂層範本、$4 分類範本、$5 模式（active／deprecated）
# 副作用：把該樹所有知識檔的相對路徑（相對來源根）追加到 $NEWLIST。
build_tree() {
    src="$1"; stage_root="$2"; root_tmpl="$3"; cat_tmpl="$4"; mode="$5"
    : > "$ROWS"

    # 知識檔 → dir<TAB>basename<TAB>title<TAB>trigger<TAB>summary<TAB>關係欄<TAB>創建時間<TAB>更新時間<TAB>狀態
    # 排除各層 index.md；生效樹另排除 deprecated/ 子樹。
    if [ "$mode" = "deprecated" ]; then
        find "$src" -type f -name '*.md' ! -name 'index.md' 2>/dev/null | LC_ALL=C sort
    else
        find "$src" -type f -name '*.md' ! -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null | LC_ALL=C sort
    fi | while IFS= read -r f; do
        rel="${f#"$src"/}"
        printf '%s\n' "$rel" >> "$NEWLIST"
        dir="$(dirname "$rel")"
        fields="$(parse_file "$f")"
        title="$(printf '%s' "$fields" | cut -f1)"
        trigger="$(printf '%s' "$fields" | cut -f2)"
        summary="$(printf '%s' "$fields" | cut -f3)"
        if [ "$mode" = "deprecated" ]; then
            relation="$(printf '%s' "$fields" | cut -f5)"
        else
            relation="$(printf '%s' "$fields" | cut -f4)"
        fi
        [ -n "$title" ] || title="$rel"
        [ -n "$relation" ] || relation="-"
        # 沒有狀態欄的是這個欄位出現前、經使用者同意才寫入的知識。
        status="$(printf '%s' "$fields" | cut -f6)"
        if [ -z "$status" ] || [ "$status" = "-" ]; then
            status="$DEFAULT_STATUS"
        fi
        if [ "$mode" = "deprecated" ]; then
            created="$(lookup_created "deprecated/$rel" "$rel")"
        else
            created="$(lookup_created "$rel" "deprecated/$rel")"
        fi
        updated="$(file_mtime "$f")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dir" "$(basename "$rel")" "$title" "$trigger" "$summary" "$relation" "$created" "$updated" "$status" >> "$ROWS"
    done

    mkdir -p "$stage_root"

    # 清單列的輸出格式：生效清單比停用清單多最後一欄「狀態」。
    if [ "$mode" = "deprecated" ]; then
        row_fmt='printf "| [%s](%s) | %s | %s | %s | %s | %s |\n", $3, $2, $4, $5, $6, $7, $8'
    else
        row_fmt='printf "| [%s](%s) | %s | %s | %s | %s | %s | %s |\n", $3, $2, $4, $5, $6, $7, $8, $9'
    fi

    # 頂層：分類目錄表（分類／筆數／知識標題）。分類欄刻意用反引號純文字而非 Markdown
    # 連結——索引解析器一律把「第一欄有連結」的列視為一筆知識，做成連結會讓每個分類
    # 被誤算成一筆知識檔。
    root_out="$stage_root/index.md"
    if template_head "$root_tmpl" > "$root_out" 2>/dev/null; then
        :
    elif [ "$mode" = "deprecated" ]; then
        printf '# 公用知識庫——已停用決策索引\n\n生效知識請見 [../index.md](../index.md)。完整清單在各分類的 `{分類}/index.md`。\n\n## 分類目錄\n\n| 分類 | 筆數 | 知識標題 |\n|------|------|----------|\n' > "$root_out"
    else
        printf '# 公用知識庫索引\n\n先掃分類目錄，命中後再讀該分類的 `{分類}/index.md`。已停用決策見 [deprecated/index.md](deprecated/index.md)。\n\n## 分類目錄\n\n| 分類 | 筆數 | 知識標題 |\n|------|------|----------|\n' > "$root_out"
    fi

    # 分類彙總列：依分類排序，每列帶筆數與該分類全部知識標題（以 、 串接）。
    # 筆數放在頂層是刻意的——選單列的狀態快取只 stat 頂層索引，靠筆數欄的變動偵測
    # 整棵樹的新增／刪除，不必逐一 stat 每份子索引。
    awk -F'\t' '
        $1 != "." {
            if (!( $1 in seen )) { order[++n]=$1; seen[$1]=1 }
            count[$1]++
            titles[$1] = (titles[$1]=="" ? $3 : titles[$1] "、" $3)
        }
        END { for (i=1;i<=n;i++) printf "| `%s` | %d | %s |\n", order[i], count[order[i]], titles[order[i]] }
    ' "$ROWS" >> "$root_out"

    if ! awk -F'\t' '$1 != "." { found=1 } END { exit found ? 0 : 1 }' "$ROWS"; then
        printf '| %s |  |  |\n' '<!-- 新增知識時由 kb-reindex.sh 自動登錄 -->' >> "$root_out"
    fi

    # 未分類知識：直接放在知識庫根目錄、不屬於任何分類的知識檔，就地列在頂層。
    if awk -F'\t' '$1 == "." { found=1 } END { exit found ? 0 : 1 }' "$ROWS"; then
        if [ "$mode" = "deprecated" ]; then
            printf '\n## 未分類知識\n\n| 知識 | 觸發時機 | 摘要 | 被取代於 | 創建時間 | 更新時間 |\n|------|----------|------|----------|----------|----------|\n' >> "$root_out"
        else
            printf '\n## 未分類知識\n\n| 知識 | 觸發時機 | 摘要 | 取代 | 創建時間 | 更新時間 | 狀態 |\n|------|----------|------|------|----------|----------|------|\n' >> "$root_out"
        fi
        awk -F'\t' "\$1 == \".\" { $row_fmt }" "$ROWS" >> "$root_out"
    fi

    # 各分類子索引：完整清單（生效七欄、停用六欄），第一欄連結相對該分類目錄。
    awk -F'\t' '$1 != "." { print $1 }' "$ROWS" | LC_ALL=C sort -u | while IFS= read -r dir; do
        write_category_index "$stage_root" "$dir" "$cat_tmpl" "$mode"
        awk -F'\t' -v d="$dir" "\$1 == d { $row_fmt }" \
            "$ROWS" >> "$stage_root/$dir/index.md"
    done
}

# 把 STAGE 的索引檔同步到實際位置：內容相同則不動，不同才備份原檔後覆寫。
# $1 STAGE 根目錄、$2 實際根目錄、$3 備份檔名前綴
sync_stage() {
    stage_root="$1"; real_root="$2"; prefix="$3"
    [ -d "$stage_root" ] || return 0
    find "$stage_root" -type f -name 'index.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r staged; do
        rel="${staged#"$stage_root"/}"
        target="$real_root/$rel"
        if [ -f "$target" ] && cmp -s "$staged" "$target"; then
            continue
        fi
        mkdir -p "$(dirname "$target")"
        if [ -f "$target" ]; then
            mkdir -p "$BACKUP_DIR"
            # 備份檔名以 - 取代路徑分隔符，讓各層索引的備份平鋪在同一個資料夾。
            cp "$target" "$BACKUP_DIR/$prefix-$(printf '%s' "$rel" | tr '/' '-')-backup-$TS.md"
        fi
        cp "$staged" "$target"
        printf 'changed\n'
    done
}

# 移除已無知識檔的分類所遺留的孤兒子索引（頂層索引永遠保留）。
# $1 STAGE 根目錄、$2 實際根目錄、$3 備份檔名前綴
prune_orphan_indexes() {
    stage_root="$1"; real_root="$2"; prefix="$3"
    [ -d "$real_root" ] || return 0
    find "$real_root" -mindepth 2 -type f -name 'index.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r existing; do
        rel="${existing#"$real_root"/}"
        # deprecated/ 有自己的一棵樹，不由生效樹的清理流程處理。
        case "$real_root/$rel" in
            "$DEP_DIR"/*) [ "$prefix" = "deprecated-index" ] || continue ;;
        esac
        [ -f "$stage_root/$rel" ] && continue
        mkdir -p "$BACKUP_DIR"
        cp "$existing" "$BACKUP_DIR/$prefix-$(printf '%s' "$rel" | tr '/' '-')-orphan-$TS.md"
        rm -f "$existing"
        printf 'changed\n'
    done
}

# 索引是各裝置可自行重建的衍生物，又是每次建檔都整份覆寫的熱點；留在 Dropbox 同步裡，
# 兩台裝置先後寫入就會被改名成衝突複本、原檔消失。知識檔檔名唯一且只寫一次，仍照常同步。
# 兩個屬性分別對應 File Provider 版與舊版 Dropbox；不在同步資料夾內時設了也無作用。
# 設不上（缺 xattr、檔案系統不支援）靜默略過，不影響重建結果。目前只處理 macOS。
mark_sync_ignored() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    find "$KB_DIR" -type f -name 'index.md' 2>/dev/null | while IFS= read -r idx; do
        xattr -w 'com.apple.fileprovider.ignore#P' 1 "$idx" 2>/dev/null || true
        xattr -w com.dropbox.ignored 1 "$idx" 2>/dev/null || true
    done
}

# 既有索引登錄的知識路徑（相對 KB_DIR），供新增／移除統計。
# 子索引登錄的是相對該目錄的檔名，需補回目錄前綴；舊的單層索引則前綴為空，自然相容。
collect_old_links() {
    find "$KB_DIR" -type f -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null | LC_ALL=C sort | while IFS= read -r idx; do
        dir="$(dirname "${idx#"$KB_DIR"/}")"
        parse_index_links "$idx" | while IFS= read -r link; do
            if [ "$dir" = "." ]; then
                printf '%s\n' "$link"
            else
                printf '%s/%s\n' "$dir" "$link"
            fi
        done
    done
}

collect_old_links > "$OLDLIST"
collect_old_created > "$OLDCREATED"

# 生效樹
build_tree "$KB_DIR" "$STAGE/active" "$TEMPLATE" "$CAT_TEMPLATE" "active"
cp "$NEWLIST" "$NEWLIST.active"
: > "$NEWLIST"

# 停用樹（deprecated/ 存在時才處理）
HAS_DEP=0
if [ -d "$DEP_DIR" ]; then
    HAS_DEP=1
    build_tree "$DEP_DIR" "$STAGE/deprecated" "$DEP_TEMPLATE" "$DEP_CAT_TEMPLATE" "deprecated"
fi

RESULT="$(
    sync_stage "$STAGE/active" "$KB_DIR" "index"
    prune_orphan_indexes "$STAGE/active" "$KB_DIR" "index"
    if [ "$HAS_DEP" -eq 1 ]; then
        sync_stage "$STAGE/deprecated" "$DEP_DIR" "deprecated-index"
        prune_orphan_indexes "$STAGE/deprecated" "$DEP_DIR" "deprecated-index"
    fi
)"
[ -n "$RESULT" ] && CHANGED=1

# 內容沒變也要標記：剛升級的裝置上，既有索引還帶著同步狀態。
mark_sync_ignored

if [ "$CHANGED" -eq 0 ]; then
    echo "✅ 索引已是最新，無需變更：$INDEX"
    exit 0
fi

ADDED="$(grep -Fxvf "$OLDLIST" "$NEWLIST.active" 2>/dev/null | grep -c . || true)"
REMOVED="$(grep -Fxvf "$NEWLIST.active" "$OLDLIST" 2>/dev/null | grep -c . || true)"
CATS="$(find "$KB_DIR" -mindepth 2 -type f -name 'index.md' ! -path "$DEP_DIR/*" 2>/dev/null | grep -c . || true)"

echo "✅ 已重建兩層索引：$INDEX"
echo "   分類子索引：$CATS 份；新增登錄：$ADDED 筆；移除斷鏈：$REMOVED 筆"
[ "$HAS_DEP" -eq 1 ] && echo "   停用索引：$DEP_INDEX"
echo "   原索引備份：$BACKUP_DIR/"
