#!/usr/bin/env bash
# DeerFlow Service Manager — Interactive menu for starting/stopping services
# Usage: bash scripts/__deerflow-menu.sh

set -e

REPO_ROOT="$(builtin cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "$REPO_ROOT"

# ── PID files ────────────────────────────────────────────────────────────────
PID_DIR="$REPO_ROOT/.deer-flow"
GW_PID_FILE="$PID_DIR/gateway.pid"
FE_PID_FILE="$PID_DIR/frontend.pid"
NGX_PID_FILE="$PID_DIR/nginx.pid"

# ── Colors ───────────────────────────────────────────────────────────────────
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
cyan()   { echo -e "\033[36m$*\033[0m"; }

# ── PID helpers ──────────────────────────────────────────────────────────────
_is_running() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_get_pid() {
    local f="$1"
    if [ -f "$f" ]; then
        local pid
        pid=$(cat "$f" 2>/dev/null)
        if _is_running "$pid"; then
            echo "$pid"
        else
            rm -f "$f"
        fi
    fi
}

_ensure_pid_dir() {
    mkdir -p "$PID_DIR"
}

# ── Log rotation ─────────────────────────────────────────────────────────────
_rotate_log() {
    local log_file="$1"
    if [ ! -f "$log_file" ]; then
        return 0
    fi
    local size
    size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
    if [ "$size" -gt 10485760 ]; then
        mv "$log_file" "${log_file}.$(date +%Y%m%d_%H%M%S).bak"
    fi
}

LOCAL_NGINX_DIR="$REPO_ROOT/.tools/nginx"
LOCAL_NGINX_EXE="$LOCAL_NGINX_DIR/nginx.exe"

_ensure_nginx_in_path() {
    if ! command -v nginx >/dev/null 2>&1 && [ -f "$LOCAL_NGINX_EXE" ]; then
        export PATH="$LOCAL_NGINX_DIR:$PATH"
        green "Using bundled nginx from $LOCAL_NGINX_DIR"
    fi
}

# ── Status ───────────────────────────────────────────────────────────────────
show_status() {
    local gw_pid fe_pid ngx_pid
    gw_pid=$(_get_pid "$GW_PID_FILE")
    fe_pid=$(_get_pid "$FE_PID_FILE")
    ngx_pid=$(_get_pid "$NGX_PID_FILE")

    echo ""
    cyan "========== DeerFlow Service Manager =========="
    echo ""

    if [ -n "$gw_pid" ]; then
        echo -n "  Gateway  : "; green "running  (PID: $gw_pid, http://localhost:8001)"
    else
        echo -n "  Gateway  : "; red   "stopped"
    fi

    if [ -n "$fe_pid" ]; then
        echo -n "  Frontend : "; green "running  (PID: $fe_pid, http://localhost:3000)"
    else
        echo -n "  Frontend : "; red   "stopped"
    fi

    if [ -n "$ngx_pid" ]; then
        echo -n "  Nginx    : "; green "running  (PID: $ngx_pid, http://localhost:2026)"
    else
        echo -n "  Nginx    : "; red   "stopped"
    fi

    echo ""
    cyan "=============================================="
    echo ""
}

# ── Cleanup stale ports (Windows-friendly) ───────────────────────────────────
cleanup_ports() {
    local killed=false
    for port in 8001 3000 2026; do
        # Windows netstat: TCP  0.0.0.0:8001  0.0.0.0:0  LISTENING  1234
        local pid
        pid=$(netstat -ano 2>/dev/null | awk -v p=":$port " '$0 ~ p && /LISTENING/ {print $NF; exit}')
        if [ -n "$pid" ] && [ "$pid" != "0" ]; then
            yellow "  Port $port occupied by PID $pid, killing..."
            cmd //c "taskkill /F /PID $pid" >/dev/null 2>&1 || true
            killed=true
        fi
    done
    $killed && sleep 1 || true
}

# ── Start ────────────────────────────────────────────────────────────────────
start_all() {
    _ensure_pid_dir
    _ensure_nginx_in_path

    local gw_pid fe_pid ngx_pid
    gw_pid=$(_get_pid "$GW_PID_FILE")
    fe_pid=$(_get_pid "$FE_PID_FILE")
    ngx_pid=$(_get_pid "$NGX_PID_FILE")

    if [ -n "$gw_pid" ] || [ -n "$fe_pid" ] || [ -n "$ngx_pid" ]; then
        yellow "Some services already running. Restarting..."
        stop_all
        sleep 1
    fi

    cleanup_ports

    # Nginx now passes $http_host (includes port) so origin matches.
    # Keep this as a fallback safety net.
    export GATEWAY_CORS_ORIGINS="http://localhost:2026"

    echo "Starting DeerFlow services (dev mode)..."
    echo "  This may take 30-60 seconds."
    echo ""

    mkdir -p logs
    mkdir -p temp/client_body_temp temp/proxy_temp temp/fastcgi_temp temp/uwsgi_temp temp/scgi_temp

    # Rotate logs if they exceed 10MB
    _rotate_log "$REPO_ROOT/logs/gateway.log"
    _rotate_log "$REPO_ROOT/logs/frontend.log"
    _rotate_log "$REPO_ROOT/logs/nginx.log"

    # Gateway — use exec in subshell so $! is the uvicorn PID, not a shell wrapper
    echo -n "Starting Gateway... "
    (
        cd backend
        PYTHONPATH=. exec uv run uvicorn app.gateway.app:app \
            --host 0.0.0.0 --port 8001 \
            --reload --reload-include='*.yaml' --reload-include='.env' \
            --reload-exclude='*.pyc' --reload-exclude='__pycache__' \
            --reload-exclude='sandbox/' --reload-exclude='.deer-flow/' \
            > ../logs/gateway.log 2>&1
    ) &
    echo $! > "$GW_PID_FILE"
    sleep 2
    gw_pid=$(_get_pid "$GW_PID_FILE")
    if [ -n "$gw_pid" ]; then
        green "OK (PID: $gw_pid)"
    else
        red "FAILED"
        yellow "Check logs/gateway.log"
        return 1
    fi

    # Frontend
    echo -n "Starting Frontend... "
    (
        cd frontend
        exec pnpm run dev > ../logs/frontend.log 2>&1
    ) &
    echo $! > "$FE_PID_FILE"
    sleep 3
    fe_pid=$(_get_pid "$FE_PID_FILE")
    if [ -n "$fe_pid" ]; then
        green "OK (PID: $fe_pid)"
    else
        red "FAILED"
        yellow "Check logs/frontend.log"
        return 1
    fi

    # Nginx
    echo -n "Starting Nginx... "
    (
        exec nginx -g 'daemon off;' -c "$REPO_ROOT/docker/nginx/nginx.local.conf" -p "$REPO_ROOT" > logs/nginx.log 2>&1
    ) &
    echo $! > "$NGX_PID_FILE"
    sleep 1
    ngx_pid=$(_get_pid "$NGX_PID_FILE")
    if [ -n "$ngx_pid" ]; then
        green "OK (PID: $ngx_pid)"
    else
        red "FAILED"
        yellow "Check logs/nginx.log"
        return 1
    fi

    echo ""
    green "All services started"
    echo "  Access: http://localhost:2026"
    echo ""
}

# ── Stop ─────────────────────────────────────────────────────────────────────
stop_all() {
    echo "Stopping DeerFlow services..."

    local pid
    pid=$(_get_pid "$GW_PID_FILE")
    if [ -n "$pid" ]; then
        echo -n "  Gateway  ... "
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        if _is_running "$pid"; then
            kill -9 "$pid" 2>/dev/null || cmd //c "taskkill /F /PID $pid" >/dev/null 2>&1 || true
        fi
        rm -f "$GW_PID_FILE"
        green "stopped"
    fi

    pid=$(_get_pid "$FE_PID_FILE")
    if [ -n "$pid" ]; then
        echo -n "  Frontend ... "
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        if _is_running "$pid"; then
            kill -9 "$pid" 2>/dev/null || cmd //c "taskkill /F /PID $pid" >/dev/null 2>&1 || true
        fi
        rm -f "$FE_PID_FILE"
        green "stopped"
    fi

    pid=$(_get_pid "$NGX_PID_FILE")
    if [ -n "$pid" ]; then
        echo -n "  Nginx    ... "
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        if _is_running "$pid"; then
            kill -9 "$pid" 2>/dev/null || cmd //c "taskkill /F /PID $pid" >/dev/null 2>&1 || true
        fi
        rm -f "$NGX_PID_FILE"
        green "stopped"
    fi

    # Fallback: brute-force any remaining port holders
    for port in 8001 3000 2026; do
        local stale
        stale=$(netstat -ano 2>/dev/null | awk -v p=":$port " '$0 ~ p && /LISTENING/ {print $NF; exit}')
        if [ -n "$stale" ] && [ "$stale" != "0" ]; then
            cmd //c "taskkill /F /PID $stale" >/dev/null 2>&1 || true
        fi
    done

    green "All services stopped"
    sleep 0.5
}

restart_all() {
    stop_all
    sleep 1
    start_all
}

sync_upstream() {
    echo ""
    cyan "========== Sync main with upstream =========="
    echo ""

    if ! git remote | grep -q "^upstream$"; then
        red "No 'upstream' remote found."
        yellow "Add it with: git remote add upstream https://github.com/bytedance/deer-flow.git"
        return 1
    fi

    # Stop services before sync to avoid port/build conflicts
    local any_running=false
    if [ -n "$(_get_pid "$GW_PID_FILE")" ] || [ -n "$(_get_pid "$FE_PID_FILE")" ] || [ -n "$(_get_pid "$NGX_PID_FILE")" ]; then
        any_running=true
        yellow "Services running, stopping before sync..."
        stop_all
        sleep 1
    fi

    # Auto-commit if working tree is dirty
    if [ -n "$(git status --porcelain)" ]; then
        yellow "Working tree is dirty, auto-committing..."
        git add -A
        if ! git commit -m "auto: sync upstream $(date '+%Y-%m-%d %H:%M:%S')"; then
            red "Auto-commit failed"
            return 1
        fi
        green "Auto-commit done"
    fi

    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD)

    # Switch to main for sync
    if [ "$original_branch" != "main" ]; then
        echo "Switching to main..."
        if ! git checkout main; then
            red "Failed to checkout main"
            return 1
        fi
    fi

    local pre_hash
    pre_hash=$(git rev-parse HEAD)

    echo "Fetching upstream..."
    if ! git fetch upstream; then
        red "Fetch upstream failed"
        [ "$original_branch" != "main" ] && git checkout "$original_branch"
        return 1
    fi

    echo "Merging upstream/main..."
    if ! git merge upstream/main --no-edit; then
        red "Merge conflict! Resolve manually, then run again."
        return 1
    fi

    local post_hash
    post_hash=$(git rev-parse HEAD)

    if [ "$pre_hash" = "$post_hash" ]; then
        green "Already up to date."
    else
        if git diff --name-only "$pre_hash" "$post_hash" | grep -q "^frontend/"; then
            yellow "Frontend changes detected, running build check..."
            cd frontend
            if pnpm build > ../logs/frontend-build.log 2>&1; then
                green "Build check passed"
            else
                red "Build failed! Check logs/frontend-build.log"
                cd "$REPO_ROOT"
                return 1
            fi
            cd "$REPO_ROOT"
        fi

        echo "Pushing to origin..."
        if ! git push origin main; then
            red "Push failed"
            [ "$original_branch" != "main" ] && git checkout "$original_branch"
            return 1
        fi
        green "Push successful"
    fi

    # Switch back to original branch and auto-rebase
    if [ "$original_branch" != "main" ]; then
        echo "Switching back to $original_branch..."
        git checkout "$original_branch"
        echo "Rebasing $original_branch onto main..."
        if git rebase main; then
            green "Rebase successful"
        else
            red "Rebase conflict! Resolve manually, then run: git rebase --continue"
            return 1
        fi
    fi

    # Restart services if they were running before sync
    if [ "$any_running" = true ]; then
        echo ""
        yellow "Restarting services..."
        start_all
    fi

    echo ""
}

# ── Menu ─────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    show_status

    echo "  1) Start all services    (dev mode)"
    echo "  2) Stop all services"
    echo "  3) Restart services"
    echo "  4) Sync main with upstream"
    echo ""
    echo "  0) Exit"
    echo ""
    read -r -p "  Select [0-4]: " choice
    echo ""

    case "$choice" in
        1) start_all ;;
        2) stop_all ;;
        3) restart_all ;;
        4) sync_upstream ;;
        0)
            # stop_all
            echo "Bye."
            exit 0
            ;;
        *) red "Invalid choice: $choice" ;;
    esac

    if [ "$choice" != "0" ]; then
        echo ""
        read -r -p "Press Enter to continue..."
    fi
}

# ── Init ─────────────────────────────────────────────────────────────────────
init_tools() {
    local nginx_dir="$REPO_ROOT/.tools/nginx"
    local nginx_url="https://nginx.org/download/nginx-1.29.8.zip"

    if [ ! -f "$nginx_dir/nginx.exe" ]; then
        yellow "Bundled nginx not found, downloading..."
        mkdir -p "$nginx_dir"
        local zip_file="$REPO_ROOT/.tools/nginx.zip"
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "$zip_file" "$nginx_url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$zip_file" "$nginx_url"
        else
            red "Neither curl nor wget found. Please install one of them."
            return 1
        fi
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$zip_file" -d "$REPO_ROOT/.tools/"
            mv "$REPO_ROOT/.tools/nginx-1.29.8"/* "$nginx_dir/"
            rm -rf "$REPO_ROOT/.tools/nginx-1.29.8" "$zip_file"
            green "Nginx downloaded to $nginx_dir"
        else
            red "unzip not found. Please install unzip."
            return 1
        fi
    fi
}

# ── Main loop ────────────────────────────────────────────────────────────────
main() {
    init_tools
    while true; do
        show_menu
    done
}

main
