#!/bin/sh
# Обработчик ссылок cloudcli-open: для Linux - «Показать в проводнике» из CloudCLI.
#
# Регистрирует для текущего пользователя схему ссылок cloudcli-open: (xdg,
# без root) и кладёт рядом маленький скрипт на Python 3. По клику в CloudCLI
# браузер спрашивает, открыть ли приложение, и скрипт переводит путь на сервере
# в папку на этом компьютере и выделяет файл в файловом менеджере. Файлы только
# выделяются, не запускаются. Фоновых процессов нет.
#
# Запуск:   sh install-linux.sh [--from /home/me/work/ --to ~/Nextcloud/work]
#           sh install-linux.sh --uninstall
# Повторный запуск обновляет скрипт, config.json оставляет как есть.
set -eu

DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cloudcli-open"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP="$APPS/cloudcli-open.desktop"
FROM=""
TO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --uninstall)
      rm -rf "$DIR" "$DESKTOP"
      update-desktop-database "$APPS" 2>/dev/null || true
      echo "Удалено."
      exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null || { echo "Нужен python3." >&2; exit 1; }
mkdir -p "$DIR" "$APPS"

if [ -f "$DIR/config.json" ]; then
  echo "config.json уже есть, оставляю: $DIR/config.json"
else
  if [ -z "$FROM" ]; then
    echo "Какая папка на сервере соответствует какой папке на этом компьютере."
    printf "Папка на сервере (как её показывает CloudCLI, например /home/me/work/): "
    read -r FROM
  fi
  if [ -z "$TO" ]; then
    printf "Папка на этом компьютере: "
    read -r TO
  fi
  case "$FROM" in /*) ;; *) echo "Путь на сервере должен начинаться с '/': $FROM" >&2; exit 1 ;; esac
  case "$TO" in "~"*) TO="$HOME${TO#\~}" ;; esac
  [ -d "$TO" ] || { echo "Папки нет: $TO" >&2; exit 1; }
  FROM="$FROM" TO="$TO" python3 -c '
import json, os, sys
from_ = os.environ["FROM"].rstrip("/") + "/"
to = os.path.abspath(os.environ["TO"])
json.dump({"map": [{"from": from_, "to": to}]}, sys.stdout, ensure_ascii=False, indent=2)
' > "$DIR/config.json"
  echo "Записан $DIR/config.json"
fi

cat > "$DIR/reveal.py" <<'PY'
#!/usr/bin/env python3
"""Обработчик ссылок cloudcli-open: - вызывается браузером по клику «Показать в проводнике».

Ставится install-linux.sh из CloudCLI. Настройки - config.json рядом, журнал - log.txt.
"""
import json
import os
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "log.txt")
# Синк может отставать от агента, так что клик может обогнать файл.
WAIT_FOR_FILE_SEC = 5


def log(line):
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1 << 20:
            os.remove(LOG)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
    except OSError:
        pass


def notify(text):
    try:
        subprocess.run(["notify-send", "Показать в проводнике", text], timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def resolve(remote, mapping):
    """Путь на сервере -> (путь здесь, корень) или None, если путь не из настроенных папок."""
    if ".." in remote.split("/"):
        return None
    # Длинный префикс первым: /home/x/nextcloud/work/ должен победить /home/x/nextcloud/.
    for m in sorted(mapping, key=lambda m: len(m["from"]), reverse=True):
        src = m["from"].rstrip("/")
        if remote != src and not remote.startswith(src + "/"):
            continue
        root = os.path.realpath(m["to"])
        full = os.path.normpath(os.path.join(root, remote[len(src):].lstrip("/")))
        if full == root or full.startswith(root + os.sep):
            return full, root
        return None
    return None


def reveal(path):
    # Выделение умеет не каждый менеджер - пробуем через DBus, иначе открываем папку.
    try:
        subprocess.run(
            [
                "dbus-send", "--session", "--print-reply",
                "--dest=org.freedesktop.FileManager1",
                "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1.ShowItems",
                "array:string:file://" + urllib.parse.quote(path),
                "string:",
            ],
            check=True, capture_output=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        folder = path if os.path.isdir(path) else os.path.dirname(path)
        subprocess.Popen(["xdg-open", folder])


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else ""
    prefix = "cloudcli-open:"
    encoded = url[len(prefix):] if url.startswith(prefix) else url
    remote = urllib.parse.unquote(encoded[2:] if encoded.startswith("//") else encoded)
    if not remote.startswith("/"):
        log("bad url " + url)
        notify("Не понял ссылку: " + url)
        return 1

    with open(os.path.join(HERE, "config.json"), encoding="utf-8") as f:
        mapping = json.load(f)["map"]
    loc = resolve(remote, mapping)
    if not loc:
        log("reject " + remote)
        notify("Этот путь не настроен на этом компьютере: " + remote)
        return 1
    full, root = loc

    deadline = time.monotonic() + WAIT_FOR_FILE_SEC
    while not os.path.exists(full) and time.monotonic() < deadline:
        time.sleep(0.5)
    if os.path.exists(full):
        reveal(full)
        log("open " + remote)
        return 0

    folder = os.path.dirname(full)
    while folder.startswith(root) and not os.path.isdir(folder):
        folder = os.path.dirname(folder)
    if folder == root or folder.startswith(root + os.sep):
        reveal(folder)
        log("pending " + remote)
        return 0

    log("no root " + root)
    notify("Папки нет на этом компьютере: " + root)
    return 1


if __name__ == "__main__":
    sys.exit(main())
PY
chmod +x "$DIR/reveal.py"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=CloudCLI - показать в проводнике
Exec=python3 "$DIR/reveal.py" %u
MimeType=x-scheme-handler/cloudcli-open;
NoDisplay=true
Terminal=false
EOF

update-desktop-database "$APPS" 2>/dev/null || true
xdg-mime default cloudcli-open.desktop x-scheme-handler/cloudcli-open

echo
echo "Готово. Дальше:"
echo "1. В CloudCLI: Настройки -> Внешний вид -> «Показать в проводнике» - включить."
echo "2. На ссылке на файл в чате - значок папки; в файловом дереве - правый клик."
echo "3. Первый клик браузер спросит, открыть ли приложение, - разреши."
