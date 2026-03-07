FROM --platform=linux/amd64 python:3.11-slim

# Java (JRE) のインストール
RUN apt-get update && \
    apt-get install -y --no-install-recommends default-jre && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# GitHub Actions (Terraform) が直前にダウンロードしたJARをコピー
COPY bigquery-antipattern-recognition.jar .

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
