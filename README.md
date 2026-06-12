# LayoutSwitcher

Лёгкая нативная утилита для macOS. Заменяет **Punto Switcher**, **Lightshot** и **AnyDesk** одной программой ~250 строк Swift, без телеметрии, без иконки в доке.

## Горячие клавиши

| Клавиши | Действие |
|---------|----------|
| `Cmd+Shift` | Переключить раскладку клавиатуры |
| `Cmd+\` | Скриншот области → JPEG в `~/Screenshots/` + копия в буфер + HUD-плашка |
| `Cmd+Shift+\` | Видео: открывает нативную панель записи macOS (выбор области, звук, стоп) |
| Свайп 3 пальцами ←/→ | Листание страниц лаунчера (имитирует двухпальцевый свайп — для замен Launchpad: LaunchNext и т.п.) |
| Резкий взмах 2 пальцами ↑ | Скрыть лаунчер (Escape) |

> Жесты активны только когда **лаунчер** (по умолч. `LaunchNext`) — активное приложение; в остальных приложениях трекпад работает как обычно.

Клавиша скриншота меняется без пересборки:
```bash
defaults write com.nikita.layoutswitcher screenshotKeycode 42   # 42=\  50=`  14=е
```

Жесты настраиваются без пересборки (затем перезапуск приложения):
```bash
defaults write com.nikita.layoutswitcher swipeGain -2000             # листание: сила/инверсия (по умолч. -1500)
defaults write com.nikita.layoutswitcher swipeFlickVel 4.0           # скорость взмаха ↑ для скрытия, ед/сек (минус=инверсия, 0=выкл)
defaults write com.nikita.layoutswitcher launcherBundleId LaunchNext # к какому приложению привязаны жесты
```

> Скрытие — по **скорости резкого взмаха двумя пальцами вверх** (а не по расстоянию): срабатывает мгновенно, не двигая страницу, и не конфликтует с Mission Control (тот остаётся на трёх пальцах). Пиковая скорость взмаха пишется в `~/Library/Logs/lsswipe.log` — по ней удобно подобрать `swipeFlickVel`.

## Под капотом — только нативные инструменты macOS

- Раскладка — `TISSelectInputSource`
- Скриншот — `/usr/sbin/screencapture`
- Видео — нативная панель Cmd+Shift+5 (через CGEvent)
- Перехват клавиш — CGEvent event tap
- Жесты трекпада — чтение через MultitouchSupport (`src/mtswipe.c`): 3 пальца вбок → точный скролл-жест с фазой, 2 пальца резко вверх → Escape; активны только пока лаунчер фронтмост (NSWorkspace + CGWindowList)
- Уведомления — свой HUD на NSPanel (системные глушатся у фоновых процессов)

## Сборка

```bash
swiftc src/main.swift src/mtswipe.c -import-objc-header src/bridge.h \
  -framework Carbon -framework AppKit -framework Foundation \
  -F /System/Library/PrivateFrameworks -framework MultitouchSupport \
  -o LayoutSwitcherBin
```

Затем собрать `.app` bundle, подписать (`codesign --force --deep -s -`), положить в `/Applications`.

## Установка автозапуска

LaunchAgent `~/Library/LaunchAgents/com.nikita.layoutswitcher.plist` с `KeepAlive` — поднимает приложение при логине и при сбое.

## Права macOS

Нужны два разрешения в **Системные настройки → Конфиденциальность**:
- **Универсальный доступ** (Accessibility) — для перехвата клавиш
- **Запись экрана** (Screen Recording) — для скриншотов и видео

> ⚠️ При каждой пересборке ad-hoc подпись меняет cdhash, и macOS сбрасывает права — их нужно выдать заново.
