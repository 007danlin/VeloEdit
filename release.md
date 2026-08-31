# Release

## Локальная сборка

```bash
./Scripts/build-app.sh
codesign --verify --deep --strict Build/VeloEdit.app
```

Без `VELOEDIT_CODESIGN_IDENTITY` создаётся ad-hoc signature. Для release задаётся Developer ID identity, затем выполняются hardened-runtime signing, `notarytool submit --wait`, stapling и DMG packaging. Скрипт не содержит credentials.

## Release gates

- Все tests/build/CLI smoke проходят.
- Реальные import/proxy/preview/final workflows проверены на M4 Air.
- 10 fixtures импортированы в поддерживаемую версию Final Cut Pro.
- Third-party/model licenses зафиксированы.
- Privacy/network audit подтверждает offline default.
- Developer ID signature, notarization и Gatekeeper launch проверены на чистой системе.
