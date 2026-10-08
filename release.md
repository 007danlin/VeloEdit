# Release

## Локальная сборка

По умолчанию собирается **Universal 2: arm64 + x86_64**, минимум macOS 14. Приложение, speech worker, OVRLEY, FFmpeg и ffprobe содержат обе архитектуры. Ollama поставляется с универсальными исполняемыми файлами и отдельными подходящими CPU/Metal-плагинами. На Apple Silicon сохраняются нативный ARM-код и Neural Engine; на Intel распознавание речи использует Core ML CPU/GPU. Дополнительный MLX v4 backend рассчитан на macOS 26.2+, при этом в пакете сохранён MLX v3 для более старых систем.

```bash
./Scripts/build-app.sh
codesign --verify --deep --strict Build/VeloEdit.app
python3 Scripts/verify-architectures.py Build/VeloEdit.app
python3 Scripts/smoke-universal.py Build/VeloEdit.app --output Build/UniversalSupport/smoke.json
```

Первая сборка скачивает зависимости с проверкой SHA-256 и собирает FFmpeg 9.0.2 из исходников для обеих архитектур. Версии и источники закреплены в `Distribution/native-dependencies.json`; кеш и изолированный Rust toolchain находятся в `Build/NativeDependencies`. Глобальная установка Homebrew/Rust не изменяется. Последующие сборки используют кеш. `VELOEDIT_ARCHS=arm64 ./Scripts/build-app.sh` доступен для локальной разработки, но установщик принимает только полный универсальный пакет.

`ArchitectureReport.json` внутри приложения фиксирует архитектуры, минимальные версии macOS и зависимости каждого Mach-O файла. Упаковка останавливается при отсутствии обязательного среза, внешней библиотеке или несовместимом минимуме macOS. `BuildInfo.json` также фиксирует архитектуры и модель ИИ-режиссёра (`qwen3:4b-instruct`). Intel smoke-check на M-чипе использует Rosetta; он не заменяет проверку GPU и реального распознавания/инференса на физическом Intel Mac.

Без `VELOEDIT_CODESIGN_IDENTITY` создаётся ad-hoc signature для локальной разработки. Это не доверенная подпись разработчика Apple. `sign-app.py` подписывает все Mach-O файлы (включая FFmpeg, Ollama и библиотеки) изнутри наружу, затем приложение; `--deep` используется только при проверке. При Developer ID включаются hardened runtime и secure timestamp. Все вложенные подписи проверяются отдельно, в том числе код в Resources.

## Локальный установочный образ

Один раз подготовить изолированные инструменты упаковки (они не входят в приложение):

```bash
python3 -m venv Build/PackagingPython
Build/PackagingPython/bin/python3 -m pip install -r Distribution/requirements.txt
```

```bash
python3 Scripts/build-distribution.py
```

Команда полностью пересобирает приложение и создаёт `Build/Distribution/VeloEdit-<version>-<build>-<arch>-local/` с DMG, SHA-256, инструкцией и `distribution.json`. Окно Finder открывается в размере 760 × 500 с фоном Retina, значком VeloEdit слева, зелёной стрелкой и ссылкой на `/Applications` справа. В окне видны только два значка; все лицензии сохранены внутри подписанного приложения. `Install.txt` находится рядом с DMG, не в окне установщика. Установка — перетаскивание приложения в Applications. Никаких фоновых установочных скриптов или изменений системных настроек нет.

Редактируемый [макет Figma](https://www.figma.com/design/cZk2AI5z9zOpCyJKcAU8nF?node-id=2-8), экспорт SVG и фон 1×/2× — `Distribution/Installer/`. `layout.json` задаёт размер окна и координаты настоящих значков Finder, которые не нарисованы на фоне. Установочная графика использует Inter; интерфейс приложения сохраняет системный шрифт macOS. `package-dmg.py` собирает `.DS_Store` и переносимый alias фона через dmgbuild, проверяет подпись копии приложения внутри образа. После изменения макета нужно повторно экспортировать фон в обоих масштабах и проверить готовый DMG в Finder.

После уже выполненного `./Scripts/build-app.sh` можно использовать `--skip-build` для локальной упаковки. Публичный выпуск эту опцию не допускает. Локальный DMG не нотариализован, помечен `local` и не предназначен для публичного распространения. Gatekeeper на другом Mac может заблокировать запуск. Скрипт не обходит Gatekeeper и не меняет quarantine у пользователя.

## Правообладатель и лицензии

Правообладатель: **Daniel L**, по указанию владельца проекта. Компания не обязательна. Имя и необязательный контакт хранятся в `Resources/Legal/publisher.json`; `bundle-legal.py` подставляет их в лицензию и copyright внутри приложения. Имя в сертификате Apple определяется данными Apple Developer Account и может отличаться от выбранного авторского имени.

`LICENSE.txt` в корне относится только к собственному коду и ресурсам. Условия для пользователя собираются из `Resources/Legal/LICENSE.txt`, а сведения о назначении сторонних компонентов — из `Resources/Legal/THIRD_PARTY.txt`. В приложении они доступны через **VeloEdit → Лицензия и компоненты…**. Исходные лицензии сохраняются; добавляется инвентаризация Rust-пакетов и точная конфигурация встроенного FFmpeg.

Текущая сборка включает GPL OVRLEY и FFmpeg с `--enable-gpl`; subprocess/JSON не доказывает юридическую независимость. Папка OVRLEY-Source сама по себе не доказывает полноту Corresponding Source, а ссылки Homebrew/FFmpeg — надлежащую доставку исходников. Уведомления о моделях и транзитивных native-зависимостях также требуют завершения аудита. Перед распространением нужно либо выполнить применимые условия и подтвердить совместимость интеграции, либо заменить соответствующие компоненты. Нельзя удалить чужое авторство или объявить чужие компоненты собственными.

Конкретные незакрытые проверки записаны в `Distribution/legal-review.json`. Публичный режим требует `status: approved` и путь `evidence` к непустому документу в репозитории для каждой проверки. Эти поля заполняются по результатам реальной проверки с зафиксированными версиями, изменениями, способом получения соответствующих исходников и уведомлениями. Сама отметка не создаёт прав и не заменяет проверку.

Открытие репозитория не закрывает эти проверки. Собственная лицензия запрещает
неразрешённую перепубликацию оригинальных компонентов, но сохраняет права по
лицензиям зависимостей и [право просмотра и fork публичного репозитория на GitHub](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).
Это не способ запретить разрешённое GPL копирование OVRLEY или покрываемых GPL производных работ.

Лицензирование приложения отдельно от экспортируемого видео: согласно
[GPLv3, раздел 2](https://www.gnu.org/licenses/gpl-3.0.html#section2), результат
работы программы не становится GPL-произведением автоматически. Поэтому
лицензии FFmpeg/OVRLEY хранятся в приложении, а не прикладываются к каждому фильму.
Музыка с [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) сохраняет
требования атрибуции. `music-credits.json` содержит сведения о требующей атрибуции
музыке текущего монтажа, которые пользователь должен указать при публикации;
само наличие JSON рядом с видео не заменяет соблюдение условий трека.

## Подписанный и нотариализованный выпуск

1. Зарегистрироваться в Apple Developer Program (можно как физическое лицо).
2. В Xcode → Settings → Accounts добавить свой аккаунт, создать или импортировать **Developer ID Application** с приватным ключом в Keychain. Для DMG сертификат Developer ID Installer не нужен; он относится к `.pkg`.
3. Создать профиль `notarytool` в Keychain через интерактивный ввод на своём Mac. Не передавать пароли/приватные ключи в чат или репозиторий:

```bash
xcrun notarytool store-credentials VeloEdit-notary
```

4. Завершить лицензионные проверки выше. Проверить готовность:

```bash
export VELOEDIT_CODESIGN_IDENTITY='Developer ID Application: YOUR LEGAL NAME (TEAMID)'
export VELOEDIT_NOTARY_PROFILE='VeloEdit-notary'
python3 Scripts/build-distribution.py --check
```

5. Собрать публичный выпуск (эта команда отправляет приложение и DMG в сервис нотариализации Apple):

```bash
python3 Scripts/build-distribution.py --release
```

Команда заново строит весь `.app`, проверяет подписи, нотариализует приложение, прикрепляет ticket, собирает и подписывает DMG, нотариализует и прикрепляет ticket к DMG. Успешными считаются только ответ Apple `Accepted`, успешная проверка tickets и Gatekeeper. Готовый каталог публикуется локально атомарно после проверок; при ошибке публичный DMG не выдаётся за готовый. Пароли берутся только из Keychain. Результаты нотариализации и контрольные суммы сохраняются рядом с образом.

Developer ID/hardened runtime требуют проверки запуска на чистом Mac, включая локальный AI, speech worker, телеметрию, импорт и экспорт. Пока нет аккаунта/сертификата, этот сетевой путь остаётся непроверенным; локальная ad-hoc сборка его не подтверждает.

Документация: [Apple Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [подпись вложенного кода](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), [нотариализация](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation), [FFmpeg](https://ffmpeg.org/legal.html).

## Release gates

- Все tests/build/CLI smoke проходят.
- Реальные import/proxy/preview/final workflows проверены на M4 Air.
- 10 fixtures импортированы в поддерживаемую версию Final Cut Pro.
- Third-party/model licenses зафиксированы.
- Privacy/network audit подтверждает offline default.
- Developer ID signature, notarization и Gatekeeper launch проверены на чистой системе.
