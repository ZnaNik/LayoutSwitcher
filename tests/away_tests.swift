// Тесты чистой логики режима «отошёл» (src/away.swift). Без XCTest: самописный assert.
// Сборка и запуск: bash tests/run.sh

import Foundation

var failures = 0
var checks = 0

func check(_ cond: Bool, _ name: String, line: Int = #line) {
    checks += 1
    if cond {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) (tests/away_tests.swift:\(line))")
    }
}

func checkEq(_ got: AwayAction, _ want: AwayAction, _ name: String, line: Int = #line) {
    checks += 1
    if got == want {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name): получено \(got), ожидалось \(want) (tests/away_tests.swift:\(line))")
    }
}

@main
struct AwayTests {
    static func main() {
        // Значения по умолчанию
        do {
            let m = AwayMode()
            check(m.delay == 30, "по умолчанию delay = 30")
            check(m.wakeThreshold == 1.0, "по умолчанию wakeThreshold = 1.0")
            check(m.enabled == false, "по умолчанию выключен")
            check(m.dimmed == false, "по умолчанию не погашен")
        }

        // Выключенный никогда не гасит
        do {
            let m = AwayMode()
            checkEq(m.tick(idle: 0), .none, "выключен: idle 0 -> none")
            checkEq(m.tick(idle: 30), .none, "выключен: idle 30 -> none")
            checkEq(m.tick(idle: 100000), .none, "выключен: idle огромный -> none")
            check(m.dimmed == false, "выключен: dimmed остаётся false")
        }

        // Включение само по себе ничего не делает
        do {
            let m = AwayMode()
            checkEq(m.toggle(), .none, "toggle (включение) -> none")
            check(m.enabled, "после toggle enabled = true")
            check(m.dimmed == false, "после включения dimmed = false")
        }

        // Порог гашения: 29.9 -> none, 30 -> dim
        do {
            let m = AwayMode()
            _ = m.toggle()
            checkEq(m.tick(idle: 0), .none, "включён: idle 0 -> none")
            checkEq(m.tick(idle: 29.9), .none, "включён: idle 29.9 -> none")
            check(m.dimmed == false, "включён: на 29.9 не погашен")
            checkEq(m.tick(idle: 30), .dim, "включён: idle 30 -> dim")
            check(m.dimmed, "после dim dimmed = true")
        }

        // Повторный dim не выдаётся, пока погашен
        do {
            let m = AwayMode()
            _ = m.toggle()
            checkEq(m.tick(idle: 31), .dim, "первый dim")
            checkEq(m.tick(idle: 31.5), .none, "повторный tick (idle растёт) -> none, не dim")
            checkEq(m.tick(idle: 60), .none, "ещё tick -> none")
            checkEq(m.tick(idle: 3600), .none, "очень долгий простой -> none")
            check(m.dimmed, "всё ещё погашен")
        }

        // Пробуждение: при dimmed idle 5 -> none, 0.3 -> undim
        do {
            let m = AwayMode()
            _ = m.toggle()
            _ = m.tick(idle: 30)
            checkEq(m.tick(idle: 5), .none, "погашен: idle 5 -> none")
            check(m.dimmed, "погашен: idle 5 не будит")
            checkEq(m.tick(idle: 1.0), .none, "погашен: idle ровно 1.0 -> none (порог строгий)")
            checkEq(m.tick(idle: 0.3), .undim, "погашен: idle 0.3 -> undim")
            check(m.dimmed == false, "после undim dimmed = false")
            check(m.enabled, "после undim режим остаётся включён")
        }

        // После undim: idle 10 -> none, 30 -> снова dim
        do {
            let m = AwayMode()
            _ = m.toggle()
            _ = m.tick(idle: 30)
            _ = m.tick(idle: 0.3)
            checkEq(m.tick(idle: 10), .none, "после undim: idle 10 -> none")
            checkEq(m.tick(idle: 29.9), .none, "после undim: idle 29.9 -> none")
            checkEq(m.tick(idle: 30), .dim, "после undim: idle 30 -> снова dim")
            check(m.dimmed, "снова погашен")
            // и цикл повторяется ещё раз
            checkEq(m.tick(idle: 0.0), .undim, "второе пробуждение")
            checkEq(m.tick(idle: 45), .dim, "третье гашение")
        }

        // toggle при dimmed -> undim, enabled = false
        do {
            let m = AwayMode()
            _ = m.toggle()
            _ = m.tick(idle: 30)
            checkEq(m.toggle(), .undim, "toggle при dimmed -> undim")
            check(m.enabled == false, "после выключения enabled = false")
            check(m.dimmed == false, "после выключения dimmed = false")
            checkEq(m.tick(idle: 0.0), .none, "tick после выключения (idle 0) -> none")
            checkEq(m.tick(idle: 100), .none, "tick после выключения (idle 100) -> none")
            checkEq(m.tick(idle: 100), .none, "повторный tick после выключения -> none")
        }

        // toggle при включённом, но не погашенном -> none
        do {
            let m = AwayMode()
            _ = m.toggle()
            checkEq(m.toggle(), .none, "выключение без гашения -> none")
            check(m.enabled == false, "выключен")
            checkEq(m.tick(idle: 100), .none, "после выключения не гасит")
        }

        // Повторное включение после выключения работает
        do {
            let m = AwayMode()
            _ = m.toggle()
            _ = m.tick(idle: 30)
            _ = m.toggle()
            checkEq(m.toggle(), .none, "повторное включение -> none")
            check(m.enabled, "включён снова")
            checkEq(m.tick(idle: 29), .none, "после повторного включения до порога -> none")
            checkEq(m.tick(idle: 30), .dim, "после повторного включения порог -> dim")
        }

        // Страховка: выключен, но dimmed (если состояние рассинхронизировали) -> undim
        // Достижимо только через toggle, который сам снимает dimmed; проверяем, что tick не врёт.
        do {
            let m = AwayMode()
            _ = m.toggle()
            _ = m.tick(idle: 30)
            _ = m.toggle()
            checkEq(m.tick(idle: 0), .none, "после toggle-undim лишнего undim не будет")
        }

        // Свои параметры
        do {
            let m = AwayMode(delay: 5, wakeThreshold: 0.5)
            _ = m.toggle()
            checkEq(m.tick(idle: 4.9), .none, "delay 5: 4.9 -> none")
            checkEq(m.tick(idle: 5), .dim, "delay 5: 5 -> dim")
            checkEq(m.tick(idle: 0.7), .none, "wake 0.5: 0.7 -> none")
            checkEq(m.tick(idle: 0.4), .undim, "wake 0.5: 0.4 -> undim")
        }

        print("")
        print("проверок: \(checks), провалов: \(failures)")
        if failures > 0 {
            print("ПРОВАЛ")
            exit(1)
        }
        print("OK")
    }
}
