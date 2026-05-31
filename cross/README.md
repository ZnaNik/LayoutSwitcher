# LayoutSwitcher — кросс-платформенное ядро (Go)

Одна кодовая база на Go, собирается и под **Windows**, и под **macOS**. Это и есть «общее ядро»: `main.go` общий, платформенные действия в `platform_windows.go` / `platform_darwin.go` (разделены build-тегами).

## Готовые сборки (Windows)

| Файл | Что |
|------|-----|
| `LayoutSwitcher.exe` | Рабочая версия, без консольного окна — для постоянного использования |
| `LayoutSwitcher_debug.exe` | С консолью и логами — запусти первым чтобы видеть что происходит |

Просто скачай и запусти. Установка не нужна, зависимостей нет (один статический .exe ~1.7 МБ).

## Горячие клавиши (Windows)

| Клавиши | Действие | Через что |
|---------|----------|-----------|
| `Ctrl+Shift` | Переключить раскладку | Win32 `WM_INPUTLANGCHANGEREQUEST` (нативно) |
| `Ctrl+\` | Скриншот области → в буфер | встроенный Snipping (Win+Shift+S) |
| `Ctrl+Shift+\` | Запись видео | Xbox Game Bar (Win+Alt+R) |

`Ctrl+Shift` ловится низкоуровневым keyboard hook (`WH_KEYBOARD_LL`) — тот же принцип что event tap на Mac: ловим когда Ctrl+Shift зажали и отпустили без других клавиш.

## Автозапуск на Windows

Положи ярлык `LayoutSwitcher.exe` в папку автозагрузки:
```
Win+R → shell:startup → перетащи туда ярлык
```

## Сборка из исходника (с любой ОС)

```bash
# Windows .exe
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-H windowsgui -s -w" -o LayoutSwitcher.exe .

# macOS (ядро; основная Mac-версия — Swift, см. ../src/main.swift)
GOOS=darwin GOARCH=arm64 go build -o LayoutSwitcher .
```

## ⚠️ Статус тестирования

Сборка проверена (компилируется под Windows и macOS), но **запуск на живой Windows не проверялся** — собрано кросс-компиляцией с Mac. Первый прогон делай через `LayoutSwitcher_debug.exe` чтобы видеть логи. Возможны правки под реальное поведение Windows (особенно раскладка и эмуляция клавиш).

## Почему Mac остался на Swift

macOS-версия (`../src/main.swift`) уже отлажена и в проде с полноценным CGEvent tap. Go-ядро сделано в первую очередь под Windows. При желании можно перевести и Mac на это ядро, но рабочую Swift-версию трогать смысла нет.
