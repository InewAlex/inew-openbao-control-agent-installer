# Эксплуатация и выпуск

Автор: INew

## Проверка комплекта

После распаковки Release asset выполните:

```bash
bash ./verify-release.sh
bash -n ./install.sh
```

Успешная проверка завершается строкой `release_valid sha256=<хеш>`.

## Службы и файлы

Для среды `<env>` используются:

- служба `inew-openbao-control-agent@<env>.service`;
- конфигурация `/etc/inew-openbao-control-agent/<env>/agent.json`;
- состояние `/var/lib/inew-openbao-control-agent/<env>`;
- аудит `/var/log/inew-openbao-control-agent/<env>`;
- резервные копии Agent `/var/backups/inew-openbao-control-agent/<env>`;
- Nginx `/etc/nginx/conf.d/inew-openbao-control-agent-<env>.conf`;
- версии `/opt/inew-openbao-control-agent/releases/<version>` и независимая ссылка `current-<env>`.

Каталог распаковки Release asset не является каталогом установки. Допустимо скачать и распаковать архив в созданный через `mktemp -d` временный каталог: после успешного `sudo ./install.sh` служба использует только постоянные пути выше. Для DEV точкой запуска является `/opt/inew-openbao-control-agent/current-dev/inew-openbao-control-agent`, для PROD — `/opt/inew-openbao-control-agent/current-prod/inew-openbao-control-agent`.

Проверка фактических путей после установки DEV:

```bash
readlink -f /opt/inew-openbao-control-agent/current-dev
systemctl cat inew-openbao-control-agent@dev.service
systemctl is-enabled inew-openbao-control-agent@dev.service
systemctl is-active inew-openbao-control-agent@dev.service
```

Первая команда должна показать каталог `/opt/inew-openbao-control-agent/releases/<version>`, а `ExecStart` — путь через `current-dev`. Для PROD замените `dev` на `prod`.

Быстрая диагностика:

```bash
sudo systemctl status inew-openbao-control-agent@dev.service
sudo journalctl -u inew-openbao-control-agent@dev.service --since today
sudo nginx -t
curl --fail http://127.0.0.1:9120/api/v1/health
```

Замените `dev` и порт на значения нужной среды. Не отправляйте журнал в публичный issue без обезличивания.

## Новый одноразовый код привязки

На уже установленной среде временно остановите службу, создайте код от имени её системного пользователя и сразу запустите службу:

```bash
sudo systemctl stop inew-openbao-control-agent@dev.service
sudo -u inew-openbao-agent-dev /opt/inew-openbao-control-agent/current-dev/inew-openbao-control-agent \
  --config /etc/inew-openbao-control-agent/dev/agent.json --create-pairing
sudo systemctl start inew-openbao-control-agent@dev.service
```

Код вводится в OpenBao Manager и не должен сохраняться в тикете, истории команд или общем чате.

## Откат

При ошибке установщик автоматически восстанавливает заменённые файлы и прежнее состояние службы. Путь к резервной копии выводится после успешной установки. Системный пользователь и созданные каталоги намеренно не удаляются автоматически: это исключает потерю состояния при ошибочном определении принадлежности файлов.

Для ручного отката остановите службу, восстановите только нужные файлы из указанного `install-<timestamp>-<env>`, верните прежнюю ссылку `current`, затем выполните:

```bash
sudo systemctl daemon-reload
sudo nginx -t
sudo systemctl restart inew-openbao-control-agent@dev.service
sudo systemctl reload nginx
```

## Правила выпуска

1. Публичный Git ZIP содержит только текстовые файлы репозитория и не содержит `release/`.
2. GitHub Release asset содержит те же файлы плюс `release/inew-openbao-control-agent`, `manifest.json` и `SHA256SUMS`.
3. Версия Release должна совпадать с `version` в manifest.
4. SHA-256 архива публикуется в описании GitHub Release по независимому каналу формирования комплекта.
5. До публикации проверяются разрешённый состав, отсутствие ссылок, секретов и внутренних путей.
6. Версия 1 является офлайн-релизом без цифровой подписи и автоматического обновления.
