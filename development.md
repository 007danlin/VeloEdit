# Разработка VeloEdit

## Быстрый цикл

```bash
./Scripts/dev-build.sh --jobs 2
./Scripts/dev-test.sh --jobs 2
.build/arm64-apple-macosx/debug/veloedit-cli help
```

На текущем macOS 26 host frontend Swift и SDK отличаются patch-версией. Скрипты используют локальный read-only compatibility wrapper и workspace module cache. На актуальном полном Xcode допустимы обычные `swift build` / `swift test`.

## Targets

- `VeloEditCore`: модели и сервисы без SwiftUI/AppKit.
- `VeloEdit`: macOS SwiftUI app.
- `veloedit-cli`: smoke, batch workflow и diagnostics.
- `VeloEditCoreTests`: Swift Testing unit/integration checks.

## Definition of done

Изменение должно собирать все targets, проходить tests, не менять оригиналы и обновлять `TODO.md`, `CHANGELOG.md`, `ARCHITECTURE.md`. Media/render изменения дополнительно проверяются на реальном файле в подписанном app host.
