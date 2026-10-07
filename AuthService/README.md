# Единый вход

Актуальные документы лежат в корне `D:\+SERG\WS\AUTZ`: README.md, ARCHITECTURE.md, SECURITY.md, API.md, DEPLOYMENT.md, OPERATIONS.md.

Рабочий адрес:

https://1c.domain.com/pwa-auth-test/

Одна форма. Отдельного экрана «1C user name» нет.

## Как выбирается провайдер

`POST /auth/login`

- `DOMAIN\user` или `user@domain` — Active Directory. Пароль проверяется через `LogonUser` (`NETWORK_CLEARTEXT`). Windows-токен остаётся только в памяти процесса до logout или перезапуска пула.
- имя без домена — пользователь 1С. Пароль проверяется запросом к `UH_Medvedev_test`. В браузер он не возвращается.
- `GET /auth/sso/login` — Negotiate/NTLM, только на этом пути.

Дальше интерфейс ходит в `/auth/zno/api/...`. Браузер сам в 1С не обращается.

- AD и SSO: запрос уходит в `/UH_Medvedev_test_osauth` под Windows-токеном пользователя.
- 1C: запрос уходит в существующую `/UH_Medvedev_test` с серверным Basic.

`UH_Medvedev_test` не переключалась на Windows Authentication.

## Проверка

`GET /auth/health`

`GET /auth/debug/identity` — пользователь, тип входа и Windows identity. Пароля и токена в ответе нет.

Журнал без пароля: `C:\inetpub\authservice-data\identity.log`

## Команды

Из повышенного PowerShell:

```powershell
D:\+SERG\WS\AUTZ\scripts\deploy.ps1
D:\+SERG\WS\AUTZ\scripts\test.ps1
D:\+SERG\WS\AUTZ\scripts\rollback.ps1
```
