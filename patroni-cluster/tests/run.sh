#!/bin/bash
# Запуск тестов репликации с формированием отчётов (pytest + HTML/Allure).
set -e

REPORTS_DIR="${REPORTS_DIR:-/reports}"
mkdir -p "$REPORTS_DIR"

ALLURE_DIR="$REPORTS_DIR/allure-results"
HTML_REPORT="$REPORTS_DIR/report.html"
JSON_REPORT="$REPORTS_DIR/results.json"

rm -rf "$ALLURE_DIR"
mkdir -p "$ALLURE_DIR"

ARGS=(--alluredir="$ALLURE_DIR" --html="$HTML_REPORT" --self-contained-html)
if [ -n "${EXTRA_PYTEST_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  ARGS+=($EXTRA_PYTEST_ARGS)
fi

# shellcheck disable=SC2086
pytest "${ARGS[@]}" -p no:cacheprovider "$@"

# JSON-копия результатов для последующей обработки
python - <<'PY'
import json, glob, os
res = []
for f in glob.glob(os.path.join(os.environ.get('REPORTS_DIR','/reports'),'allure-results','*-result.json')):
    try:
        with open(f, encoding='utf-8') as fh:
            res.append(json.load(fh))
    except Exception:
        pass
with open(os.path.join(os.environ.get('REPORTS_DIR','/reports'),'results.json'),'w',encoding='utf-8') as fh:
    json.dump(res, fh, ensure_ascii=False, indent=2)
print(f"[REPORT] Allure-результаты: {os.environ.get('REPORTS_DIR','/reports')}/allure-results")
print(f"[REPORT] HTML-отчёт: {os.environ.get('REPORTS_DIR','/reports')}/report.html")
print(f"[REPORT] JSON-результаты: {os.environ.get('REPORTS_DIR','/reports')}/results.json")
PY
