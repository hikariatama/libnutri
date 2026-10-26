# Сборка для iPhone через CLI

Требуется полный Xcode с iOS 27 SDK. Simulator runtimes для сборки на физический iPhone не нужны. Скрипт использует `/Applications/Xcode.app/Contents/Developer` через `DEVELOPER_DIR` и не меняет глобальный `xcode-select`.

## Проверка сборки без подписи

Из корня репозитория:

```sh
scripts/build-app.sh
```

Такая сборка проверяет iOS-код, но не устанавливается на обычный iPhone.

## Подписанная сборка

Настройте основной Apple Account в Xcode → Settings → Accounts. Выберите его Team ID. Потребуются сертификат Apple Development с закрытым ключом и provisioning profile; automatic signing может создать их через аккаунт.

Подключите iPhone, подтвердите доверие компьютеру и включите Developer Mode на устройстве, если потребуется. Найдите ID устройства:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
```

Соберите приложение, подставив значения своей команды и устройства:

```sh
TEAM_ID=YOUR_TEAM_ID DEVICE_ID=YOUR_DEVICE_ID scripts/build-app.sh
```

Разрешённые скриптом provisioning updates могут создать App ID, зарегистрировать устройство и создать или обновить профиль в выбранной Apple Developer Team. Скрипт не публикует приложение в App Store или TestFlight.

Результат по умолчанию находится в `../work/DeviceBuild/Build/Products/Debug-iphoneos/NutritionTracker.app`. Путь можно изменить через `BUILD_DIR`.

После успешной подписанной сборки установите и запустите приложение:

```sh
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  ../work/DeviceBuild/Build/Products/Debug-iphoneos/NutritionTracker.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID dev.local.NutritionTracker
```

Для первого запуска Personal Team-сборки iOS может потребовать доверие к developer-профилю: Settings → General → VPN & Device Management → Developer App → Trust. Это отдельное подтверждение от доверия компьютеру и Developer Mode. Если iOS предлагает Allow & Restart, завершите перезагрузку и разблокируйте устройство перед повторным запуском.

С Personal Team бесплатного аккаунта потребуется обновлять development-подпись примерно каждые семь дней.

Для другой установки Xcode передайте `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`.

## Аккаунт и последующая смена команды

Apple Account для подписи может отличаться от аккаунта iCloud на iPhone и Mac. Для использования текущего аккаунта достаточно добавить его в инструменты разработки.

При смене Developer Team потребуется новая подпись. Доступ к Keychain зависит от команды; перед переносом нужно отдельно проверить сохранность локальных данных и возможность обновления приложения на месте. API-ключ можно повторно ввести в настройках приложения.
