# ce-deploy-tool

Скрипт для развёртывания фронтенда (React/Vite) и бэкенда (Python) на Debian/Ubuntu.

## Требования

- Debian/Ubuntu
- Запуск через `sudo` (не от root напрямую)

## Использование

```bash
sudo ./deploy.sh --front https://github.com/.../ce-candidates-front.git
sudo ./deploy.sh --back https://github.com/.../ce-candidates-backend.git
```

Репозиторий клонируется в `~/<имя-репо>`. При повторном запуске выполняется `git pull`.

## Что делает (режим --front)

1. Создаёт/заполняет `.env.production`
2. Устанавливает nginx (если нет)
3. Устанавливает nvm и Node LTS (если нет)
4. Устанавливает npm-зависимости
5. Создаёт каталог сборки и настраивает права
6. Генерирует конфиг nginx (из репо или дефолтный)
7. Настраивает sudoers для `chown` без пароля
8. Запускает `npm run build:prod`

## Что делает (режим --back)

1. Создаёт/заполняет `.env` (универсальная логика плейсхолдеров)
2. Создаёт Python venv и устанавливает зависимости
3. Запускает `alembic upgrade head`
4. Генерирует systemd service (из репо или дефолтный)
5. Включает и запускает сервис `<имя-репо>.service`

## .env — универсальная логика

Скрипт парсит `.env.example` / `.env.production.example`:
- **Плейсхолдер** (your-*, change-*, localhost и т.п.): спрашивает значение или генерирует
- **Секрет** (в плейсхолдере есть secret/key/password/token/pepper/random): генерирует UUID
- Если целевой файл существует — спрашивает «Перезаписать?»

## backend.service.template

Шаблон ищется в репозитории проекта. Если нет — используется дефолтный из deploy-tool.

Плейсхолдеры: `{{DOMAIN}}`, `{{SITE_ROOT}}`, `{{BACKEND_HOST}}`, `{{BACKEND_PORT}}`.

Шаблон systemd service ищется в репозитории (`backend.service`). Если нет — используется `backend.service.template`. Плейсхолдеры: `{{USER}}`, `{{GROUP}}`, `{{PROJECT_DIR}}` (или `YOUR_USER`, `YOUR_GROUP`, `PROJECT_DIR`).

## Логирование

Вывод команд (apt, npm, git и т.д.) пишется в `/tmp/ce-deploy-tool-YYYYMMDD-HHMMSS.log`. На экран выводятся только вопросы и результаты шагов.
