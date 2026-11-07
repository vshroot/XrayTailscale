# Исходники xraytailscale (модули)

`xraytailscale` в корне репозитория — **собранный** single-file.
Редактировать нужно модули здесь, затем пересобрать:

```bash
./build.sh                              # пересобрать xraytailscale
bash validation/test-build-sync.sh      # проверить отсутствие рассинхрона
```

Модули конкатенируются в порядке сортировки имён файлов.
Порядок следования функций в собранном файле = исходный порядок монолита,
поэтому сборка воспроизводит прежнее поведение один в один.

## Карта модулей

| Файл | Содержимое |
| --- | --- |
| `00-core.sh` | Константы, пути, цвета, source-safety guard, root-check, `github_raw_curl`, `get_server_ip` |
| `05-profile-utils.sh` | Метаданные транспортов, генерация VLESS URL, `update_transport_settings_for_sni`, базовые URL подписок |
| `10-system.sh` | `safe_jq_write`, бэкапы/откаты, systemd unit, `safe_restart_xray`, UFW |
| `15-profile-sync.sh` | Синхронизация профилей на порту, смена SNI/fingerprint/порта в метаданных |
| `20-migrations.sh` | Миграции (host tuning, Reality, XHTTP, routing, mlkem) |
| `25-sni-bypass-core.sh` | Ядро bypass-правил, SNI probe |
| `30-ui-update.sh` | ASCII/banner, обновление Xray-core, `xraytailscale-update` |
| `35-subscription.sh` | HAPP subscription server, TLS (IP/domain), меню подписок |
| `40-bulk-happ.sh` | Bulk HAPP users: seed, генерация, revoke/delete, repair |
| `45-tailscale.sh` | Tailscale exit node |
| `50-cascade.sh` | Каскадный upstream, outbound-server node |
| `55-main-menu.sh` | Главное меню |
| `60-profile-create.sh` | Создание профилей, multi-route, `add_inbound` |
| `65-profile-manage.sh` | Удаление/подключение профилей, смена SNI/fingerprint/порта |
| `70-bypass-menu.sh` | Меню bypass routing |
| `75-pq-adguard.sh` | Post-quantum upgrade, аварийное удаление AdGuard |
| `80-domain.sh` | Серверный домен: хранение и автоподстановка |
| `85-selfsteal.sh` | Self-steal: свой сайт + nginx + Let's Encrypt + Reality dest |
| `99-dispatch.sh` | CLI dispatch (subcommands, main_menu) |

## Правила

- Не вставлять top-level side effects в модули: top-level код выполняется
  при source (тесты source'ят собранный файл). Интерактив — только внутри функций.
- Новый модуль = новый файл `NN-name.sh` с подходящим номером, затем `./build.sh`.
- После любых правок: `./build.sh && bash validation/test-build-sync.sh`
  и полный прогон `validation/*.sh`.
