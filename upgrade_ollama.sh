#!/bin/bash

set -e
set -o pipefail

echo "🔄 Ollama 升级脚本 for FnOS, 脚本v2.3.0"

# 1. 查找 Ollama 安装路径
echo "🔍 查找 Ollama 安装路径..."
VOL_PREFIXES=(/vol1 /vol2 /vol3 /vol4 /vol5 /vol6 /vol7 /vol8 /vol9)
AI_INSTALLER=""

# 遍历寻找 ollama 安装目录
for vol in "${VOL_PREFIXES[@]}"; do
    if [ -d "$vol/@appcenter/ai_installer/ollama" ]; then
        AI_INSTALLER="$vol/@appcenter/ai_installer"
        echo "✅ 找到安装路径：$AI_INSTALLER"
        break
    fi
done

## 如果未找到主安装路径，则检查是否存在中断的备份
if [ -z "$AI_INSTALLER" ]; then
    for vol in "${VOL_PREFIXES[@]}"; do
        testdir="$vol/@appcenter/ai_installer"
        if [ -d "$testdir" ]; then
            cd "$testdir"
            LAST_BK=$(ls -td ollama_bk_* 2>/dev/null | head -n 1)
            if [ -n "$LAST_BK" ] && [ ! -d "ollama" ]; then
                echo "⚠️ 检测到未完成的升级：$testdir 中存在备份 $LAST_BK，但当前没有 ollama/"
                mv "$LAST_BK" ollama
                echo "✅ 已恢复 $LAST_BK 为 ollama/， 请重新执行本脚本更新"
                if [ -x "./ollama/bin/ollama" ]; then
                    ./ollama/bin/ollama --version
                else
                    echo "⚠️ 还原后未找到 ollama 可执行文件，可能备份不完整"
                fi
                exit 0  # ✅ 成功还原后立即退出整个脚本
            fi
        fi
    done

    echo "❌ 未找到 Ollama 安装路径，也没有检测到可恢复的中断备份"
    exit 1
fi

cd "$AI_INSTALLER"

# 2. 打印当前版本
echo "📦 正在检测当前 Ollama 客户端版本..."

if [ -x "./ollama/bin/ollama" ]; then
    VERSION_RAW=$(./ollama/bin/ollama --version 2>&1)
    CLIENT_VER=$(echo "$VERSION_RAW" | grep -i "client version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    if [ -n "$CLIENT_VER" ]; then
        echo "📦 当前已安装版本：v$CLIENT_VER（客户端）"
    else
        echo "⚠️ 无法获取版本号，原始输出如下："
        echo "$VERSION_RAW"
    fi
else
    echo "❌ 未找到 ollama 可执行文件"
fi

# 3. 询问是否使用 GitHub 代理
echo ""
echo "🌏 是否使用 GitHub 代理加速？（同时用于版本检测和下载）"
echo "   常用代理示例："
echo "     - https://ghgo.xyz/"
echo "     - https://gh-proxy.com/"
echo "     - https://github.moeyy.xyz/"
echo ""
read -r -p "请输入代理地址（直接回车跳过，不使用代理）： " PROXY_URL < /dev/tty

if [ -n "$PROXY_URL" ]; then
    PROXY_URL="${PROXY_URL%/}"
    echo "✅ 使用代理：$PROXY_URL"
else
    echo "ℹ️ 不使用代理，直接连接 GitHub"
fi

# 4. 获取最新版本号
FILENAME="ollama-linux-amd64.tar.zst"
RELEASES_URL="https://github.com/ollama/ollama/releases"
if [ -n "$PROXY_URL" ]; then
    RELEASES_URL="${PROXY_URL}/${RELEASES_URL}"
fi

echo "🌐 获取 Ollama 最新版本号..."
LATEST_TAG=$(curl -sL "$RELEASES_URL" | grep -oP '/ollama/ollama/releases/tag/\K[^"]+' | head -n 1)

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 无法从 GitHub 获取 Ollama 最新版本号，请检查网络连接或代理设置"
    exit 1
fi

echo "📦 最新版本号：$LATEST_TAG"

# 构造下载地址
GITHUB_URL="https://github.com/ollama/ollama/releases/download/$LATEST_TAG/$FILENAME"
if [ -n "$PROXY_URL" ]; then
    URL="${PROXY_URL}/${GITHUB_URL}"
else
    URL="$GITHUB_URL"
fi

# ========== Ollama 升级 ==========
if [ "$CLIENT_VER" = "${LATEST_TAG#v}" ]; then
    echo "✅ Ollama 当前已是最新版本（v$CLIENT_VER），无需升级。"
    OLLAMA_UPGRADED=false
else
    echo ""
    echo "📋 Ollama 版本信息："
    echo "   当前版本：v${CLIENT_VER:-未知}"
    echo "   最新版本：$LATEST_TAG"
    read -r -p "❓ 是否升级 Ollama？[Y/n] " CONFIRM_OLLAMA < /dev/tty
    CONFIRM_OLLAMA="${CONFIRM_OLLAMA:-Y}"

    if [[ "$CONFIRM_OLLAMA" =~ ^[Yy]$ ]]; then
        # 如果已有完整文件就跳过下载
        if [ -f "$FILENAME" ]; then
            echo "🔍 检测到本地已有 $FILENAME，验证完整性..."
            if zstd -t "$FILENAME" 2>/dev/null; then
                echo "✅ 本地压缩包完整，跳过下载"
            else
                echo "❌ 本地文件损坏，重新下载"
                rm -f "$FILENAME"
            fi
        fi

        # 如果文件不存在才开始下载
        if [ ! -f "$FILENAME" ]; then
            echo "⬇️ 正在下载版本 $LATEST_TAG ..."
            DOWNLOAD_OK=false

            if command -v aria2c >/dev/null 2>&1; then
                echo "🚀 使用 aria2c 多线程下载..."
                if aria2c -x 16 -s 16 -k 1M -o "$FILENAME" "$URL"; then
                    DOWNLOAD_OK=true
                else
                    echo "⚠️ aria2c 下载失败，尝试使用 curl 重新下载..."
                    rm -f "$FILENAME"
                fi
            fi

            if [ "$DOWNLOAD_OK" = false ]; then
                echo "⬇️ 使用 curl 下载..."
                if curl -L -o "$FILENAME" "$URL"; then
                    DOWNLOAD_OK=true
                else
                    rm -f "$FILENAME"
                fi
            fi

            if [ "$DOWNLOAD_OK" = false ]; then
                echo "❌ 下载失败，请检查网络连接"
                echo "   建议使用 GitHub 代理重新运行脚本"
                exit 1
            fi
        fi

        # 备份旧版本
        BACKUP_NAME="ollama_bk_$(date +%Y%m%d_%H%M%S)"
        mv ollama "$BACKUP_NAME"
        echo "📦 已备份原版 Ollama 为：$BACKUP_NAME"

        # 解压部署新版本
        echo "📦 解压到 ollama/ ..."
        mkdir -p ollama
        tar --use-compress-program=unzstd -xf "$FILENAME" -C ollama

        # 打印新版本确认
        if [ -x "./ollama/bin/ollama" ]; then
            VERSION_RAW=$(./ollama/bin/ollama --version 2>&1)
            NEW_VER=$(echo "$VERSION_RAW" | grep -i "client version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
            if [ -n "$NEW_VER" ]; then
                echo "✅ Ollama 已升级至：v$NEW_VER"
            else
                echo "⚠️ 无法提取版本号，原始输出如下："
                echo "$VERSION_RAW"
            fi
        fi
        OLLAMA_UPGRADED=true
    else
        echo "⏭️ 跳过 Ollama 升级"
        OLLAMA_UPGRADED=false
    fi
fi

# ========== pip 升级 ==========
PIP_DIR="$AI_INSTALLER/python/bin"

# 自动检测 Python 可执行文件路径
PYTHON_EXEC=""
for pybin in /var/apps/ai_installer/target/python/bin/python3.*; do
    if [ -x "$pybin" ] && [[ "$pybin" != *.* ]] 2>/dev/null || [[ "$pybin" =~ python3\.[0-9]+$ ]]; then
        PYTHON_EXEC="$pybin"
        break
    fi
done

if [ -z "$PYTHON_EXEC" ]; then
    PYTHON_EXEC=$(find "$AI_INSTALLER/python/bin" -maxdepth 1 -name 'python3.*' -executable 2>/dev/null | head -n 1)
fi

if [ -z "$PYTHON_EXEC" ]; then
    echo "⚠️ 未找到 Python 可执行文件，跳过 pip 和 open-webui 升级"
else
    echo "🐍 检测到 Python：$PYTHON_EXEC"

    # 获取当前 pip 版本
    CURRENT_PIP_VER=$("$PYTHON_EXEC" -m pip --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)
    LATEST_PIP_VER=$(curl -sL https://pypi.org/pypi/pip/json 2>/dev/null | grep -oP '"version"\s*:\s*"\K[^"]+' | head -n 1)

    echo ""
    echo "📋 pip 版本信息："
    echo "   当前版本：${CURRENT_PIP_VER:-未知}"
    echo "   最新版本：${LATEST_PIP_VER:-获取失败}"

    if [ -n "$CURRENT_PIP_VER" ] && [ "$CURRENT_PIP_VER" = "$LATEST_PIP_VER" ]; then
        echo "✅ pip 当前已是最新版本，无需升级。"
    else
        read -r -p "❓ 是否升级 pip？[Y/n] " CONFIRM_PIP < /dev/tty
        CONFIRM_PIP="${CONFIRM_PIP:-Y}"

        if [[ "$CONFIRM_PIP" =~ ^[Yy]$ ]]; then
            echo "⬆️ 正在升级 pip..."
            "$PYTHON_EXEC" -m pip install --upgrade pip || {
                echo "❌ pip 升级失败，可能是网络问题"
                echo "   请尝试设置代理后重新运行："
                echo "   export https_proxy=http://127.0.0.1:7890"
                echo "   export http_proxy=http://127.0.0.1:7890"
            }
        else
            echo "⏭️ 跳过 pip 升级"
        fi
    fi

    # ========== open-webui 升级 ==========
    if [ -x "$PIP_DIR/pip3" ]; then
        CURRENT_WEBUI_VER=$("$PIP_DIR/pip3" show open_webui 2>/dev/null | grep -i "^Version:" | awk '{print $2}')
        LATEST_WEBUI_VER=$(curl -sL https://pypi.org/pypi/open_webui/json 2>/dev/null | grep -oP '"version"\s*:\s*"\K[^"]+' | head -n 1)

        echo ""
        echo "📋 open-webui 版本信息："
        echo "   当前版本：${CURRENT_WEBUI_VER:-未知}"
        echo "   最新版本：${LATEST_WEBUI_VER:-获取失败}"

        if [ -n "$CURRENT_WEBUI_VER" ] && [ "$CURRENT_WEBUI_VER" = "$LATEST_WEBUI_VER" ]; then
            echo "✅ open-webui 当前已是最新版本，无需升级。"
        else
            read -r -p "❓ 是否升级 open-webui？[Y/n] " CONFIRM_WEBUI < /dev/tty
            CONFIRM_WEBUI="${CONFIRM_WEBUI:-Y}"

            if [[ "$CONFIRM_WEBUI" =~ ^[Yy]$ ]]; then
                echo "⬆️ 正在升级 open-webui..."
                cd "$PIP_DIR"
                ./pip3 install --upgrade open_webui || {
                    echo "❌ open-webui 升级失败"
                    echo "🔎 常见原因：网络不通 / pip太旧 / 无法连接 PyPI"
                    echo "✔️ 可尝试设置代理或手动升级："
                    echo "   export https_proxy=http://127.0.0.1:7890"
                    echo "   export http_proxy=http://127.0.0.1:7890"
                }
            else
                echo "⏭️ 跳过 open-webui 升级"
            fi
        fi
    else
        echo "⚠️ 未找到 pip3，跳过 open-webui 升级"
    fi
fi

echo ""
echo "🎉 操作完成！"
