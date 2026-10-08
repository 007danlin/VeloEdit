# Разработка VeloEdit

## Быстрый цикл

```bash
./Scripts/dev-build.sh --jobs 2
./Scripts/dev-test.sh --jobs 2
.build/arm64-apple-macosx/debug/veloedit-cli help
```

Скрипты используют активный Xcode toolchain и кэш в `~/Library/Caches/VeloEditBuild`.
Полный bundle после изменений кода или ресурсов обязательно пересобирается:

```bash
./Scripts/build-app.sh
```

Результат находится в `Build/VeloEdit.app`. Для исходников нужен Git LFS:
бинарные ресурсы Ollama должны быть загружены командой `git lfs pull`.

Все команды в документации выполняются из корня проекта. Вспомогательные
скрипты описаны в [Scripts/README.md](../../Scripts/README.md), документы —
в [оглавлении](../README.md).

Проверочные Python-скрипты находятся в `Scripts/Validation/` и отслеживаются
Git. Отчёты прогонов, логи, JSON/JSONL, скриншоты и исторические аудиты
хранятся в `Local/Reports/`, замеры — в `Local/Benchmarks/`.
`output/` содержит локальные эксперименты, `Build/` — результаты сборки.
Эти три папки исключены через `.gitignore`. Не добавляйте их через `git add -f`.
Свежий clone этих файлов не содержит; ссылки в технических заданиях ведут
к зафиксированной версии в истории Git. Требования и тесты сохранены,
а прежний успешный прогон не считается проверкой текущей сборки.
Тестовые входные данные следует помещать в `Tests/Fixtures/`, а ресурсы
приложения — в `Resources/`.
Не удаляйте `Package.resolved`, Cargo lockfiles, исходники `ThirdParty/` и их
лицензии при очистке: они нужны для воспроизводимой сборки и уведомлений.

Например, прежний аудит можно прочитать без восстановления файла в проекте:
`git show 8646d9d:EDITOR_TOOLKIT_AUDIT.md`.

## Targets

- `VeloEditCore`: модели и сервисы без SwiftUI/AppKit.
- `VeloEdit`: macOS SwiftUI app.
- `veloedit-cli`: smoke, batch workflow и diagnostics.
- `VeloEditCoreTests`: Swift Testing unit/integration checks.

## Definition of done

Изменение должно собирать все targets, проходить tests, не менять оригиналы и обновлять `Docs/Planning/roadmap.md`, `CHANGELOG.md`, `Docs/Architecture/overview.md`. Media/render изменения дополнительно проверяются на реальном файле в подписанном app host.
