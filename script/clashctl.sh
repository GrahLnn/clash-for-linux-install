# shellcheck disable=SC2148
# shellcheck disable=SC2155

function clashon() {
    _get_proxy_port
    sudo systemctl start "$BIN_KERNEL_NAME" && _okcat '已开启代理环境' ||
        _failcat '启动失败: 执行 "clashstatus" 查看日志' || return 1

    local auth=$(sudo "$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME")
    [ -n "$auth" ] && auth=$auth@

    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
}

watch_proxy() {
    systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null && [ -z "$http_proxy" ] && {
        _is_root || _failcat '未检测到代理变量，可执行 clashon 开启代理环境' && clashon
    }
}

function clashoff() {
    sudo systemctl stop "$BIN_KERNEL_NAME" && _okcat '已关闭代理环境' ||
        _failcat '关闭失败: 执行 "clashstatus" 查看日志' || return 1

    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}

clashrestart() {
    { clashoff && clashon; } >&/dev/null
}

function clashstatus() {
    sudo systemctl status "$BIN_KERNEL_NAME" "$@"
}

function clashui() {
    # 防止tun模式强制走代理获取不到真实公网ip
    clashoff >&/dev/null
    _get_ui_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
    clashon >&/dev/null
}

_merge_config_restart() {
    local backup="/tmp/rt.backup"
    sudo cat "$CLASH_CONFIG_RUNTIME" 2>/dev/null | sudo tee $backup >&/dev/null
    
    # 创建临时文件用于处理配置合并
    local temp_config="/tmp/clash_merge_temp.yaml"
    local raw_rules="/tmp/raw_rules.yaml"
    local mixin_rules="/tmp/mixin_rules.yaml"
    
    # 首先进行常规配置合并（除了 rules）
    sudo "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item)' "$CLASH_CONFIG_RAW" "$CLASH_CONFIG_MIXIN" | sudo tee "$temp_config" >&/dev/null
    
    # 提取原始配置的 rules
    sudo "$BIN_YQ" '.rules // []' "$CLASH_CONFIG_RAW" | sudo tee "$raw_rules" >&/dev/null
    
    # 提取 mixin 配置的 rules  
    sudo "$BIN_YQ" '.rules // []' "$CLASH_CONFIG_MIXIN" | sudo tee "$mixin_rules" >&/dev/null
    
    # 检查是否存在 rules 需要合并
    local has_mixin_rules=$(sudo "$BIN_YQ" 'length' "$mixin_rules")
    local has_raw_rules=$(sudo "$BIN_YQ" 'length' "$raw_rules")
    
    if [ "$has_mixin_rules" -gt 0 ] || [ "$has_raw_rules" -gt 0 ]; then
        # 合并 rules：mixin rules 优先（放在前面）+ raw rules（放在后面）
        sudo "$BIN_YQ" eval-all '. as $item ireduce ([]; . + $item)' "$mixin_rules" "$raw_rules" | \
        sudo "$BIN_YQ" -i '.rules = input' "$temp_config"
    fi
    
    # 将最终配置写入运行时配置文件
    sudo cat "$temp_config" | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null
    
    # 清理临时文件
    sudo rm -f "$temp_config" "$raw_rules" "$mixin_rules" 2>/dev/null
    
    _valid_config "$CLASH_CONFIG_RUNTIME" || {
        sudo cat $backup | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null
        _error_quit "验证失败：请检查 Mixin 配置"
    }
    clashrestart
}

function clashsecret() {
    case "$#" in
    0)
        _okcat "当前密钥：$(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")"
        ;;
    1)
        sudo "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    # shellcheck disable=SC2015
    [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart
    sleep 0.5s
    sudo journalctl -u "$BIN_KERNEL_NAME" --since "1 min ago" | grep -E -m1 'unsupported kernel version|Start TUN listening error' && {
        _tunoff >&/dev/null
        _error_quit '不支持的内核版本'
    }
    _okcat "Tun 模式已开启"
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

function clashupdate() {
    local url=$(cat "$CLASH_CONFIG_URL")
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        sudo tail "${CLASH_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${CLASH_CONFIG_RAW} 进行更新..."
        url="file://$CLASH_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置定时任务
    [ "$is_auto" = true ] && {
        sudo grep -qs 'clashupdate' "$CLASH_CRON_TAB" || echo "0 0 */2 * * $_SHELL -i -c 'clashupdate $url'" | sudo tee -a "$CLASH_CRON_TAB" >&/dev/null
        _okcat "已设置定时更新订阅" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >&/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >&/dev/null
        _failcat '❌' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" 2>&1 | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
        _error_quit
    }

    _download_config "$CLASH_CONFIG_RAW" "$url" || _rollback "下载失败：已回滚配置"
    _valid_config "$CLASH_CONFIG_RAW" || _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG"

    _merge_config_restart && _okcat '🍃' '订阅更新成功'
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >&/dev/null
    _okcat '✅' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
}

function clashmixin() {
    case "$1" in
    -e)
        sudo vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$CLASH_CONFIG_RUNTIME"
        ;;
    -s)
        # 显示规则融合状态
        local raw_rules_count=$(sudo "$BIN_YQ" '.rules | length' "$CLASH_CONFIG_RAW" 2>/dev/null || echo 0)
        local mixin_rules_count=$(sudo "$BIN_YQ" '.rules | length' "$CLASH_CONFIG_MIXIN" 2>/dev/null || echo 0)
        local runtime_rules_count=$(sudo "$BIN_YQ" '.rules | length' "$CLASH_CONFIG_RUNTIME" 2>/dev/null || echo 0)
        
        _okcat "📊 规则融合状态："
        echo "  原始配置规则数: $raw_rules_count"
        echo "  Mixin 规则数: $mixin_rules_count"  
        echo "  运行时规则总数: $runtime_rules_count"
        echo ""
        
        if [ "$mixin_rules_count" -gt 0 ]; then
            _okcat "🔝 Mixin 规则（高优先级）："
            sudo "$BIN_YQ" '.rules[]' "$CLASH_CONFIG_MIXIN" 2>/dev/null | head -5 | sed 's/^/  /'
            [ "$mixin_rules_count" -gt 5 ] && echo "  ... 还有 $((mixin_rules_count - 5)) 条规则"
            echo ""
        fi
        
        if [ "$raw_rules_count" -gt 0 ]; then
            _okcat "📋 原始配置规则（低优先级）："
            sudo "$BIN_YQ" '.rules[]' "$CLASH_CONFIG_RAW" 2>/dev/null | head -3 | sed 's/^/  /'
            [ "$raw_rules_count" -gt 3 ] && echo "  ... 还有 $((raw_rules_count - 3)) 条规则"
        fi
        ;;
    *)
        less -f "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

function clashctl() {
    case "$1" in
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    ui)
        clashui
        ;;
    status)
        shift
        clashstatus "$@"
        ;;

    tun)
        shift
        clashtun "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    *)
        cat <<EOF

Usage:
    clash      COMMAND  [OPTION]
    mihomo     COMMAND  [OPTION]
    clashctl   COMMAND  [OPTION]
    mihomoctl  COMMAND  [OPTION】

Commands:
    on                   开启代理
    off                  关闭代理
    ui                   面板地址
    status               内核状况
    tun      [on|off]    Tun 模式
    mixin    [-e|-r|-s]  Mixin 配置
                         -e  编辑 Mixin 配置
                         -r  查看运行时配置
                         -s  显示规则融合状态
    secret   [SECRET]    Web 密钥
    update   [auto|log]  更新订阅

EOF
        ;;
    esac
}

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}
