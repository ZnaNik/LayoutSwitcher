// LayoutSwitcher — кросс-платформенное ядро (Windows + macOS).
// Общая логика здесь. Платформенные действия — в platform_windows.go / platform_darwin.go.
package main

import (
	"log"
)

// Действия, которые реализует каждая платформа по-своему.
type Platform interface {
	// SwitchLayout переключает раскладку клавиатуры на следующую.
	SwitchLayout()
	// Screenshot запускает выделение области и сохранение скриншота.
	Screenshot()
	// RecordVideo открывает нативную панель записи видео.
	RecordVideo()
	// Run запускает перехват горячих клавиш (блокирующий вызов).
	Run(hk HotkeyHandlers)
}

// Колбэки горячих клавиш, которые платформа дёргает при срабатывании.
type HotkeyHandlers struct {
	OnSwitchLayout func()
	OnScreenshot   func()
	OnRecordVideo  func()
}

func main() {
	log.SetPrefix("[LayoutSwitcher] ")
	log.Println("Запуск...")

	p := newPlatform() // создаётся в platform_<os>.go

	handlers := HotkeyHandlers{
		OnSwitchLayout: p.SwitchLayout,
		OnScreenshot:   p.Screenshot,
		OnRecordVideo:  p.RecordVideo,
	}

	log.Println("Горячие клавиши:")
	log.Println("  Ctrl+Shift      → переключить раскладку")
	log.Println("  Ctrl+\\          → скриншот области")
	log.Println("  Ctrl+Shift+\\    → запись видео")

	p.Run(handlers) // блокирующий: слушает клавиши до выхода
}
