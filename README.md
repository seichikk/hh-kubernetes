Домашнее задание по распределённым вычислениям, «Управление ресурсами в Kubernetes».
Бровкин Аким Алексеевич, группа J3310

Отчёт: [`report/report.pdf`](report/report.pdf). Журналы подов: [`logs/`](logs/). Выводы всех команд текстом: [`report/out/`](report/out/).

Расчёт взят из ДЗ-3 ([hh-mapreduce](https://github.com/seichikk/hh-mapreduce)): частоты навыков, пар и троек в вакансиях «Программист, разработчик на C# и .NET», свой MapReduce поверх S3. Хранилище RustFS из ДЗ-2 переехало внутрь кластера.

## Что сделано

1. **Кластер kind** из трёх узлов (control-plane и два рабочих), Kubernetes v1.37.0, metrics-server для `kubectl top`. На каждом узле под систему отдано 8 CPU и 5 ГиБ, поэтому подам остаётся 4 CPU.
2. **Образ** `hh-k8s:1` (`docker/Dockerfile`): Python 3.12, pyarrow, boto3, `lab/common.py` и `lab/mapreduce.py` из ДЗ-3 без правок и новый `lab/kube.py`. Каждая команда в конце печатает пик памяти и время процессора из cgroup контейнера (`memory.peak`, `cpu.stat`).
3. **OOMKilled и предел.** С пределом 256Mi под падает через 3 с с `OOMKilled`, код 137. Пик по трём запускам 895 МиБ, предел 1152Mi = пик × 1,25 с округлением до 64 МиБ. Перебор пределов: 256–640 МиБ падают, с 768 МиБ расчёт проходит. Результат совпал с ДЗ-3 по SHA-256.
4. **RustFS в кластере:** StatefulSet с четырьмя PVC (erasure coding 2+2, как в ДЗ-2), бакет перенесён Job'ом `s3-copy` со сверкой SHA-256. С пределом 1Gi хранилище само получило `OOMKilled` под параллельной нагрузкой, предел поднят до 2Gi по замеру.
5. **Расчёт по частям:** `split` делит файл на 12 частей по концам CSV-записей, Indexed Job `pairs-map` считает их по 6 подов одновременно, `pairs-reduce` складывает. Файлы `k1.csv`–`k3.csv` побайтно совпали с ДЗ-3, топ-10 пар в `results/k8s/k2.csv`.
6. **Ожидание:** 12 подов по 1 CPU сразу, 6 из них в `Pending` с `Insufficient cpu`, хотя реально каждый тратит около 0,23 CPU.
7. **Вытеснение:** `PriorityClass` `hh-low` и `hh-high`. Срочная задача на 3 CPU вытеснила 3 пода плановой, плановая пересчитала их части (`podFailurePolicy` не тратит на это `backoffLimit`) и тоже совпала с ДЗ-3.
8. **Квота:** `ResourceQuota` на 4 CPU и 2 ГиБ. Под без пределов не создаётся вовсе, из 12 подов одновременно живут 4, срочная задача с высоким приоритетом ждёт, пока плановая освободит квоту.
9. **Ответы на вопросы** о соответствии YARN, Mesos и Kubernetes в разделе отчёта «Ответы на вопросы».

## Как запустить

Нужны Docker Desktop (виртуальной машине не меньше 8 ГиБ), kind, kubectl и хранилище из ДЗ-3: контейнер `rustfs` с бакетом `hh-lake` на `127.0.0.1:19000`.

```bash
bash scripts/00_cluster.sh     # кластер kind, metrics-server, образ
bash scripts/01_oom.sh         # OOMKilled, замер пика, подбор предела
bash scripts/02_storage.sh     # rustfs в кластере, перенос бакета
bash scripts/03_parallel.sh    # 12 частей в Indexed Job, reduce, сверка с дз-3
bash scripts/04_pending.sh     # ожидание процессора
bash scripts/05_preempt.sh     # вытеснение по приоритету
bash scripts/06_quota.sh       # квота пространства имён
bash scripts/07_report.sh      # pdf-отчёт
bash scripts/99_delete.sh      # удалить кластер
```

## Структура

```
k8s/kind.yaml               кластер: узлы и резерв ресурсов под систему
k8s/00..01                  пространства имён, адрес s3 снаружи кластера
k8s/10-whole-oom.yaml       расчёт целиком с пределом 256Mi
k8s/12-whole.yaml           то же с подобранным пределом
k8s/20..23                  rustfs в кластере, перенос бакета, новый адрес s3
k8s/30..32                  split, map (Indexed Job), reduce
k8s/40-map-all.yaml         все 12 частей сразу
k8s/50..52                  классы приоритета, плановая и срочная задачи
k8s/60-quota.yaml           квота пространства имён
lab/kube.py                 команды whole, split, map, reduce, copy
lab/mapreduce.py, common.py расчёт из дз-3 без изменений
scripts/                    запуск по шагам, timeline.py строит графики из watch.log
logs/                       журналы всех подов, describe, события, watch.log
results/k8s, results/hw3    итоговые таблицы и таблицы дз-3 для сравнения
report/                     отчёт и выводы команд
```
