# Meeting Notes

A menu bar app for macOS that records a meeting (your mic **and** the other side of
the call), transcribes it, and writes a summary with decisions and action items to
`~/MeetingNotes/`.

No accounts, no cloud storage, no telemetry. Audio and notes never leave this Mac.
The only network traffic is the API calls you explicitly configure — and if you
install whisper.cpp and run Ollama, there are none at all.

---

## Quick start

```bash
./build.sh --install
open "/Applications/Meeting Notes.app"
```

A waveform icon appears in the menu bar. If you can't see it — a crowded or
notched menu bar hides status items silently — **double-click the app again** and a
control window opens with the same buttons. Then:

1. **Grant permissions** — see below. Screen Recording needs an app restart.
2. **Set up transcription** — run `./install-deps.sh` for the offline path, or put an
   API key in `~/MeetingNotes/.env`.
3. **Add an LLM key** for summaries (or run Ollama locally).
4. Click the icon → **Start Recording**. Click **Stop Recording** when the meeting ends.

Check the **Diagnostics…** menu item at any point — it tells you exactly which
permissions, binaries, models and keys the app can see.

---

## Three ways to control it

The menu bar icon is the primary one, but it is never the only one:

| | How |
|---|---|
| **Menu bar** | Click the waveform icon. |
| **Control window** | Double-click the app in `/Applications` while it is already running, or pick *Show Control Window* from the menu. |
| **Global hotkey** | `⌃⌥⌘R` starts and stops recording from any app. Registered through Carbon, so it needs no Accessibility permission. |

The status item deliberately stays icon-only while recording — the elapsed time
goes in the menu and the window rather than the menu bar, because a status item
that grows is the first thing macOS hides when the bar is full.

## Permissions you need to grant

macOS gates both halves of the recording. You will be prompted the first time, but
you can set them up ahead of time in **System Settings › Privacy & Security**.

| Permission | Why | Where |
|---|---|---|
| **Microphone** | Records your voice. | Privacy & Security → Microphone → enable **Meeting Notes** |
| **Screen Recording** | The only way macOS lets an app capture *other apps'* audio — the people on your call. | Privacy & Security → Screen Recording → enable **Meeting Notes** |
| **Notifications** *(optional)* | Tells you when the note is ready. | Notifications → Meeting Notes |

**About Screen Recording:** this sounds heavier than it is. The app configures the
capture at 2×2 pixels with the cursor hidden and only ever reads the audio track —
nothing on your screen is recorded, transmitted or written to disk. Apple simply
files system-audio capture under that permission. If you would rather not grant it,
choose **Record Microphone Only** when prompted, or untick *Capture System Audio* in
the menu; you will get your side of the conversation only.

**Screen Recording needs a restart.** macOS grants it on next launch, not
immediately. After enabling it: quit Meeting Notes from the menu and open it again.

### Stopping the permission prompts

If macOS keeps asking for permissions you have already granted, it is almost always
this: an **ad-hoc signature has no stable identity**, so macOS pins the grant to the
hash of the binary. Check with:

```bash
codesign -d -r- "/Applications/Meeting Notes.app"
# ad-hoc  =>  designated => cdhash H"a059..."   <- changes on every rebuild
```

Every rebuild changes that hash, so every rebuild looks like a different app and
every grant is forgotten. If you are not rebuilding, the grants stick — this only
bites during development.

**The fix: sign with a stable identity.** A self-signed certificate is enough:

```bash
./create-signing-identity.sh
./build.sh --install
tccutil reset ScreenCapture app.local.meetingnotes
tccutil reset Microphone app.local.meetingnotes
```

Then grant the two permissions once more. They stick from then on, because the
designated requirement is now the certificate rather than the binary hash.

If the script's keychain import does not take, make the certificate by hand:
**Keychain Access → Certificate Assistant → Create a Certificate…**, named
`Meeting Notes Local Signing`, Identity Type **Self Signed Root**, Certificate Type
**Code Signing**, left in the **login** keychain.

`build.sh` finds that certificate by name automatically — or set `CODESIGN_IDENTITY`
to use a different one. The designated requirement becomes identity-based, and your
grants then survive every rebuild.

**Clear the stale entries once**, since the old per-hash grants are still lying
around:

```bash
tccutil reset ScreenCapture app.local.meetingnotes
tccutil reset Microphone app.local.meetingnotes
```

Then launch the app and grant each once more.

> Keep only one copy of the app. A second bundle (for example the one in `build/`)
> is a separate identity to macOS, with its own separate permission grants.

---

## Installing dependencies

### Build the app

Xcode Command Line Tools are the only build requirement:

```bash
xcode-select --install   # if you don't have them
./build.sh --install
```

### Option A — fully offline (whisper.cpp)

```bash
./install-deps.sh
```

That installs `whisper-cpp` via Homebrew and downloads `ggml-medium.bin` (~1.5 GB)
to `~/MeetingNotes/models/`. Nothing else to configure — the app finds both on its
own.

To build whisper.cpp by hand instead:

```bash
git clone https://github.com/ggerganov/whisper.cpp ~/whisper.cpp
cd ~/whisper.cpp && cmake -B build && cmake --build build -j --config Release
```

The app checks Homebrew paths, `~/whisper.cpp/build/bin/`, and your `PATH`.

### Option B — hosted Whisper

Skip `install-deps.sh` and put a key in `~/MeetingNotes/.env`:

```
OPENAI_API_KEY=sk-...
# or
GROQ_API_KEY=gsk_...
```

Recordings longer than ten minutes are split automatically, since both APIs cap
uploads at 25 MB.

### Summaries

Add whichever you have to `~/MeetingNotes/.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GROQ_API_KEY=gsk_...
```

Or run [Ollama](https://ollama.com) for summaries that never leave the machine:

```bash
ollama pull llama3.1:8b
```

The app picks up whatever Ollama has installed. Note that a large local model can
take several minutes on a long meeting; an 8B model is usually the better trade.

Test your setup without holding a meeting:

```bash
"/Applications/Meeting Notes.app/Contents/MacOS/MeetingNotes" --test-summary
```

---

## What gets saved

```
~/MeetingNotes/
├── .env                        your configuration
├── models/ggml-medium.bin      the local whisper model
├── 2026-09-22-1430.md          the note
└── 2026-09-22-1430.m4a         the audio, kept next to it
```

Each note looks like this — summary first, full transcript below the divider:

```markdown
# Meeting Notes — Tuesday 22 September 2026 at 14:30

- **Duration:** 41m 12s
- **Audio:** [2026-09-22-1430.m4a](2026-09-22-1430.m4a)
- **Transcribed by:** whisper.cpp (ggml-medium.bin, local)
- **Summarized by:** anthropic/claude-sonnet-5

## Summary
- Billing migration is roughly eighty percent complete…
- (five bullets)

## Decisions
- Cut over on the fourteenth rather than month end, because the load test…

## Action Items
- [ ] **Priya** — fix the PDF renderer (due: Thursday)
- [ ] **Marcus** — write the support briefing (due: Wednesday)

---

## Transcript

Right, let's start. Priya, where are we on the billing migration?…
```

Audio is captured at 16 kHz mono — what whisper wants — then compressed to `.m4a`
after transcription, so an hour of meeting costs about 7 MB instead of 115 MB. Set
`AUDIO_FORMAT=wav` in `.env` to keep the uncompressed original.

---

## Configuration

Everything is optional; the defaults work. Edit via the **Edit .env…** menu item, or
`~/MeetingNotes/.env` directly.

| Key | Default | Meaning |
|---|---|---|
| `NOTES_DIR` | `~/MeetingNotes` | Where notes and audio go |
| `TRANSCRIBE_BACKEND` | `auto` | `auto` \| `local` \| `openai` \| `groq` |
| `WHISPER_BIN` | auto-detected | Path to `whisper-cli` |
| `WHISPER_MODEL` | auto-detected | Path to a `ggml-*.bin` |
| `WHISPER_LANGUAGE` | `auto` | Or `en`, `de`, `fr`, … |
| `WHISPER_THREADS` | cores − 2 | Local transcription threads |
| `LLM_PROVIDER` | `auto` | `anthropic` \| `openai` \| `groq` \| `ollama` \| `none` |
| `LLM_MODEL` | per provider | Overrides the default model. Providers retire names — if a summary fails with a 404, the error lists what your account can actually use. |
| `OLLAMA_HOST` | `http://localhost:11434` | Local LLM endpoint |
| `AUDIO_FORMAT` | `m4a` | `m4a` or `wav` |
| `CAPTURE_SYSTEM_AUDIO` | `true` | Start with system audio on |

`auto` means: transcribe locally if whisper.cpp and a model are present, otherwise
use a key; summarize with Anthropic, then OpenAI, then Groq, then a local Ollama.

---

## Working offline

With whisper.cpp installed and Ollama running, the app makes no network requests at
all. Confirm with **Diagnostics…** — it should report a local whisper binary, a
model, and `ollama` as the summary provider.

If you are offline and a stage fails, the note is still written with everything that
succeeded, and the audio is always kept. A failed transcription leaves you a note
pointing at the recording; a failed summary leaves you the full transcript.

---

## Troubleshooting

**"System audio was not captured" in the note.** Screen Recording isn't granted, or
was granted after launch. Enable it, then quit and reopen the app.

**No menu bar icon.** macOS silently drops status items that do not fit, which bites
hardest on notched displays with a full menu bar. The app is probably running fine —
check with `pgrep -fl "Meeting Notes"`. Use `⌃⌥⌘R`, or double-click the app in
`/Applications` to open the control window, which does not depend on menu bar space.
To get the icon back, quit a menu bar app or two, or run something like
[Ice](https://github.com/jordanbaird/Ice) to manage overflow.

**`⌃⌥⌘R` does nothing.** Another app already owns that combination; the app logs a
line to Console at launch when registration fails. Use the control window instead.

**Transcription says no model found.** Run `./install-deps.sh`, or point
`WHISPER_MODEL` at a `ggml-*.bin` you already have. Diagnostics shows the paths that
were searched.

**Summary is empty or malformed.** Small local models sometimes drop a section. Try
a larger one, or set `LLM_PROVIDER` to a hosted key.

**"does not have that model".** The provider retired that model name. The error
lists the models your account can use — put one in `LLM_MODEL`. To check by hand:
`curl -s -H "Authorization: Bearer $GROQ_API_KEY" https://api.groq.com/openai/v1/models`

**The transcript is one long block.** That's expected — whisper.cpp doesn't do
speaker separation. The summary step is what turns it into something readable.

---

## Development

```bash
swift build -c release
.build/release/MeetingNotes --selftest       # mixer, WAV, splitting, note format
.build/release/MeetingNotes --test-summary   # check the configured LLM
./build.sh                                   # bundle only, into build/
```

Source layout:

| File | Responsibility |
|---|---|
| `AudioRecorder.swift` | ScreenCaptureKit (system) + AVAudioEngine (mic) capture |
| `TimelineMixer.swift` | Merges both sources onto one host-clock timeline |
| `WavWriter.swift` | Streaming WAV output and chunk splitting |
| `Transcriber.swift` | whisper.cpp subprocess, OpenAI/Groq upload |
| `Summarizer.swift` | Anthropic / OpenAI / Groq / Ollama, with map-reduce for long meetings |
| `NoteWriter.swift` | Markdown layout |
| `Pipeline.swift` | Stop → transcribe → summarize → save |
| `AppDelegate.swift` | Menu bar, permissions, alerts |
| `ControlWindow.swift` | The window fallback when the menu bar icon is unreachable |
| `GlobalHotKey.swift` | `⌃⌥⌘R` via Carbon, no Accessibility permission needed |

The two sources arrive on separate threads at different sample rates, so the mixer
places samples by capture timestamp rather than arrival order, and flushes anything
older than two seconds to disk. Memory stays flat regardless of meeting length, and
a source that stalls or never starts (mic-only recording) doesn't block the other.

## Privacy

- No account, no sign-in, no telemetry, no analytics, no crash reporting.
- Audio, transcripts and notes are written only to `~/MeetingNotes/`.
- API keys are read from `~/MeetingNotes/.env` and sent only to the provider they
  belong to.
- The recorder excludes its own process audio, so it never captures itself.
- Uninstalling is `rm -rf "/Applications/Meeting Notes.app"`. Your notes stay put.
