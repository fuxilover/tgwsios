# TG WS Proxy (iOS tweak)

Локальный SOCKS5→WebSocket(TLS) мост для Telegram на джейлбрейке, идейно
как [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy), но
не порт кода, а независимая реализация под iOS, использующая тот же
подход, что и официальный Android-порт этого проекта: **локальный
SOCKS5-прокси**, на который Telegram настраивается через свою же
встроенную функцию "Прокси" — без перехвата системного трафика.

## Как это работает

```
Telegram iOS → SOCKS5 (127.0.0.1:1080) → tgwsproxyd → wss:// → Telegram DC
                                                    ↘ (fallback) прямой TCP
```

- `tgwsproxyd` — launchd-демон (Tool), слушает `127.0.0.1:1080`, поднимает
  `wss://<dc>.web.telegram.org/apiws` и гоняет байты в обе стороны.
  Если WS не поднялся (таймаут/редирект) — падает обратно на прямой TCP,
  как и апстрим-проект.
- `TGWSProxyAutoConnect` — Logos-твик, инжектится **только** в Telegram
  (`ph.telegra.Telegraph`) и один раз за перезагрузку открывает
  `tg://socks?server=127.0.0.1&port=1080` — это официальная, публично
  задокументированная ссылка самого Telegram для добавления/включения
  SOCKS5-прокси (тот же механизм, что кнопка "Открыть в Telegram" в
  трее десктопной версии).

**Важно и честно:** Telegram сам покажет один раз системный диалог
"Включить этот прокси?" — это его собственная защита, обойти её нельзя
(и не нужно) из твика. После одного тапа настройка остаётся навсегда.

## Ограничения (как и у апстрима)

- Реально ускоряются/маскируются только DC2/DC4 (см. `config/tgwsproxy.conf`
  и issues апстрима) — остальные DC просто идут напрямую через TCP.
- Голосовые звонки не проксируются (архитектурное ограничение MTProto-proxy).
- Это не системный VPN — под прокси попадает только трафик Telegram,
  который сам Telegram направит через настроенный SOCKS5.
- Домены `*.web.telegram.org` и путь `/apiws` — публичные, используются
  веб-версией Telegram (webogram/tdweb); если Telegram их сменит,
  поправьте `config/tgwsproxy.conf`.

## Сборка

Нужен Theos на macOS/Linux с iOS SDK (16.5) и `ldid`.

```bash
git clone --recursive https://github.com/theos/theos $THEOS  # если ещё нет
export THEOS=/path/to/theos
cd tgwsproxy-tweak

# rootless (roothide, Dopamine, palera1n rootless) — iOS 15-18
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

# rootful (checkra1n/unc0ver-era, или rootful Dopamine)
make clean package FINALPACKAGE=1
```

Оба `.deb` появятся в `packages/`. Установи через `dpkg -i` по SSH,
Sileo/Zebra, или `filza`.

## Сборка через GitHub Actions (без своего Mac/Linux)

В репозитории есть `.github/workflows/build.yml`. Он сам ставит Theos +
iOS SDK на `macos-latest` раннере и собирает оба `.deb` (rootful и
rootless).

1. Залей папку `tgwsproxy-tweak` в свой GitHub-репозиторий (git init,
   commit, push — или просто загрузи файлы через веб-интерфейс GitHub).
2. Вкладка **Actions** → разреши workflows, если спросит.
3. Запусти вручную: **Actions → Build TG WS Proxy tweak → Run workflow**
   (или просто запушь коммит в `main` — соберётся автоматически).
4. Когда сборка позеленеет, зайди в неё и скачай артефакт
   **tgwsproxy-debs** — внутри будут оба `.deb`-файла.
5. Дальше как обычно: закинь нужный `.deb` на телефон и поставь через
   `dpkg -i` / Sileo / Filza.

Если хочешь ещё и автоматический GitHub Release при пуше тега:
```bash
git tag v1.0.0
git push origin v1.0.0
```
— джоба `release` в workflow прикрепит `.deb`-файлы к релизу.

## Настройка вручную (если не хочешь автопатч)

Просто не ставь `TGWSProxyAutoConnect`, а в Telegram:
`Настройки → Данные и память → Настройки прокси → Добавить прокси`:
- Тип: **SOCKS5**
- Сервер: `127.0.0.1`
- Порт: `1080` (или что указал в `config/tgwsproxy.conf`)
- Логин/пароль: пусто

## Логи и отладка

- `/var/log/tgwsproxy.log` (rootful) или `/var/jb/var/log/tgwsproxy.log` (rootless)
- Перезапуск демона: `launchctl kickstart -k system/com.local.tgwsproxy`
  (путь к сервису может быть `system/` или `gui/501/` в зависимости от
  того, как твой jailbreak грузит LaunchDaemons — если не сработает,
  сделай `launchctl unload`/`load` с полным путём к plist).

## Честно про масштаб

Это чистая переработка идеи apстрима под iOS-демон+твик, а не
построчный порт Python-кода — тонкости апстрима (Fake TLS, CF Worker
фоллбэк, пул WS-соединений, авто-обновление списка CF-доменов) здесь
**не реализованы**, чтобы получить рабочий MVP. Каркас (Makefile,
control, launchd, SOCKS5-парсер, WS-мост, автопатч через `tg://socks`)
рабочий и собираемый; протестируй на устройстве и допили под свои DC/IP,
если Telegram выдаёт другие адреса датацентров в твоём регионе.
