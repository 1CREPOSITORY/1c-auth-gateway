# 1C Auth Gateway

Authentication gateway for 1C web/PWA applications.

Шлюз аутентификации для веб-публикаций и PWA 1С. Браузер не ходит в защищённые URL 1С напрямую и не хранит пароль.

Поддерживаемые сценарии:

- Active Directory username/password
- Windows SSO
- 1C username/password
- server-side session
- proxy to 1C
- IIS deployment tooling
- interactive installer/rollback

Current project status: internal corporate environment / controlled perimeter.

Это не готовое решение для публикации в интернет. Перед внешним deployment нужен отдельный security review. Подробности: [SECURITY.md](SECURITY.md).

Примеры адресов:

- IIS: `IIS-SERVER-01.domain.com`
- публикация 1С и PWA: `https://1c.domain.com`
- шлюз: `https://auth.domain.com/auth` или `https://1c.domain.com/auth` на том же сайте
- UI endpoint: `/UH_Medvedev_test/hs/mobile/ui`

## Состав

- `AuthService\` — исходники модуля IIS и `web.config.example`. Рабочий `web.config` локальный и в Git не входит.
- `pwa-auth-test\` — тестовый интерфейс «Согласование ЗНО».
- `scripts\` — сборка, выкладка, проверки и откат. Публичный адрес читается из `environment.local.ps1`, образец — `environment.example.ps1`.
- `tools\authservice-installer\` — интерактивная установка и rollback. Каталог `backups` в Git не входит.
- Документы: [ARCHITECTURE.md](ARCHITECTURE.md), [API.md](API.md), [DEPLOYMENT.md](DEPLOYMENT.md), [OPERATIONS.md](OPERATIONS.md), [SNAPSHOT_README.md](SNAPSHOT_README.md).

Локальный адрес для проверок на своём сервере задаётся так:

```powershell
Copy-Item .\environment.example.ps1 .\environment.local.ps1
Copy-Item .\AuthService\web.config.example .\AuthService\web.config
```

После этого в `environment.local.ps1` и `AuthService\web.config` подставляются имя своего сайта и отпечаток сертификата.

Установщик:

```powershell
cd .\tools\authservice-installer
.\install-authservice.ps1 -PlanOnly
.\install-authservice.ps1
.\rollback-authservice.ps1
```
