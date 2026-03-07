from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import os
import re
import logging

# --- ロガーの設定 ---
# Cloud Runで時刻、ログレベル（INFO/ERROR等）、メッセージが綺麗に出力されるフォーマット
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s"
)
logger = logging.getLogger(__name__)

app = FastAPI()

class AnalyzeRequest(BaseModel):
    query: str

@app.post("/analyze")
def analyze_query(req: AnalyzeRequest):
    # 長すぎるクエリがログを埋め尽くさないよう、最初の100文字だけログに出す
    short_query = req.query[:100] + ("..." if len(req.query) > 100 else "")
    logger.info(f"Received analysis request. Query: {short_query}")

    jar_path = "bigquery-antipattern-recognition.jar"

    if not os.path.exists(jar_path):
        error_msg = "JAR file not found."
        logger.error(error_msg)
        raise HTTPException(status_code=500, detail=error_msg)

    try:
        logger.info("Executing JAR file...")
        result = subprocess.run(
            ["java", "-jar", jar_path, "--query", req.query],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60
        )

        raw_output = result.stdout

        # Java側の実行がエラー（終了コードが0以外）だった場合のログ
        if result.returncode != 0:
            logger.warning(f"JAR execution returned non-zero exit code: {result.returncode}")

        # 正規表現で「Recommendations for query:」から次の「---」までの部分だけを切り抜く
        recommendations = ""
        match = re.search(r"Recommendations for query:.*?(?=\n-|$)", raw_output, re.DOTALL)

        if match:
            # 見つかった場合はその部分だけを抽出
            recommendations = match.group(0).strip()
            logger.info("Anti-patterns found and extracted successfully.")
        else:
            # 何も指摘がなかった場合
            recommendations = "No anti-patterns found."
            logger.info("No anti-patterns found in the query.")

        return {
            "status": "success",
            "recommendations": recommendations,
        }

    except subprocess.TimeoutExpired:
        logger.error("Analysis timed out after 60 seconds.")
        raise HTTPException(status_code=504, detail="Analysis timed out.")
    except Exception as e:
        # logger.exception() を使うと、エラーのスタックトレースもログに記録してくれます
        logger.exception("An unexpected error occurred during analysis.")
        raise HTTPException(status_code=500, detail=str(e))
