Единая точка входа: https://1c.domain.com/pwa-auth-test/

1. Если нет AD-сессии, открывается Log in.
2. POST /auth/ad/login проверяет DOMAIN\user и пароль на сервере.
3. После успеха показывается «Согласование ЗНО».
4. Доступ к /UH_Medvedev_test/hs/mobile/api/tasks по-прежнему требует Basic учётной записи HTTP-сервиса 1С.
   Пароль AD туда не отправляется.
5. /UH_Medvedev_test/hs/mobile/ui без Basic даёт IIS 401.5. Этот URL в браузере не открывать:
   интерфейс отдаётся из /pwa-auth-test/, а данные читаются через /api/tasks с заголовком Authorization.

Сервис авторизации: D:\+SERG\WS\AUTZ\AuthService
