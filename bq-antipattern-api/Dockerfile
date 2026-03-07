# --- ステージ1: JARファイルの取得 ---
FROM google/cloud-sdk:slim AS fetcher
ARG BUCKET_NAME

RUN gcloud storage cp gs://bigquery-antipattern-recognition-for-bq-analyzer-api-9klp \
    /bigquery-antipattern-recognition.jar . --project=ea-agentspacepj

# Pythonの軽量イメージをベースにする
FROM --platform=linux/amd64 python:3.11-slim

# Java (JRE) をコンテナ内にインストールする
RUN apt-get update && \
    apt-get install -y --no-install-recommends default-jre && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ステージ1からJARファイルをコピー
COPY --from=fetcher /tmp/bigquery-antipattern-recognition.jar .

# ライブラリのインストール
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# コードとJARファイルをコピー
COPY app.py .

# FastAPIサーバーをポート8080で起動
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
