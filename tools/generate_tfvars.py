import os

# スクリプトがあるディレクトリ（root/tools）を取得
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def generate_tfvars(
        env_path=os.path.join(BASE_DIR, '../.env'),
        tfvars_path=os.path.join(BASE_DIR, '../terraform/terraform.tfvars')
):
    """
    .env ファイルを読み込み、Terraform 用の .tfvars ファイルを生成する。
    - キーはすべて小文字に変換（SCREAMING_SNAKE_CASE -> snake_case）
    - 値はすべてダブルクォーテーションで囲む
    - 等号 (=) の位置を自動で揃える
    """
    if not os.path.exists(env_path):
        print(f"エラー: {env_path} が見つかりません。")
        return

    kv_pairs = []
    max_key_len = 0

    with open(env_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            # 空行やコメント行をスキップ
            if not line or line.startswith('#'):
                continue

            # 最初の '=' で分割
            if '=' in line:
                # インラインコメントを除去して分割
                parts = line.split('#')[0].split('=', 1)
                if len(parts) < 2:
                    continue

                key = parts[0].strip().lower() # 小文字化
                value = parts[1].strip().strip('"').strip("'") # 既存の引用符を除去

                kv_pairs.append((key, value))
                if len(key) > max_key_len:
                    max_key_len = len(key)

    # tfvars 形式に整形して書き出し
    with open(tfvars_path, 'w', encoding='utf-8') as f:
        for key, value in kv_pairs:
            # アライメント用のスペースを計算
            padding = " " * (max_key_len - len(key))
            f.write(f'{key}{padding} = "{value}"\n')

    print(f"完了: {tfvars_path} を生成しました。")

if __name__ == "__main__":
    generate_tfvars()
