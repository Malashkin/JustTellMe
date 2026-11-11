# JustTellMe

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-black)
[![Release](https://img.shields.io/github/v/release/Malashkin/JustTellMe)](https://github.com/Malashkin/JustTellMe/releases/latest)

> **Private, offline push-to-talk dictation for macOS.** Hold a key, speak, release — the text is typed into
> whatever app you are in. Runs entirely on your Mac with whisper.cpp (Metal / Neural Engine): no cloud,
> no account, no subscription. Tuned for Russian with English terms mixed in, works for English too.
> Light on the Mac: the model leaves memory when you are not dictating, and updates install themselves.

## Установка
1. Скачайте `JustTellMe.zip` со страницы [последнего выпуска](https://github.com/Malashkin/JustTellMe/releases/latest) и распакуйте в «Программы».
2. Первый запуск: правый клик → «Открыть» (приложение не нотариально заверено Apple).
3. Разрешите микрофон и «Универсальный доступ» — главное окно подскажет, чего не хватает.

Дальше обновления ставятся из самого приложения.

Локальная диктовка для macOS (Apple Silicon): зажмите клавишу (Fn или правый ⌥), говорите, отпустите — текст вставится в активное поле. Распознавание полностью на устройстве через [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal), модель large-v3-turbo встроена в приложение.

Документация: [docs/](docs/AGENTS.md) — продукт, архитектура и решения (ADR), сборка, тесты, приватность, [CHANGELOG](docs/CHANGELOG.md).

## Возможности
- Push-to-talk на Fn (🌐) или правом ⌥: удерживайте и говорите; короткое нажатие — диктовка без рук до следующего нажатия; Esc — отмена
- Распознавание кусками прямо во время речи: после отпускания клавиши текст появляется примерно через секунду
- Опциональное ускорение Neural Engine (Core ML-энкодер, скачивается 1,2 ГБ; macOS один раз готовит модель)
- Языки: авто (ru/en, английские слова остаются латиницей), русский, английский
- Главное окно (клик по значку приложения или меню 🎙 → «Открыть JustTellMe…»):
  - **Главная** — всё надиктованное по дням, поиск, копирование, исправление; цифры за сегодня
  - **Статистика** — слова, символы, скорость, сэкономленное время, график по дням, приложения, языки
  - **Словарь** — подсказка, личный словарь и замены; встроенный словарь популярных англоязычных терминов в русской речи
  - **Настройки** — клавиша, режим, язык, микрофон, модель, Neural Engine, выгрузка модели, звуки, приглушение, буфер обмена, автозапуск
- Вставка не затирает буфер обмена: прежнее содержимое возвращается, менеджеры буфера надиктованное не сохраняют
- ⌃⌥V — вставить последнее надиктованное ещё раз (если текст ушёл не туда)
- Если курсор не в поле ввода, появляется карточка с текстом и кнопкой «Скопировать»
- Бережёт ресурсы: модель (~0,7 ГБ) выгружается после 15 минут простоя и загружается заново за полсекунды, пока вы говорите; окошко записи почти не нагружает процессор
- Обновления с GitHub раз в день: установка в два клика с проверкой подписи, разрешения сохраняются
- «Исправить и запомнить…» — обучение на исправлениях (новые слова → словарь, исправленные фрагменты → замены)
- Смена моделей: встроенная, из файла или загрузка из меню
- Самодостаточный бандл: без Homebrew/Python на целевой машине

## Сборка
Требования (только на машине сборки): Xcode Command Line Tools, cmake, git, curl.

```bash
./build.sh            # → dist/JustTellMe.app и dist/JustTellMe.zip
SKIP_ZIP=1 ./build.sh # без zip
```

`build.sh` сам клонирует whisper.cpp на зафиксированном коммите, применяет патч из `patches/` и скачивает модель.

## Тесты
```bash
scripts/test.sh                 # unit + интеграционные (нужен хотя бы один ./build.sh)
JTM_SKIP_SLOW=1 scripts/test.sh # быстро: без распознавания речи и проверки архивов обновления
```
Тесты работают во временной папке (`JTM_SUPPORT_DIR`) и не трогают вашу историю и словарь. Результаты — `TEST_RESULTS.md`.

## Установка своей сборки
1. Скопируйте `dist/JustTellMe.app` в «Программы».
2. Разрешите микрофон и включите JustTellMe в «Настройки → Конфиденциальность и безопасность → Универсальный доступ».
3. Без постоянной подписи (`scripts/make-signing-identity.sh`) после пересборки удалите JustTellMe из «Универсального доступа» и добавьте заново (или `tccutil reset Accessibility com.justtellme.app`).

## Выпуск версии
Поднять `CFBundleShortVersionString` в `Resources/Info.plist`, перенести записи CHANGELOG в раздел версии, закоммитить и отправить, затем `scripts/release.sh`: сборка, все тесты, тег и GitHub Release с `JustTellMe.zip`. Установленные приложения увидят обновление в течение суток.

## Отладочные режимы
Бинарник `JustTellMe.app/Contents/MacOS/JustTellMe` понимает скрытые флаги (без интерфейса или с тестовым окном):
`--transcribe file.wav [--lang] [--model] [--encoder] [--repeat N]`, `--stream file.wav` (замер задержки после «отпускания»),
`--learn "распознано" "исправлено"`, `--list-models`, `--audio-info [--test-mute]`, `--demo-paste "текст"`,
`--demo-overlay [out.png]`, `--demo-window out-prefix` (PNG всех страниц главного окна), `--demo-card out.png`,
`--unload-cycle file.wav` (выгрузка и повторная загрузка модели), `--focus-check [сек]` (есть ли поле ввода),
`--update-check`, `--update-stage file.zip [--version X]`, `--update-install other/JustTellMe.app`.

## Структура
- `Sources/App` — Swift: меню, главное окно, горячая клавиша, запись, потоковое распознавание, вставка, словари, статистика
- `Sources/Shim` — C-обёртка над whisper.cpp
- `Resources` — Info.plist, иконка, встроенный словарь и замены
- `patches` — патч к whisper.cpp
- `Tests` — тесты (свой мини-харнесс: на машине только Command Line Tools, без XCTest)

Личные данные (история диктовок, личный словарь, замены, скачанные модели) хранятся в `~/Library/Application Support/JustTellMe/` и в репозиторий не попадают.

## Лицензия
[MIT](LICENSE). Сторонние компоненты: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT),
модели [Whisper](https://github.com/openai/whisper) (MIT), [Silero VAD](https://github.com/snakers4/silero-vad) (MIT).
