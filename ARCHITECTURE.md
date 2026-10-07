# Архитектура

Контур остаётся прежним. Hardening не меняет способ входа и не вводит JWT.

```text
PWA /pwa-auth-test
        │  HTTPS, JSON, cookie zno_sid
        ▼
AuthService, приложение IIS /auth
пул AuthService, ASP.NET 4.8, память процесса
        │
        ├── AD: LogonUser, WindowsIdentity в памяти
        ├── 1С: один Basic-запрос к /UH_Medvedev_test, пароль в памяти сессии
        └── SSO: Negotiate/NTLM только на /auth/sso/login
        │
        ▼
прокси /auth/zno/api/...
        │
        ├── authType=1C  → HTTPS Basic → /UH_Medvedev_test/hs/mobile
        └── authType=AD или SSO → HTTPS под имперсонацией → /UH_Medvedev_test_osauth/hs/mobile
```

Браузер вызывает только `/auth` и `/auth/zno`. Заголовок `Authorization` к 1С собирает сервер.

## AD

Имя содержит `\` или `@`. `LogonUser` с типом `NETWORK_CLEARTEXT`. Пароль после проверки не хранится. В сессии остаётся первичный Windows-токен. Дальнейшие вызовы 1С идут в публикацию Windows Authentication, 1С сопоставляет «Пользователь ОС».

## 1С

Имя без домена. Сервер один раз читает `GET /api/tasks` публикации `/UH_Medvedev_test` с Basic. Код 200 создаёт сессию. Пароль остаётся в памяти процесса до выхода, таймаута или перезапуска пула. В браузер он не возвращается.

Штатная сессия HTTP-сервиса `IBSession` отдельно проверяется скриптом `run-as-admin-step.ps1`. Пока ответ 1С без успешного входа её не выдаёт, рабочий Basic не заменяется.

## SSO

`GET /auth/sso/login`. На этом пути IIS включает Windows Authentication, providers Negotiate и NTLM. Успешный вход создаёт ту же серверную сессию, что и пароль AD. Для HTML-клиента без SSO — редирект на PWA с `sso=unavailable`.

## Сессия

Идентификатор — 32 случайных байта, hex. Cookie `zno_sid`: `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, без `Domain`. `Path=/` оставлен: предыдущая смена пути уже приводила к двум cookie и ложному «Session expired».

Простой: 45 минут. Абсолютный срок: 12 часов. Любой успешный вызов прокси и `GET /auth/me` продлевают простой в пределах абсолютного срока.

Одновременно разрешено несколько сессий одной личности (телефон и компьютер). `POST /auth/logout` закрывает текущую. `POST /auth/logout-all` закрывает все сессии этой личности. Перезапуск пула закрывает все, потому что хранилище только в памяти.

## Две тестовые публикации

`/UH_Medvedev_test` — прежняя точка Basic. IIS Basic выключен: Basic выполняет ISAPI 1С. Её сетью не закрываем.

`/UH_Medvedev_test_osauth` — та же база, другой `base` в `default.vrd`, Windows Authentication. AuthService вызывает её с этого сервера по `https://127.0.0.1`. Телефон через VPN открывает `/pwa-auth-test` и `/auth`. Отдельную роль IIS для запрета чужих IP не ставим: на проде публикация закрывается тем же способом, что и остальные внутренние публикации, без нового компонента.

В целевой схеме у прикладных баз будет одна публикация, а каталог служб делает FPS. AuthService к этому моменту уже отдаёт подтверждённую личность.

## Доверие для FPS

Браузерный JSON с полем `identity` доверенным не является. Сервер FPS должен сам вызвать `GET /auth/me` на AuthService, передав cookie сессии, и верить только этому ответу. Выпуск JWT в этот компонент не входит.
