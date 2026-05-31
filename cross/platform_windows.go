//go:build windows

package main

import (
	"log"
	"syscall"
	"time"
	"unsafe"
)

var (
	user32                  = syscall.NewLazyDLL("user32.dll")
	procSetWindowsHookEx     = user32.NewProc("SetWindowsHookExW")
	procCallNextHookEx       = user32.NewProc("CallNextHookEx")
	procGetMessage           = user32.NewProc("GetMessageW")
	procSendInput            = user32.NewProc("SendInput")
	procGetForegroundWindow  = user32.NewProc("GetForegroundWindow")
	procPostMessage          = user32.NewProc("PostMessageW")
)

const (
	whKeyboardLL = 13
	wmKeyDown    = 0x0100
	wmKeyUp      = 0x0101
	wmSysKeyDown = 0x0104
	wmSysKeyUp   = 0x0105

	vkShift   = 0x10
	vkControl = 0x11
	vkLWin    = 0x5B
	vkMenu    = 0x12 // Alt
	vkOEM5    = 0xDC // клавиша \
	vkS       = 0x53
	vkR       = 0x52

	wmInputLangChangeRequest = 0x0050
	hklNext                  = 1

	inputKeyboard = 1
	keyEventKeyUp = 0x0002
)

type kbDLLHookStruct struct {
	VkCode    uint32
	ScanCode  uint32
	Flags     uint32
	Time      uint32
	ExtraInfo uintptr
}

type keyInput struct {
	Type uint32
	Ki   keybdInput
	_    [8]byte // padding до размера INPUT
}

type keybdInput struct {
	Vk      uint16
	Scan    uint16
	Flags   uint32
	Time    uint32
	ExtraInfo uintptr
}

type windowsPlatform struct {
	handlers HotkeyHandlers

	ctrlDown  bool
	shiftDown bool
	// comboDirty: была ли нажата обычная клавиша, пока держали Ctrl+Shift
	comboDirty bool
}

func newPlatform() Platform { return &windowsPlatform{} }

// --- Действия ---

func (p *windowsPlatform) SwitchLayout() {
	// Переключаем раскладку в активном окне на следующую (нативно)
	hwnd, _, _ := procGetForegroundWindow.Call()
	procPostMessage.Call(hwnd, wmInputLangChangeRequest, 0, hklNext)
}

func (p *windowsPlatform) Screenshot() {
	// Эмулируем Win+Shift+S → встроенный Snipping (выделение области в буфер)
	sendCombo([]uint16{vkLWin, vkShift, vkS})
	log.Println("Скриншот: выдели область (улетает в буфер, Ctrl+V для вставки)")
}

func (p *windowsPlatform) RecordVideo() {
	// Эмулируем Win+Alt+R → запись через Xbox Game Bar
	sendCombo([]uint16{vkLWin, vkMenu, vkR})
	log.Println("Видео: запись через Game Bar (повторно Win+Alt+R — стоп)")
}

// --- Эмуляция нажатий через SendInput ---

func sendCombo(keys []uint16) {
	n := len(keys)
	inputs := make([]keyInput, 0, n*2)
	// нажать по порядку
	for _, k := range keys {
		inputs = append(inputs, keyInput{Type: inputKeyboard, Ki: keybdInput{Vk: k}})
	}
	// отпустить в обратном порядке
	for i := n - 1; i >= 0; i-- {
		inputs = append(inputs, keyInput{Type: inputKeyboard, Ki: keybdInput{Vk: keys[i], Flags: keyEventKeyUp}})
	}
	procSendInput.Call(
		uintptr(len(inputs)),
		uintptr(unsafe.Pointer(&inputs[0])),
		unsafe.Sizeof(inputs[0]),
	)
	time.Sleep(50 * time.Millisecond)
}

// --- Low-level keyboard hook ---

var globalWP *windowsPlatform

func (p *windowsPlatform) Run(h HotkeyHandlers) {
	p.handlers = h
	globalWP = p

	hook, _, err := procSetWindowsHookEx.Call(
		whKeyboardLL,
		syscall.NewCallback(hookProc),
		0,
		0,
	)
	if hook == 0 {
		log.Fatalf("Не удалось поставить keyboard hook: %v", err)
	}
	log.Println("Запущен. Слушаю клавиши.")

	// Цикл сообщений (нужен чтобы hook работал)
	var msg [48]byte
	for {
		procGetMessage.Call(uintptr(unsafe.Pointer(&msg[0])), 0, 0, 0)
	}
}

func hookProc(nCode int, wParam uintptr, lParam uintptr) uintptr {
	if nCode >= 0 {
		kb := (*kbDLLHookStruct)(unsafe.Pointer(lParam))
		if globalWP.handle(wParam, kb) {
			return 1 // подавить событие
		}
	}
	ret, _, _ := procCallNextHookEx.Call(0, uintptr(nCode), wParam, lParam)
	return ret
}

// handle возвращает true если событие надо подавить.
func (p *windowsPlatform) handle(msg uintptr, kb *kbDLLHookStruct) bool {
	vk := kb.VkCode
	down := msg == wmKeyDown || msg == wmSysKeyDown
	up := msg == wmKeyUp || msg == wmSysKeyUp

	isCtrl := vk == vkControl || vk == 0xA2 || vk == 0xA3
	isShift := vk == vkShift || vk == 0xA0 || vk == 0xA1

	// Отслеживаем модификаторы
	if isCtrl {
		if down {
			p.ctrlDown = true
			if p.shiftDown {
				p.comboDirty = false
			}
		} else if up {
			// Ctrl отпущен: если держали Ctrl+Shift чисто — переключаем раскладку
			if p.ctrlDown && p.shiftDown && !p.comboDirty {
				go p.handlers.OnSwitchLayout()
			}
			p.ctrlDown = false
		}
		return false
	}
	if isShift {
		if down {
			p.shiftDown = true
			if p.ctrlDown {
				p.comboDirty = false
			}
		} else if up {
			if p.ctrlDown && p.shiftDown && !p.comboDirty {
				go p.handlers.OnSwitchLayout()
			}
			p.shiftDown = false
		}
		return false
	}

	// Любая обычная клавиша при зажатых модификаторах отменяет "чистый" Ctrl+Shift
	if down {
		p.comboDirty = true

		// Ctrl+\ → скриншот ;  Ctrl+Shift+\ → видео
		if vk == vkOEM5 && p.ctrlDown {
			if p.shiftDown {
				go p.handlers.OnRecordVideo()
			} else {
				go p.handlers.OnScreenshot()
			}
			return true // подавляем
		}
	}

	return false
}
