#!/bin/bash
# Mouse2Mouse 緊急復旧スクリプト
# カーソルがロックされた場合、別ターミナルまたはSSHから実行:
#   bash rescue.sh
#
# SSHの場合:
#   ssh user@このMacのIP 'bash /path/to/rescue.sh'

echo "=== Mouse2Mouse Emergency Recovery ==="

# 1. アプリを強制終了（SIGTERMでカーソル解除ハンドラーが発火）
echo "Sending SIGTERM to Mouse2Mouse..."
killall -TERM Mouse2Mouse 2>/dev/null

sleep 0.5

# 2. まだ生きていたらSIGKILL
if pgrep -x Mouse2Mouse > /dev/null; then
    echo "Still running, sending SIGKILL..."
    killall -9 Mouse2Mouse 2>/dev/null
fi

# 3. Python経由でカーソルロックを強制解除
echo "Releasing cursor lock..."
python3 -c "
import ctypes
import ctypes.util

cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library('CoreGraphics'))
cg.CGAssociateMouseAndMouseCursorPosition(1)
print('Cursor lock released')
" 2>/dev/null || echo "Python fallback failed (cursor may already be unlocked)"

echo "=== Recovery complete ==="
