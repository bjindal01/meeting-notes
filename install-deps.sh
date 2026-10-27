#!/usr/bin/env bash
# Installs the optional local-transcription stack: whisper.cpp + the medium model.
# Skip this entirely if you only want to use the OpenAI/Groq APIs.
set -euo pipefail

NOTES_DIR="${NOTES_DIR:-$HOME/MeetingNotes}"
MODEL_DIR="$NOTES_DIR/models"
MODEL_NAME="${MODEL_NAME:-ggml-medium.bin}"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"

echo "==> whisper.cpp"
if command -v whisper-cli >/dev/null 2>&1; then
    echo "    already installed: $(command -v whisper-cli)"
elif command -v brew >/dev/null 2>&1; then
    echo "    installing via Homebrew…"
    brew install whisper-cpp
else
    cat <<'MSG'
    Homebrew not found. Either install it from https://brew.sh and re-run this
    script, or build whisper.cpp by hand:

        git clone https://github.com/ggerganov/whisper.cpp ~/whisper.cpp
        cd ~/whisper.cpp && cmake -B build && cmake --build build -j --config Release

    The app looks in ~/whisper.cpp/build/bin/ automatically.
MSG
fi

echo ""
echo "==> Model: $MODEL_NAME (~1.5 GB)"
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "    already present: $MODEL_DIR/$MODEL_NAME"
else
    echo "    downloading to $MODEL_DIR …"
    # -C - resumes a partial download if this script was interrupted.
    curl -L -C - --progress-bar -o "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
fi

echo ""
echo "==> Config"
if [ ! -f "$NOTES_DIR/.env" ]; then
    cp "$(dirname "$0")/.env.example" "$NOTES_DIR/.env"
    echo "    created $NOTES_DIR/.env — add an LLM API key to it for summaries."
else
    echo "    $NOTES_DIR/.env already exists, leaving it alone."
fi

echo ""
echo "Done. Local transcription is ready:"
echo "  binary: $(command -v whisper-cli 2>/dev/null || echo 'not on PATH — see above')"
echo "  model:  $MODEL_DIR/$MODEL_NAME"
