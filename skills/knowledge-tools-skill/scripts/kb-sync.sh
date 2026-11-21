#!/bin/sh
# kb-sync.sh
# 功能：在本機知識庫與另一份指定位置的知識庫之間單向搬運知識檔（pull 拉取／push 推送）。
#       採合併語意（union）：只新增、不刪除，接收端獨有的知識檔一律保留。索引不複製，
#       搬完由 kb-reindex.sh 在接收端重建，避免兩邊索引各自演化互相覆蓋。
# 用法：sh kb-sync.sh <pull|push> <對方 knowledge 路徑> [--dry-run] [--overwrite] [--yes]
# 參數：
#   pull              對方 → 本機（本機為接收端）
#   push              本機 → 對方（對方為接收端）
#   <路徑>            對方 knowledge 目錄的路徑（本機／掛載路徑；需已存在且含 index.md）
#   --dry-run         只印搬運計畫，不寫入任何檔案
#   --overwrite       同路徑但內容不同時以來源覆蓋接收端（覆蓋前備份）；預設跳過並列為衝突
#   --yes             非互動環境明確授權寫入
# 流程：
#   1. 解析 KNOWLEDGE_BASE_DIR 與對方路徑，依方向決定來源／接收端
#   2. 遞迴掃描來源知識檔（含 deprecated/，排除各層 index.md）
#   3. 逐筆以內容比對分為新增／相同／衝突（不看 mtime：跨裝置與雲端同步的 mtime 不可信）
#   4. 印出計畫；--dry-run 到此結束
#   5. 取得授權（--yes 或互動輸入 yes，否則中止 結束碼 3）
#   6. 複製新增檔；--overwrite 時先備份再覆蓋衝突檔
#   7. 在接收端執行 kb-reindex.sh 重建兩層索引
# 產出：於接收端新增／覆蓋知識檔；覆蓋前備份至 <接收端上層>/backups/sync-<時戳>/<相對路徑>；
#       接收端索引由 kb-reindex.sh 重建（其自身另有備份）
# 環境變數：KNOWLEDGE_BASE_DIR  本機知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成（含 --dry-run 與無事可做）；1 參數或結構錯誤；2 完成但有跳過的衝突；
#         3 未取得授權而中止
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d%H%M%S)"

usage() {
    echo "用法：sh kb-sync.sh <pull|push> <對方 knowledge 路徑> [--dry-run] [--overwrite] [--yes]"
}

DIRECTION=""
REMOTE=""
DRY_RUN=0
OVERWRITE=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --overwrite) OVERWRITE=1 ;;
        --yes)       ASSUME_YES=1 ;;
        -*)          echo "❌ 未知參數：$arg"; usage; exit 1 ;;
        *)
            if [ -z "$DIRECTION" ]; then
                DIRECTION="$arg"
            elif [ -z "$REMOTE" ]; then
                REMOTE="$arg"
            else
                echo "❌ 參數過多：$arg"; usage; exit 1
            fi
            ;;
    esac
done

case "$DIRECTION" in
    pull|push) ;;
    "") echo "❌ 缺少方向（pull 或 push）"; usage; exit 1 ;;
    *)  echo "❌ 未知方向：$DIRECTION（只接受 pull 或 push）"; usage; exit 1 ;;
esac

if [ -z "$REMOTE" ]; then
    echo "❌ 缺少對方 knowledge 路徑"
    usage
    exit 1
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

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# 兩端都必須是既有的知識庫。對方目錄不存在時不代建：路徑打錯而默默長出一棵假知識庫，
# 比直接報錯難救得多。
check_kb() {
    if [ ! -d "$1" ]; then
        echo "❌ $2 knowledge 目錄不存在：$(to_display "$1")"
        echo "   請先在該位置執行 init-knowledge-base.sh 建立。"
        exit 1
    fi
    if [ ! -f "$1/index.md" ]; then
        echo "❌ $2 缺少 index.md，不像是知識庫：$(to_display "$1")"
        echo "   請先在該位置執行 init-knowledge-base.sh 或 reindex 建立。"
        exit 1
    fi
}

check_kb "$KB_DIR" "本機"
check_kb "$REMOTE" "對方"

# 兩端解析成絕對路徑後才比較，否則相對路徑或 symlink 會讓「同一個目錄」看起來不同，
# 使來源與接收端指到同一處而白做一輪 reindex。
KB_DIR="$(CDPATH= cd -- "$KB_DIR" && pwd -P)"
REMOTE="$(CDPATH= cd -- "$REMOTE" && pwd -P)"
if [ "$KB_DIR" = "$REMOTE" ]; then
    echo "❌ 來源與接收端是同一個目錄，無可同步：$(to_display "$KB_DIR")"
    exit 1
fi

if [ "$DIRECTION" = "pull" ]; then
    SRC="$REMOTE"
    DST="$KB_DIR"
else
    SRC="$KB_DIR"
    DST="$REMOTE"
fi

echo "🔄 方向：$DIRECTION"
echo "   來源：$(to_display "$SRC")"
echo "   接收：$(to_display "$DST")"
echo ""

ADD_LIST="$(mktemp "${TMPDIR:-/tmp}/kb-sync-add.XXXXXX")"
CONFLICT_LIST="$(mktemp "${TMPDIR:-/tmp}/kb-sync-conflict.XXXXXX")"
trap 'rm -f "$ADD_LIST" "$CONFLICT_LIST"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SAME_COUNT=0
while IFS= read -r path; do
    [ -z "$path" ] && continue
    rel="${path#"$SRC"/}"
    # 防呆：正常 find 結果不會有 ..，但符號連結指向樹外時可能出現，一律不搬。
    case "$rel" in
        ..*|*/../*) continue ;;
    esac
    if [ ! -e "$DST/$rel" ]; then
        printf '%s\n' "$rel" >> "$ADD_LIST"
    elif cmp -s "$path" "$DST/$rel"; then
        SAME_COUNT=$((SAME_COUNT + 1))
    else
        printf '%s\n' "$rel" >> "$CONFLICT_LIST"
    fi
done <<EOF
$(find "$SRC" -type f -name '*.md' ! -name 'index.md' 2>/dev/null | LC_ALL=C sort)
EOF

ADD_COUNT="$(grep -c . "$ADD_LIST" || true)"
CONFLICT_COUNT="$(grep -c . "$CONFLICT_LIST" || true)"

echo "📋 搬運計畫"
echo "   新增：$ADD_COUNT"
echo "   相同（略過）：$SAME_COUNT"
if [ "$OVERWRITE" -eq 1 ]; then
    echo "   衝突（--overwrite 覆蓋）：$CONFLICT_COUNT"
else
    echo "   衝突（略過）：$CONFLICT_COUNT"
fi
echo ""

if [ "$ADD_COUNT" -gt 0 ]; then
    echo "➕ 將新增："
    while IFS= read -r rel; do [ -z "$rel" ] || echo "   • $rel"; done < "$ADD_LIST"
    echo ""
fi

if [ "$CONFLICT_COUNT" -gt 0 ]; then
    if [ "$OVERWRITE" -eq 1 ]; then
        echo "♻️  將覆蓋（內容不同，覆蓋前備份）："
    else
        echo "⚠️  衝突（兩端同路徑但內容不同，預設不動）："
    fi
    while IFS= read -r rel; do [ -z "$rel" ] || echo "   • $rel"; done < "$CONFLICT_LIST"
    if [ "$OVERWRITE" -ne 1 ]; then
        echo "   👉 確認要以來源為準時，加上 --overwrite 重跑；要保留接收端版本則不需處理。"
    fi
    echo ""
fi

PENDING="$ADD_COUNT"
[ "$OVERWRITE" -eq 1 ] && PENDING=$((PENDING + CONFLICT_COUNT))

if [ "$DRY_RUN" -eq 1 ]; then
    echo "ℹ️  --dry-run：未寫入任何內容。"
    exit 0
fi

if [ "$PENDING" -eq 0 ]; then
    echo "✅ 沒有需要搬運的知識檔，接收端未變更。"
    [ "$CONFLICT_COUNT" -gt 0 ] && exit 2
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "確定將上述 %s 個知識檔寫入 %s？（輸入 yes 確認）： " "$PENDING" "$(to_display "$DST")"
        read -r ans || ans=""
        if [ "$ans" != "yes" ]; then
            echo "已取消，未寫入任何內容。"
            exit 3
        fi
    else
        echo "⚠️  非互動環境且未帶 --yes，已中止，未寫入任何內容。"
        exit 3
    fi
fi

BACKUP_DIR="$(dirname "$DST")/backups/sync-$TS"

copy_one() {
    _rel="$1"
    mkdir -p "$(dirname "$DST/$_rel")"
    cp "$SRC/$_rel" "$DST/$_rel"
}

while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    copy_one "$rel"
    echo "✅ 新增：$rel"
done < "$ADD_LIST"

if [ "$OVERWRITE" -eq 1 ] && [ "$CONFLICT_COUNT" -gt 0 ]; then
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        mkdir -p "$(dirname "$BACKUP_DIR/$rel")"
        cp "$DST/$rel" "$BACKUP_DIR/$rel"
        copy_one "$rel"
        echo "♻️  覆蓋：$rel"
    done < "$CONFLICT_LIST"
    echo "📦 被覆蓋的原檔備份於：$(to_display "$BACKUP_DIR")"
fi

echo ""
echo "🔁 於接收端重建索引…"
if ! KNOWLEDGE_BASE_DIR="$DST" sh "$SCRIPT_DIR/kb-reindex.sh"; then
    echo "❌ 接收端索引重建失敗，知識檔已寫入但索引可能不一致，請手動於該位置執行 reindex。"
    exit 1
fi

echo ""
if [ "$OVERWRITE" -ne 1 ] && [ "$CONFLICT_COUNT" -gt 0 ]; then
    echo "⚠️  完成，但有 $CONFLICT_COUNT 個衝突未處理（見上方清單）。"
    exit 2
fi
echo "✅ 同步完成。"
