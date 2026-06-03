# XrayTailscale

**Автоматизированная установка личного Xray VLESS Reality на VPS + Tailscale exit node**

**Текущая версия: 2.0**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)
[![Xray](https://img.shields.io/badge/Xray-core-blue.svg)](https://github.com/XTLS/Xray-core)

Требуется личный Xray VLESS для собственных нужд? Впадлу настраивать, хочется автоматизации и удобства? Этот скрипт для тебя.

XrayTailscale ставит Xray-core, создает Reality inbound'ы, генерирует профили, раздает их через HAPP-compatible подписку и умеет поднимать Tailscale exit node на той же VPS. В актуальной архитектуре один профиль больше не равен одному маршруту: профиль содержит набор live routes с одним `sub_token`, а клиент получает их одной короткой ссылкой подписки.

Завайбкодил и бегло перепроверил Киса, недокодер и недо-знайка bash. За последние дни активной разработки и тестов мной было установлено, что регуляции становятся все жестче. В XrayTailscale я вложил и вкладываю все, что способно сохранить доступ к свободному интернету.

---

## Возможности

- [x] Автоматическая установка актуального Xray-core на VPS.
- [x] Multi-route профиль: одна подписка, несколько транспортов.
- [x] HAPP subscription server через `xraytailscale-sub.service` + nginx.
- [x] Public HTTPS subscription по IP VPS или по домену.
- [x] Local-only режим `127.0.0.1:8080` для debug/SSH tunnel.
- [x] HAPP-compatible XHTTP fallback без PQ encryption.
- [x] XHTTP + VLESS post-quantum encryption `mlkem768x25519plus`.
- [x] v2ray-compatible base64 subscription body для v2rayNG/v2rayN.
- [x] Revoke подписки через смену `sub_token`.
- [x] Смена SNI, fingerprint, port и advanced-настроек профиля.
- [x] Bypass routing: выбранные домены можно отправлять напрямую, не через VPN.
- [x] Tailscale exit node: VPS можно добавить в tailnet и использовать как exit node.
- [x] Автоматические миграции существующих профилей при запуске `xraytailscale`.
- [x] TCP BBR и расширенные geo-базы Loyalsoldier.
- [ ] H2, WebSocket, SplitHTTP и Clash/mihomo subscriptions не заявлены как поддерживаемые.

Что изменилось относительно старого `main`:

- AdGuard Home меню удалено. Старые установки с AdGuard Home миграция очищает как deprecated.
- Старый список фиксированных портов неактуален: маршруты создаются на случайных высоких портах.
- Старый режим "выбери один тип профиля" больше не основной: создание профиля сразу создает набор маршрутов.

---

## Запуск и настройка

Вам нужен оплаченный VPS, где и будет работать VPN. После входа на сервер достаточно выполнить одну команду установки. Можно ставить сразу от `root`, но для нормальной безопасности лучше использовать отдельного пользователя с `sudo`; гайд ниже.

### Операционная система

- Debian 10+ (Buster, Bullseye, Bookworm, Trixie)
- Ubuntu 20.04+ (Focal, Jammy, Noble)

> Лично мной все тестировалось в основном на Debian. На других системах работа не гарантируется.

### Ресурсы сервера

- RAM: минимум 512 MB, рекомендуется 1 GB+
- CPU: 1 ядро, рекомендуется 2+
- Диск: минимум 1 GB свободного места
- Доступ: `root` или пользователь с `sudo`

### Деплой в 1 команду

Репозиторий приватный, поэтому для деплоя нужен GitHub token с доступом `Contents: Read-only` к `vshroot/XrayTailscale`.

На VPS выполните одну команду:

```bash
read -rsp 'GitHub token: ' GH_TOKEN; echo; curl -fsSL -H "Authorization: Bearer $GH_TOKEN" https://raw.githubusercontent.com/vshroot/XrayTailscale/main/install.sh | sudo env XRAYTAILSCALE_GITHUB_TOKEN="$GH_TOKEN" bash
```

После установки запускайте меню:

```bash
sudo xraytailscale
```

Внутри приложения под ключевыми пунктами есть пояснения, поэтому с типами маршрутов, режимами подписки и Tailscale exit node можно ознакомиться прямо в терминале.

---

## Рекомендации по безопасности

Из коробки можно установить XrayTailscale прямо на `root`. Однако по-хорошему нужен отдельный пользователь.

На сервере:

```bash
adduser <username>
usermod -aG sudo <username>
su - <username>
```

На вашем ПК, откуда вы заходите по SSH:

```bash
ssh-keygen -t ed25519 -C <your_email@example.com>
ssh-copy-id <username>@<айпи_сервера>
```

Затем подключитесь как `<username>@<айпи_сервера>`. Если вход по ключу работает, можно отключить вход по паролю и опционально запретить root-login.

```bash
sudo nano /etc/ssh/sshd_config
```

Проверьте или выставьте:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

> Внимание: если потеряете SSH-ключи, не сможете зайти на сервер. Убедитесь, что вход по ключу работает, и только потом отключайте пароль.

---

## Быстрый старт с HAPP

1. Запустите меню:

```bash
sudo xraytailscale
```

2. Выберите `9) Подписка HAPP`.

3. Для обычного телефона или клиента выберите один из public-режимов:

| Пункт | Когда использовать |
| --- | --- |
| `1) Создать HAPP-подписку по IP VPS` | Быстрый режим без домена. XrayTailscale создаст multi-route профиль `happ` с 7 маршрутами и даст `https://<ip>/sub/<token>`. IP certificates у Let's Encrypt short-lived, renew должен работать. |
| `2) Создать HAPP-подписку по домену` | Рекомендуется для постоянного использования. XrayTailscale создаст multi-route профиль `happ` с 7 маршрутами и даст `https://sub.example.com/sub/<token>`. |
| `3) local-only debug` | Только для проверки на сервере или через SSH tunnel. Не работает напрямую с телефона. |

4. Импортируйте показанный subscription URL или QR-код в HAPP.

HAPP-flow автоматически создаёт или переиспользует multi-route профиль с набором маршрутов:

| Маршрут | Назначение |
| --- | --- |
| `xhttp-legacy` | HAPP-compatible XHTTP fallback, `decryption=none`, без PQ. |
| `xhttp-pq` | XHTTP + VLESS post-quantum encryption `mlkem768x25519plus`. |
| `tcp-mux` | TCP Reality без Vision-flow, запасной вариант. |
| `grpc` | gRPC Reality, чувствителен к HTTP/2/SNI. |
| `tcp-vision` | Основной быстрый маршрут для HAPP subscription. |
| `tcp-utls-firefox` | TCP Vision с fingerprint Firefox. |
| `tcp-xudp` | TCP Vision + XUDP, узкий fallback для жестких мобильных сетей. |

Для ручного контроля SNI, транспорта или отдельного маршрута используйте `1) Создать новый профиль`.

---

## Как работает подписка

`xraytailscale-sub.service` слушает локально `127.0.0.1:8080`. Наружу его публикует nginx через HTTPS.

Endpoint имеет вид:

```text
https://<domain-or-ip>/sub/<32-hex-token>
```

Токен хранится в profile JSON как `sub_token`. Если токен скомпрометирован, используйте `Revoke` в меню подписки: старый URL перестанет работать.

Поведение по клиентам:

- HAPP получает plain-text список `vless://` routes, HAPP headers и опциональный `happ://routing/onadd/...`.
- В HAPP subscription быстрые TCP/Vision маршруты идут перед XHTTP, чтобы сломанный XHTTP у клиента не становился дефолтным подключением.
- Если есть `xhttp-legacy`, HAPP не получает PQ-XHTTP как XHTTP-кандидат.
- v2rayNG/v2rayN получают классический base64 body без HAPP metadata.
- Старые profile JSON без live inbound не показываются в меню подписки; старые URL возвращают `410 Gone`.

### Домен и DNS

Для доменного режима создайте `A` запись на IPv4 VPS. `AAAA` используйте только если IPv6 реально настроен и доступен на VPS.

Если домен в Cloudflare, для тестов надежнее поставить запись в режим `DNS only`, а не `Proxied`. Certbot должен достучаться до VPS по HTTP challenge на 80 порту.

Если 443 занят Xray или другим сервисом, подписка автоматически уйдет на 8443, и URL будет с портом: `https://domain:8443/sub/<token>`.

### Безопасность подписки

URL подписки нельзя считать публичным. Он защищен opaque token'ом, но любой, кто получил URL, может скачать список routes.

Что уже сделано:

- token 32 hex символа;
- `/sub/<token>` без валидного токена возвращает одинаковый 404;
- stale profile возвращает 410 без выдачи маршрутов;
- nginx добавляет `Cache-Control: no-store`;
- endpoint `/` и любые не-`/sub/` пути возвращают 404;
- есть rate limit на nginx location `/sub/`;
- revoke меняет `sub_token`.

Что нужно делать оператору:

- не публиковать subscription URL в открытых чатах;
- при утечке нажать `Revoke`;
- не использовать local-only URL для внешнего клиента;
- не держать Cloudflare/прокси/панели на том же домене без понимания nginx config.

---

## Главное меню

Актуальные пункты:

| Пункт | Назначение |
| --- | --- |
| `1` | Создать новый профиль вручную: single-route или multi-route. |
| `2` | Удалить профиль и связанные inbound'ы. |
| `3` | Показать данные подключения по профилю. |
| `4` | Управление профилем: SNI, fingerprint, port, advanced. |
| `8` | Обновить отдельный профиль до PQ XHTTP. |
| `9` | HAPP subscription: автоматически создать/переиспользовать 7-route профиль, public TLS, URL/QR/revoke. |
| `10` | Обновить Xray-core. |
| `11` | Bypass routing: домены напрямую, минуя VPN. |
| `12` | Tailscale exit node: установить Tailscale, включить IP forwarding и объявить VPS как exit node. |

Любая смена SNI, fingerprint, порта или advanced-настроек требует обновить подписку в клиенте или заново получить raw route через "Подключиться по профилю".

### Bypass routing

Bypass routing добавляет правила в Xray routing, чтобы выбранные домены шли через `freedom` outbound напрямую.

Есть дефолтный bundle с группами:

- Steam
- RU-сервисы
- RU-банки
- RU-маркетплейсы
- Yandex

Меню интерактивное: стрелки двигают выбор, пробел включает/выключает группу, Enter применяет настройки.

### Tailscale exit node

Пункт `12` устанавливает Tailscale, включает `tailscaled`, записывает sysctl-настройки для IP forwarding и запускает advertise exit node. Auth key можно вставить прямо в меню скрытым вводом; XrayTailscale его не сохраняет. Если auth key не вводить, Tailscale покажет URL для ручного входа.

После настройки зайдите в Tailscale admin console и разрешите для VPS опцию `Use as exit node`. Без этого клиенты увидят машину в tailnet, но не смогут использовать ее как exit node.

---

## Клиенты для подключения

Практическая рекомендация: для HAPP импортируйте именно subscription URL, а не отдельный raw `vless://`. Для диагностики можно смотреть raw routes через `Подключиться по профилю`, но основной UX v2.0 — одна подписка на профиль.

Совместимость HAPP-flow на 12 мая 2026:

| Клиент | Статус | Комментарий |
| --- | --- | --- |
| HAPP | Рекомендуется | Основной целевой клиент. Поддерживает добавление стандартной подписки по URL/QR и VLESS links. |
| v2rayNG | Частично | Получает v2ray-compatible base64 подписку. HAPP routing metadata не используется. Для нестабильных маршрутов переключайтесь на TCP/gRPC/legacy raw route. |
| v2rayN | Частично | Подписки с VLESS поддерживаются, но HAPP-specific metadata не используется. |
| Shadowrocket | Advanced/manual | Может быть полезен для raw VLESS, но не является основным клиентом для HAPP subscription flow. |
| sing-box / Hiddify / NekoBox / mihomo | Не целевые | Не рассчитывайте на PQ-XHTTP и HAPP subscription routing. Используйте только вручную проверенные legacy маршруты. |

Ссылки на клиентов:

### Linux

- Throne — https://github.com/throneproj/Throne
- v2rayA — https://github.com/v2rayA/v2rayA
- Qv2ray — https://github.com/Qv2ray/Qv2ray

### Android

- HAPP — https://www.happ.su/
- v2rayNG — https://github.com/2dust/v2rayNG
- NekoBox — https://github.com/MatsuriDayo/NekoBoxForAndroid

### iOS

- HAPP — https://www.happ.su/
- Shadowrocket — https://apps.apple.com/app/shadowrocket/id932747118
- V2Box — https://apps.apple.com/app/v2box-v2ray-client/id6446814690

### Windows

- Throne — https://github.com/throneproj/Throne
- v2rayN — https://github.com/2dust/v2rayN
- NekoRay — https://github.com/MatsuriDayo/nekoray

### macOS

- Throne — https://github.com/throneproj/Throne
- V2RayXS — https://github.com/tzmax/V2RayXS
- Qv2ray — https://github.com/Qv2ray/Qv2ray

Документация:

- HAPP subscription: https://www.happ.su/main/faq/adding-configuration-subscription
- v2rayN subscription format: https://github.com/2dust/v2rayN/wiki/Description-of-subscription

> В связи с новостями о поломке DNS из-за блокировок VPN провайдерами, рекомендуется на клиентах держать список альтернативных ссылок и проверять DNS-настройки. Если соединение со всем интернетом пропало, проблема может быть именно там.

> На ПК-клиенте не забудьте включить TUN-режим, если вашему клиенту он нужен для системного проксирования.

---

## Обновление и удаление

Обновить XrayTailscale:

```bash
sudo xraytailscale-update
```

Если репозиторий остается приватным, передайте read-only GitHub token:

```bash
read -rsp 'GitHub token: ' GH_TOKEN; echo; sudo env XRAYTAILSCALE_GITHUB_TOKEN="$GH_TOKEN" xraytailscale-update main
```

Обновить только Xray-core можно из главного меню через пункт `10`.

Удалить XrayTailscale и Xray:

```bash
sudo xraytailscale-uninstall
```

Если установка есть, но нужно руками подтянуть свежий основной скрипт:

```bash
read -rsp 'GitHub token: ' GH_TOKEN; echo
sudo curl -fsSL -H "Authorization: Bearer $GH_TOKEN" https://raw.githubusercontent.com/vshroot/XrayTailscale/main/xraytailscale -o /usr/local/bin/xraytailscale
sudo chmod +x /usr/local/bin/xraytailscale
sudo xraytailscale
```

---

## Частые проблемы

### HAPP не обновляет подписку

Проверьте URL с VPS:

```bash
curl -vkI https://your-domain/sub/
curl -vk https://your-domain/sub/<token>
```

`/sub/` без токена должен вернуть 404. `/sub/<token>` должен вернуть 200 и тело с `vless://`.

Проверьте сервисы:

```bash
systemctl status xraytailscale-sub --no-pager -l
systemctl status nginx --no-pager -l
```

### URL показывает 127.0.0.1

Вы включили local-only режим. Он нужен только для debug. Для телефона включите `Подписка HAPP` -> `public TLS по IP` или `public TLS по домену`.

### URL показывает IP, хотя домен уже добавлен

Нужно заново включить доменный режим в меню `Подписка HAPP` -> `Установить public TLS по домену`. DNS запись сама по себе не меняет `.subscription_domain`.

### XHTTP в HAPP не работает

Для XHTTP-кандидата в HAPP должен использоваться `xhttp-legacy`, а не `xhttp-pq`. При этом subscription отдаёт TCP/Vision маршруты первыми, чтобы клиент не упирался в XHTTP, если конкретная версия HAPP или сеть его режет. После обновления до актуального `main` запустите `sudo xraytailscale`, дождитесь миграций и обновите подписку в HAPP.

Проверьте, что в профиле появился route `xhttp-legacy`, а в live config есть его порт:

```bash
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' /usr/local/etc/xray/profiles/<profile>.json
```

Последняя колонка здесь — `pq_enabled`, а не health/status. Для всех non-PQ routes значение `false` ожидаемо; `true` должен быть только у `xhttp-pq`.

### v2rayNG то подключается, то нет

v2rayNG не является основным клиентом HAPP flow. Он получает v2ray-compatible body, но маршруты все равно зависят от поддержки конкретного транспорта и версии Xray-core внутри клиента. Начинайте с TCP routes, затем проверяйте gRPC/XHTTP отдельно.

### После смены SNI, port или fingerprint старое подключение умерло

Это нормально. После таких изменений обновите подписку в клиенте или заново получите raw route.

### На сервере есть старые профили test3/test4, но они не работают

Если profile JSON указывает на порты, которых уже нет в `config.json`, это stale profile. Новая подписка такие routes не выдает; старый token вернет `410 Gone`.

### Сколько пользователей можно подключить?

Неограниченно. Можно создавать профили для себя и близких. Один профиль теперь удобнее воспринимать как одну подписку с набором маршрутов, а не как один одиночный маршрут.

### Можно ли использовать несколько профилей одновременно?

Да. Создавайте сколько угодно профилей и добавляйте их в клиент. Разные подписки, SNI, порты и маршруты дают больше вариантов для обхода блокировок.

### Подключение с клиента не работает

Возможные причины по порядку:

1. Клиент не поддерживает конкретный транспорт — начните с HAPP subscription или TCP routes.
2. SNI не подходит — замените его и обновите подписку.
3. Порт блокируется провайдером — измените порт профиля.
4. Fingerprint детектируется — попробуйте firefox вместо chrome.
5. Подписка stale — проверьте, что route есть в live `config.json`.

Лучше заранее сделать и сохранить 2-4 профиля, чтобы переключаться между ними в экстренной ситуации.

### Я повторно использовал приложение и меня выкинуло с сервера

Если подключиться к вашему же VPN и затем что-то менять на сервере в XrayTailscale, SSH может оборваться. Самый легкий способ этого избежать: подключаться к серверу не через один из своих же маршрутов.

Можно также включить keep-alive на SSH:

```bash
sudo nano /etc/ssh/sshd_config
```

```text
ClientAliveInterval 60
ClientAliveCountMax 120
TCPKeepAlive yes
```

Затем:

```bash
sudo systemctl restart sshd
```

### В ходе установки или работы вылезла ошибка

Первым делом с помощью `CTRL + SHIFT + C` скопируйте ошибку из терминала и пришлите любой нейросети. Она сформулирует проблему и пути решения.

Если проблема в коде XrayTailscale, можно написать в Telegram или открыть issue.

---

## Полезные команды

Запуск меню:

```bash
sudo xraytailscale
```

Проверка Xray:

```bash
sudo /usr/local/bin/xray test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
```

Проверка подписочного backend:

```bash
sudo systemctl status xraytailscale-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/
```

Посмотреть routes профиля:

```bash
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' /usr/local/etc/xray/profiles/<profile>.json
```

---

## Лицензия

Этот проект распространяется под лицензией MIT License. См. файл [LICENSE](LICENSE) для подробностей.

---

## Благодарности

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — за отличный протокол.
- [HAPP](https://www.happ.su/) — за целевой клиент и subscription flow.
- [2dust/v2rayNG](https://github.com/2dust/v2rayNG) — за Android-клиент и v2ray-compatible подписки.
- [2dust/v2rayN](https://github.com/2dust/v2rayN) — за Windows-клиент и subscription format.
- [Umalanif/xray-server-setup](https://github.com/Umalanif/xray-server-setup) — за референс с uTLS и автоматизацию.
- [ServerTechnologies/simple-xray-core](https://github.com/ServerTechnologies/simple-xray-core) — за удобное и быстрое развертывание.
- Моему сообществу за поддержку на протяжении этих лет, без вас бы помер и не вайбкодил.

---

## Поддержка проекта

Если пригодилось, поставьте звезду на GitHub. Не знаю зачем они мне, но давайте.

Также можно подкинуть деньгу на эти адреса:

EVM: `0x7acE4442b92f2769c24484c78A13024B139E1A5b`

Solana: `FS9RBrG5yXJty3WNWgkBkfai6BfNoYxGMFeH1LQEpRZr`

TON: `UQA56zsOv3zvU5x-p7iNNDL8jHh9dt7Q7WlY_gfbaj4ZhcyT`

BTC: `34EznmkBGpBu4dUnzoHL5GBnpg2Rq86v4H`

Вы не иронично можете помочь, поддержав бессонные ночи за вайбкодом любой копеечкой. Верю в солидарность и поддержку гражданского общества.

---

**Сделано для свободного интернета**
