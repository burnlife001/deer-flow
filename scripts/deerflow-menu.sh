#!/usr/bin/env bash
# DeerFlow Service Manager — Interactive menu for starting/stopping services
# Usage: bash scripts/deerflow-menu.sh

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
        echo -n "  Gateway  : "; green "running  (PID: $gw_pid, port: 8001)"
    else
        echo -n "  Gateway  : "; red   "stopped"
    fi

    if [ -n "$fe_pid" ]; then
        echo -n "  Frontend : "; green "running  (PID: $fe_pid, port: 3000)"
    else
        echo -n "  Frontend : "; red   "stopped"
    fi

    if [ -n "$ngx_pid" ]; then
        echo -n "  Nginx    : "; green "running  (PID: $ngx_pid, port: 2026)"
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
    $killed && sleep 1
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

    # Nginx proxy_set_header Host $host strips the port, so the backend sees
    # Host=localhost while the browser sends Origin=http://localhost:2026.
    # CSRF middleware rejects this mismatch. Explicitly whitelist the proxy URL.
    export GATEWAY_CORS_ORIGINS="http://localhost:2026"

    echo "Starting DeerFlow services (dev mode)..."
    echo "  This may take 30-60 seconds."
    echo ""

    mkdir -p logs
    mkdir -p temp/client_body_temp temp/proxy_temp temp/fastcgi_temp temp/uwsgi_temp temp/scgi_temp

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

pull_build_push() {
    echo ""
    cyan "========== Pull → Build → Push =========="
    echo ""

    if ! git remote | grep -q "^upstream$"; then
        red "No 'upstream' remote found."
        yellow "Add it with: git remote add upstream https://github.com/bytedance/deer-flow.git"
        return 1
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "main" ]; then
        red "Current branch is '$branch', not main. Switch to main first."
        return 1
    fi

    local pre_hash
    pre_hash=$(git rev-parse HEAD)

    local stashed=false
    if [ -n "$(git status --porcelain)" ]; then
        yellow "Local changes detected, stashing..."
        git stash push -m "deerflow-menu-auto-stash-$(date +%s)"
        stashed=true
    fi

    echo "Fetching upstream..."
    if ! git fetch upstream; then
        red "Fetch upstream failed"
        [ "$stashed" = true ] && git stash pop
        return 1
    fi

    echo "Merging upstream/main..."
    if ! git merge upstream/main --no-edit; then
        red "Merge conflict! Resolve manually, then run again."
        [ "$stashed" = true ] && yellow "Your changes are stashed: git stash list"
        return 1
    fi

    local post_hash
    post_hash=$(git rev-parse HEAD)
    if [ "$pre_hash" = "$post_hash" ]; then
        green "Already up to date."
        [ "$stashed" = true ] && git stash pop
        return 0
    fi

    if git diff --name-only "$pre_hash" "$post_hash" | grep -q "^frontend/"; then
        yellow "Frontend changes detected, running build check..."
        cd frontend
        if pnpm build > ../logs/frontend-build.log 2>&1; then
            green "Build check passed"
        else
            red "Build failed! Check logs/frontend-build.log"
            cd "$REPO_ROOT"
            [ "$stashed" = true ] && yellow "Run 'git stash pop' after fixing."
            return 1
        fi
        cd "$REPO_ROOT"
    fi

    echo "Pushing to origin..."
    if git push origin main; then
        green "Push successful"
    else
        red "Push failed"
        [ "$stashed" = true ] && git stash pop
        return 1
    fi

    [ "$stashed" = true ] && git stash pop
    echo ""
}

# ── Menu ─────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    show_status

    echo "  1) Start all services    (dev mode)"
    echo "  2) Stop all services"
    echo "  3) Restart services"
    echo "  4) Pull → Build → Push"
    echo ""
    echo "  0) Exit"
    echo ""
    read -r -p "  Select [0-4]: " choice
    echo ""

    case "$choice" in
        1) start_all ;;
        2) stop_all ;;
        3) restart_all ;;
        4) pull_build_push ;;
        0)
            stop_all
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

# ── Main loop ────────────────────────────────────────────────────────────────
main() {
    while true; do
        show_menu
    done
}

main
