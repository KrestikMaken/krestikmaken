#!/usr/bin/env bash
set -euo pipefail

# ====== НАСТРОЙКИ ПО УМОЛЧАНИЮ ======
WORKDIR="/dev/shm/ocr-translator-$USER"              # быстро: в RAM
TESSDATA_DIR="/usr/share/tesseract-ocr/5/tessdata"   # путь к языкам tesseract
OCR_LANGS="${OCR_LANGS:-eng+rus}"                    # eng | rus | eng+rus | ...
TR_FROM="${TR_FROM:-auto}"                           # язык-источник для translate-shell
TR_TO="${TR_TO:-ru}"                                 # язык назначения

mkdir -p "$WORKDIR"

need() { command -v "$1" >/dev/null 2>&1 || { notify-send "OCR-Translate" "Не найдено: $1"; exit 1; }; }
need tesseract
need trans
need yad
command -v slop >/dev/null 2>&1 || true
command -v maim >/dev/null 2>&1 || true
command -v xdotool >/dev/null 2>&1 || true
command -v xclip >/dev/null 2>&1 || true
command -v gnome-screenshot >/dev/null 2>&1 || true
command -v import >/dev/null 2>&1 || true
command -v xprop >/dev/null 2>&1 || true
command -v xev >/dev/null 2>&1 || true
command -v notify-send >/dev/null 2>&1 || true

# ====== ПАРАМЕТРЫ КОМАНДНОЙ СТРОКИ ======
# --from=xx --to=yy --ocr=aa+bb --ask
for arg in "$@"; do
  case "$arg" in
    --from=*) TR_FROM="${arg#*=}";;
    --to=*)   TR_TO="${arg#*=}";;
    --ocr=*)  OCR_LANGS="${arg#*=}";;
    --ask)    ASK=1;;
    *) ;;
  esac
done

# ====== GUI-выбор языков (по желанию) ======
if [ "${ASK:-0}" -eq 1 ]; then
  SEL=$(yad --form --title="Выбор языков" --separator="|" \
        --field="OCR (eng/rus/eng+rus)":CB "eng|rus|eng+rus|deu|fra|spa|eng+rus" \
        --field="Перевод С (from)":CB "auto|en|ru|de|fr|es|zh|ja|uk|pl|tr" \
        --field="Перевод НА (to)":CB "ru|en|de|fr|es|zh|ja|uk|pl|tr" \
        --button="OK:0" --button="Отмена:1" ) || exit 0
  IFS="|" read -r OCR_LANGS TR_FROM TR_TO <<<"$SEL"
fi

IMG="$WORKDIR/shot.png"
TXT_BASE="$WORKDIR/text"
TXT="$TXT_BASE.txt"
LOG="$WORKDIR/ocr.log"
: > "$LOG"
rm -f "$IMG" "$TXT"

# ====== 1) Выделение области + скриншот ======
SEL="$(slop -f "%x %y %w %h" 2>/dev/null || true)"
if [ -n "$SEL" ]; then
  read -r X Y W H <<<"$SEL"
  if command -v maim >/dev/null 2>&1; then
    maim -g "${W}x${H}+${X}+${Y}" "$IMG"
  else
    import -window root -crop "${W}x${H}+${X}+${Y}" "$IMG"
  fi
  OX=$X; OY=$((Y + H + 8))
else
  gnome-screenshot -a -f "$IMG" || { notify-send "OCR-Translate" "Выделение отменено"; exit 1; }
  if command -v xdotool >/dev/null 2>&1; then
    eval "$(xdotool getmouselocation --shell 2>/dev/null || echo X=200 Y=200)"
    OX=$X; OY=$((Y + 16))
  else
    OX=200; OY=200
  fi
fi
[ -s "$IMG" ] || { notify-send "OCR-Translate" "Скриншот не создан"; exit 1; }

# ====== 2) OCR (tesseract) ======
unset TESSDATA_PREFIX
PSM_USE=6
if [ -n "${W:-}" ] && [ -n "${H:-}" ]; then
  if [ "$H" -lt 60 ] || [ $((W/H)) -gt 8 ]; then PSM_USE=7; fi
fi
tesseract "$IMG" "$TXT_BASE" -l "$OCR_LANGS" --psm "$PSM_USE" \
  --tessdata-dir "$TESSDATA_DIR" -c user_defined_dpi=300 >>"$LOG" 2>&1 || {
  yad --title="OCR-Translate" --button=ok --text="Ошибка OCR.\nСмотри лог:\n$LOG"
  exit 1
}
[ -s "$TXT" ] || { yad --title="OCR-Translate" --button=ok --text="Текст не распознан 😕"; exit 0; }
SRC="$(tr -d '\r' < "$TXT")"

# ====== 3) Перевод ======
TR="$(printf '%s' "$SRC" | trans -e google -b -s "$TR_FROM" -t "$TR_TO" 2>/dev/null || true)"
[ -n "$TR" ] || TR="(перевод пуст)"
command -v xclip >/dev/null 2>&1 && printf '%s' "$TR" | xclip -selection clipboard || true

# ====== 4) Оверлей (yad) с прозрачностью, кнопки, Esc ======
WIDTH=700; HEIGHT=260
GEO="${WIDTH}x${HEIGHT}+${OX}+${OY}"

echo "$TR" | yad --text-info \
  --class=TranslateOverlay \
  --undecorated --skip-taskbar --on-top \
  --geometry="$GEO" --borders=12 \
  --wrap --fontname="Sans Bold 13" \
  --fore=white --back="#202020" \
  --buttons-layout=end \
  --button="Копировать":2 \
  --button="Закрыть (Esc)":0 \
  --title="Перевод" &
PID=$!

# небольшая пауза, найдём id окна и зададим прозрачность
sleep 0.1
WID=$(xdotool search --pid "$PID" | tail -1 2>/dev/null || true)
if [ -n "$WID" ]; then
  OPACITY_HEX=$(printf 0x%x $((0xffffffff * 90 / 100)))   # 90% непрозрачности
  # НЕ меняем тип окна на TOOLTIP, чтобы его можно было фокусировать
  xprop -id "$WID" -f _COMPTON_SHADOW 8u -set _COMPTON_SHADOW 0 >/dev/null 2>&1 || true
  xprop -id "$WID" -f _NET_WM_WINDOW_OPACITY 32c -set _NET_WM_WINDOW_OPACITY "$OPACITY_HEX" >/dev/null 2>&1 || true
  # активируем окно, чтобы Esc работал
  xdotool windowactivate "$WID" 2>/dev/null || true
fi

# просто ждём завершения окна (Esc/кнопка/Alt+F4)
wait "$PID"; RC=$?

# Если нажали "Копировать" (код 2) — кладём перевод в буфер
if [ "${RC:-0}" -eq 2 ] && commandv xclip >/dev/null 2>&1; then
  printf '%s' "$TR" | xclip -selection clipboard
  notify-send "Перевод" "Скопировано в буфер обмена"
fi

exit 0
