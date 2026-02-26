# Pythonの軽量イメージをベースにする
FROM --platform=linux/amd64 python:3.11-slim

# Java (JRE) をコンテナ内にインストールする
RUN apt-get update && \
    apt-get install -y --no-install-recommends default-jre && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ライブラリのインストール
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# コードとJARファイルをコピー
COPY app.py .
COPY bigquery-antipattern-recognition.jar .

# FastAPIサーバーをポート8080で起動
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
