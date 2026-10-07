# Snapshot AuthService_MVP_WORKING_2026-10-07

Дата снимка: 2026-10-07 13:40 (серверное время).

Это проверенная рабочая версия до security hardening. Снимок лежит вне каталога исходников, чтобы следующие правки его не затёрли.

Каталог:

`D:\+SERG\WS\AUTZ-snapshots\AuthService_MVP_WORKING_2026-10-07`

Проверка целостности: файл `VERIFY-OK.txt`. SHA-256 ключевых файлов совпал с работающими копиями в IIS (`SHA256.txt`).

## Адреса на момент снимка

- PWA: https://1c.domain.com/pwa-auth-test/
- AuthService: https://1c.domain.com/auth
- Публикация 1С Basic: https://1c.domain.com/UH_Medvedev_test/hs/mobile
- Публикация 1С Windows: https://1c.domain.com/UH_Medvedev_test_osauth/hs/mobile
- База: `UH_Medvedev_test`, платформа 8.3.27.2214

## Что внутри

- `workspace` — полная копия `D:\+SERG\WS\AUTZ` на момент снимка
- `inetpub` — `authservice`, `pwa-auth-test`, `auth-test`, `auth`, `zno`, обе публикации 1С (`default.vrd`, `web.config`)
- `iis` — сайт, приложения, пулы, привязки, authentication, providers, IP restrictions, authorization
- `authservice-data-listing.txt` — только имена файлов журнала, без содержимого
- `rollback-to-mvp.ps1` — копия скрипта восстановления

Журналы `C:\inetpub\authservice-data\*.log` в снимок не копировались.

## IIS

- Сайт: Default Web Site
- Привязки: HTTP `*:80`, HTTPS `*:443`, сертификат в хранилище My
- Приложение `/auth` → `C:\inetpub\wwwroot\authservice`, пул `AuthService`
- Пул `AuthService`: .NET v4.0, Integrated, ApplicationPoolIdentity, maxProcesses = 1
- `/auth`: anonymous включён, Basic и Windows выключены
- `/auth/sso`: anonymous выключен, Windows включён, providers Negotiate, NTLM
- `/UH_Medvedev_test`: IIS anonymous включён, IIS Basic выключен. Basic выполняет сама публикация 1С (ISAPI), это не модуль IIS
- `/UH_Medvedev_test_osauth`: anonymous выключен, Windows включён, пул как у тестовой публикации (`DefaultAppPool`)
- Extended Protection в снимке не задан (пустой элемент `extendedProtection`)

## Сессия на момент снимка

- Cookie: `zno_sid`, `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax`, без `Domain`
- Значение: 32 случайных байта в hex
- Скользящий срок: 8 часов
- Абсолютный срок: 12 часов
- Хранение: память процесса `AuthService`
- Входы: AD (`LogonUser`), пароль 1С (Basic к `/UH_Medvedev_test`), SSO (`/auth/sso/login`)

## Восстановление

Только вручную, от администратора, из `D:\+SERG\WS\AUTZ`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\+SERG\WS\AUTZ\scripts\rollback-to-mvp.ps1 -Confirm
```

Без `-Confirm` скрипт ничего не меняет.

Восстанавливаются исходники `AuthService`, `pwa-auth-test`, `auth-test`, развёрнутые каталоги IIS этих приложений и обеих публикаций, флаги authentication и Extended Protection из `iis\settings.json`. Пул `AuthService` перезапускается, затем проверяется `GET /auth/health`. Новые роли IIS не устанавливаются.

Снимок при восстановлении не удаляется.
