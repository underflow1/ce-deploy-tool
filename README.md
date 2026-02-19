# ce-deploy-tool

Скрипт для развёртывания фронтенда (React/Vite) и бэкенда (Python) на Debian/Ubuntu.

## Требования

- Debian/Ubuntu
- Запуск через `sudo` (не от root напрямую)

## Использование

```bash
sudo ./deploy.sh --front https://github.com/.../ce-candidates-front.git
```

Репозиторий клонируется в `~/ce-candidates-front` (или `~/<имя-репо>`). При повторном запуске выполняется `git pull`.

Режим `--back` пока не реализован.

## Что делает (режим --front)

1. Создаёт/заполняет `.env.production`
2. Устанавливает nginx (если нет)
3. Устанавливает nvm и Node LTS (если нет)
4. Устанавливает npm-зависимости
5. Создаёт каталог сборки и настраивает права
6. Генерирует конфиг nginx (из репо или дефолтный)
7. Настраивает sudoers для `chown` без пароля
8. Запускает `npm run build:prod`

## nginx.template

Шаблон ищется в репозитории проекта. Если нет — используется дефолтный из deploy-tool.

Плейсхолдеры: `{{DOMAIN}}`, `{{SITE_ROOT}}`, `{{BACKEND_HOST}}`, `{{BACKEND_PORT}}`.

## Логирование

Вывод команд (apt, npm, git и т.д.) пишется в `/tmp/ce-deploy-tool-YYYYMMDD-HHMMSS.log`. На экран выводятся только вопросы и результаты шагов.
