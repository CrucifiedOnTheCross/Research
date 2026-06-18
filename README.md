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

## Быстрые проверки

Внутри собранного образа:

```bash
docker run --rm --entrypoint pytest isic2019-trainer:latest -q
```
