#!/usr/bin/env bash
set -euo pipefail

extended_demo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
extended_demo_env="${DEMO_ENV_PREFIX:-$extended_demo_root/.conda}"
extended_demo_conda="${CONDA_EXE:-conda}"

command -v curl >/dev/null || { printf '%s\n' 'curl is required.' >&2; exit 1; }
if [[ ! -x "$extended_demo_env/bin/python" ]]; then
    if ! command -v "$extended_demo_conda" >/dev/null 2>&1; then
        printf '%s\n' 'Conda is required. Install Miniforge or set CONDA_EXE.' >&2
        exit 1
    fi
    "$extended_demo_conda" env create --prefix "$extended_demo_env" --file "$extended_demo_root/environment.yml" --yes
fi

export PATH="$extended_demo_env/bin:$PATH"
export DASK_NUM_WORKERS=2
export OMP_NUM_THREADS=2
export OPENBLAS_NUM_THREADS=2

"$extended_demo_env/bin/python" -u - "$extended_demo_root" <<'PY'
import base64
import copy
import csv
import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
import zipfile

import nbformat
from nbclient import NotebookClient

root = Path(sys.argv[1])
source_path = root / 'src/demo_cold_start.ipynb'
output = root / 'results/extended-demo'
source = nbformat.read(source_path, as_version=4)
spans = {1: (0, 8), 2: (8, 33), 3: (33, 45), 5: (52, 81)}
if len(source.cells) != 81 or '## 4. Per request analysis' not in source.cells[45].source:
    raise SystemExit('The author notebook layout has changed; review section boundaries.')
for index, cell in enumerate(source.cells):
    cell.setdefault('id', f'author-{index}')
    cell.metadata['author_cell_index'] = index
    if cell.cell_type == 'code':
        cell.outputs = []
        cell.execution_count = None
        cell.metadata.pop('execution', None)
source.nbformat_minor = 5
for index, before, after in [
    (4, "region_names = ['R5']", "region_names = ['R2']"),
    (54, "region = 'R1'", "region = 'R2'"),
    (71, "region = 'R5'", "region = 'R2'"),
]:
    if before not in source.cells[index].source:
        raise SystemExit(f'Unexpected region assignment in author cell {index}.')
    source.cells[index].source = source.cells[index].source.replace(before, after)
if shutil.disk_usage(root).free < 90 * 1024**3:
    raise SystemExit('The extended demo needs at least 90 GiB free before downloading; temporary data peaks near 70 GiB.')

output.mkdir(parents=True, exist_ok=True)
(root / '.cache').mkdir(exist_ok=True)
metrics = {}
plots = {}
intro = nbformat.v4.new_markdown_cell(
    '# Расширенный запуск авторского notebook\n\n'
    'Запуск: `bash scripts/run_extended_demo.sh`. Разделы 1, 2, 3 и 5 выполняются '
    'в отдельных ядрах на данных R2; изменён только выбор региона. Код раздела 4 исключён. '
    'Временные данные удаляются после запуска; для повторения используйте скрипт.'
)
skipped = nbformat.v4.new_markdown_cell(
    '<a id="perrequest"></a>\n## 4. Пропущен\n\n'
    'Загрузка полного набора запросов в pandas потребовала бы около 100 ГиБ RAM. '
    'Ни одна кодовая ячейка этого раздела не запускается и не включена в этот файл.'
)
probes = {
    1: "{'cold_start_events': len(df_all_cold_starts)}",
    2: "{'request_series_days': int(df_requests['day'].nunique())}",
    3: "{'runtime_metadata_rows': len(df_runtime_triggerType)}",
    5: "{'request_events': int(num_requests), 'histogram_count': int(hist_values.sum()), 'active_functions': len(df_func_counts)}",
}

def save():
    saved = copy.deepcopy(source)
    saved.cells = [intro] + saved.cells[:45] + [skipped] + saved.cells[52:]
    saved.metadata['extended_demo_run'] = {'status': 'completed', 'skipped_sections': [4]}
    nbformat.write(saved, output / 'demo_cold_start.ipynb')
    for filename, contents in plots.items():
        (output / filename).write_bytes(contents)

def download(name, file_id, datasets, work):
    suffix = '.csv' if name == 'runtime_triggerType' else '.zip'
    archive = work / (name + suffix)
    url = f'https://drive.usercontent.google.com/download?id={file_id}&export=download&confirm=t'
    print(f'Downloading {name}...', flush=True)
    subprocess.run([
        'curl', '--fail', '--location', '--retry', '3', '--retry-delay', '5',
        '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '90',
        '--silent', '--show-error', '--output', str(archive), url,
    ], check=True)
    if suffix == '.csv':
        with archive.open() as stream:
            columns = next(csv.reader(stream))
        if not {'funcID', 'runtime'} <= set(columns):
            raise RuntimeError(f'{name}: response is not the expected metadata CSV.')
        destination = datasets / 'runtime_triggerType/df_funcID_runtime_triggerType.csv'
        destination.parent.mkdir(parents=True, exist_ok=True)
        archive.replace(destination)
        file_count = 1
    else:
        if not zipfile.is_zipfile(archive):
            with archive.open('rb') as stream:
                response = stream.read(8192)
            if b'Quota exceeded' in response:
                raise RuntimeError(f'Google Drive: Quota exceeded for {name}. Try again later: {url}')
            raise RuntimeError(f'{name}: response is not a ZIP; check Google Drive availability: {url}')
        with zipfile.ZipFile(archive) as zipped:
            entries = [entry for entry in zipped.infolist() if not entry.is_dir()]
            for entry in entries:
                member = PurePosixPath(entry.filename)
                if member.is_absolute() or '..' in member.parts or member.suffix != '.csv':
                    raise RuntimeError(f'Unexpected archive entry: {entry.filename}')
                if name.startswith('requests_part_'):
                    destination = datasets / 'per_request/R2' / member.name
                else:
                    if member.parts[0] != 'R2':
                        raise RuntimeError(f'Unexpected region: {entry.filename}')
                    destination = datasets / name / Path(*member.parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                with zipped.open(entry) as source_file, destination.open('xb') as target:
                    shutil.copyfileobj(source_file, target, 4 * 1024**2)
            file_count = len(entries)
        archive.unlink()
    print(f'Ready {name}: {file_count} CSV; archive removed.', flush=True)

def execute(section, work):
    first, last = spans[section]
    notebook = copy.deepcopy(source)
    notebook.cells = notebook.cells[first:last]
    notebook.cells.append(nbformat.v4.new_code_cell(f'import json\nprint(json.dumps({probes[section]}))'))
    section_started = time.monotonic()
    def progress(cell, cell_index):
        if cell.cell_type == 'code':
            label = first + cell_index if cell_index < last - first else 'summary'
            print(f'Section {section}, cell {label}', flush=True)
    NotebookClient(
        notebook, timeout=1800, startup_timeout=120, kernel_name='python3',
        resources={'metadata': {'path': str(work / 'src')}}, on_cell_start=progress,
    ).execute()
    text = ''.join(o.get('text', '') for o in notebook.cells[-1].outputs)
    metrics.update(json.loads(text))
    source.cells[first:last] = notebook.cells[:-1]
    for index, filename in {7: 'cold-start-cdf.png', 44: 'cold-start-by-runtime.png', 65: 'request-duration-cdf.png'}.items():
        if first <= index < last:
            images = [o['data']['image/png'] for o in source.cells[index].outputs if 'image/png' in o.get('data', {})]
            if len(images) != 1:
                raise RuntimeError(f'Expected one plot in author cell {index}.')
            plots[filename] = base64.b64decode(images[0])
    print(f'Section {section} completed in {time.monotonic() - section_started:.2f} s.', flush=True)

work = None
try:
    with TemporaryDirectory(prefix='extended-demo-', dir=root / '.cache') as temporary:
        work = Path(temporary)
        (work / 'src').mkdir()
        datasets = work / 'datasets/cold_start_dataset'
        for variable, name in [('MPLCONFIGDIR', 'matplotlib'), ('JUPYTER_CONFIG_DIR', 'jupyter/config'), ('JUPYTER_RUNTIME_DIR', 'jupyter/runtime')]:
            directory = work / name
            directory.mkdir(parents=True, exist_ok=True)
            os.environ[variable] = str(directory)
        download('cold_start', '1qjnBBH_yEOnxAG5vFPQwx6xyITZrrP8L', datasets, work)
        if len(list((datasets / 'cold_start/R2').glob('*.csv'))) != 31:
            raise RuntimeError('Expected 31 cold-start CSV files.')
        execute(1, work)
        download('quantiles', '1iZk-n_5IT7j3M_pHpRzhwSPTuJ2vxvlR', datasets, work)
        execute(2, work)
        shutil.rmtree(datasets / 'quantiles')
        download('runtime_triggerType', '1dUg_yxeLR5OyldivPZGW5djYF31166EG', datasets, work)
        execute(3, work)
        shutil.rmtree(datasets / 'cold_start')
        shutil.rmtree(datasets / 'runtime_triggerType')
        request_ids = [
            '1clZwg5z6vAIF38K3NSkAxuzASsa5GN4B', '1S-MpmXdRSxiADKMXKlDnVdHM5Hlw2cKv',
            '1o4_KES_thVoC-P98uneeVbGrQH1G3VqM', '1jcFk5XBhmkwiz9EH8c69WW0BGDJ1UFeQ',
            '1PqeJp9DrpkD3UHHbvizPOCfNGptpRgBI', '1eT9n9yQZUeKFAyIblS0ks1XqQ_g2OJZl',
            '1SG7tHcuflIE-EE8AoAp99aMVqEF0vJL8', '1mCFakKPn8crcNrzFjmBttIJY7-TW3c3r',
            '1lW4N3SrN_z5BgjkHjU2QtDolROs8YhP5', '1TBD_1GysKZyGUaFll0qUz5FPR1gVjX0B',
        ]
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(download, f'requests_part_{i:02d}', file_id, datasets, work) for i, file_id in enumerate(request_ids, 1)]
            for future in futures:
                future.result()
        if len(list((datasets / 'per_request/R2').glob('*.csv'))) != 200:
            raise RuntimeError('Expected 200 per-request CSV files.')
        execute(5, work)
        expected = {'cold_start_events': 2072823, 'request_events': 321345210, 'histogram_count': 321345210, 'active_functions': 1612}
        if any(metrics.get(key) != value for key, value in expected.items()):
            raise RuntimeError(f'Counts differ from the previous extended demo run: {metrics}')
finally:
    print(f'Temporary extended demo data removed: {work is None or not work.exists()}', flush=True)

save()
for name, value in metrics.items():
    print(f'{name}: {value}')
print('Saved results/extended-demo/demo_cold_start.ipynb and three PNG plots.')
PY
