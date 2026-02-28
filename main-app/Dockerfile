# 軽量なPythonイメージを使用
FROM python:3.11-slim

# 標準出力・標準エラー出力をバッファリングしない設定（ログが即座に出るようにする）
ENV PYTHONUNBUFFERED=1

# 作業ディレクトリの設定
WORKDIR /app

# まず要件ファイルだけコピーしてインストール（キャッシュを効かせるため）
COPY requirements.txt .

# ライブラリのインストール
RUN pip install --no-cache-dir pip==23.3.1 setuptools==68.2.2 && \
	pip install --no-cache-dir -r requirements.txt

# ディレクトリ単位でコピー
COPY src/ ./src/
COPY sql/ ./sql/
COPY prompts/ ./prompts/

# 非rootユーザーで実行
RUN useradd -m appuser
USER appuser

# 実行コマンド
CMD ["python", "src/main.py"]