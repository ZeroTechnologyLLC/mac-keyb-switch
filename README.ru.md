# mac-keyb-switch (layoutd)

Мгновенное переключение раскладки **Cmd+Space** на macOS — без задержки на отпускании клавиш и без потерь нажатий под CPU-нагрузкой.

```
$ make install
```

[README in English](README.md)

## Зачем

Системный хоткей «Input Sources» (Cmd+Space) в macOS имеет две проблемы:

1. **Переключение происходит на отпускании клавиш (keyUp)**, а не на нажатии. Пока держишь Cmd+Space — ничего не происходит, раскладка меняется только после отпускания.
2. **Под CPU-нагрузкой нажатия теряются** (10–30%): событие проходит через цепочку symbolic hotkey → WindowServer → TextInputMenuAgent, и любой перегруженный узел её роняет. Замер на 12-ядерном стресс-тесте: медиана 364 мс, худшие случаи 2.4 с, часть нажатий теряется полностью.

Сама механика переключения (`TISSelectInputSource`) при этом работает за 2–9 мс.

Это давняя и широко известная проблема:

- [Keyboard language switch lag, a long standing issue that never gets fixed](https://discussions.apple.com/thread/255940643) — Apple Community: «классический cmd+space лагает непредсказуемо. Иногда работает нормально, иногда не срабатывает и требует четырёх нажатий»
- [Cannot switch input language with CMD Space](https://discussions.apple.com/thread/255233761) — Apple Community (Sonoma)
- [Delay/unresponsive on change input](https://developer.apple.com/forums/thread/51454) — Apple Developer Forums
- [Why there is a language switch lag?](https://discussions.apple.com/thread/7769867) — Apple Community (тянется ещё с Sierra)
- [Delay in switching the language layout on mac OS](https://www.reddit.com/r/mac/comments/r2odrh/delay_in_switching_the_language_layout_on_mac_os/) — Reddit

## Как работает

`layoutd` — маленький демон (один Swift-файл, ~250 строк):

1. Активный `CGEventTap` (session-level) перехватывает Cmd+Space **раньше системы**
2. На keyDown сразу вызывает `TISSelectInputSource` — раскладка меняется в момент нажатия
3. keyDown и keyUp поглощаются — системный хоткей не срабатывает повторно
4. Дедупликация: macOS 27 под нагрузкой дублирует события (пара UP+DOWN с интервалом 0.0–0.2 мс); DOWN раньше 40 мс после UP и раньше 60 мс после переключения — глотается

## Результаты замеров

| Конфигурация | Потери под нагрузкой | Медиана | Срабатывание |
|---|---|---|---|
| Cmd+Space (системный) | 10–30% | 364 мс | на keyUp |
| Caps Lock (системный) | 0% | 55 мс | на keyDown |
| **Cmd+Space + layoutd** | **0%** | **47–162 мс** | **на keyDown** |

Методика: listenOnly event tap + поллинг `TISCopyCurrentKeyboardInputSource` каждые 1 мс; нагрузка — 12 busy-loop ядер (loadavg 10–43).

## Установка

Требования: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```bash
make install
```

Соберёт бинарник, подпишет (если найден сертификат Apple Development), скопирует в `~/Library/Application Support/layoutd/`, создаст LaunchAgent и запустит.

**Единственный ручной шаг** — Accessibility-разрешение (нужно один раз):

```bash
make accessibility   # откроет Системные настройки → Конфиденциальность → Универсальный доступ
```

1. Если в списке уже есть **layoutd от прошлой установки — сначала удалите его** («−»): macOS не подхватывает новую запись, пока висит старая с той же подписью/именем
2. «+» → ⌘⇧G → `~/Library/Application Support/layoutd/layoutd` → добавить

KeepAlive перезапустит агента автоматически в течение ~10 секунд после выдачи разрешения.

## Использование

```bash
make status        # состояние агента + последние события
make log           # живой лог переключений
make restart       # перезапуск
make stop          # остановить
make uninstall     # полное удаление
```

Свои раскладки (по умолчанию US ↔ Russian) — задаются при установке и прописываются в LaunchAgent:

```bash
make list                                        # список доступных Input Source ID
make install FIRST=com.apple.keylayout.British SECOND=com.apple.keylayout.Russian
```

## Диагностика проблем

| Симптом | Причина | Решение |
|---|---|---|
| `FATAL: cannot create event tap` | нет Accessibility-разрешения | выдать в панели (см. Установка) |
| Не работает после перезагрузки | BTS пометил агента `disallowed` (macOS сбрасывает разрешения фоновых агентов при крупных апдейтах) | `sfltool dumpbtm \| grep -A12 layoutd` — если `disallowed`, сменить Label в plist (новое имя файла + Label) и `make restart` |
| Переключается дважды подряд | системные дубликаты событий | уже лечится дедупликацией; при рецидиве запустить с `--debug` и смотреть интервалы в логе |
| Совсем ничего в логе | Secure Input (поле пароля во фронтмосте) или тап отключён | проверить фронтмост; `make restart` |

## Технические заметки

- **Подпись**: бинарник подписывается сертификатом Apple Development с фиксированным identifier `dev.layoutd` — тогда Accessibility-разрешение переживает пересборки. Adhoc-подпись привязывает TCC по cdhash и слетает при каждой пересборке. Если сертификат истёк/отозван, Makefile подпишет adhoc и предупредит — обновите `SIGN_ID` в Makefile (`security find-identity -v -p codesigning`).
- **Background Task Management**: macOS 27+ после крупных апдейтов может помечать LaunchAgent как `disallowed` — агент не поднимается при буте и не виден в Login Items. Лечится сменой Label (чистая BTS-запись).
- **event.timestamp vs DispatchTime.now()**: дедупликация сравнивает время обработки, а не метки событий — под нагрузкой доставка в тап задерживается неравномерно (UP может прийти через 193 мс, DOWN через 27 мс), и сравнение по timestamp пропускает дубликаты.
- **Синтетический постинг** Cmd+Space (CGEvent post) не триггерит symbolic hotkey — системные хоткеи режут синтетику; замеры возможны только listenOnly-тапом и физическими нажатиями.

## Лицензия

MIT
