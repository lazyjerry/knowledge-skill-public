#!/bin/sh
# kb-import.sh
# 功能：跨工具記憶匯入的單一進入點；驗證工具名稱後分派到對應 adapter。
# 用法：sh kb-import.sh <claude|codex|copilot> [來源] [--dry-run|--write] [選項...]
# 參數：
#   <claude|codex|copilot>  來源工具
#   [來源]                  來源路徑（adapter 各有預設）；Copilot 建議用 --from-file
#   --dry-run               預設；只輸出規模統計，不落地
#   --write                 確認後產生候選任務資料夾
#   --limit N               候選筆數上限（預設 50）
#   --scope user|repository 覆寫候選 scope
#   --repository owner/name 標註 repository
#   --since YYYY-MM-DD       只取該日(含)之後修改的來源
#   --workspace 路徑         候選輸出工作區根（預設目前目錄）
#   --from-file 路徑         指定單一來源檔（Copilot 主要入口）
# 流程：解析工具 → exec kb-import-<tool>.sh，原樣轉傳其餘參數與結束碼。
# 產出：見 adapter 與 kb-import-lib.sh。
# 結束碼：轉傳 adapter；未知工具為 1。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

usage() {
    echo "用法：sh kb-import.sh <claude|codex|copilot> [來源] [--dry-run|--write] [選項...]"
    echo "  預設 --dry-run（只統計不落地）；確認後加 --write 產生候選。"
    echo "  選項：--limit N／--scope user|repository／--repository owner/name／--since YYYY-MM-DD／--workspace 路徑／--from-file 路徑"
}

TOOL="${1:-}"
[ "$#" -gt 0 ] && shift || true

case "$TOOL" in
    claude|codex|copilot) exec sh "$SCRIPT_DIR/kb-import-$TOOL.sh" "$@" ;;
    ""|-h|--help) usage; [ -z "$TOOL" ] && exit 1 || exit 0 ;;
    *) echo "❌ 未知工具：$TOOL"; echo ""; usage; exit 1 ;;
esac
