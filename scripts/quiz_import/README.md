# Импорт тестовых заданий (ИКГ) в банк вопросов

Два .docx с банками тестов (1 и 2 семестр) превращаются в `quiz_question`-блоки **банка вопросов**
(library blocks). Владелец блоков — любой аккаунт на ваш выбор (`--owner`).

| Файл | Что делает |
|---|---|
| `docx_reader.exs` | читает .docx (абзацы, картинки по порядку) без внешних зависимостей |
| `parse.exs` | .docx → бандл: `questions.json` + `images/` + `report.txt` (запускается локально) |
| `import.exs` | бандл → БД и MinIO через `Athena.Content`/`Athena.Media` (dev и прод) |
| `pack.sh` | собирает каталог/архив для копирования на прод |
| `prod_import.sh` | на хосте: кладёт файлы в контейнер и вызывает `import.exs` через `bin/web rpc` |

## Перед запуском на проде (важно)

1. **Сначала выкатите релиз с фиксом `Athena.Workers.MediaCleanup`.** Старый чистильщик не смотрит
   `library_blocks.content` и раз в час удаляет «неиспользуемые» картинки — то есть все картинки из импорта.
2. **Правильные ответы в .docx не размечены.** Все варианты в вопросах «выбор» импортируются с `is_correct: false`,
   пока их не расставят в студии. У вопросов на соответствие верные пары заданы порядком, они работают сразу.
   Открытые вопросы (там только картинка и «укажите номер…») проверяются вручную.

## 1. Разобрать документы (локально)

```bash
mix run scripts/quiz_import/parse.exs "ИКГ_ЗАЧЕТ_1 семестр_2025_TZ_1.docx" --set ikg-1sem --label "ИКГ-1"
mix run scripts/quiz_import/parse.exs "ИКГ_ЗАЧЕТ_2 семестр_2025_TZ_4.docx" --set ikg-2sem --label "ИКГ-2"
```

Результат лежит в `tmp/quiz_bundle/<set>/`. Парсер печатает итог и пишет `report.txt`:
- **ANOMALIES** — задания, которые не удалось разобрать (в бандл не попадают, exit code 2). Сейчас их нет.
- **NOTES** — что парсер вывел сам: задания без вариантов стали открытыми вопросами; выброшены
  «лишние» абзацы из исходника (оторванные цифры, чужие фразы с «____»); ручная правка задания 141 из набора 2
  (в исходнике 5 названий и 4 картинки, название без картинки убрано).

Каждый блок получает два тега: `тема:…` и `подтема:…` (запятые из названий убираются, запятая разделяет теги).
Заголовок блока: `[ИКГ-1] 1.1.1 — начало вопроса`.

## 2. Отладка в dev

```bash
mix run -e 'Code.require_file("scripts/quiz_import/import.exs"); QuizImport.Importer.list_owners()'

# пробный запуск: валидирует всё, ничего не пишет
mix run -e 'Code.require_file("scripts/quiz_import/import.exs"); QuizImport.Importer.run(bundle: "tmp/quiz_bundle/ikg-1sem", owner: "LOGIN")'

# настоящий импорт (в dev нужен bucket: mix athena.storage.setup)
mix run -e 'Code.require_file("scripts/quiz_import/import.exs"); QuizImport.Importer.run(bundle: "tmp/quiz_bundle/ikg-1sem", owner: "LOGIN", apply: true)'
```

## 3. На прод

Локально:

```bash
scripts/quiz_import/pack.sh                     # -> tmp/quiz_import_pack.tar.gz
scp tmp/quiz_import_pack.tar.gz user@host:~/
```

На хосте (где работает docker compose с контейнером `athena_web`):

```bash
tar xzf quiz_import_pack.tar.gz && cd quiz_import_pack

./prod_import.sh --list-owners                          # кто может быть владельцем
./prod_import.sh --owner LOGIN --set ikg-1sem           # пробный запуск, ничего не пишет
./prod_import.sh --owner LOGIN --set ikg-1sem --apply   # импорт
./prod_import.sh --owner LOGIN --set ikg-2sem
./prod_import.sh --owner LOGIN --set ikg-2sem --apply
```

`LOGIN` — логин (или UUID) аккаунта, которому достанутся вопросы. Аккаунт должен быть активным и иметь право
редактировать библиотеку (`library.update` или роль admin). Другое имя контейнера или бинаря:
`ATHENA_CONTAINER=... ATHENA_BIN=... ./prod_import.sh ...`.

Файлы копируются в `/tmp/quiz_import` внутри контейнера и удаляются после запуска. Новый образ для самого импорта не нужен.

### Повторные запуски и откат

- Служебных тегов нет, поэтому импортированные блоки узнаются по **заголовку**: вопросы, у которых у этого владельца уже есть блок
  с таким же заголовком, пропускаются. Не переименовывайте блоки до отката: переименованный откат не найдёт и при повторном
  импорте создастся его копия.
  Если запуск оборвался, достаточно повторить команду, и он продолжит с места остановки.
- Картинки лежат по ключу `library/<owner_id>/quiz-import/<set>/imageN.png` и повторно не загружаются.
- Откат набора: `./prod_import.sh --owner LOGIN --set ikg-1sem --rollback --apply`
  (без `--apply` только покажет, сколько блоков удалит). Удаляются блоки владельца с заголовками из бандла. Блок, привязанный к курсу, не удаляется и попадает в список ошибок.
  Картинки откатившихся блоков уберёт `MediaCleanup`.
