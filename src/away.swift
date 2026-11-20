// Режим «отошёл»: чистая логика без AppKit (чтобы тестировалась: tests/away_tests.swift).
//
// Идея: пока режим включён и человек не трогает мышь и клавиатуру `delay` секунд,
// экран гасится (чёрные окна + яркость 0), но дисплей системно не спит. Любое движение
// мыши или нажатие (простой меньше `wakeThreshold`) возвращает экран. Режим при этом
// остаётся включённым: через следующие `delay` секунд простоя экран погаснет снова.
// Режим снимается только повторным переключением.

enum AwayAction: Equatable { case none, dim, undim }

final class AwayMode {
    /// Сколько секунд простоя до гашения.
    let delay: Double
    /// Простой меньше этого значения = человек трогает мышь/клавиатуру (будим экран).
    let wakeThreshold: Double
    private(set) var enabled = false
    private(set) var dimmed = false

    init(delay: Double = 30, wakeThreshold: Double = 1.0) {
        self.delay = delay
        self.wakeThreshold = wakeThreshold
    }

    /// Переключение горячей клавишей.
    /// Включение: действия нет. Выключение при погашенном экране: .undim (и dimmed = false).
    func toggle() -> AwayAction {
        if !enabled {
            enabled = true
            return .none
        }
        enabled = false
        if dimmed {
            dimmed = false
            return .undim
        }
        return .none
    }

    /// Вызывается таймером; idle: секунд с последнего события ввода.
    func tick(idle: Double) -> AwayAction {
        if !enabled {
            // Страховка: режим выключен, а экран ещё погашен.
            if dimmed {
                dimmed = false
                return .undim
            }
            return .none
        }
        if dimmed {
            if idle < wakeThreshold {
                dimmed = false
                return .undim
            }
            return .none
        }
        if idle >= delay {
            dimmed = true
            return .dim
        }
        return .none
    }
}
