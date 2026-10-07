# HTTP API AuthService

Базовый адрес: `https://1c.domain.com`.

Тела JSON, кодировка UTF-8. Секрет в cookie не кладётся. Ответы службы: `Cache-Control: no-store`, без `WWW-Authenticate`.

## POST /auth/login

Тело: `{"username":"...","password":"..."}`. Имя длиннее 180 символов, с двоеточием или переводом строки, отклоняется. Тело больше 8192 байт — 400.

Выбор провайдера: `\` или `@` — AD, иначе 1С.

Успех 200:

```json
{"ok":true,"authenticated":true,"identity":"DOMAIN\\user","osUser":"DOMAIN\\user","authType":"AD","activeSessions":1}
```

`authType`: `AD`, `1C` или, для SSO, `SSO`.

`Set-Cookie: zno_sid=<64 hex>; Path=/; Secure; HttpOnly; SameSite=Lax`.

Ошибки:

- 400 `Username and password are required.`
- 401 `{"ok":false,"error":"Invalid username or password.","code":"INVALID_CREDENTIALS"}`
- 403 `INVALID_ORIGIN`, если заголовок Origin есть и это не `https://1c.domain.com`
- 429 `Too many attempts. Try again later.`, заголовок `Retry-After: 600`

## GET /auth/sso/login

Windows Authentication только на этом пути. Успех для браузера: cookie и редирект 302 на `/pwa-auth-test/`. Без SSO и с `Accept: text/html`: редирект на `/pwa-auth-test/?sso=unavailable`. Для JSON: 401 `SSO_UNAVAILABLE`.

## GET /auth/me

Нужна cookie живой сессии. Успех — тот же JSON, что у login. Продлевает простой. Нет сессии: 401 `SESSION_EXPIRED`.

Это контракт для FPS. Верить можно только ответу, который FPS получил сам, предъявив cookie. Поле identity из браузера основанием не является.

## GET /auth/sessions

Отдельного маршрута нет. Число сессий этой личности входит в `GET /auth/me` как `activeSessions`.

## POST /auth/logout

Тело `{}`. Закрывает сессии, чьи id пришли в cookie, и гасит `zno_sid`. Ответ 200 `{"ok":true}`. Чужой Origin — 403.

## POST /auth/logout-all

Тело `{}`. Нужна живая сессия. Закрывает все сессии с той же личностью и гасит cookie. Ответ 200 `{"ok":true,"revoked":true}`. Нет сессии — 401 `SESSION_EXPIRED`.

## GET /auth/health

200 `{"ok":true,"service":"auth"}`. Сессия не нужна.

## GET /auth/fps/services

Нужна сессия. Временный ответ с одной службой «Согласование ЗНО». Каталог FPS здесь не реализуется.

## Прокси /auth/zno/api/...

Временный контур для ЗНО. Путь после `/auth/zno` должен начинаться с `/api/`. Запрещены `..`, обратная косая и абсолютный URL.

Метод, query, `Content-Type` и тело (до 2 МБ) уходят в 1С. Тело больше 2 МБ — 413. Вложения ЗНО читаются GET-запросом, лимит тела на них не действует. Отдельный лимит для загрузки файлов не вводился: текущий UI файлы не загружает.

Браузерные `Authorization`, `Cookie` и `Host` в 1С не копируются. Обратно не отдаются `Set-Cookie` 1С и `WWW-Authenticate`.

Нет сессии: 401 `SESSION_EXPIRED`. Интерфейс возвращает на форму входа.

1С ответила 401 или 403: клиенту 403 `SERVICE_NOT_AUTHORIZED`. Сессия при этом не уничтожается. Интерфейс показывает текст ошибки и остаётся в приложении.

Успех: код, `Content-Type` и тело 1С без изменений, плюс `Cache-Control: no-store`.

Чужой Origin на POST, PUT, PATCH и DELETE — 403 `INVALID_ORIGIN`, сессия не используется.
