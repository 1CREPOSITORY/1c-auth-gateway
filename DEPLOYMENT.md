# Установка

Сервер: `IIS-SERVER-01.domain.com`, IIS, сайт Default Web Site.

Нужны уже стоящие на сервере IIS, ASP.NET 4.8 и Windows Authentication. Новые роли IIS скрипт не ставит. Отдельный .NET SDK не нужен: сборка идёт `csc.exe` из .NET Framework 4.8.

Каталоги:

- исходники `D:\+SERG\WS\AUTZ`
- приложение `/auth` → `C:\inetpub\wwwroot\authservice`, пул `AuthService` (.NET v4.0, Integrated, ApplicationPoolIdentity, один процесс)
- PWA → `C:\inetpub\wwwroot\pwa-auth-test`
- данные и журнал → `C:\inetpub\authservice-data`
- Basic-публикация → `C:\inetpub\wwwroot\UH_Medvedev_test`
- Windows-публикация → `C:\inetpub\wwwroot\UH_Medvedev_test_osauth`, пул тот же, что у тестовой публикации

Привязки сайта: HTTP `*:80` и HTTPS `*:443`. Сертификат имени `1c.domain.com` лежит в LocalMachine\My. В локальный `AuthService\web.config` записывается его отпечаток, ключ `ExpectedCertThumbprint`. В репозиторий этот файл не входит: образец — `AuthService\web.config.example`.

Authentication:

- `/auth` — anonymous, без Basic и без Windows
- `/auth/sso` — только Windows, providers Negotiate, NTLM
- `/UH_Medvedev_test` — как была, IIS Basic не включается
- `/UH_Medvedev_test_osauth` — только Windows, как в рабочей версии. Отдельный компонент ограничения по IP не используется

Пароли в скрипты не записываются.

Полный шаг установки и проверки:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\+SERG\WS\AUTZ\scripts\run-as-admin-step.ps1
```

Он вызывает `scripts\deploy.ps1`, затем `scripts\security-check.ps1`, снимает пробу `IBSession` и локальный Negotiate. Новые компоненты Windows не устанавливает. Extended Protection не меняет.

Повторная выкладка без пробы отказа:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\+SERG\WS\AUTZ\scripts\deploy.ps1
```

`deploy.ps1` выкладывает службу в уже существующие приложения IIS и не меняет набор ролей сервера.

Откат именно к снимку до hardening, только вручную:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\+SERG\WS\AUTZ\scripts\rollback-to-mvp.ps1 -Confirm
```

`scripts\rollback.ps1` по-прежнему откатывает последний каталог из `backup\inetpub-latest.txt`, который создаёт `deploy.ps1`. Это откат последней выкладки, не обязательно снимок MVP.
