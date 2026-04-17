#!/usr/bin/env python3
"""
mlx-whisper inference wrapper for Standup pipeline.
Outputs JSON segments compatible with the pipeline's expected format.

Usage:
  .venv/bin/python3 scripts/mlx_whisper_infer.py --audio /path/to/audio.wav [--model turbo] [--output segments.json]
"""

import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser(description="mlx-whisper transcription")
    parser.add_argument("--audio", type=str, required=True)
    parser.add_argument("--model", type=str, default="mlx-community/whisper-turbo",
                        help="HuggingFace model path (default: mlx-community/whisper-turbo)")
    parser.add_argument("--language", type=str, default=None,
                        help="Language code (e.g. 'hi', 'en'). None for auto-detect.")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON path (default: stdout)")
    args = parser.parse_args()

    import mlx_whisper

    result = mlx_whisper.transcribe(
        args.audio,
        path_or_hf_repo=args.model,
        language=args.language,
        word_timestamps=False,
        verbose=False,
    )

    segments = []
    for seg in result.get("segments", []):
        text = seg.get("text", "").strip()
        if not text:
            continue
        segments.append({
            "startTime": round(seg["start"], 2),
            "endTime": round(seg["end"], 2),
            "text": text,
        })

    output = json.dumps(segments, ensure_ascii=False, indent=2)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"Wrote {len(segments)} segments to {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
