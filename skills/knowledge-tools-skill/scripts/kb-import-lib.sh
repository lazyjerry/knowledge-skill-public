#!/bin/sh
# kb-import-lib.sh
# 功能：跨工具記憶匯入 adapter 的共用函式庫（被 kb-import-*.sh 以 . 載入，非獨立執行）。
#       提供共用參數解析、secret scan、內容 hash 去重、規模統計與候選任務資料夾產生。
# 用法：在 adapter 內：. "$SCRIPT_DIR/kb-import-lib.sh"，定義 adapter_enumerate 後呼叫 kb_run。
# 參數：（由 kb_parse_args 解析）見各全域變數說明。
# 流程：adapter 設定 TOOL／預設值 → 定義 adapter_enumerate（列舉來源記憶）→ kb_run。
# 產出：dry-run 僅輸出規模統計；--write 產生 <工作區>/docs/knowledge-skill/記憶候選_<tool>-NNN/。
# 環境變數：無（KNOWLEDGE_BASE_DIR 與本庫無關，promotion 才用到）。
# 結束碼：0 完成；1 參數或來源錯誤；2 無合格候選。
#
# adapter 約定：
#   - 設定 TOOL（claude|codex|copilot）、SCOPE_DEFAULT、KIND_DEFAULT。
#   - 定義函式 adapter_enumerate：對每筆來源記憶輸出一列（TAB 分隔，內容禁含 TAB）：
#       <來源檔絕對路徑>\t<source_id>\t<scope>\t<repository>\t<source_kind>
#     僅負責「找出來源並分類」，不做 secret scan／去重／落地（交給本庫）。

# ── 共用全域（大寫；adapter 與本庫共享）────────────────────────────
OPT_SRC=""            # 位置參數：來源路徑或 --from-file 目標
OPT_DRYRUN=1          # 預設 dry-run；--write 設 0
OPT_LIMIT=50          # 候選筆數上限
OPT_SCOPE=""          # 覆寫 scope；空字串時用 adapter SCOPE_DEFAULT
OPT_REPO="-"          # repository 標註
OPT_SINCE=""          # 只取此日期(含)之後修改的來源（YYYY-MM-DD）
WORKSPACE="."         # 候選輸出工作區根（含 docs/knowledge-skill）

# 顯示路徑（家目錄縮成 ~）
kb_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# 解析共用參數；未知參數交回 adapter 自行處理會過於複雜，故未知參數視為錯誤。
kb_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run) OPT_DRYRUN=1 ;;
            --write) OPT_DRYRUN=0 ;;
            --limit) shift; OPT_LIMIT="${1:-}" ;;
            --limit=*) OPT_LIMIT="${1#--limit=}" ;;
            --scope) shift; OPT_SCOPE="${1:-}" ;;
            --scope=*) OPT_SCOPE="${1#--scope=}" ;;
            --repository) shift; OPT_REPO="${1:-}" ;;
            --repository=*) OPT_REPO="${1#--repository=}" ;;
            --since) shift; OPT_SINCE="${1:-}" ;;
            --since=*) OPT_SINCE="${1#--since=}" ;;
            --workspace) shift; WORKSPACE="${1:-}" ;;
            --workspace=*) WORKSPACE="${1#--workspace=}" ;;
            --from-file) shift; OPT_SRC="${1:-}" ;;
            --from-file=*) OPT_SRC="${1#--from-file=}" ;;
            --*) echo "❌ 未知參數：$1" >&2; return 1 ;;
            *) if [ -z "$OPT_SRC" ]; then OPT_SRC="$1"; else echo "❌ 參數過多：$1" >&2; return 1; fi ;;
        esac
        shift
    done
    case "$OPT_LIMIT" in
        ''|*[!0-9]*) echo "❌ --limit 需為正整數：$OPT_LIMIT" >&2; return 1 ;;
    esac
    return 0
}

# 偵測 find 是否支援 -newermt 且能解析使用者給的 --since 日期（BSD 與 GNU find 皆有 -newermt）。
kb_since_supported() {
    find "${TMPDIR:-/tmp}" -maxdepth 0 -newermt "$OPT_SINCE" >/dev/null 2>&1
}

# 來源檔修改時間是否在 --since(含)之後；OPT_SINCE 為空時恆為真。
kb_within_since() {
    [ -z "$OPT_SINCE" ] && return 0
    [ -n "$(find "$1" -newermt "$OPT_SINCE" 2>/dev/null)" ]
}

# 來源檔修改時間（UTC ISO-8601）；GNU date 失敗改試 BSD stat，皆失敗回退 fallback。
kb_mtime() {
    _f="$1"; _fallback="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    if _m="$(date -u -r "$_f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" && [ -n "$_m" ]; then
        echo "$_m"; return 0
    fi
    if _m="$(TZ=UTC stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$_f" 2>/dev/null)" && [ -n "$_m" ]; then
        echo "$_m"; return 0
    fi
    echo "$_fallback"
}

# 正規化內容（去前後空白、壓掉連續空行）後算 sha256；輸出純 hash。
kb_hash() {
    awk 'NF{blank=0; gsub(/^[ \t]+|[ \t]+$/,""); print; next} {if(!blank)print""; blank=1}' "$1" \
        | shasum -a 256 | awk '{print $1}'
}

# secret scan：命中常見憑證樣式即回傳 0（視為含機密，須排除）。
# 寧可多排除：樣式偏寬鬆，grep 讀不到檔案（結束碼 2）也視為含機密，只有確定沒命中才放行。
# sk- 與 sk_live_ 前面要求非英數，避免 task-…、risk-… 這類一般字串誤判。
kb_has_secret() {
    _rc=0
    grep -Eiq \
        -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
        -e '(api[_-]?key|secret[a-z_-]*|token|password|passwd)["'"'"' ]*[:=]' \
        -e 'AKIA[0-9A-Z]{16}' \
        -e 'gh[pousr]_[0-9A-Za-z]{20,}' \
        -e 'github_pat_[0-9A-Za-z_]{20,}' \
        -e 'xox[bp]-[0-9A-Za-z-]{10,}' \
        -e 'hooks\.slack\.com/services/' \
        -e '(^|[^0-9A-Za-z])sk-[0-9A-Za-z_-]{20,}' \
        -e '(^|[^0-9A-Za-z])[sr]k_(live|test)_[0-9A-Za-z]{10,}' \
        -e 'AIza[0-9A-Za-z_-]{35}' \
        -e 'bearer +[0-9A-Za-z._~+/-]{20,}' \
        -e '[a-z][a-z0-9+.-]*://[^/@[:space:]:]+:[^/@[:space:]]+@' \
        "$1" 2>/dev/null || _rc=$?
    [ "$_rc" -ne 1 ]
}

# 取一行摘要：優先 front matter description／標題，其次首個 H1，再退首個非空行。
# LC_ALL=C 不可省略：macOS 內建 awk 在 UTF-8 locale 下比較兩個多位元組字串時 == 恆為
# true，會讓任何中文欄名都命中「標題」的判斷而取到錯誤的摘要。
kb_summary() {
    LC_ALL=C awk '
        BEGIN { fm=0 }
        NR==1 && $0=="---" { fm=1; next }
        fm==1 && $0=="---" { fm=0; next }
        fm==1 {
            i=index($0,":")
            if (i>0) {
                k=substr($0,1,i-1); v=substr($0,i+1)
                gsub(/^[ \t]+|[ \t]+$/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",v)
                if ((k=="description"||k=="標題"||k=="title") && v!="" && desc=="") desc=v
            }
            next
        }
        /^# / { if (h1=="") { h1=substr($0,3); gsub(/^[ \t]+|[ \t]+$/,"",h1) } next }
        { l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l); if (l!="" && first=="") first=l }
        END {
            s=desc; if (s=="") s=h1; if (s=="") s=first
            gsub(/\t/," ",s)
            if (length(s)>160) s=substr(s,1,157) "..."
            print s
        }
    ' "$1"
}

# 取下一個流水序號（NNN）給 記憶候選_<tool>-NNN。
kb_next_seq() {
    _container="$1"; _prefix="$2"; _max=0
    for _d in "$_container/$_prefix"-*/; do
        [ -d "$_d" ] || continue
        _n="$(basename "$_d")"; _n="${_n##*-}"
        case "$_n" in *[!0-9]*) continue ;; esac
        # 去前導 0 不可用 printf '%d'：008、009 會被當成八進位而失敗，序號因此倒退、撞到既有資料夾
        _n="${_n#"${_n%%[!0]*}"}"; _n="${_n:-0}"
        [ "$_n" -gt "$_max" ] && _max="$_n"
    done
    printf '%03d' $((_max + 1))
}

# 主流程：列舉 → 過濾(since/secret/dedup) → 規模統計 → dry-run 或落地。
kb_run() {
    : "${TOOL:?adapter 未設定 TOOL}"
    [ -z "$OPT_SCOPE" ] && OPT_SCOPE="${SCOPE_DEFAULT:-user}"

    if [ -n "$OPT_SINCE" ] && ! kb_since_supported; then
        echo "❌ --since 無法使用：本機 find 不支援 -newermt 或日期無法解析：$OPT_SINCE" >&2
        echo "   請改用可解析格式（如 2024-01-01、'Jan 1 2024'）。" >&2
        return 1
    fi

    CONTAINER="$WORKSPACE/docs/knowledge-skill"
    LEDGER_DIR="$CONTAINER/.import-ledger"
    LEDGER="$LEDGER_DIR/$TOOL.tsv"

    raw="$(mktemp "${TMPDIR:-/tmp}/kb-import-raw.XXXXXX")"
    kept="$(mktemp "${TMPDIR:-/tmp}/kb-import-kept.XXXXXX")"
    trap 'rm -f "$raw" "$kept"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! adapter_enumerate > "$raw"; then
        echo "❌ 來源列舉失敗（schema 不支援或來源不可讀）。" >&2
        return 1
    fi

    total=0; n_secret=0; n_dup=0; n_since=0; n_kept=0; n_limit=0
    # 逐筆過濾
    while IFS="$(printf '\t')" read -r src sid scope repo kind; do
        [ -z "$src" ] && continue
        total=$((total + 1))
        if ! kb_within_since "$src"; then n_since=$((n_since + 1)); continue; fi
        if kb_has_secret "$src"; then n_secret=$((n_secret + 1)); continue; fi
        h="$(kb_hash "$src")"
        key="$h:$scope:$repo:$kind"
        if [ -f "$LEDGER" ] && grep -Fq "$key	" "$LEDGER" 2>/dev/null; then
            n_dup=$((n_dup + 1)); continue
        fi
        if [ "$n_kept" -ge "$OPT_LIMIT" ]; then n_limit=$((n_limit + 1)); continue; fi
        n_kept=$((n_kept + 1))
        sum="$(kb_summary "$src")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$sid" "$scope" "$repo" "$kind" "$src" "$sum" >> "$kept"
    done < "$raw"

    # ── 規模統計（dry-run 與落地皆顯示）──
    echo "📊 匯入規模統計（${TOOL}）"
    echo "   來源：$(kb_display "$OPT_SRC")"
    echo "   掃描筆數：$total"
    echo "   排除：機密 ${n_secret}／重複 ${n_dup}／不符 --since ${n_since}／超過 --limit(${OPT_LIMIT}) ${n_limit}"
    echo "   合格候選：$n_kept"
    if [ "$n_kept" -gt 0 ]; then
        echo "   scope 分布："
        awk -F'\t' '{c[$3]++} END{for(s in c)printf "     - %s：%d\n", s, c[s]}' "$kept"
    fi

    if [ "$n_kept" -eq 0 ]; then
        echo "⚠️  無合格候選，未產生任何檔案。"
        return 2
    fi

    if [ "$OPT_DRYRUN" -eq 1 ]; then
        echo ""
        echo "👉 dry-run：未落地。確認後加 --write 產生候選資料夾。"
        [ "$n_limit" -gt 0 ] && echo "   提示：有 $n_limit 筆超過上限，可調高 --limit 或用 --scope/--repository/--since 縮窄。"
        return 0
    fi

    kb_write_candidate
}

# 落地：建立候選任務資料夾並寫入四個必要檔（只存摘要與 metadata，不複製全文）。
kb_write_candidate() {
    mkdir -p "$CONTAINER" "$LEDGER_DIR"
    seq="$(kb_next_seq "$CONTAINER" "記憶候選_$TOOL")"
    folder="$CONTAINER/記憶候選_${TOOL}-${seq}"
    if [ -e "$folder" ]; then
        echo "❌ 候選資料夾已存在，未覆寫：$(kb_display "$folder")" >&2
        return 1
    fi
    # 報告檔名須帶任務英文名稱（kebab-case），供 kb-consolidate.sh 的命名檢查通過
    report_file="report-${TOOL}-memory-import.md"
    mkdir -p "$folder"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$folder/prompt.md" <<EOF
# 任務請求：跨工具記憶匯入候選（${TOOL}）

## 原始請求

\`\`\`
由 kb-import-$TOOL.sh 於 $now 唯讀掃描來源產生候選，待人工審核後再以 kb-promote.sh 沉澱。
\`\`\`

## 期望產出

- [ ] 審核候選記憶：判斷哪些跨專案可重用
- [ ] 對通過項目以 canonical MADR 建檔，再 kb-promote.sh 安裝

**產出類型：**
- 文件：notes.md（候選清單）、$report_file（候選摘要與 metadata）
- 程式碼：無
- 其他：來源去重 ledger（$TOOL.tsv）

## 參考文件

| 檔案路徑 | 引用範圍描述 |
|----------|--------------|
| $(kb_display "$OPT_SRC") | 匯入來源（唯讀） |
EOF

    cat > "$folder/task_plan.md" <<EOF
# 任務計劃：審核 $TOOL 記憶候選

## 目標
從 $TOOL 匯入的候選中篩出跨專案可重用知識，建檔後沉澱進共用知識庫。

## 執行模式
一次完成

## 報告保存路徑
$folder/

## 階段
- [x] 階段 1：read-only adapter 匯入候選
- [ ] 階段 2：人工審核可重用性與 scope
- [ ] 階段 3：建立 MADR 並 kb-promote.sh
- [ ] 階段 4：reindex + status 驗證

## 已做決策
- 候選只存摘要與來源指標，不複製 vendor 全文。

## 狀態
**階段 2** - 待人工審核
EOF

    {
        printf '# 筆記：%s 記憶匯入候選\n\n' "$TOOL"
        printf -- '---  %s  第 1 次更新筆記 ---\n' "$now"
        printf '## 任務摘要\n'
        printf 'kb-import-%s.sh 唯讀掃描來源產生 %s 筆候選，僅保留摘要與 metadata 供人工審核。\n\n' "$TOOL" "$n_kept"
        printf '## 候選清單\n'
        while IFS="$(printf '\t')" read -r h sid scope repo kind src sum; do
            printf -- '- [%s] %s\n' "$kind" "$sum"
        done < "$kept"
        printf -- '---\n'
    } > "$folder/notes.md"

    {
        printf '# %s 記憶匯入候選\n\n' "$TOOL"
        printf '匯入時間：%s\n\n' "$now"
        printf '合格候選 %s 筆。每筆只保留摘要與來源 metadata，原文留在 evidence 指回來源。\n\n' "$n_kept"
        i=0
        while IFS="$(printf '\t')" read -r h sid scope repo kind src sum; do
            i=$((i + 1))
            printf '## 候選 %d：%s\n\n' "$i" "$sum"
            printf '\`\`\`yaml\n'
            printf 'source_tool: %s\n' "$TOOL"
            printf 'source_kind: %s\n' "$kind"
            printf 'scope: %s\n' "$scope"
            printf 'repository: %s\n' "$repo"
            printf 'source_id: %s\n' "$sid"
            printf 'source_hash: %s\n' "$h"
            printf 'evidence: %s\n' "$(kb_display "$src")"
            printf 'observed_at: %s\n' "$(kb_mtime "$src" "$now")"
            printf 'status: proposed\n'
            printf '\`\`\`\n\n'
        done < "$kept"
    } > "$folder/$report_file"

    # 寫入 ledger（idempotent：key 已存在不重複）
    while IFS="$(printf '\t')" read -r h sid scope repo kind src sum; do
        key="$h:$scope:$repo:$kind"
        grep -Fq "$key	" "$LEDGER" 2>/dev/null || printf '%s\t%s\t%s\n' "$key" "$sid" "$now" >> "$LEDGER"
    done < "$kept"

    echo ""
    echo "✅ 已產生候選資料夾：$folder"
    echo "   候選 $n_kept 筆；ledger：$LEDGER"
    echo "👉 人工審核 $report_file → 建立 MADR → kb-promote.sh 安裝 → reindex/status 驗證。"
}
