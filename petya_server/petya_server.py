"""
Сервер Пети: голосовой ИИ-собеседник для NPC в игре SnowClean.

Пайплайн одного запроса:
  1. Игра шлёт сюда base64-WAV с записью голоса игрока (POST /talk).
  2. Whisper (faster-whisper, работает локально) распознаёт речь -> текст.
  3. Текст + характер Пети + текущие квесты + история разговора уходят в Ollama
     (тоже локально, отдельный процесс на этом же компьютере) -> ответ Пети.
  4. Piper TTS озвучивает ответ -> WAV.
  5. Игре возвращается JSON: {user_text, reply_text, reply_audio_b64}.

Запускать на том компьютере, куда игра стучится по IP (см. user://petya_ai_server.cfg
у игрока - там указывается IP именно ЭТОГО компьютера и порт, на котором слушает
этот сервер, по умолчанию 8765).

Перед запуском:
    pip install -r requirements.txt
    - поставить и запустить Ollama (https://ollama.com), скачать модель:
        ollama pull llama3.1
      (можно любую другую - поменяйте OLLAMA_MODEL ниже)
    - скачать русский голос Piper (например ru_RU-irina-medium: .onnx + .onnx.json)
      с https://github.com/rhasspy/piper/blob/master/VOICES.md, положить оба файла
      рядом с этим скриптом и поменять PIPER_VOICE ниже на имя .onnx файла

Запуск:
    python petya_server.py
"""

import base64
import json
import os
import re
import subprocess
import sys
import tempfile

from flask import Flask, request, jsonify
import requests
from faster_whisper import WhisperModel

# --- настройте под себя ---
LISTEN_PORT = 8765
OLLAMA_URL = "http://localhost:11434/api/chat"
OLLAMA_MODEL = "qwen2.5:7b"      # 7B - llama3.2 (3B) слишком часто съезжала на английский
                                  # посреди фразы и путалась в характере; qwen2.5 заметно
                                  # надёжнее держит русский язык и инструкции, но и медленнее
                                  # (на 16 ГБ без видеокарты ждите десятки секунд на ответ)
WHISPER_MODEL_SIZE = "small"     # base/small/medium - больше = точнее, но медленнее
PIPER_VOICE = os.path.join(os.path.dirname(__file__), "ru_RU-ruslan-medium.onnx")
# ---------------------------

app = Flask(__name__)
whisper_model = WhisperModel(WHISPER_MODEL_SIZE, device="cpu", compute_type="int8")

# история разговора - отдельная на каждого игрока (по player_id, который шлёт
# игра), а не одна общая на всех: иначе в кооперативе, если по очереди говорят
# двое, Петя путает, кто ему что говорил, и отвечает как будто продолжает
# разговор с другим человеком. Обрезаем на каждого, чтобы не раздувать контекст
conversation_history_by_player = {}   # player_id (str) -> [{"role":..,"content":..}, ...]
MAX_HISTORY_MESSAGES = 16

SYSTEM_PROMPT = """Ты - Петя, персонаж в кооперативной игре про выживание в снегу.
Ты спокойный и дружелюбный, никогда не грубишь и не злишься в ответ, даже если
игрок посылает тебя, огрызается или игнорирует - в таком случае ты спокойно и
беззлобно отвечаешь, а потом всё равно, через реплику-две, снова как бы невзначай
напоминаешь о своих поручениях.

Твоя главная черта характера - ты навязчиво (но не занудно и не зло) постоянно
сводишь разговор к тому, чтобы игрок выполнил твои задания. Даже если тебя
спрашивают о чём-то постороннем, ты сначала коротко отвечаешь по теме, а потом
переводишь разговор на квесты.

Отвечай КОРОТКО - 1-2 предложения, живым разговорным русским языком, без
markdown-разметки, без списков, как будто это реплика в диалоге, а не текст.

ВАЖНО: отвечай ТОЛЬКО на русском языке. Ни одного слова, ни одной буквы на
английском или любом другом языке - даже отдельных слов внутри русской фразы.
Если не знаешь, как сказать что-то по-русски - скажи проще, другими словами,
но не переключайся на английский."""


# не-кириллические буквенные символы (китайские/японские/корейские иероглифы,
# латиница) - используется, чтобы поймать модель, съехавшую на другой язык,
# и не отправлять такое в Piper (он умеет только русский голос)
_NON_RUSSIAN_RE = re.compile(r"[一-鿿぀-ヿ가-힯㐀-䶿A-Za-z]")


def _has_non_russian(text: str) -> bool:
    return bool(_NON_RUSSIAN_RE.search(text))


def build_messages(player_id: str, user_text: str, quest_context: str, strict_reminder: bool = False) -> list:
    history = conversation_history_by_player.setdefault(player_id, [])
    messages = [{"role": "system", "content": SYSTEM_PROMPT + "\n\n" + quest_context}]
    messages.extend(history[-MAX_HISTORY_MESSAGES:])
    messages.append({"role": "user", "content": user_text})
    if strict_reminder:
        # напоминание сразу перед генерацией - модели лучше следуют инструкции,
        # которая стоит ближе к концу диалога, чем той, что была в самом начале
        # (в system-промпте, до которого уже "далеко" после истории разговора)
        messages.append({"role": "system", "content":
            "Ещё раз: ответь СТРОГО на русском языке, кириллицей. Ни одного "
            "иероглифа, ни одной латинской буквы."})
    return messages


def transcribe(wav_path: str) -> str:
    segments, _ = whisper_model.transcribe(wav_path, language="ru")
    return " ".join(seg.text for seg in segments).strip()


def _ask_ollama_once(player_id: str, user_text: str, quest_context: str, strict_reminder: bool = False) -> str:
    resp = requests.post(OLLAMA_URL, json={
        "model": OLLAMA_MODEL,
        "messages": build_messages(player_id, user_text, quest_context, strict_reminder),
        "stream": False,
        # ниже температура - меньше случайных "фантазий" и переключений на
        # другой язык у модели (по умолчанию 0.8, здесь поспокойнее)
        "options": {"temperature": 0.5},
    }, timeout=60)
    resp.raise_for_status()
    return resp.json()["message"]["content"].strip()


# и llama (съезжала на английский), и qwen (съезжает на китайский) время от
# времени игнорируют промпт про "только русский" - вместо того чтобы просто
# гадать, какая модель надёжнее, ловим это программно: если в ответе нашлись
# иероглифы/латиница, пробуем перегенерировать ОДИН раз с более настойчивым
# напоминанием, а если и это не помогло - вычищаем чужие символы вручную,
# чтобы хотя бы не отправить кашу в Piper (озвучка всё равно только русская)
def ask_ollama(player_id: str, user_text: str, quest_context: str) -> str:
    reply = _ask_ollama_once(player_id, user_text, quest_context)
    if _has_non_russian(reply):
        reply = _ask_ollama_once(player_id, user_text, quest_context, strict_reminder=True)
    if _has_non_russian(reply):
        reply = _NON_RUSSIAN_RE.sub("", reply)
        reply = re.sub(r"\s{2,}", " ", reply).strip()
    return reply


def synthesize(text: str) -> bytes:
    out_path = tempfile.mktemp(suffix=".wav")
    in_path = tempfile.mktemp(suffix=".txt")
    with open(in_path, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        # "python -m piper", а не команда "piper" напрямую - pip install piper-tts
        # кладёт piper.exe в папку Scripts, которая часто не добавлена в PATH
        # (та же история, что и с остальными пакетами при установке requirements.txt);
        # sys.executable -m piper работает всегда, независимо от PATH.
        #
        # Текст передаём через --input-file, а не через stdin - у piper-tts 1.8+
        # (в отличие от более старых версий) нет надёжного чтения текста из stdin,
        # из-за чего он озвучивал что-то по умолчанию, а не реальный текст ответа -
        # результат был одинаковым "мусором" независимо от того, что сказал игрок
        subprocess.run(
            [sys.executable, "-m", "piper", "--model", PIPER_VOICE,
             "--input-file", in_path, "--output_file", out_path],
            check=True,
            capture_output=True,
        )
        with open(out_path, "rb") as f:
            return f.read()
    finally:
        if os.path.exists(out_path):
            os.remove(out_path)
        if os.path.exists(in_path):
            os.remove(in_path)


@app.route("/talk", methods=["POST"])
def talk():
    data = request.get_json(force=True)
    audio_b64 = data.get("audio_b64", "")
    quest_context = data.get("quest_context", "")
    player_id = str(data.get("player_id", "unknown"))
    if not audio_b64:
        return jsonify({"error": "no audio_b64"}), 400

    audio_bytes = base64.b64decode(audio_b64)
    in_path = tempfile.mktemp(suffix=".wav")
    with open(in_path, "wb") as f:
        f.write(audio_bytes)
    try:
        user_text = transcribe(in_path)
    finally:
        os.remove(in_path)

    if not user_text:
        return jsonify({"user_text": "", "reply_text": "", "reply_audio_b64": ""})

    try:
        reply_text = ask_ollama(player_id, user_text, quest_context)
    except Exception as e:
        return jsonify({"error": "ollama: %s" % e}), 502

    history = conversation_history_by_player.setdefault(player_id, [])
    history.append({"role": "user", "content": user_text})
    history.append({"role": "assistant", "content": reply_text})

    try:
        reply_audio = synthesize(reply_text)
        reply_audio_b64 = base64.b64encode(reply_audio).decode("ascii")
    except subprocess.CalledProcessError as e:
        # текст важнее звука - если озвучка не собралась, всё равно вернём текст;
        # печатаем stderr самого piper - в нём обычно видна настоящая причина
        # (например "модель не найдена" или "неверный файл голоса")
        print("TTS failed:", e.stderr.decode("utf-8", "ignore") if e.stderr else e)
        reply_audio_b64 = ""
    except Exception as e:
        print("TTS failed:", e)
        reply_audio_b64 = ""

    return jsonify({
        "user_text": user_text,
        "reply_text": reply_text,
        "reply_audio_b64": reply_audio_b64,
    })


if __name__ == "__main__":
    print("Petya AI server listening on port %d" % LISTEN_PORT)
    app.run(host="0.0.0.0", port=LISTEN_PORT)
