from __future__ import annotations

import tempfile
import json
import importlib
from pathlib import Path
from typing import Any

import soundfile as sf


class _TokenizerOnlyProcessor:
    def __init__(self, tokenizer: Any):
        self.tokenizer = tokenizer


def _normalize_language(language: str) -> str | None:
    if not language:
        return None
    if language.lower() == "auto":
        return "en"
    return language


def _read_duration_seconds(audio_path: str) -> float:
    info = sf.info(audio_path)
    return float(info.duration)


def _normalize_segments(raw_segments: list[Any], default_duration: float) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for item in raw_segments:
        if isinstance(item, dict):
            start = float(item.get("start", item.get("start_time", 0.0)))
            end = float(item.get("end", item.get("end_time", start)))
            text = str(item.get("text", item.get("content", ""))).strip()
        else:
            start = float(getattr(item, "start", getattr(item, "start_time", 0.0)))
            end = float(getattr(item, "end", getattr(item, "end_time", start)))
            text = str(getattr(item, "text", getattr(item, "content", ""))).strip()

        if not text:
            continue
        segments.append({"start": start, "end": end, "text": text})

    if not segments:
        return [{"start": 0.0, "end": default_duration, "text": ""}]

    return segments


def _segments_from_sentences(raw_sentences: list[Any]) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for sentence in raw_sentences:
        start = float(getattr(sentence, "start", 0.0))
        end = float(getattr(sentence, "end", start))
        text = str(getattr(sentence, "text", "")).strip()
        if not text:
            continue
        segments.append({"start": start, "end": end, "text": text})
    return segments


def _transcribe_with_model_generate(audio_path: str, model: str, language: str) -> Any:
    resolved_model = _resolve_model_alias(model)
    from mlx_audio.stt.utils import load_model

    loaded = load_model(resolved_model)
    _ensure_whisper_processor(loaded, resolved_model, strict=False)
    if language and language != "auto":
        try:
            return loaded.generate(audio_path, language=language)
        except TypeError:
            return loaded.generate(audio_path)
    return loaded.generate(audio_path)


def _ensure_whisper_processor(model_obj: Any, model_id: str, strict: bool = False) -> bool:
    if not hasattr(model_obj, "get_tokenizer"):
        return False
    if getattr(model_obj, "_processor", None) is not None:
        return True

    try:
        from huggingface_hub import snapshot_download
        from transformers import AutoTokenizer

        model_path = Path(model_id)
        if not model_path.exists():
            model_path = Path(snapshot_download(repo_id=model_id))
        tokenizer = AutoTokenizer.from_pretrained(str(model_path))
        model_obj._processor = _TokenizerOnlyProcessor(tokenizer)
        return True
    except Exception as exc:
        if strict:
            raise RuntimeError(
                f"Failed to initialize tokenizer for model '{model_id}': {exc}"
            ) from exc
        return False


def _run_generate(model_obj: Any, audio_path: str, language: str) -> Any:
    normalized_language = _normalize_language(language)
    if normalized_language:
        try:
            return model_obj.generate(audio_path, language=normalized_language)
        except TypeError:
            return model_obj.generate(audio_path)
    return model_obj.generate(audio_path)


def _retry_with_forced_tokenizer(audio_path: str, model: str, language: str) -> Any:
    from mlx_audio.stt.utils import load_model

    resolved_model = _resolve_model_alias(model)
    loaded = load_model(resolved_model)
    _ensure_whisper_processor(loaded, resolved_model, strict=True)
    return _run_generate(loaded, audio_path, language)


def _resolve_model_alias(model: str) -> str:
    aliases = {
        "mlx-community/whisper-tiny": "mlx-community/whisper-tiny-asr-fp16",
        "mlx-community/whisper-small": "mlx-community/whisper-small-asr-fp16",
        "mlx-community/whisper-medium": "mlx-community/whisper-medium-asr-fp16",
        "mlx-community/whisper-large-v3-turbo": "mlx-community/whisper-large-v3-turbo-asr-fp16",
    }
    return aliases.get(model, model)


def _load_whisper_model_compat(model: str):
    import mlx.core as mx
    import mlx.nn as nn
    from huggingface_hub import snapshot_download
    from mlx.utils import tree_unflatten
    from mlx_audio.stt.models.whisper.whisper import Model, ModelDimensions

    model_path = Path(_resolve_model_alias(model))
    if not model_path.exists():
        model_path = Path(snapshot_download(repo_id=str(model_path)))

    config = json.loads((model_path / "config.json").read_text())
    config.pop("model_type", None)
    quantization = config.pop("quantization", None)

    allowed_keys = set(ModelDimensions.__annotations__.keys())
    filtered_config = {key: value for key, value in config.items() if key in allowed_keys}
    model_args = ModelDimensions(**filtered_config)

    weights_file = model_path / "weights.safetensors"
    if not weights_file.exists():
        weights_file = model_path / "weights.npz"
    weights = mx.load(str(weights_file))

    loaded = Model(model_args, mx.float16)
    if quantization is not None:
        class_predicate = (
            lambda p, m: isinstance(m, (nn.Linear, nn.Embedding))
            and f"{p}.scales" in weights
        )
        nn.quantize(loaded, **quantization, class_predicate=class_predicate)

    loaded.update(tree_unflatten(list(weights.items())))
    mx.eval(loaded.parameters())
    return loaded


def _transcribe_with_generate_module(audio_path: str, model: str) -> Any:
    stt_generate = importlib.import_module("mlx_audio.stt.generate")
    generate_transcription = getattr(stt_generate, "generate_transcription")

    output_stub = str(tempfile.gettempdir() + "/oppy-asr-fallback")
    return generate_transcription(
        model=model,
        audio=audio_path,
        output_path=output_stub,
        format="txt",
        verbose=False,
    )


def transcribe_with_mlx(audio_path: str, model: str, language: str) -> dict[str, Any]:
    duration = _read_duration_seconds(audio_path)
    try:
        raw_result = _transcribe_with_model_generate(audio_path, model, language)
    except Exception as first_error:
        message = str(first_error)
        if "Processor not found" in message:
            raw_result = _retry_with_forced_tokenizer(audio_path, model, language)
        elif "activation_dropout" in message and "whisper" in model.lower():
            loaded = _load_whisper_model_compat(model)
            _ensure_whisper_processor(loaded, _resolve_model_alias(model), strict=False)
            raw_result = _run_generate(loaded, audio_path, language)
        elif "whisper" in model.lower():
            raw_result = _retry_with_forced_tokenizer(audio_path, model, language)
        else:
            raw_result = _transcribe_with_generate_module(audio_path, _resolve_model_alias(model))

    text = ""
    segments: list[dict[str, Any]] = []

    if isinstance(raw_result, dict):
        text = str(raw_result.get("text", "")).strip()
        segments = _normalize_segments(raw_result.get("segments", []), duration)
    else:
        text = str(getattr(raw_result, "text", "")).strip()
        maybe_segments = getattr(raw_result, "segments", None)
        if maybe_segments:
            segments = _normalize_segments(list(maybe_segments), duration)
        elif hasattr(raw_result, "sentences"):
            segments = _segments_from_sentences(list(getattr(raw_result, "sentences")))

    if not segments:
        segments = [{"start": 0.0, "end": duration, "text": text}]

    return {
        "text": text,
        "segments": segments,
        "duration_seconds": duration,
    }
