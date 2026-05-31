//go:build darwin

package main

import (
	"log"
	"os/exec"
)

// macOS-реализация общего ядра.
// Примечание: основная Mac-версия — это Swift-приложение (src/main.swift), оно уже
// в проде с полноценным event tap. Этот файл нужен чтобы общее Go-ядро компилировалось
// и под Mac тоже. Перехват чистого Cmd+Shift на Mac надёжнее делать через Swift CGEvent tap,
// поэтому здесь Run — заглушка, а действия дёргают те же системные инструменты.

type darwinPlatform struct{}

func newPlatform() Platform { return &darwinPlatform{} }

func (p *darwinPlatform) SwitchLayout() {
	// На Mac смену раскладки в Go надёжнее не делать — используется Swift-версия.
	log.Println("SwitchLayout: на macOS используйте Swift-версию (src/main.swift)")
}

func (p *darwinPlatform) Screenshot() {
	exec.Command("/usr/sbin/screencapture", "-i", "-c").Run() // область в буфер
}

func (p *darwinPlatform) RecordVideo() {
	exec.Command("/usr/bin/open", "/System/Library/CoreServices/Screenshot.app").Run()
}

func (p *darwinPlatform) Run(h HotkeyHandlers) {
	log.Println("На macOS используйте нативную Swift-версию: /Applications/LayoutSwitcher.app")
	log.Println("Это Go-ядро предназначено в первую очередь для Windows-сборки.")
}
