# Расширенный запуск авторского notebook

```bash
bash scripts/run_extended_demo.sh
```

Нужны Bash, curl и Conda. Скрипт использует окружение `.conda/` из демо
или создаёт его по `environment.yml`. При необходимости можно задать
`CONDA_EXE` и `DEMO_ENV_PREFIX`, как для демо R5. Перед запуском нужно
не менее 90 ГиБ свободного диска; на проверенной машине доступно 24 ГиБ RAM.

Выполняются разделы 1, 2, 3 и 5 [авторского notebook](https://github.com/sir-lab/data-release/blob/84a9d7727aefed486ea69e022b5ed2476d588700/src/demo_cold_start.ipynb)
на R2, каждый в отдельном ядре. Раздел 4 с загрузкой всех запросов в pandas
полностью пропускается.

Скрипт скачивает холодные события R2, временные ряды, таблицу runtime/trigger type
и все 10 частей журналов запросов из [набора авторов](https://github.com/sir-lab/data-release/blob/84a9d7727aefed486ea69e022b5ed2476d588700/README_data_release_2025.md).
Временные файлы находятся в `.cache/extended-demo-*` и удаляются при завершении или ошибке
скрипта. Повторный запуск скачивает данные заново.

Результаты сохраняются в `results/extended-demo/`:

- [Notebook с выводами](../results/extended-demo/demo_cold_start.ipynb): код раздела 4 заменён пояснением о пропуске.
- [CDF холодных запусков](../results/extended-demo/cold-start-cdf.png).
- [CDF холодных запусков по runtime](../results/extended-demo/cold-start-by-runtime.png).
- [CDF длительности запросов](../results/extended-demo/request-duration-cdf.png): показатель `totalCost_worker`, не длительность cold start.

Если сделать всё правильно, то должны получиться точно такие же графики, как в репозитории.
