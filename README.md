# ISIC 2019 multimodal training

Воспроизводимое обучение мультимодальной модели на ISIC 2019:

- `ConvNeXtV2-Base` кодирует изображение;
- projection head обучается с supervised contrastive loss (SupCon);
- вспомогательный image-only classifier напрямую обучает визуальный backbone;
- MLP кодирует `age`, `sex` и `anatomical site`;
- объединённое представление решает задачи 8-классовой диагностики,
  `melanoma-vs-rest` и `malignant-vs-benign`.

Класс `UNK` из исходной таблицы ISIC 2019 исключается. Злокачественными считаются
`MEL`, `BCC`, `AK` и `SCC`. Разбиение выполняется по `lesion_id`, поэтому изображения
одной лезии не попадают одновременно в обучение и валидацию.

## Что записывает эксперимент

Каждый запуск создаёт отдельный каталог `runs/<UTC-время>_<имя>`:

- `config.json` — все гиперпараметры;
- `environment.json` — версии Python/PyTorch/CUDA/cuDNN, GPU, драйвер, Git commit,
  состояние рабочей копии и `pip freeze`;
- `data_summary.json` — размеры split и веса классов;
- `metrics.jsonl` — метрики каждой эпохи;
- `best_metrics.json`, `best.pt`, `last.pt`;
- `tensorboard/` — журналы TensorBoard.

Основная checkpoint-метрика — multiclass MCC. Также считаются Accuracy, Balanced
Accuracy, Macro-F1, Weighted-F1, class-wise Precision/Recall/F1, confusion matrix и
бинарные метрики вспомогательных голов.

## Подготовка сервера

На Ubuntu-сервере должны быть установлены:

1. актуальный NVIDIA-драйвер с поддержкой RTX 5080;
2. Docker Engine и Docker Compose plugin;
3. NVIDIA Container Toolkit.

Проверка доступа контейнера к GPU:

```bash
docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
```

## Данные

Скачайте официальный ISIC 2019 Training Data и расположите файлы так:

```text
/srv/datasets/isic2019/
├── ISIC_2019_Training_Input/
│   ├── ISIC_0000000.jpg
│   └── ...
├── ISIC_2019_Training_GroundTruth.csv
└── ISIC_2019_Training_Metadata.csv
```

Данные не копируются в Docker image и не попадают в Git.

## Запуск через SSH

```bash
ssh user@server
git clone https://github.com/CrucifiedOnTheCross/Research.git
cd Research
export ISIC_DATA_DIR=/srv/datasets/isic2019
export RUNS_DIR="$PWD/runs"
export MODEL_CACHE_DIR="$PWD/.cache/torch"
chmod +x scripts/*.sh
docker compose build
```

Рекомендуемый запуск в `tmux`, чтобы обучение не прервалось после закрытия SSH:

```bash
tmux new -s isic
./scripts/train.sh
# Отсоединиться: Ctrl-b, затем d
# Вернуться: tmux attach -t isic
```

Или полностью фоновый запуск:

```bash
mkdir -p logs
nohup ./scripts/train.sh > logs/docker-train.log 2>&1 &
echo $! > logs/docker-train.pid
tail -f logs/docker-train.log
```

### Фактический сервер Windows (`lab-bio@10.200.1.180`)

Проект уже размещён в `C:\Users\lab-bio\Research`. После размещения датасета запустите
обучение одной удалённой командой; контейнер работает в detached-режиме и не завершится
при закрытии SSH:

```powershell
ssh lab-bio@10.200.1.180 powershell -NoProfile -ExecutionPolicy Bypass `
  -File C:\Users\lab-bio\Research\scripts\train-server.ps1 `
  -DataDir D:\Datasets\isic2019
```

Скрипт выведет ID контейнера. Текущий ID также хранится в
`C:\Users\lab-bio\Research\last-container-id.txt`. Проверить состояние и смотреть лог:

```powershell
ssh lab-bio@10.200.1.180 docker ps
$id = ssh lab-bio@10.200.1.180 type C:\Users\lab-bio\Research\last-container-id.txt
ssh lab-bio@10.200.1.180 docker logs -f $id
```

Возобновление из checkpoint:

```bash
./scripts/train.sh --resume runs/<run>/last.pt
```

## TensorBoard через безопасный SSH-туннель

На сервере:

```bash
./scripts/tensorboard.sh
```

На локальном компьютере:

```bash
ssh -N -L 6006:localhost:6006 user@server
```

Откройте `http://localhost:6006`. Порт TensorBoard не требуется публиковать наружу.

## Автоматическая выгрузка результатов с сервера

Для сервера `lab-bio@10.200.1.180` предусмотрена фоновая синхронизация на локальный
Windows-компьютер. Логи и метрики копируются по мере изменения, а `best.pt` — когда
эксперимент получает состояние `completed`. Временные загрузки имеют суффикс `.part`,
поэтому недокачанный файл не будет принят за готовый.

Один запуск синхронизации:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync-results.ps1
```

Установка локальной задачи Windows, запускающей синхронизацию каждые 10 минут:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-result-sync.ps1
```

Результаты появятся в `server-results/`. По умолчанию большой `last.pt` не копируется;
если он нужен для продолжения обучения, установите задачу с флагом
`-IncludeLastCheckpoint`. Посмотреть или удалить задачу:

```powershell
Get-ScheduledTask -TaskName "ISIC Research Result Sync"
Unregister-ScheduledTask -TaskName "ISIC Research Result Sync"
```

Скрипт использует SSH-ключ и поэтому требует, чтобы команда
`ssh -o BatchMode=yes lab-bio@10.200.1.180 exit` выполнялась без запроса пароля.

## Полностью автоматическая подготовка сервера

На Windows-сервере следующий скрипт в фоне скачивает официальный ISIC 2019 с
продолжением прерванной загрузки, проверяет точные размеры файлов и количество 25 331
изображений, распаковывает данные, собирает образ, запускает обучение и TensorBoard:

```powershell
ssh lab-bio@10.200.1.180 powershell -NoProfile -ExecutionPolicy Bypass `
  -File C:\Users\lab-bio\Research\scripts\start-server-pipeline.ps1
```

Состояние хранится в `pipeline-status.json`, подробный вывод — в
`pipeline-stdout.log` и `pipeline-stderr.log`. TensorBoard слушает только localhost
сервера; для безопасного просмотра используйте SSH-туннель:

```powershell
ssh -N -L 6006:127.0.0.1:6006 lab-bio@10.200.1.180
```

После этого интерфейс доступен на `http://localhost:6006`.

### Автоматическое восстановление подключения

Локальная задача `ISIC Research Connectivity` запускается при входе в Windows и
каждые 2 минуты. Она восстанавливает SSH-туннель TensorBoard с keepalive и выгружает
результаты минимум раз в 10 минут; после пропажи сети повтор происходит автоматически.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install-connectivity-watchdog.ps1
```

Текущее состояние записывается в `server-results/connectivity-state.json`, события —
в `server-results/connectivity-watchdog.log`. Повторная установка безопасна и заменяет
предыдущую задачу синхронизации.

Автоматически копируются компактные результаты экспериментов: config, environment,
metrics, status и GPU telemetry. Checkpoints остаются на сервере, чтобы десятки
абляций не заполнили локальный диск. Нужный `best.pt` можно получить явно:

```powershell
.\scripts\sync-results.ps1 -IncludeBestCheckpoint
```

## Очередь исследовательских экспериментов

Предзарегистрированный план находится в `experiments/PROTOCOL.md`, а машинная очередь
— в `experiments/queue.json`. Она ждёт завершения активной full-модели, затем запускает
41 эксперимент последовательно: baselines, controlled additions, leave-one-out
ablation, sensitivity, seeds и пять grouped folds. Состояние хранится в
`experiment-queue-state.json`, логи запуска — в `queue-logs/`.

```powershell
ssh lab-bio@10.200.1.180 powershell -NoProfile -ExecutionPolicy Bypass `
  -File C:\Users\lab-bio\Research\scripts\start-experiment-queue.ps1
```

После успешного запуска сохраняется компактный `best.pt`; большой resumable
`last.pt` удаляется. При сбое `last.pt` остаётся для диагностики и продолжения.

## Настройка производительности

Исходная конфигурация рассчитана на RTX 5080 16 GB и i7-14700KF: BF16, TF32,
channels-last, `torch.compile`, 12 DataLoader workers и gradient accumulation.
Настройки находятся в `configs/train.yaml`. Если возникает CUDA OOM, сначала уменьшите
`training.batch_size` с 16 до 12 или 8, сохраняя эффективный batch увеличением
`gradient_accumulation_steps`.

Режим `experiment.deterministic: false` быстрее, но seed и все начальные условия всё
равно фиксируются. Для максимально строгой повторяемости включите `true`; это может
снизить скорость и не гарантирует побитовую идентичность между разными версиями GPU,
CUDA и PyTorch.

Цикл не копирует scalar loss на CPU на каждом батче: метрики накапливаются на GPU и
переносятся один раз в конце эпохи. Validation-предсказания также передаются одним
пакетом, а metadata/targets предвычисляются до запуска DataLoader workers. Это не
меняет loss, аугментации, порядок примеров или эффективный batch size. В TensorBoard
для новых запусков записываются `performance/train_images_per_second` и
`performance/validation_images_per_second`.

Готовые аугментированные батчи намеренно не кешируются: такой кеш заморозил бы
случайные crop/color jitter. Исходные JPEG занимают около 9.1 GB и обслуживаются
системным файловым кешем; явный RAM-кеш имеет смысл только после измеренного
I/O bottleneck.

### Мониторинг GPU

Фоновая задача `ISIC GPU Monitor` каждые 5 секунд записывает utilization, VRAM,
мощность, температуру, частоты и параметры PCIe в
`gpu-telemetry/gpu-snapshots.csv`. Файл автоматически попадает в локальную папку
`server-results/gpu-telemetry` вместе с результатами экспериментов.

Запуск или переустановка монитора:

```powershell
ssh lab-bio@10.200.1.180 powershell -NoProfile -ExecutionPolicy Bypass `
  -File C:\Users\lab-bio\Research\scripts\start-gpu-monitor.ps1
```

Сводка за последние 10 минут:

```powershell
ssh lab-bio@10.200.1.180 powershell -NoProfile -ExecutionPolicy Bypass `
  -File C:\Users\lab-bio\Research\scripts\summarize-gpu-monitor.ps1
```

## Быстрые проверки

Внутри собранного образа:

```bash
docker run --rm --entrypoint pytest isic2019-trainer:latest -q
```
