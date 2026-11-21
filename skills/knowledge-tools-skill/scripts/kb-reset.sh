#!/bin/sh
# kb-reset.sh
# 功能：備份壓縮整個 knowledge 後清空其內容，並從範本重建一份空的 index.md。
# 用法：sh kb-reset.sh [--yes]
# 參數：--yes  在非互動環境下明確授權清空（不可逆）；互動環境改以輸入 yes 確認。
# 流程：
#   1. 解析 KNOWLEDGE_BASE_DIR，備份目錄取其上層的 backups/（在 knowledge 之外）
#   2. tar.gz 壓縮整個 knowledge 並驗證
#   3. 取得授權後清空 knowledge
#   4. 從範本重建空 index.md
# 產出：建立 <KB 上層>/backups/knowledge-backup-<時戳>.tar.gz；清空 <KB> 後重建 index.md
# 環境變數：KNOWLEDGE_BASE_DIR  共用知識庫 knowledge 目錄；未設定時讀設定檔 ~/.config/knowledge-skill/config，再退回預設 $HOME/.knowledge-skill/knowledge
# 結束碼：0 完成；1 目錄不存在或備份失敗；3 未取得授權而中止
set -e

ASSUME_YES=0
case "${1:-}" in
    --yes) ASSUME_YES=1 ;;
    "") ;;
    *) echo "用法：sh kb-reset.sh [--yes]"; exit 1 ;;
esac

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
TEMPLATE="$SKILL_DIR/../knowledge-skill/assets/knowledge-index.md"
TS="$(date +%Y%m%d%H%M%S)"
CATEGORIES="ui ux dev ops data else"

to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

if [ ! -d "$KB_DIR" ]; then
    echo "⚠️  knowledge 目錄不存在，無可重置：$(to_display "$KB_DIR")"
    exit 1
fi

PARENT="$(dirname "$KB_DIR")"
BASE_NAME="$(basename "$KB_DIR")"
BACKUP_DIR="$PARENT/backups"
BACKUP_FILE="$BACKUP_DIR/knowledge-backup-$TS.tar.gz"

# 1. 備份壓縮並驗證（備份在 knowledge 之外，不會被後續清空波及）
mkdir -p "$BACKUP_DIR"
if ! tar -czf "$BACKUP_FILE" -C "$PARENT" "$BASE_NAME"; then
    echo "❌ 備份失敗，已中止，未清空任何內容。"
    rm -f "$BACKUP_FILE"
    exit 1
fi
if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "❌ 備份檔驗證失敗，已中止，未清空任何內容。"
    exit 1
fi
SIZE="$(wc -c < "$BACKUP_FILE" | tr -d ' ')"
printf '✅ 已備份壓縮並驗證：%s（%s bytes）\n' "$(to_display "$BACKUP_FILE")" "$SIZE"

MD_COUNT="$(find "$KB_DIR" -type f -name '*.md' | wc -l | tr -d ' ')"
echo "ℹ️  knowledge 內現有 ${MD_COUNT} 個 .md 檔將被清空。"

# 2. 取得授權（不可逆）
if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "確定清空 %s？此動作不可逆（輸入 yes 確認）： " "$(to_display "$KB_DIR")"
        read -r ans || ans=""
        if [ "$ans" != "yes" ]; then
            echo "已取消，未清空任何內容。"
            exit 3
        fi
    else
        echo "⚠️  非互動環境且未帶 --yes，已中止。確認後請加上 --yes 重跑。"
        exit 3
    fi
fi

# 3. 清空 knowledge 內容
find "$KB_DIR" -mindepth 1 -delete
echo "✅ 已清空 knowledge 內容：$(to_display "$KB_DIR")"

# 4. 重建分類目錄骨架
for c in $CATEGORIES; do
    mkdir -p "$KB_DIR/$c"
done
echo "✅ 已重建分類目錄骨架：$CATEGORIES"

# 5. 重建空索引
if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$KB_DIR/index.md"
else
    cat > "$KB_DIR/index.md" <<'EOF'
# 公用知識庫索引

本目錄為**跨專案共用**的知識庫，儲存可重用的注意事項，供所有專案的任務參考。

> 📍 預設位置 `$HOME/.knowledge-skill/knowledge/`，可用環境變數 `KNOWLEDGE_BASE_DIR` 覆寫。

知識檔依分類歸檔（`ui`/`ux`/`dev`/`ops`/`data`/`else`），索引以相對路徑登錄。已停用決策見 [deprecated/index.md](deprecated/index.md)。

## 知識清單

| 知識 | 觸發時機 | 摘要 | 取代 |
|------|----------|------|------|
| <!-- 新增知識時由 kb-reindex.sh 自動登錄 --> |  |  |  |
EOF
fi
echo "✅ 已重建空索引：$(to_display "$KB_DIR/index.md")"
echo "📦 備份保留於：$(to_display "$BACKUP_FILE")"
