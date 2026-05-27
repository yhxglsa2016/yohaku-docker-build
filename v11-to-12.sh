#!/usr/bin/env bash
# ============================================================
# Mix Space v11 → v12 升级脚本（仅适用于容器部署）
# 版本: 1.4.0
# 最后更新: 2026-05-12
# ============================================================

# 不使用 set -e，改为手动控制关键步骤，避免因非致命错误中断整个脚本
set -uo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 错误处理 (仅用于致命错误)
die() {
    echo -e "${RED}[致命错误] $1${NC}" >&2
    exit 1
}

# 0. 权限检查
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "本脚本必须以 root 权限运行。请使用: sudo bash $0"
    fi
}

# -----------------------------------------------------------
# 通用工具函数
# -----------------------------------------------------------

# 检测容器是否全部运行
check_containers_running() {
    local compose_file="$1"
    echo -e "${BLUE}[检查] 正在检测容器运行状态...${NC}"
    docker compose -f "$compose_file" up -d --wait 2>/dev/null || true

    local max_wait=120
    local waited=0
    local interval=5
    echo -n "     "
    while [ $waited -lt $max_wait ]; do
        local all_healthy=true
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local container_status=$(echo "$line" | awk '{print $2}')
            if [ "$container_status" != "running" ] && [ "$container_status" != "Up" ] && ! echo "$line" | grep -qi "healthy"; then
                all_healthy=false
            fi
        done < <(docker compose -f "$compose_file" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2)

        if $all_healthy; then
            echo ""
            echo -e "${GREEN}    ✓ 所有容器均已运行且健康。${NC}"
            return 0
        fi
        sleep $interval
        waited=$((waited + interval))
        echo -n "."
    done

    echo ""
    echo -e "${YELLOW}[警告] 等待超时（${max_wait}秒），请手动确认容器状态后继续。${NC}"
    docker compose -f "$compose_file" ps
    read -rp "是否继续？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        die "用户选择退出。"
    fi
}

# 备份 data 目录 + 旧配置，备份前先停止容器
perform_backup() {
    local work_dir="$1"
    local backup_file="mx-space-full-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    echo -e "${BLUE}[备份] 停止所有服务以保证数据一致性...${NC}"
    cd "$work_dir"
    docker compose down 2>/dev/null || true

    echo -e "${BLUE}[备份] 正在创建完整备份...${NC}"
    if [ -d "./data" ]; then
        tar czf "$backup_file" ./data || die "data 目录备份失败"
        echo -e "${GREEN}    ✓ 数据已备份至: $work_dir/$backup_file${NC}"
    else
        echo -e "${YELLOW}    警告: 未找到 data 目录，跳过数据备份。${NC}"
    fi

    if [ -f "./docker-compose.yml" ]; then
        cp ./docker-compose.yml ./docker-compose.yml.v11.backup || die "旧配置文件备份失败"
        echo -e "${GREEN}    ✓ 旧配置已备份至: docker-compose.yml.v11.backup${NC}"
    else
        echo -e "${YELLOW}    警告: 未找到 docker-compose.yml，跳过配置备份。${NC}"
    fi

    # 备份后重新启动 MongoDB（假设 v11 compose 中 MongoDB 服务名为 mongo）
    echo -e "${BLUE}[提示] 备份完成，重新启动 MongoDB 容器...${NC}"
    if docker compose config --services 2>/dev/null | grep -qw "mongo"; then
        docker compose up -d mongo || echo -e "${YELLOW}    警告: 启动 mongo 服务失败，请手动启动 MongoDB。${NC}"
    else
        echo -e "${YELLOW}    未找到 mongo 服务，请手动确保 MongoDB 可访问。${NC}"
    fi
    sleep 5
    echo -e "${GREEN}    ✓ MongoDB 应该已启动。${NC}"
}

# 迁移日志验证（仅显示关键信息）
verify_migration() {
    local log_file="$1"
    echo ""
    echo -e "${BLUE}============== 迁移日志检查 ==============${NC}"

    if [ ! -f "$log_file" ]; then
        echo -e "${RED}[失败] 未找到迁移日志文件。${NC}"
        return 1
    fi

    if grep -q "✅ Migration finished" "$log_file" 2>/dev/null; then
        echo -e "${GREEN}    ✓ 检测到: ✅ Migration finished${NC}"
    else
        echo -e "${YELLOW}    未检测到完成标记，请仔细检查日志。${NC}"
    fi

    # 显示尾部
    echo ""
    echo -e "${BLUE}-------------- 日志尾部 (最后 30 行) --------------${NC}"
    tail -30 "$log_file"
    echo -e "${BLUE}---------------------------------------------------${NC}"
}

# 自动检测数据库服务名（适用 docker compose）
get_service_name() {
    local compose_file="$1"
    local pattern="$2"   # 用于匹配服务名的 grep 扩展正则
    docker compose -f "$compose_file" config --services 2>/dev/null | grep -Ei "$pattern" | head -1
}

# -----------------------------------------------------------
# 官方方案
# -----------------------------------------------------------
run_official() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  官方 Docker 部署升级${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    while true; do
        read -rp "请输入 docker-compose.yml 所在目录的绝对路径: " WORK_DIR
        if [ -f "$WORK_DIR/docker-compose.yml" ]; then
            echo -e "${GREEN}    ✓ 已找到 docker-compose.yml${NC}"
            cd "$WORK_DIR" || die "无法进入目录 $WORK_DIR"
            break
        else
            echo -e "${RED}    ✗ 该目录下未找到 docker-compose.yml，请重新输入。${NC}"
        fi
    done
    echo -e "${BLUE}[工作目录] $WORK_DIR${NC}"

    # 备份
    echo ""
    echo -e "${BLUE}[步骤 1] 备份数据...${NC}"
    perform_backup "$WORK_DIR"

    # 拉取新配置
    echo ""
    echo -e "${BLUE}[步骤 2] 拉取官方 v12 docker-compose.yml...${NC}"
    wget -O docker-compose.yml "https://fastly.jsdelivr.net/gh/mx-space/core@master/docker-compose.yml" || die "下载新配置失败"
    echo -e "${GREEN}    ✓ 已拉取官方 v12 配置。${NC}"

    # 自动检测新配置中的 postgres 和 redis 服务名
    local pg_service=$(get_service_name "$WORK_DIR/docker-compose.yml" "postgres|db")
    local redis_service=$(get_service_name "$WORK_DIR/docker-compose.yml" "redis")
    if [ -z "$pg_service" ] || [ -z "$redis_service" ]; then
        echo -e "${YELLOW}未能自动检测到 postgres/redis 服务名，请手动输入:${NC}"
        docker compose config --services
        read -rp "PostgreSQL 服务名: " pg_service
        read -rp "Redis 服务名: " redis_service
    fi

    # 启动新数据库
    echo ""
    echo -e "${BLUE}[步骤 3] 启动 PostgreSQL 和 Redis...${NC}"
    docker compose up -d "$pg_service" "$redis_service" || die "启动新数据库服务失败"
    echo -e "${YELLOW}    等待 10 秒确保数据库就绪...${NC}"
    sleep 10
    docker compose ps
    echo ""
    echo -e "${BLUE}[检查] 确认 PostgreSQL 端口映射...${NC}"
    docker port "$pg_service" 5432 || echo -e "${YELLOW}    警告: 未检测到 5432 端口映射，请手动确认。${NC}"

    # 迁移（增加 --allow-missing-refs，并忽略非零退出码）
    echo ""
    echo -e "${BLUE}[步骤 4] 执行 MongoDB → PostgreSQL 数据迁移...${NC}"
    local MIGRATION_LOG="$WORK_DIR/migration-$(date +%Y%m%d-%H%M%S).log"
    echo -e "${YELLOW}    提示: 迁移工具将连接本地 MongoDB (127.0.0.1:27017) 与 PostgreSQL (127.0.0.1:5432)。${NC}"
    echo -e "${YELLOW}    已添加 --allow-missing-refs 参数，缺失引用将被跳过（通常无害）。${NC}"
    read -rp "    确认开始迁移？(y/N): " confirm_migrate
    if [[ ! "$confirm_migrate" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}    已跳过迁移步骤。${NC}"
        return
    fi

    # 临时关闭 set -e，避免迁移的非致命错误导致脚本退出
    set +e
    docker run --rm --network host \
        -e MONGO_URI="mongodb://127.0.0.1:27017/mx-space" \
        -e PG_URL="postgres://mx:mx@127.0.0.1:5432/mx_core" \
        node:22-alpine \
        npx -y @mx-space/mongo-pg-cli@latest --mode apply --allow-missing-refs 2>&1 | tee "$MIGRATION_LOG"
    local migration_exit_code=$?
    set -e

    if [ $migration_exit_code -ne 0 ]; then
        echo -e "${YELLOW}⚠️ 迁移工具返回非零退出码 (${migration_exit_code})，但这可能是由于缺失引用等警告引起。${NC}"
    fi

    echo ""
    verify_migration "$MIGRATION_LOG"

    echo ""
    echo -e "${YELLOW}请检查上述日志。缺失引用（Missing refs）通常是可忽略的残留数据。${NC}"
    echo -e "${YELLOW}如果日志末尾出现 ✅ Migration finished，则表示迁移成功。${NC}"
    echo ""

    while true; do
        read -rp "是否继续启动 v12？(y/N，选择 N 将触发回退): " continue_ok
        case "$continue_ok" in
            [Yy]* ) echo -e "${GREEN}    ✓ 用户确认继续。${NC}"; break ;;
            [Nn]* | "" ) echo -e "${RED}    ✗ 用户选择回退...${NC}"; rollback "$WORK_DIR"; exit 1 ;;
            * ) echo "    请输入 y 或 n。" ;;
        esac
    done

    # 启动全部服务
    echo ""
    echo -e "${BLUE}[步骤 5] 启动 Mix Space v12 全部服务...${NC}"
    docker compose up -d --wait || die "启动 v12 服务失败"
    echo -e "${GREEN}    ✓ 已启动。${NC}"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  升级完成！${NC}"
    echo -e "${GREEN}  - 请打开首页验证文章和评论是否正常${NC}"
    echo -e "${GREEN}  - 登录后台（/proxy/qaqdmin）验证管理功能${NC}"
    echo -e "${GREEN}  - 如有问题，请重新运行本脚本并选择「恢复备份」${NC}"
    echo -e "${GREEN}============================================${NC}"
}

# -----------------------------------------------------------
# 1Panel 定制方案
# -----------------------------------------------------------
run_1panel() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  1Panel 定制部署升级${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    local WORK_DIR="/opt/1panel/apps/local/mxspace/mxspace"
    echo -e "${BLUE}[步骤 1] 检测 1Panel 部署目录: $WORK_DIR${NC}"
    if [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
        die "在 $WORK_DIR 下未找到 docker-compose.yml，请确认路径。"
    fi
    echo -e "${GREEN}    ✓ 已找到 docker-compose.yml${NC}"
    cd "$WORK_DIR" || die "无法进入目录 $WORK_DIR"

    # 备份
    echo ""
    echo -e "${BLUE}[步骤 2] 备份数据...${NC}"
    perform_backup "$WORK_DIR"

    # 拉取新配置
    echo ""
    echo -e "${BLUE}[步骤 3] 拉取 1Panel 定制版 docker-compose.yml...${NC}"
    wget -O docker-compose.yml "https://github.com/IPF-Sinon/yohaku-docker-build/raw/refs/heads/main/docker-compose.yml" || die "下载新配置失败"
    echo -e "${GREEN}    ✓ 已拉取 1Panel 定制版 v12 配置。${NC}"

    # 自动检测新配置中的 postgres 和 redis 服务名
    local pg_service=$(get_service_name "$WORK_DIR/docker-compose.yml" "postgres|db")
    local redis_service=$(get_service_name "$WORK_DIR/docker-compose.yml" "redis")
    if [ -z "$pg_service" ] || [ -z "$redis_service" ]; then
        echo -e "${YELLOW}未能自动检测到 postgres/redis 服务名，请手动输入:${NC}"
        docker compose config --services
        read -rp "PostgreSQL 服务名: " pg_service
        read -rp "Redis 服务名: " redis_service
    fi

    # 启动新数据库
    echo ""
    echo -e "${BLUE}[步骤 4] 启动 PostgreSQL 和 Redis...${NC}"
    docker compose up -d "$pg_service" "$redis_service" || die "启动新数据库服务失败"
    echo -e "${YELLOW}    等待 10 秒确保数据库就绪...${NC}"
    sleep 10
    docker compose ps
    echo ""
    echo -e "${BLUE}[检查] 确认 PostgreSQL 端口映射...${NC}"
    docker port "$pg_service" 5432 || echo -e "${YELLOW}    警告: 未检测到 5432 端口映射，请手动确认。${NC}"

    # 迁移（增加 --allow-missing-refs，并忽略非零退出码）
    echo ""
    echo -e "${BLUE}[步骤 5] 执行 MongoDB → PostgreSQL 数据迁移...${NC}"
    local MIGRATION_LOG="$WORK_DIR/migration-$(date +%Y%m%d-%H%M%S).log"
    echo -e "${YELLOW}    提示: 迁移工具将通过 1panel-network 连接。${NC}"
    echo -e "${YELLOW}      MongoDB:  mxspace-mongo:27017${NC}"
    echo -e "${YELLOW}      PostgreSQL: $pg_service:5432${NC}"
    echo -e "${YELLOW}    已添加 --allow-missing-refs 参数，缺失引用将被跳过。${NC}"
    read -rp "    确认开始迁移？(y/N): " confirm_migrate
    if [[ ! "$confirm_migrate" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}    已跳过迁移步骤。${NC}"
        return
    fi

    # 临时关闭 set -e
    set +e
    docker run --rm --network 1panel-network \
        -e MONGO_URI="mongodb://mxspace-mongo:27017/mx-space" \
        -e PG_URL="postgres://mx:mx@${pg_service}:5432/mx_core" \
        node:22-alpine \
        npx -y @mx-space/mongo-pg-cli@latest --mode apply --allow-missing-refs 2>&1 | tee "$MIGRATION_LOG"
    local migration_exit_code=$?
    set -e

    if [ $migration_exit_code -ne 0 ]; then
        echo -e "${YELLOW}⚠️ 迁移工具返回非零退出码 (${migration_exit_code})，但这可能是由于缺失引用等警告引起。${NC}"
    fi

    echo ""
    verify_migration "$MIGRATION_LOG"

    echo ""
    echo -e "${YELLOW}请检查上述日志。缺失引用（Missing refs）通常是可忽略的残留数据。${NC}"
    echo -e "${YELLOW}如果日志末尾出现 ✅ Migration finished，则表示迁移成功。${NC}"
    echo ""

    while true; do
        read -rp "是否继续启动 v12？(y/N，选择 N 将触发回退): " continue_ok
        case "$continue_ok" in
            [Yy]* ) echo -e "${GREEN}    ✓ 用户确认继续。${NC}"; break ;;
            [Nn]* | "" ) echo -e "${RED}    ✗ 用户选择回退...${NC}"; rollback "$WORK_DIR"; exit 1 ;;
            * ) echo "    请输入 y 或 n。" ;;
        esac
    done

    # 启动全部服务
    echo ""
    echo -e "${BLUE}[步骤 6] 启动 Mix Space v12 全部服务...${NC}"
    docker compose up -d --wait || die "启动 v12 服务失败"
    echo -e "${GREEN}    ✓ 已启动。${NC}"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  升级完成！${NC}"
    echo -e "${GREEN}  - 请打开首页验证文章和评论是否正常${NC}"
    echo -e "${GREEN}  - 登录后台（/proxy/qaqdmin）验证管理功能${NC}"
    echo -e "${GREEN}  - 如有问题，请重新运行本脚本并选择「恢复备份」${NC}"
    echo -e "${GREEN}============================================${NC}"
}

# -----------------------------------------------------------
# 回滚
# -----------------------------------------------------------
rollback() {
    local work_dir="$1"
    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  正在回滚到 v11...${NC}"
    echo -e "${YELLOW}============================================${NC}"

    cd "$work_dir" || die "无法进入目录 $work_dir"
    echo -e "${BLUE}1. 停止所有服务...${NC}"
    docker compose down 2>/dev/null || true

    echo -e "${BLUE}2. 恢复旧 docker-compose.yml...${NC}"
    if [ -f "$work_dir/docker-compose.yml.v11.backup" ]; then
        cp "$work_dir/docker-compose.yml.v11.backup" "$work_dir/docker-compose.yml" || die "恢复配置文件失败"
        echo -e "${GREEN}    ✓ 已恢复 v11 配置。${NC}"
    else
        die "未找到备份文件 docker-compose.yml.v11.backup，无法自动恢复。"
    fi

    echo -e "${BLUE}3. 启动 v11 服务...${NC}"
    docker compose up -d --wait || die "启动 v11 服务失败"
    echo -e "${GREEN}    ✓ v11 已启动。${NC}"
}

# -----------------------------------------------------------
# 恢复备份
# -----------------------------------------------------------
run_restore() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  恢复备份（回滚到 v11）${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    while true; do
        read -rp "请输入 docker-compose.yml 所在目录的绝对路径: " WORK_DIR
        if [ -f "$WORK_DIR/docker-compose.yml" ]; then
            echo -e "${GREEN}    ✓ 已找到 docker-compose.yml${NC}"
            cd "$WORK_DIR" || die "无法进入目录 $WORK_DIR"
            break
        else
            echo -e "${RED}    ✗ 该目录下未找到 docker-compose.yml，请重新输入。${NC}"
        fi
    done

    echo -e "${BLUE}[工作目录] $WORK_DIR${NC}"
    echo ""
    echo -e "${BLUE}执行回滚操作...${NC}"

    echo "    1. 停止所有服务..."
    docker compose down 2>/dev/null || true

    echo "    2. 恢复 v11 配置..."
    if [ -f "$WORK_DIR/docker-compose.yml.v11.backup" ]; then
        cp "$WORK_DIR/docker-compose.yml.v11.backup" "$WORK_DIR/docker-compose.yml" || die "恢复配置文件失败"
        echo -e "${GREEN}       ✓ 已恢复 v11 配置。${NC}"
    else
        die "未找到备份文件 docker-compose.yml.v11.backup。"
    fi

    echo "    3. 启动 v11 服务..."
    docker compose up -d --wait || die "启动 v11 服务失败"
    echo -e "${GREEN}       ✓ v11 已启动。${NC}"

    echo ""
    read -rp "恢复是否成功？(y/N): " restore_ok
    if [[ ! "$restore_ok" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${YELLOW}尝试通过备份的 data 目录恢复...${NC}"
        local latest_backup=$(ls -1t "$WORK_DIR"/mx-space-full-backup-*.tar.gz 2>/dev/null | head -1)
        if [ -z "$latest_backup" ]; then
            die "未找到 data 备份文件，无法继续。"
        fi
        echo -e "${BLUE}    找到备份: $latest_backup${NC}"
        if [ -d "$WORK_DIR/data" ]; then
            rm -rf "$WORK_DIR/data"
        fi
        tar xzf "$latest_backup" -C "$WORK_DIR" || die "解压备份失败"
        echo -e "${GREEN}    ✓ data 目录已恢复。${NC}"
        docker compose down 2>/dev/null || true
        docker compose up -d --wait || die "重新启动服务失败"
        echo -e "${GREEN}    ✓ 服务已启动。${NC}"
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  恢复完成。${NC}"
    echo -e "${GREEN}============================================${NC}"
}

# -----------------------------------------------------------
# 主菜单
# -----------------------------------------------------------
main_menu() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Mix Space v11 → v12 升级脚本${NC}"
    echo -e "${BLUE}  请选择升级方案:${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "  [1] 官方 Docker 部署升级"
    echo "  [2] 1Panel 定制部署升级"
    echo "  [3] 恢复备份（回滚到 v11）"
    echo "  [q] 退出"
    echo ""
    read -rp "请输入选项 (1/2/3/q): " choice

    case "$choice" in
        1) run_official ;;
        2) run_1panel ;;
        3) run_restore ;;
        q|Q) echo "退出。"; exit 0 ;;
        *) die "无效选项，请重新运行脚本。" ;;
    esac
}

# -----------------------------------------------------------
# 入口
# -----------------------------------------------------------
check_root
main_menu
