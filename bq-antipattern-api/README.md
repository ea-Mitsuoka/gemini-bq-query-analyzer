# BigQuery Anti-pattern Analyzer API

## 📌 概要
`bq-antipattern-api` は、Google Cloud 公式のOSSツールである [bigquery-antipattern-recognition](https://github.com/GoogleCloudPlatform/bigquery-antipattern-recognition) をラップし、REST APIとして提供するマイクロサービスです。

BigQueryのSQLクエリを受け取り、AST（構文木）解析によってBigQuery特有のアンチパターン（パフォーマンス低下やコスト増大の要因）を検出し、その結果をスッキリとしたJSON形式で返却します。
SaaS型の自動SQL監査基盤において、**「構文解析エンジン」**の役割を担います。

## 🏗 アーキテクチャ設計の意図
公式ツールはJavaで実装されており、通常はCLIツールとして実行されますが、本システムでは以下の理由からPython (FastAPI) でAPI化（Cloud Run化）しています。
* **オーケストレーションの分離**: 抽出・AI生成（Cloud Run A）と構文解析（Cloud Run B）を疎結合にし、各コンポーネントのスケールと保守を容易にするため。
* **JVM起動ロスの隠蔽**: FastAPIの裏側でJavaプロセスを起動することで、呼び出し元から扱いやすい標準的なHTTP APIとして振る舞わせるため。
* **テキストのノイズ除去**: Javaが吐き出す大量の実行ログから、Pythonの正規表現を用いて「必要な改善推奨事項（Recommendations）」のみを抽出してAIへ渡すため。

## 📂 ディレクトリ構成

```text
bq-antipattern-api/
├── app.py               # FastAPIアプリケーション本体
├── Dockerfile           # コンテナビルド設定（マルチアーキテクチャ対応）
├── requirements.txt     # Python依存パッケージ
├── bigquery-antipattern-recognition.jar # [手動配置] 解析エンジンの実体
└── README.md            # 本ドキュメント
```

## 🚀 ローカルでの開発とテスト手順

ローカル環境（Mac/Windows）でテストを行う場合、ZetaSQLライブラリのCPUアーキテクチャ制約（`x86_64` 依存）を回避するため、必ずDockerを使用して `linux/amd64` プラットフォーム上で実行します。

### 1. 準備 (JARファイルのダウンロード)

本リポジトリにはファイルサイズ削減のためJARファイルを含めていません。
公式の [GitHub Releases](https://github.com/GoogleCloudPlatform/bigquery-antipattern-recognition/releases) から最新の `bigquery-antipattern-recognition.jar` をダウンロードし、root/bq-antipattern-api/に配置してください。

### 2. Dockerイメージのビルド

```bash
docker build -t antipattern-api-local .
```

*(※ Dockerfile内で `--platform=linux/amd64` が指定されているため、M1/M2/M3 Macでも自動的にIntelエミュレーション環境が構築されます。)*

### 3. コンテナの起動

```bash
docker run -p 8080:8080 antipattern-api-local
```

### 4. APIのテスト (Swagger UI)

起動後、ブラウザで以下のURLにアクセスすると、FastAPIが自動生成したテストUI画面が開きます。
👉 **[http://localhost:8080/docs](https://www.google.com/search?q=http://localhost:8080/docs)**

`POST /analyze` を展開し、「Try it out」から以下のテストクエリを送信して結果を確認してください。

**テスト用ワーストクエリ:**

```json
{
  "query": "WITH my_cte AS (SELECT * FROM `my_project.my_dataset.raw_data`) SELECT * FROM my_cte AS t1 JOIN my_cte AS t2 ON t1.id = t2.parent_id WHERE t1.id IN (SELECT user_id FROM `my_project.my_dataset.users`) ORDER BY t1.created_at"
}
```

## ☁️ Google Cloud (Cloud Run) へのデプロイ

Google Cloud SDK (`gcloud`) を使用して、ソースコードから直接Cloud Runへデプロイします。

```bash
cd bq-antipattern-api

# デフォルトのサービスアカウント使用
gcloud run deploy bq-antipattern-api \
    --source . \
    --region asia-northeast1 \
    --memory 1Gi \
    --no-allow-unauthenticated

# 指定のサービスアカウント使用
gcloud run deploy bq-antipattern-api \
    --source . \
    --region asia-northeast1 \
    --memory 1Gi \
    --no-allow-unauthenticated \
    --service-account=${SA_EMAIL}
```

* `--source .`: Cloud Buildが自動でDockerfileを解釈し、クラウド上でビルドを行います。
* `--no-allow-unauthenticated`: エンドポイントをパブリックに公開せず、IAM認証を持ったサービス（Gemini Query Analyzer など）からのリクエストのみを許可するセキュアな設定です。

ローカルからデプロイしたサービスへテストコマンドを実行する方法

```bash
# 1. あなたのGoogleアカウントの認証トークンを取得して変数(TOKEN)に格納します
TOKEN=$(gcloud auth print-identity-token)

# 2. curlコマンドを使って、トークン付きで /analyze エンドポイントにPOSTリクエストを送ります
# （あえてアンチパターンである「SELECT *」をテスト用のクエリとして投げてみます）
curl -X POST "<cloud run service url>" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
  "query": "WITH my_cte AS (SELECT * FROM `my_project.my_dataset.raw_data`) SELECT * FROM my_cte AS t1 JOIN my_cte AS t2 ON t1.id = t2.parent_id WHERE t1.id IN (SELECT user_id FROM `my_project.my_dataset.users`) ORDER BY t1.created_at"
}'
```

## 📖 API リファレンス

### `POST /analyze`

提供されたBigQuery SQLを解析し、アンチパターンを返します。

**Request Body (`application/json`)**
| パラメータ | 型 | 説明 |
| :--- | :--- | :--- |
| `query` | `string` | 解析対象のBigQuery SQLクエリ |

**Response (`application/json`)**
| パラメータ | 型 | 説明 |
| :--- | :--- | :--- |
| `status` | `string` | 処理のステータス (`success` またはエラー時) |
| `recommendations` | `string` | 抽出されたアンチパターンのリスト。問題がない場合は `"No anti-patterns found."` が返ります。 |

**レスポンス例:**

```json
{
  "status": "success",
  "recommendations": "Recommendations for query: query provided by cli:\n* SimpleSelectStar: Select * at line 1.\n* OrderByWithoutLimit: ORDER BY clause without LIMIT at line 1."
}
```
