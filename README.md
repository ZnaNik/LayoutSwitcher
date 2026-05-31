# LayoutSwitcher

Лёгкая нативная утилита для macOS. Заменяет **Punto Switcher**, **Lightshot** и **AnyDesk** одной программой ~250 строк Swift, без телеметрии, без иконки в доке.

## Горячие клавиши

| Клавиши | Действие |
|---------|----------|
| `Cmd+Shift` | Переключить раскладку клавиатуры |
| `Cmd+\` | Скриншот области → JPEG в `~/Screenshots/` + копия в буфер + HUD-плашка |
| `Cmd+Shift+\` | Видео: открывает нативную панель записи macOS (выбор области, звук, стоп) |

Клавиша скриншота меняется без пересборки:
```bash
defaults write com.nikita.layoutswitcher screenshotKeycode 42   # 42=\  50=`  14=е
```

## Под капотом — только нативные инструменты macOS

- Раскладка — `TISSelectInputSource`
- Скриншот — `/usr/sbin/screencapture`
- Видео — нативная панель Cmd+Shift+5 (через CGEvent)
- Перехват клавиш — CGEvent event tap
- Уведомления — свой HUD на NSPanel (системные глушатся у фоновых процессов)

## Сборка

```bash
swiftc src/main.swift -o LayoutSwitcherBin \
  -framework Carbon -framework AppKit -framework Foundation
```

Затем собрать `.app` bundle, подписать (`codesign --force --deep -s -`), положить в `/Applications`.

## Установка автозапуска

LaunchAgent `~/Library/LaunchAgents/com.nikita.layoutswitcher.plist` с `KeepAlive` — поднимает приложение при логине и при сбое.

## Права macOS

Нужны два разрешения в **Системные настройки → Конфиденциальность**:
- **Универсальный доступ** (Accessibility) — для перехвата клавиш
- **Запись экрана** (Screen Recording) — для скриншотов и видео

> ⚠️ При каждой пересборке ad-hoc подпись меняет cdhash, и macOS сбрасывает права — их нужно выдать заново.
