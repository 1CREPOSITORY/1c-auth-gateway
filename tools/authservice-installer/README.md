# AuthService installer

Отдельная установка AuthService на IIS-сервер, где уже есть публикация 1С. Текущие `scripts\deploy.ps1` и `scripts\rollback.ps1` этот инструмент не заменяет.

## Запуск

1. Скопируйте репозиторий на целевой IIS-сервер.
2. Откройте PowerShell от имени Administrator.
3. Перейдите в каталог:

```powershell
cd .\tools\authservice-installer
```

4. Сначала посмотрите план без изменений:

```powershell
.\install-authservice.ps1 -PlanOnly
```

5. Установка:

```powershell
.\install-authservice.ps1
```

Откат:

```powershell
.\rollback-authservice.ps1
```

Installer запускается на том IIS-сервере, куда ставится служба. Удалённую установку на другой компьютер он не выполняет.

## UI endpoint

Путь без схемы и имени сервера:

```text
/<publication>/hs/<http-service>/ui
```

Пример:

```text
/UH_Medvedev_test/hs/mobile/ui
```

Имя публикации в пути должно совпасть с выбранной публикацией. Имя сервера 1С и база читаются из её `default.vrd`.

Примеры имён серверов в документации: `IIS-SERVER-01.domain.com`, `1c.domain.com`.

## Что делает установка

Повторяет рабочую схему: приложение `/auth`, пул `AuthService`, SSO на `/auth/sso`, дополнительная публикация `<имя>_osauth` на ту же базу. Windows-публикация собирается из `default.vrd` и `web.config` выбранной публикации: меняется только `base`, строка `Srvr` / `Ref` остаётся. Обработчик `wsisapi.dll` берётся из этой публикации.

Роль IP and Domain Restrictions не устанавливается.

Backup пишется в `backups\<дата_время>\` до любых изменений IIS. Если объекта до установки не было, rollback его удаляет.
