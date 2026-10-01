# Third party notices

Polycop is distributed under the GNU General Public License version 3 or
later. It ships the components below, each under its own licence. The full
licence texts are in `App/Polycop/Resources/Licenses/` and inside the app, in
`Contents/Resources/Licenses/`.

## whisper.cpp

Copyright (c) 2023-2026 The ggml authors. MIT License
(`whisper.cpp-MIT.txt`, `ggml-MIT.txt`).

Speech recognition with the Whisper models. Shipped as the official
XCFramework of release b5130 (version 1.9.4), pinned by checksum in
`Packages/WhisperFramework/Package.swift`. It includes ggml.

Source: https://github.com/ggml-org/whisper.cpp

## audio.cpp

Copyright 2026 ShugoAI LLC. Apache License 2.0 (`audio.cpp-Apache-2.0.txt`).

Speech recognition with Qwen3-ASR, MOSS-Transcribe-Diarize and Voxtral
Realtime. Built by `Tools/build-audiocpp.sh` from the unmodified v0.8.1 source,
commit f2b4937306daa25f5c78520f3c626ed31495a37a, with only those three model
families. The framework contains:

| Component | Copyright | Licence | Text |
|---|---|---|---|
| ggml | The ggml authors | MIT | `ggml-MIT.txt` |
| BPE tokenizer from llama.cpp | The ggml authors | MIT | `llama.cpp-MIT.txt` |
| SentencePiece | Google | Apache 2.0 | `SentencePiece-Apache-2.0.txt` |
| protobuf-lite, within SentencePiece | Google | BSD 3-Clause | `protobuf-lite-BSD-3-Clause.txt` |
| Abseil, within SentencePiece | The Abseil Authors | Apache 2.0 | `abseil-Apache-2.0.txt` |
| darts-clone, within SentencePiece | Susumu Yata | BSD 2-Clause | `darts-clone-BSD-2-Clause.txt` |
| cJSON | Dave Gamble and cJSON contributors | MIT | `cJSON-MIT.txt` |
| libyaml | Ingy döt Net, Kirill Simonov | MIT | `libyaml-MIT.txt` |

Source: https://github.com/0xShug0/audio.cpp

## FFmpeg

Copyright (c) 2000-2026 the FFmpeg developers. GNU Lesser General Public
License version 2.1 or later (`FFmpeg-LGPL-2.1.txt`).

Audio decoding. The `ffmpeg` executable in `Contents/Helpers` is built by
`Tools/build-ffmpeg.sh` from the unmodified, signature-checked 9.0.2 release,
with a minimal set of demuxers and decoders, no GPL, nonfree or external
library. The script lists every configuration option and checks that the
result reports LGPL version 2.1 or later.

Corresponding source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz, also
included with each release archive together with the build script.

## Silero VAD

Copyright (c) 2020-present Silero Team. MIT License (`Silero-MIT.txt`).

Silence detection. Model version 6.2.0, in the ggml conversion published by the
whisper.cpp project.

Source: https://github.com/snakers4/silero-vad

## Models

Speech recognition models are downloaded by the user from Hugging Face and are
not part of this distribution. Each carries its own licence, shown in the app
before the download starts.
