#!/usr/bin/env bash
set -euo pipefail

demo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
demo_env="${DEMO_ENV_PREFIX:-$demo_root/.conda}"
demo_conda="${CONDA_EXE:-conda}"
demo_archive="$demo_root/data/raw/R5.zip"
demo_data="$demo_root/datasets/cold_start_dataset/cold_start/R5"
demo_url='https://drive.usercontent.google.com/download?id=1ah7nj5fyedMpOeaFgNVA7oMx3815D8BZ&export=download&confirm=t'

if [[ ! -x "$demo_env/bin/python" ]]; then
    if ! command -v "$demo_conda" >/dev/null 2>&1; then
        printf '%s\n' 'Conda is required. Install Miniforge or set CONDA_EXE to your conda executable.' >&2
        exit 1
    fi
    "$demo_conda" env create --prefix "$demo_env" --file "$demo_root/environment.yml" --yes
fi

demo_data_ready() {
    local day filename
    for day in {0..30}; do
        printf -v filename 'day_%02d.csv' "$day"
        [[ -s "$demo_data/$filename" ]] || return 1
    done
}

if demo_data_ready; then
    printf '%s\n' 'Using existing demo data (31 CSV); download and extraction skipped.'
else
    mkdir -p "$(dirname -- "$demo_archive")" "$(dirname -- "$demo_data")"
    if [[ ! -s "$demo_archive" ]]; then
        printf '%s\n' 'Downloading R5.zip...'
        curl --fail --location --retry 2 --output "$demo_archive.part" "$demo_url"
        if ! unzip -tq "$demo_archive.part" >/dev/null; then
            if LC_ALL=C grep -qi 'Quota exceeded' "$demo_archive.part"; then
                printf '%s\n' 'Google Drive download quota exceeded. Try later or place an existing R5.zip in data/raw/.' >&2
            else
                printf '%s\n' 'Download is not a valid ZIP. Download R5.zip manually using the link in nis/results.md.' >&2
            fi
            exit 1
        fi
        mv "$demo_archive.part" "$demo_archive"
    else
        printf '%s\n' 'Using existing R5.zip; download skipped.'
    fi
    unzip -oq "$demo_archive" -d "$(dirname -- "$demo_data")"
    if ! demo_data_ready; then
        printf '%s\n' 'Expected non-empty R5/day_00.csv through R5/day_30.csv after extraction.' >&2
        exit 1
    fi
fi

export PATH="$demo_env/bin:$PATH"
export MPLCONFIGDIR="$demo_root/.cache/matplotlib"
export JUPYTER_CONFIG_DIR="$demo_root/.cache/jupyter/config"
export JUPYTER_RUNTIME_DIR="$demo_root/.cache/jupyter/runtime"
mkdir -p "$MPLCONFIGDIR" "$JUPYTER_CONFIG_DIR" "$JUPYTER_RUNTIME_DIR" "$demo_root/results/demo"

"$demo_env/bin/python" - "$demo_root" <<'PY'
import base64
import copy
import json
from pathlib import Path
import sys

import nbformat
from nbclient import NotebookClient

root = Path(sys.argv[1])
data = root / 'datasets/cold_start_dataset/cold_start/R5'
if {path.name for path in data.glob('*.csv')} != {f'day_{day:02d}.csv' for day in range(31)}:
    raise SystemExit('Expected exactly 31 daily CSV files in the R5 directory.')

path = root / 'src/demo_cold_start.ipynb'
notebook = nbformat.read(path, as_version=4)
for cell in notebook.cells:
    if cell.cell_type == 'code':
        cell.outputs = []
        cell.execution_count = None
        cell.metadata.pop('execution', None)
run = copy.deepcopy(notebook)
run.cells = run.cells[:8]
if sum(cell.cell_type == 'code' for cell in run.cells) != 4:
    raise SystemExit('The author notebook first section has changed; review the selected cells.')
run.cells.append(nbformat.v4.new_code_cell('''
import json
from pathlib import Path

values = df_all_cold_starts['totalCost_cold_start']
summary = {
    'region': 'R5',
    'files': len(filenames_list_i),
    'events': len(df_all_cold_starts),
    'days': int(df_all_cold_starts['day'].nunique()),
    'day_min': int(df_all_cold_starts['day'].min()),
    'day_max': int(df_all_cold_starts['day'].max()),
    'missing_durations': int(values.isna().sum()),
    'negative_durations': int((values < 0).sum()),
    'median_seconds': float(values.median()),
    'p95_seconds': float(values.quantile(0.95)),
}
Path('../results/demo/summary.json').write_text(json.dumps(summary, indent=2) + '\\n')
'''))
print('Running the demo: author notebook first section and summary...', flush=True)
executed = NotebookClient(
    run, timeout=180, kernel_name='python3',
    resources={'metadata': {'path': str(root / 'src')}},
).execute()
images = [
    output['data']['image/png']
    for cell in executed.cells[:8] if cell.cell_type == 'code'
    for output in cell.outputs if 'image/png' in output.get('data', {})
]
if len(images) != 1:
    raise SystemExit('Expected one plot from the author notebook first section.')
(root / 'results/demo/cold-start-cdf.png').write_bytes(base64.b64decode(images[0]))
notebook.cells[:8] = executed.cells[:8]
notebook.metadata['language_info'] = executed.metadata['language_info']
nbformat.write(notebook, path)
summary = json.loads((root / 'results/demo/summary.json').read_text())
print(json.dumps(summary, indent=2))
print('Saved: src/demo_cold_start.ipynb, results/demo/cold-start-cdf.png, results/demo/summary.json')
PY
