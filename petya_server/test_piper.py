import subprocess
import sys
import tempfile
import os

MODEL_NAME = "ru_RU-ruslan-medium.onnx"

text = "Привет, как твои дела? Это тестовое сообщение для проверки голоса."

# у этой версии piper нет надёжного способа передать текст через stdin -
# пишем во временный файл и указываем его через -i/--input-file
in_path = tempfile.mktemp(suffix=".txt")
with open(in_path, "w", encoding="utf-8") as f:
    f.write(text)
try:
    subprocess.run(
        [sys.executable, "-m", "piper", "--model", MODEL_NAME, "--input-file", in_path, "--output_file", "test2.wav"],
        check=True,
    )
finally:
    os.remove(in_path)

print("Готово: test2.wav (модель:", MODEL_NAME, ")")
