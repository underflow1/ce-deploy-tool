#!/bin/bash
set -e

# === Цвета (Hetzner-style) ===
RED='\033[01;31m'
GREEN='\033[01;32m'
YELLOW='\033[01;33m'
BOLD='\033[0;1m'
NOCOL='\033[00m'

echo_red()    { echo -e "${RED}$*${NOCOL}"; }
echo_green()  { echo -e "${GREEN}$*${NOCOL}"; }
echo_yellow() { echo -e "${YELLOW}$*${NOCOL}"; }
echo_bold()   { echo -e "${BOLD}$*${NOCOL}"; }

# === Логирование ===
LOG_FILE="/tmp/ce-deploy-tool-$(date +%Y%m%d-%H%M%S).log"
run_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    "$@" >> "$LOG_FILE" 2>&1
}

trap 'echo_red "Ошибка. Последние строки лога:"; tail -20 "$LOG_FILE" 2>/dev/null; exit 1' ERR

# === Генерация UUID ===
gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32
    fi
}

# === Универсальная обработка .env ===
# process_env example_file target_file overwrite_ask
# Контекст: DOMAIN, DEPLOY_USER, DEPLOY_GROUP, BUILD_OUT_DIR, BACKEND_HOST, BACKEND_PORT и т.д. — глобальные переменные
process_env() {
    local example="$1" target="$2" overwrite_ask="$3"
    local line key val newval default is_placeholder is_secret

    [[ -f "$example" ]] || { echo_red "  Файл не найден: $example"; return 1; }

    if [[ -f "$target" && "$overwrite_ask" == "1" ]]; then
        read -p "  $target существует. Перезаписать? (y/n) [n]: " ans
        [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { echo_green "  Пропуск (не перезаписываем)."; return 0; }
    fi

    > "$target"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
            echo "$line" >> "$target"
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%$'\r'}"
            # Плейсхолдер по содержимому (your-, change-, localhost, example)
            if [[ "$val" =~ (your-|change-|change-in-|example\.|localhost|127\.0\.0\.1) ]]; then
                # Секрет по содержимому (secret|key|password|token|pepper|random)
                if [[ "${val,,}" =~ (secret|key|password|token|pepper|random) ]]; then
                    newval="$(gen_uuid)"
                else
                    case "$key" in
                        BUILD_OUT_DIR) default="${BUILD_OUT_DIR:-/var/www/$DOMAIN}" ;;
                        VITE_API_BASE_URL) default="https://${DOMAIN:-domain}/api/v1" ;;
                        DEPLOY_USER) default="${DEPLOY_USER}" ;;
                        DEPLOY_GROUP) default="${DEPLOY_GROUP:-www-data}" ;;
                        CORS_ORIGINS) default="https://${DOMAIN:-domain}" ;;
                        HOST) default="${BACKEND_HOST:-127.0.0.1}" ;;
                        PORT) default="${BACKEND_PORT:-8000}" ;;
                        DATABASE_URL) default="sqlite:///./ce_candidates.db" ;;
                        *) default="$val" ;;
                    esac
                    [[ -z "$default" ]] && default="$val"
                    read -p "  $key [$default]: " newval
                    newval="${newval:-$default}"
                fi
                echo "${key}=${newval}" >> "$target"
            elif [[ "$key" == "PORT" || "$key" == "HOST" || "$key" == "CORS_ORIGINS" ]] && [[ -n "$DOMAIN" || -n "$BACKEND_PORT" ]]; then
                # Контекстные ключи — предлагаем заменить даже без плейсхолдера
                case "$key" in
                    PORT) default="${BACKEND_PORT:-8000}" ;;
                    HOST) default="${BACKEND_HOST:-127.0.0.1}" ;;
                    CORS_ORIGINS) default="https://${DOMAIN:-domain}" ;;
                    *) default="$val" ;;
                esac
                read -p "  $key [$default]: " newval
                newval="${newval:-$default}"
                echo "${key}=${newval}" >> "$target"
            else
                echo "$line" >> "$target"
            fi
        else
            echo "$line" >> "$target"
        fi
    done < "$example"
    chown "$DEPLOY_USER:$(id -gn "$DEPLOY_USER")" "$target" 2>/dev/null || true
}

# === Проверка: не запуск от root напрямую ===
if [ "$EUID" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    echo_red "Ошибка: запуск от root запрещён по соображениям безопасности."
    echo_yellow "Используйте: sudo ./deploy.sh --front|--back https://github.com/.../repo.git"
    exit 1
fi

# === Требуется sudo ===
if [ "$EUID" -ne 0 ]; then
    echo_red "Ошибка: скрипт требует прав sudo."
    echo_yellow "Запустите: sudo ./deploy.sh --front|--back https://github.com/.../repo.git"
    exit 1
fi

DEPLOY_USER="${SUDO_USER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Проверка существования пользователя
if ! getent passwd "$DEPLOY_USER" &>/dev/null; then
    echo_red "Ошибка: пользователь $DEPLOY_USER не найден."
    exit 1
fi
USER_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
echo_green "Лог: $LOG_FILE"
echo ""

# === Парсинг аргументов ===
MODE=""
REPO_URL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --front)
            MODE="front"
            shift
            if [[ $# -gt 0 && ! "$1" == --* ]]; then
                REPO_URL="$1"
                shift
            fi
            ;;
        --back)
            MODE="back"
            shift
            if [[ $# -gt 0 && ! "$1" == --* ]]; then
                REPO_URL="$1"
                shift
            fi
            ;;
        *)
            if [[ -z "$REPO_URL" && "$1" != --* ]]; then
                REPO_URL="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$MODE" || -z "$REPO_URL" ]]; then
    echo_red "Использование: sudo ./deploy.sh --front|--back https://github.com/.../repo.git"
    exit 1
fi

# Имя репо из URL (ce-candidates-front.git -> ce-candidates-front)
REPO_NAME="$(basename "$REPO_URL" | sed 's/\.git$//')"
REPO_PATH="$USER_HOME/$REPO_NAME"

# === Клонирование / обновление репо ===
echo_bold "=== Репозиторий ==="
command -v git &>/dev/null || { run_log apt-get update -qq; run_log apt-get install -y git; }
if [[ -d "$REPO_PATH/.git" ]]; then
    echo_green "Обновление $REPO_PATH (git pull)..."
    run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "cd '$REPO_PATH' && git pull"
elif [[ -e "$REPO_PATH" ]]; then
    echo_red "Ошибка: $REPO_PATH существует, но не является git-репозиторием."
    exit 1
else
    echo_green "Клонирование $REPO_URL в $REPO_PATH..."
    run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "git clone '$REPO_URL' '$REPO_PATH'"
fi
echo ""

# === Сбор переменных в начале ===
echo_bold "=== Настройка деплоя (режим: $MODE) ==="
echo ""

read -p "Домен (например: candidates-dev.teplobit.ru): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo_red "Домен обязателен."; exit 1; }

read -p "Пользователь [$DEPLOY_USER]: " DEPLOY_USER_INPUT
DEPLOY_USER="${DEPLOY_USER_INPUT:-$DEPLOY_USER}"

read -p "Группа [www-data]: " DEPLOY_GROUP_INPUT
DEPLOY_GROUP="${DEPLOY_GROUP_INPUT:-www-data}"

if [[ "$MODE" == "front" ]]; then
    read -p "Путь для сборки [/var/www/$DOMAIN]: " BUILD_OUT_DIR_INPUT
    BUILD_OUT_DIR="${BUILD_OUT_DIR_INPUT:-/var/www/$DOMAIN}"
    read -p "API URL [https://$DOMAIN/api/v1]: " VITE_API_INPUT
    VITE_API_BASE_URL="${VITE_API_INPUT:-https://$DOMAIN/api/v1}"
    read -p "Хост бэкенда [127.0.0.1]: " BACKEND_HOST_INPUT
    BACKEND_HOST="${BACKEND_HOST_INPUT:-127.0.0.1}"
    read -p "Порт бэкенда [8000]: " BACKEND_PORT_INPUT
    BACKEND_PORT="${BACKEND_PORT_INPUT:-8000}"
elif [[ "$MODE" == "back" ]]; then
    read -p "Порт бэкенда [8000]: " BACKEND_PORT_INPUT
    BACKEND_PORT="${BACKEND_PORT_INPUT:-8000}"
    BACKEND_HOST="127.0.0.1"
fi

echo ""
echo_green "Переменные собраны. Запуск..."
echo ""

# === Функции для режима front ===
deploy_front() {
    local repo="$1"
    local env_prod="$repo/.env.production"
    local env_example="$repo/.env.production.example"

    # --- .env.production ---
    echo_bold "[1/8] Проверка .env.production"
    if [[ -f "$env_example" ]]; then
        process_env "$env_example" "$env_prod" 1
        echo_green "  .env.production готов."
    else
        echo_red "  Не найден .env.production.example"
        exit 1
    fi

    # --- nginx ---
    echo_bold "[2/8] Установка nginx"
    if command -v nginx &>/dev/null; then
        echo_green "  nginx уже установлен."
    else
        run_log apt-get update -qq
        run_log apt-get install -y nginx
        echo_green "  nginx установлен."
    fi

    # --- nvm + Node ---
    echo_bold "[3/8] Установка nvm и Node"
    local nvm_dir="$USER_HOME/.nvm"
    if [[ -d "$nvm_dir" ]]; then
        echo_green "  nvm уже установлен."
    else
        run_log apt-get install -y curl
        run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
        echo_green "  nvm установлен."
    fi

    # bashrc: nvm init (идемпотентно)
    local bashrc="$USER_HOME/.bashrc"
    if [[ -f "$bashrc" ]] && grep -q 'NVM_DIR' "$bashrc" 2>/dev/null; then
        echo_green "  nvm уже добавлен в .bashrc."
    else
        if [[ -f "$bashrc" ]]; then
            echo '' >> "$bashrc"
            echo '# nvm' >> "$bashrc"
            echo 'export NVM_DIR="$HOME/.nvm"' >> "$bashrc"
            echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$bashrc"
            chown "$DEPLOY_USER:$(id -gn "$DEPLOY_USER")" "$bashrc"
            echo_green "  nvm добавлен в .bashrc."
        fi
    fi

    # Node LTS (проверяем именно node, т.к. nvm version — это версия nvm, не Node)
    local node_ok
    node_ok=$(sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && command -v node' 2>/dev/null || true)
    if [[ -n "$node_ok" ]]; then
        echo_green "  Node уже установлен (nvm)."
    else
        run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && nvm install --lts'
        echo_green "  Node LTS установлен."
    fi

    # --- npm install ---
    echo_bold "[4/8] Установка зависимостей npm"
    run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "cd '$repo' && export NVM_DIR=\"\$HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\" && (npm ci 2>/dev/null || npm install)"
    echo_green "  Зависимости установлены."

    # --- BUILD_OUT_DIR ---
    echo_bold "[5/8] Подготовка каталога сборки"
    mkdir -p "$BUILD_OUT_DIR"
    chown "$DEPLOY_USER:$(id -gn "$DEPLOY_USER")" "$BUILD_OUT_DIR"
    echo_green "  Каталог $BUILD_OUT_DIR готов."

    # --- nginx config ---
    echo_bold "[6/8] Генерация конфига nginx"
    local tpl=""
    if [[ -f "$repo/nginx.template" ]]; then
        tpl="$repo/nginx.template"
        echo_green "  Используется nginx.template из репозитория."
    else
        tpl="$SCRIPT_DIR/nginx.template"
        echo_green "  Используется дефолтный nginx.template."
    fi

    local nginx_conf="/etc/nginx/sites-available/$DOMAIN"
    sed -e "s|{{DOMAIN}}|$DOMAIN|g" \
        -e "s|{{SITE_ROOT}}|$BUILD_OUT_DIR|g" \
        -e "s|{{BACKEND_HOST}}|$BACKEND_HOST|g" \
        -e "s|{{BACKEND_PORT}}|$BACKEND_PORT|g" \
        "$tpl" > "$nginx_conf"

    if [[ ! -L "/etc/nginx/sites-enabled/$DOMAIN" ]]; then
        ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    fi
    run_log nginx -t && run_log systemctl reload nginx
    echo_green "  Конфиг nginx создан и активирован."

    # --- sudoers ---
    echo_bold "[7/8] Настройка sudoers"
    local sudoers_file="/etc/sudoers.d/$REPO_NAME"
    # В sudoers спецсимвол : в user:group нужно экранировать
    local sudoers_rule="${DEPLOY_USER} ALL=(ALL) NOPASSWD: /usr/bin/chown -R ${DEPLOY_USER}\\:${DEPLOY_GROUP} ${BUILD_OUT_DIR}"
    # Всегда перезаписываем правило (идемпотентно), т.к. путь/пользователь могли измениться
    echo "$sudoers_rule" > "$sudoers_file"
    chmod 440 "$sudoers_file"
    echo_green "  sudoers настроен."

    # --- build ---
    echo_bold "[8/8] Сборка production"
    run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "cd '$repo' && export NVM_DIR=\"\$HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\" && npm run build:prod"
    echo_green "  Сборка завершена."
}

# === Функция deploy_back ===
deploy_back() {
    local repo="$1"
    local env_file="$repo/.env"
    local env_example="$repo/.env.example"

    # --- .env ---
    echo_bold "[1/6] Проверка .env"
    if [[ -f "$env_example" ]]; then
        process_env "$env_example" "$env_file" 1
        echo_green "  .env готов."
    else
        echo_red "  Не найден .env.example"
        exit 1
    fi

    # --- Python venv ---
    echo_bold "[2/6] Python venv и зависимости"
    command -v python3 &>/dev/null || { run_log apt-get update -qq; run_log apt-get install -y python3; }
    # python3.X-venv — отдельный пакет на Debian/Ubuntu (версия должна совпадать)
    local pyver
    pyver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3")
    python3 -c "import venv" 2>/dev/null || {
        run_log apt-get update -qq
        run_log apt-get install -y "python${pyver}-venv" 2>/dev/null || run_log apt-get install -y python3-venv
    }
    if [[ -d "$repo/.venv" ]]; then
        echo_green "  venv уже существует."
    else
        run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "cd '$repo' && python3 -m venv .venv"
        echo_green "  venv создан."
    fi
    run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "cd '$repo' && .venv/bin/pip install -r requirements.txt -q"
    echo_green "  Зависимости установлены."

    # --- Alembic ---
    echo_bold "[3/6] Миграции БД"
    run_log sudo -u "$DEPLOY_USER" env HOME="$USER_HOME" bash -c "cd '$repo' && .venv/bin/alembic upgrade head"
    echo_green "  Миграции применены."

    # --- systemd service ---
    echo_bold "[4/6] systemd service"
    local tpl=""
    if [[ -f "$repo/backend.service" ]]; then
        tpl="$repo/backend.service"
        echo_green "  Используется backend.service из репозитория."
    else
        tpl="$SCRIPT_DIR/backend.service.template"
        echo_green "  Используется дефолтный backend.service.template."
    fi

    local svc_name="${REPO_NAME}.service"
    local svc_file="/etc/systemd/system/$svc_name"
    sed -e "s|{{USER}}|$DEPLOY_USER|g" -e "s|YOUR_USER|$DEPLOY_USER|g" \
        -e "s|{{GROUP}}|$DEPLOY_GROUP|g" -e "s|YOUR_GROUP|$DEPLOY_GROUP|g" \
        -e "s|{{PROJECT_DIR}}|$repo|g" -e "s|PROJECT_DIR|$repo|g" \
        "$tpl" > "$svc_file"
    run_log systemctl daemon-reload
    run_log systemctl enable "$svc_name"
    run_log systemctl restart "$svc_name"
    echo_green "  Сервис $svc_name запущен."

    # --- Проверка ---
    echo_bold "[5/6] Проверка"
    sleep 2
    if systemctl is-active --quiet "$svc_name"; then
        echo_green "  Сервис работает."
    else
        echo_red "  Сервис не запустился. Проверьте: journalctl -u $svc_name -n 50"
        exit 1
    fi

    echo_bold "[6/6] Готово"
}

# === Запуск ===
case "$MODE" in
    front)
        deploy_front "$REPO_PATH"
        echo ""
        echo_bold "Готово."
        echo_green "Фронтенд развёрнут в $BUILD_OUT_DIR"
        ;;
    back)
        deploy_back "$REPO_PATH"
        echo ""
        echo_bold "Готово."
        echo_green "Бэкенд развёрнут. Сервис: ${REPO_NAME}.service"
        ;;
    *)
        echo_red "Неизвестный режим: $MODE"
        exit 1
        ;;
esac

echo_green "Лог: $LOG_FILE"
